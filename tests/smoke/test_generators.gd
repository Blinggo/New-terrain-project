extends RefCounted
## tests/smoke/test_generators.gd
##
## S4 - Every generator backend really produces 3D blocky terrain, and produces what we claim
## it produces. Everything here is measured from generated voxels, not assumed from docs.
##
## M01-fix rewrite. Two defects in the M01 version of this file, both of which made it report
## LESS than it appeared to:
##   1. It called `generate_block()` on every backend. The native multipass class implements
##      that as "Not implemented" (measured: it does not even route to
##      `_generate_block_fallback`), so the buffer stayed all-air and the seed-sensitivity check
##      compared two empty columns and called them identical.
##   2. It asked every backend for `get_main_function()`, which only a VoxelGeneratorGraph has.
##      On the modular backends that is a runtime error, and a GDScript function that aborts
##      returns an EMPTY value for its declared return type - so `_adapter_checks()` returned an
##      empty Array and every S4 check for those two backends vanished from the report without
##      a single FAIL. S4z now asserts coverage per backend, because "no results" and "all
##      results passed" look identical in a summary table.
## Sampling therefore dispatches on ChunkHasher.source_kind(): "column" backends are read
## through debug_column_memory(), "block" backends through generate_block().

const SUITE := "smoke"
const BLOCK := 16
const ROWS := 24  # 384 / 16

## Surface sampling grid (per side). Columns are 64 blocks apart, i.e. different regions.
const SAMPLE_GRID := 6

var _cfg: WorldConfig = null


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	_cfg = WorldConfig.load_config()

	for id in AdapterRegistry.ids():
		out.append_array(_adapter_checks(id))

	out.append(_registry_checks())
	out.append(_seed_sensitivity())
	out.append(_recommendation_evidence())
	out.append_array(_coverage_checks(out))
	return out


# --- per-backend checks --------------------------------------------------------------------

func _adapter_checks(id: String) -> Array:
	var out: Array = []
	var built: Dictionary = AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
	if not built["ok"]:
		out.append(TestHarness.fail(SUITE, "S4/%s" % id, "adapter '%s' failed to build" % id, str(built["report"])))
		return out
	var gen: Resource = built["generator"]
	var report: Dictionary = built["report"]
	var kind := ChunkHasher.source_kind(gen)
	var caps := AdapterRegistry.capabilities(id)

	# --- S4a: the class the backend really is, and the entry point that goes with it --------
	var cls := gen.get_class()
	var class_ok := _class_matches(id, cls)
	var entry_ok := (kind == "column" and gen.has_method("debug_column_memory")) \
		or (kind == "block" and gen.has_method("generate_block"))
	var legacy_flag := bool(caps.get("legacy", false))
	var flag_ok := (legacy_flag and kind == "block") or (not legacy_flag and kind == "column")
	out.append(TestHarness.result(SUITE, "S4a/%s" % id,
		"PASS" if class_ok and entry_ok and flag_ok else "FAIL",
		"'%s' builds a %s and exposes the %s entry point its capabilities claim" % [id, cls, kind],
		"class=%s expected=%s\nsource_kind=%s entry point present=%s\ncapabilities.legacy=%s (must agree with the entry point)=%s\nlabel=%s" % [
			cls, _expected_class(id), kind, str(entry_ok), str(legacy_flag), str(flag_ok), String(caps.get("label", "?"))]))

	# --- S4b: what makes this backend trustworthy -----------------------------------------
	if kind == "column":
		var plan: Dictionary = report.get("plan", {})
		var plan_ok := not plan.is_empty() and int(plan.get("pass_count", 0)) >= 1 \
			and (plan.get("errors", []) as Array).is_empty()
		var pipe: Array = report.get("pipeline", [])
		out.append(TestHarness.result(SUITE, "S4b/%s" % id, "PASS" if plan_ok and not pipe.is_empty() else "FAIL",
			"%s compiled a pass plan from the resolved pipeline" % id,
			"plan=%s\nresolved pipeline=%d modules\nnoise recipe=%s\ncolumn_factor=%s" % [
				str(plan), pipe.size(), String(report.get("noise_recipe", "?")), str(report.get("column_factor"))]))
	elif id == "noise2d":
		var channel: int = int(gen.get("channel"))
		out.append(TestHarness.result(SUITE, "S4b/noise2d", "PASS" if channel == VoxelBuffer.CHANNEL_TYPE else "FAIL",
			"noise2d writes the TYPE channel (required by the blocky mesher)",
			"channel=%d (CHANNEL_TYPE=%d)" % [channel, VoxelBuffer.CHANNEL_TYPE]))
	else:
		var compile_ok: bool = bool(report.get("compile_result", {}).get("success", false))
		out.append(TestHarness.result(SUITE, "S4b/graph", "PASS" if compile_ok else "FAIL",
			"graph compiles in code", "compile()=%s" % str(report.get("compile_result"))))

		# Every named node must be findable later (T5: "name your nodes so they can be found").
		var fn: Variant = gen.call("get_main_function")
		var names: Dictionary = report.get("node_ids", {})
		var missing: Array[String] = []
		for key in names:
			if fn.call("find_node_by_name", StringName(String(key))) == 0:
				missing.append(String(key))
		out.append(TestHarness.result(SUITE, "S4c/graph", "PASS" if missing.is_empty() else "FAIL",
			"all %d graph nodes are findable by name" % names.size(),
			"missing=%s" % str(missing) if not missing.is_empty() else "nodes=%s" % str(names.keys())))

		# The OutputType node must be the one bound to id 44, resolved by name.
		var resolved: Dictionary = report.get("node_types_resolved", {})
		out.append(TestHarness.result(SUITE, "S4d/graph",
			"PASS" if int(resolved.get("OutputType", -1)) == 44 else "FAIL",
			"OutputType resolved by name to id 44 (absent from the NodeTypeID enum)",
			"resolved=%s" % str(resolved)))

	# --- S4m: modular backends must EXECUTE every module in the plan (evidence E2) ----------
	if kind == "column":
		out.append(_module_execution_check(id, gen, report))

	# --- terrain shape: sample a grid of columns and measure the surface --------------------
	var samples := _sample_surface(gen, SAMPLE_GRID)
	var heights: Array = samples["heights"]
	var min_h: int = heights[0]
	var max_h: int = heights[0]
	for h_variant in heights:
		var h: int = h_variant
		min_h = mini(min_h, h)
		max_h = maxi(max_h, h)
	var relief := max_h - min_h
	out.append(TestHarness.result(SUITE, "S4e/%s" % id, "PASS" if relief >= 3 else "FAIL",
		"terrain has real 3D relief: surface spans y=%d..%d (%d blocks) over %d columns" % [min_h, max_h, relief, heights.size()],
		"samples=%s" % str(samples["summary"])))

	# Column continuity: every 16-block row STRICTLY BELOW the surface row must be completely
	# solid in this column. Rows at or above the surface are air by design, so they are not
	# counted - the M01 version of this loop had the comparison the other way round and reported
	# the sky as holes.
	var floating := 0
	var rows_checked := 0
	var hole_examples: Array[String] = []
	for col_variant in samples["columns"]:
		var col: Dictionary = col_variant
		var top: int = col["top"]
		if top < _cfg.world_y_min:
			continue
		for row in _rows_below(top):
			rows_checked += 1
			if not bool(col["solid_rows"].get(row, false)):
				floating += 1
				if hole_examples.size() < 4:
					hole_examples.append("row %d (y %d..%d) under a surface at y=%d" % [
						row, _cfg.world_y_min + row * BLOCK, _cfg.world_y_min + row * BLOCK + BLOCK - 1, top])
	out.append(TestHarness.result(SUITE, "S4f/%s" % id, "PASS" if floating == 0 and rows_checked > 0 else "FAIL",
		"columns are solid from the surface down to world_y_min (no floating terrain)",
		"rows checked below the surface=%d holes=%d %s" % [rows_checked, floating, str(hole_examples)]))

	# Voxel ids actually written.
	var ids_used: Array = samples["ids"]
	if id == "noise2d":
		# Documented limitation, not a bug: VoxelGeneratorHeightmap hardcodes the value 1.
		out.append(TestHarness.result(SUITE, "S4g/noise2d", "PASS" if ids_used == [0, 1] else "FAIL",
			"noise2d writes only air (0) and voxel id 1 - VoxelGeneratorHeightmap limitation, recorded in the report",
			"ids=%s" % str(ids_used)))
	else:
		# The graph and BOTH modular backends run the same surface rule, so all three must write
		# grass on top and stone below. For the modular backends that is the visible proof that
		# the modules ran at all (E2).
		var has_grass := 1 in ids_used
		var has_stone := 3 in ids_used
		out.append(TestHarness.result(SUITE, "S4g/%s" % id, "PASS" if has_grass and has_stone else "FAIL",
			"%s writes grass (1) on top and stone (3) below" % id,
			"ids=%s" % str(ids_used)))
		var thickness: Array = samples["grass_thickness"]
		var expected := int(_cfg.gen_params.get("grass_depth", 3))
		var measured_ok := thickness.size() > 0 and int(thickness[0]) == expected
		out.append(TestHarness.result(SUITE, "S4h/%s" % id, "PASS" if measured_ok else "FAIL",
			"grass layer is %d blocks thick as configured" % expected,
			"measured thicknesses=%s" % str(thickness)))

	# Nothing outside the world column, and all ids fit the 8-bit TYPE channel we configured.
	out.append(TestHarness.result(SUITE, "S4i/%s" % id,
		"PASS" if samples["out_of_bounds"] == 0 and samples["max_id"] < 256 else "FAIL",
		"no voxels outside y=[%d,%d) and all ids fit the 8-bit TYPE channel" % [_cfg.world_y_min, _cfg.world_y_max],
		"out_of_bounds=%d max_id=%d" % [samples["out_of_bounds"], samples["max_id"]]))

	return out


## The class each backend must build. Kept as a table in the TEST (not in src/) on purpose: the
## adapters stay free of expectations about themselves, and a wrong class here is a real defect.
func _expected_class(id: String) -> String:
	match id:
		"native_cb":
			return "VoxelGeneratorMultipassCB"
		"experimental_columns":
			return "VoxelGeneratorScript"
		"graph":
			return "VoxelGeneratorGraph"
		"noise2d":
			return "VoxelGeneratorNoise2D"
	return "<unknown id>"


func _class_matches(id: String, cls: String) -> bool:
	# A GDScript subclass of an extension class reports the BASE class from get_class(), so the
	# native multipass backend reports VoxelGeneratorMultipassCB and the self-hosted one reports
	# VoxelGeneratorScript. Both are asserted exactly; neither may drift to the other.
	return cls == _expected_class(id)


## S4m: every module in the compiled plan actually executed while generating real columns.
## This is the smoke-level guard for reviewer evidence E2 ("the default backend ignored the
## active modules"): a module that resolves but never runs is a FAIL here, not a curiosity.
func _module_execution_check(id: String, gen: Resource, report: Dictionary) -> Dictionary:
	var planned: Array = []
	var plan: Dictionary = report.get("plan", {})
	for pass_variant in (plan.get("passes", []) as Array):
		var p: Dictionary = pass_variant
		for m in (p.get("modules", []) as Array):
			planned.append(String(m))
	for provider in (plan.get("providers", []) as Array):
		planned.append(String(provider))

	# Generate a handful of columns so every module has had the chance to run.
	for i in 4:
		gen.call("debug_column_memory", Vector3i(i * BLOCK, _cfg.world_y_min, 0))
	var st: Dictionary = gen.call("stats") if gen.has_method("stats") else {}
	var executed: Dictionary = st.get("executed_counts", {})
	var missing: Array[String] = []
	var counts: Array[String] = []
	for m in planned:
		var n := int(executed.get(m, 0))
		counts.append("%s=%d" % [m, n])
		if n == 0:
			missing.append(m)
	var skipped: Dictionary = st.get("skipped", {})
	return TestHarness.result(SUITE, "S4m/%s" % id, "PASS" if missing.is_empty() and not planned.is_empty() else "FAIL",
		"%s executed all %d planned modules while generating columns" % [id, planned.size()],
		"planned=%s\nexecutions=%s\nskipped by quality tier=%s\npipeline_errors=%s\nblackboard_errors=%s" % [
			str(planned), ", ".join(counts), str(skipped),
			str(st.get("pipeline_errors", [])), str(st.get("blackboard_errors", []))])


# --- sampling ------------------------------------------------------------------------------

## Sample a deterministic grid of columns and report the surface profile.
func _sample_surface(gen: Resource, grid: int) -> Dictionary:
	var heights: Array = []
	var columns: Array = []
	var ids := {}
	var out_of_bounds := 0
	var max_id := 0
	var grass_thickness: Array = []
	var summary: Array[String] = []

	for gi in grid:
		for gj in grid:
			var x := (gi - grid / 2) * 64
			var z := (gj - grid / 2) * 64
			var col := _scan_column(gen, x, z)
			heights.append(col["top"])
			columns.append(col)
			for v in col["ids"]:
				ids[int(v)] = true
			max_id = maxi(max_id, int(col["max_id"]))
			out_of_bounds += int(col["out_of_bounds"])
			if int(col["grass_thickness"]) >= 0 and grass_thickness.size() < 6:
				grass_thickness.append(col["grass_thickness"])
			if gi == 0 and gj < 3:
				summary.append("(x=%d,z=%d) top=%d ids=%s" % [x, z, int(col["top"]), str(col["ids"])])

	var id_list: Array = ids.keys()
	id_list.sort()
	return {
		"heights": heights,
		"columns": columns,
		"ids": id_list,
		"max_id": max_id,
		"out_of_bounds": out_of_bounds,
		"grass_thickness": grass_thickness,
		"summary": summary,
	}


## Walk one world column at voxel (x, z) from world_y_min to world_y_max and report the surface
## height, the ids present and how thick the grass layer is. Dispatches on the backend's own
## entry point: "column" backends build the whole column in memory (their generate_block() is
## either unimplemented or a wrapper), "block" backends are asked for one 16^3 block per row.
func _scan_column(gen: Resource, x: int, z: int) -> Dictionary:
	var column_ids: Array = []
	if ChunkHasher.source_kind(gen) == "column":
		var writer: MemoryColumnWriter = gen.call("debug_column_memory", Vector3i(x, _cfg.world_y_min, z))
		if writer == null:
			push_error("test_generators: %s returned no column for (%d, %d)" % [gen.get_class(), x, z])
			return _empty_column()
		for row in ROWS * BLOCK:
			column_ids.append(writer.get_type_world(Vector3i(x, _cfg.world_y_min + row, z)))
	else:
		for row in ROWS:
			var origin := Vector3i(x, _cfg.world_y_min + row * BLOCK, z)
			var format := VoxelFormat.new()
			format.type_depth = VoxelBuffer.DEPTH_8_BIT
			var buf: VoxelBuffer = format.create_buffer(Vector3i(BLOCK, BLOCK, BLOCK))
			gen.call("generate_block", buf, origin, 0)
			var lx := ((x % BLOCK) + BLOCK) % BLOCK
			var lz := ((z % BLOCK) + BLOCK) % BLOCK
			for y in BLOCK:
				column_ids.append(buf.get_voxel(lx, y, lz, VoxelBuffer.CHANNEL_TYPE))
	return _summarise_column(column_ids)


## Row indices strictly below the surface row: the rows that must be completely solid.
func _rows_below(top: int) -> Array:
	var out: Array = []
	var top_row := int(floorf(float(top - _cfg.world_y_min) / float(BLOCK)))
	for row in range(0, top_row):
		out.append(row)
	return out


func _empty_column() -> Dictionary:
	return {
		"top": _cfg.world_y_min - 1, "ids": [], "max_id": 0, "out_of_bounds": 0,
		"solid_rows": {}, "grass_thickness": -1,
	}


## Turn one column's voxel ids (bottom to top) into the measurements the checks assert on.
func _summarise_column(column_ids: Array) -> Dictionary:
	var top := _cfg.world_y_min - 1
	var ids := {}
	var max_id := 0
	var out_of_bounds := 0
	var solid_rows := {}
	for i in column_ids.size():
		var v: int = int(column_ids[i])
		ids[v] = true
		max_id = maxi(max_id, v)
		var world_y := _cfg.world_y_min + i
		if v != 0:
			top = maxi(top, world_y)
			if world_y < _cfg.world_y_min or world_y >= _cfg.world_y_max:
				out_of_bounds += 1
	# A 16-block row is "solid" when EVERY voxel of this column inside it is non-air. Both entry
	# points can answer that for one column; the M01 version read a whole 16x16 block per row,
	# which the column backends cannot do (their generate_block() is not implemented).
	for row in ROWS:
		var row_solid := true
		for y in BLOCK:
			if int(column_ids[row * BLOCK + y]) == 0:
				row_solid = false
				break
		solid_rows[row] = row_solid

	var grass_thickness := -1
	if top >= _cfg.world_y_min:
		var idx := top - _cfg.world_y_min
		var count := 0
		while idx >= 0 and int(column_ids[idx]) == 1:
			count += 1
			idx -= 1
		grass_thickness = count

	return {
		"top": top,
		"ids": ids.keys(),
		"max_id": max_id,
		"out_of_bounds": out_of_bounds,
		"solid_rows": solid_rows,
		"grass_thickness": grass_thickness,
	}


# --- registry / seed / cost ----------------------------------------------------------------

func _registry_checks() -> Dictionary:
	var ids := AdapterRegistry.ids()
	var order_ok := ids == AdapterRegistry.ORDER
	# F3 cycling must visit every id exactly once and wrap, for however many backends exist.
	var seen: Array[String] = []
	var cursor := ids[0]
	var cycle_ok := true
	for _i in ids.size():
		seen.append(cursor)
		cursor = AdapterRegistry.next_id(cursor)
	if seen != ids or cursor != ids[0]:
		cycle_ok = false
	# An unknown id must not produce a generator: try_create() returns null (create() push_errors).
	var unknown: Variant = AdapterRegistry.try_create("does_not_exist")
	var unknown_ok := unknown == null
	# And the default must be a backend that executes modules, else the whole suite is testing a
	# baseline that ignores the module set (E2).
	var default_ok := AdapterRegistry.executes_all_modules(AdapterRegistry.DEFAULT_ID)
	return TestHarness.result(SUITE, "S4j",
		"PASS" if order_ok and cycle_ok and unknown_ok and default_ok else "FAIL",
		"adapter registry exposes %d ids, cycles F3-style over all of them, refuses unknown ids, and defaults to a module-executing backend" % ids.size(),
		"ids=%s\nF3 cycle=%s wraps to %s\nunknown id -> null=%s\ndefault='%s' executes_all_modules=%s\nlegacy ids=%s" % [
			str(ids), str(seen), cursor, str(unknown_ok),
			AdapterRegistry.DEFAULT_ID, str(default_ok), str(AdapterRegistry.LEGACY_IDS)])


func _seed_sensitivity() -> Dictionary:
	## The surface height at a fixed coordinate must move when the seed changes.
	var failures: Array[String] = []
	var evidence: Array[String] = []
	for id in AdapterRegistry.ids():
		var a: Dictionary = AdapterRegistry.build_generator(id, 12345, _cfg.to_gen_context())
		var b: Dictionary = AdapterRegistry.build_generator(id, 54321, _cfg.to_gen_context())
		if not a["ok"] or not b["ok"]:
			failures.append("%s: build failed" % id)
			continue
		var ha: int = _scan_column(a["generator"], 0, 0)["top"]
		var hb: int = _scan_column(b["generator"], 0, 0)["top"]
		evidence.append("%-20s surface y=%d (seed 12345) vs y=%d (seed 54321)" % [id, ha, hb])
		if ha == hb:
			# Not fatal on its own (two seeds could agree at one point), so check a second.
			var ha2: int = _scan_column(a["generator"], 512, -384)["top"]
			var hb2: int = _scan_column(b["generator"], 512, -384)["top"]
			evidence.append("%-20s second column y=%d vs y=%d" % ["", ha2, hb2])
			if ha2 == hb2:
				failures.append("%s: two different seeds produced identical surfaces at two columns" % id)
		# An all-air column means the backend was asked through an entry point it does not
		# implement. That is how M01's version of this check "passed" for the wrong reason.
		if ha < _cfg.world_y_min or hb < _cfg.world_y_min:
			failures.append("%s: a sampled column was entirely air - the wrong entry point was used" % id)
	return TestHarness.result(SUITE, "S4k", "PASS" if failures.is_empty() else "FAIL",
		"the seed visibly changes the terrain for every adapter",
		"\n".join(evidence) if failures.is_empty() else "failures:\n" + "\n".join(failures) + "\n" + "\n".join(evidence))


func _recommendation_evidence() -> Dictionary:
	## Numbers for the report: cost per unit of generation and terrain variety, measured the same
	## way for every backend. Cost lives in bench_generation.gd (B1/B2); this is the smoke-level
	## version, small enough to run inside the suite.
	var lines: Array[String] = []
	for id in AdapterRegistry.ids():
		var built: Dictionary = AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			lines.append("%-20s build failed" % id)
			continue
		var gen: Resource = built["generator"]
		var kind := ChunkHasher.source_kind(gen)
		var t0 := Time.get_ticks_usec()
		var samples := _sample_surface(gen, 3)
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		var units := 9 if kind == "column" else 9 * ROWS
		var heights: Array = samples["heights"]
		var min_h: int = heights[0]
		var max_h: int = heights[0]
		for h_variant in heights:
			min_h = mini(min_h, int(h_variant))
			max_h = maxi(max_h, int(h_variant))
		lines.append("%-20s %d %s in %.1f ms (%.3f ms/%s) relief=%d ids=%s grass=%s" % [
			id, units, "columns" if kind == "column" else "chunks", elapsed,
			elapsed / float(units), "column" if kind == "column" else "chunk",
			max_h - min_h, str(samples["ids"]), str(samples["grass_thickness"])])
	return TestHarness.ok(SUITE, "S4l", "per-backend cost and variety measured identically (report input)", "\n".join(lines))


# --- S4z: coverage -------------------------------------------------------------------------

## A GDScript function that hits a runtime error returns an EMPTY value of its declared return
## type. In M01 that meant `_adapter_checks()` silently returned [] for the two modular
## backends: 15 checks disappeared and the summary still read "0 FAIL". This asserts that every
## backend produced its checks, so a future crash shows up as a failure instead of as silence.
func _coverage_checks(results: Array) -> Array:
	var out: Array = []
	var produced := {}
	for r_variant in results:
		var r: Dictionary = r_variant
		produced[String(r["id"])] = String(r["status"])
	var missing: Array[String] = []
	var per_backend: Array[String] = []
	for id in AdapterRegistry.ids():
		var want := ["S4a/%s" % id, "S4b/%s" % id, "S4e/%s" % id, "S4f/%s" % id, "S4g/%s" % id, "S4i/%s" % id]
		var got: Array[String] = []
		for w in want:
			if not produced.has(w):
				missing.append(w)
			else:
				got.append("%s=%s" % [w, String(produced[w])])
		per_backend.append("%-20s %d/%d checks present: %s" % [id, got.size(), want.size(), ", ".join(got)])
	out.append(TestHarness.result(SUITE, "S4z", "PASS" if missing.is_empty() else "FAIL",
		"every backend produced its S4 checks (a crashing check must not vanish silently)",
		"\n".join(per_backend) + ("\nmissing: %s" % str(missing) if not missing.is_empty() else "")))
	return out
