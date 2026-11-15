extends RefCounted
## tests/smoke/test_generators.gd
##
## S4 - Both generator adapters (T5) really produce 3D blocky terrain, and they produce what
## we claim they produce. Everything here is measured from generated VoxelBuffers, not
## assumed from documentation.

const SUITE := "smoke"
const BLOCK := 16
const ROWS := 24  # 384 / 16

var _cfg: WorldConfig = null


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	_cfg = WorldConfig.load_config()

	for id in AdapterRegistry.ids():
		out.append_array(_adapter_checks(id))

	out.append(_registry_checks())
	out.append(_seed_sensitivity())
	out.append(_recommendation_evidence())
	return out


func _adapter_checks(id: String) -> Array:
	var out: Array = []
	var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
	if not built["ok"]:
		out.append(TestHarness.fail(SUITE, "S4/%s" % id, "adapter '%s' failed to build" % id, str(built["report"])))
		return out
	var gen: Resource = built["generator"]
	var report: Dictionary = built["report"]

	# Class + channel.
	var cls := gen.get_class()
	var expected_class := "VoxelGeneratorNoise2D" if id == "noise2d" else "VoxelGeneratorGraph"
	out.append(TestHarness.result(SUITE, "S4a/%s" % id, "PASS" if cls == expected_class else "FAIL",
		"'%s' builds a %s" % [id, expected_class], "actual class=%s" % cls))

	if id == "noise2d":
		var channel: int = gen.get("channel")
		out.append(TestHarness.result(SUITE, "S4b/noise2d", "PASS" if channel == VoxelBuffer.CHANNEL_TYPE else "FAIL",
			"noise2d writes the TYPE channel (required by the blocky mesher)",
			"channel=%d (CHANNEL_TYPE=%d)" % [channel, VoxelBuffer.CHANNEL_TYPE]))
	else:
		var compile_ok: bool = bool(report.get("compile_result", {}).get("success", false))
		out.append(TestHarness.result(SUITE, "S4b/graph", "PASS" if compile_ok else "FAIL",
			"graph compiles in code", "compile()=%s" % str(report.get("compile_result"))))

		# Every named node must be findable later (T5: "name your nodes so they can be found").
		var fn: VoxelGraphFunction = gen.call("get_main_function")
		var names: Dictionary = report.get("node_ids", {})
		var missing: Array[String] = []
		for key in names:
			var wanted := String(key)
			if fn.find_node_by_name(StringName(wanted)) == 0:
				missing.append(wanted)
		out.append(TestHarness.result(SUITE, "S4c/graph", "PASS" if missing.is_empty() else "FAIL",
			"all %d graph nodes are findable by name" % names.size(),
			"missing=%s" % str(missing) if not missing.is_empty() else "nodes=%s" % str(names.keys())))

		# The OutputType node must be the one bound to id 44, resolved by name.
		var resolved: Dictionary = report.get("node_types_resolved", {})
		out.append(TestHarness.result(SUITE, "S4d/graph",
			"PASS" if int(resolved.get("OutputType", -1)) == 44 else "FAIL",
			"OutputType resolved by name to id 44 (absent from the NodeTypeID enum)",
			"resolved=%s" % str(resolved)))

	# Terrain shape: sample a grid of columns and measure the surface.
	var samples := _sample_surface(gen, 6)
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

	# Column continuity: solid all the way down from the surface (no floating slabs).
	var floating := 0
	for col_variant in samples["columns"]:
		var col: Dictionary = col_variant
		var top: int = col["top"]
		if top < _cfg.world_y_min:
			continue
		# Every block row below the surface must be fully solid.
		for row in _rows_below(top):
			if not bool(col["solid_rows"].get(row, false)):
				floating += 1
	out.append(TestHarness.result(SUITE, "S4f/%s" % id, "PASS" if floating == 0 else "FAIL",
		"columns are solid from the surface down to world_y_min (no floating terrain)",
		"holes=%d" % floating))

	# Voxel ids actually written.
	var ids_used: Array = samples["ids"]
	if id == "graph":
		var has_grass := 1 in ids_used
		var has_stone := 3 in ids_used
		out.append(TestHarness.result(SUITE, "S4g/graph", "PASS" if has_grass and has_stone else "FAIL",
			"graph writes grass (1) on top and stone (3) below",
			"ids=%s" % str(ids_used)))
		# Grass must be exactly grass_depth blocks thick above stone.
		var thickness: Array = samples["grass_thickness"]
		var expected := int(_cfg.gen_params.get("grass_depth", 3))
		out.append(TestHarness.result(SUITE, "S4h/graph",
			"PASS" if thickness.size() > 0 and thickness[0] == expected else "FAIL",
			"grass layer is %d blocks thick as configured" % expected,
			"measured thicknesses=%s" % str(thickness)))
	else:
		# Documented limitation, not a bug: VoxelGeneratorHeightmap hardcodes the value 1.
		out.append(TestHarness.result(SUITE, "S4g/noise2d", "PASS" if ids_used == [0, 1] else "FAIL",
			"noise2d writes only air (0) and voxel id 1 - VoxelGeneratorHeightmap limitation, recorded in the report",
			"ids=%s" % str(ids_used)))

	# Nothing outside the world column, and all ids fit the 8-bit TYPE channel we configured.
	out.append(TestHarness.result(SUITE, "S4i/%s" % id,
		"PASS" if samples["out_of_bounds"] == 0 and samples["max_id"] < 256 else "FAIL",
		"no voxels outside y=[%d,%d) and all ids fit the 8-bit TYPE channel" % [_cfg.world_y_min, _cfg.world_y_max],
		"out_of_bounds=%d max_id=%d" % [samples["out_of_bounds"], samples["max_id"]]))

	return out


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
			max_id = maxi(max_id, col["max_id"])
			out_of_bounds += col["out_of_bounds"]
			if col["grass_thickness"] >= 0 and grass_thickness.size() < 6:
				grass_thickness.append(col["grass_thickness"])
			if gi == 0 and gj < 3:
				summary.append("(x=%d,z=%d) top=%d ids=%s" % [x, z, col["top"], str(col["ids"])])

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


## Walk one column of 16x16x16 blocks from world_y_min to world_y_max at voxel (x, z) and
## report the surface height, the ids present and how thick the grass layer is.
func _scan_column(gen: Resource, x: int, z: int) -> Dictionary:
	var top := _cfg.world_y_min - 1
	var ids := {}
	var max_id := 0
	var out_of_bounds := 0
	var solid_rows := {}
	var column_ids := []
	var grass_thickness := -1

	for row in ROWS:
		var origin := Vector3i(x, _cfg.world_y_min + row * BLOCK, z)
		var format := VoxelFormat.new()
		format.type_depth = VoxelBuffer.DEPTH_8_BIT
		var buf: VoxelBuffer = format.create_buffer(Vector3i(BLOCK, BLOCK, BLOCK))
		gen.call("generate_block", buf, origin, 0)

		var lx := ((x % BLOCK) + BLOCK) % BLOCK
		var lz := ((z % BLOCK) + BLOCK) % BLOCK
		var row_solid := true
		for y in BLOCK:
			var v := buf.get_voxel(lx, y, lz, VoxelBuffer.CHANNEL_TYPE)
			column_ids.append(v)
			ids[v] = true
			max_id = maxi(max_id, v)
			var world_y := origin.y + y
			if v != 0:
				top = maxi(top, world_y)
				if world_y < _cfg.world_y_min or world_y >= _cfg.world_y_max:
					out_of_bounds += 1
			else:
				row_solid = false
		solid_rows[row] = row_solid

	# Grass thickness = how many consecutive id-1 blocks sit directly on top of the surface.
	if top >= _cfg.world_y_min:
		var idx := top - _cfg.world_y_min
		var count := 0
		while idx >= 0 and column_ids[idx] == 1:
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


func _rows_below(top: int) -> Array:
	## Rows strictly below the surface, i.e. rows that must be fully solid.
	var out := []
	var top_row := int(floorf(float(top - _cfg.world_y_min) / float(BLOCK)))
	for row in range(0, top_row):
		out.append(row)
	return out


func _registry_checks() -> Dictionary:
	var ids := AdapterRegistry.ids()
	var order_ok := ids == AdapterRegistry.ORDER
	var cycle := AdapterRegistry.next_id(ids[0])
	var cycle2 := AdapterRegistry.next_id(cycle)
	var cycle3 := AdapterRegistry.next_id(cycle2)
	var cycle_ok := ids.size() == 3 and cycle == ids[1] and cycle2 == ids[2] and cycle3 == ids[0]
	# AdapterRegistry.create() push_error()s on an unknown id, which would pollute the
	# "no errors from our code" evidence for A1. Capture stderr-free by asking for a known
	# bad id through the documented validation entry point instead.
	var unknown := AdapterRegistry.try_create("does_not_exist")
	return TestHarness.result(SUITE, "S4j",
		"PASS" if order_ok and cycle_ok and unknown == null else "FAIL",
		"adapter registry exposes %d ids and cycles F3-style" % ids.size(),
		"ids=%s next(%s)=%s next(%s)=%s next(%s)=%s unknown->null=%s" % [
			str(ids), ids[0], cycle, cycle, cycle2, cycle2, cycle3, str(unknown == null)])


func _seed_sensitivity() -> Dictionary:
	## The surface height at a fixed coordinate must move when the seed changes.
	var failures: Array[String] = []
	var evidence: Array[String] = []
	for id in AdapterRegistry.ids():
		var a := AdapterRegistry.build_generator(id, 12345, _cfg.to_gen_context())
		var b := AdapterRegistry.build_generator(id, 54321, _cfg.to_gen_context())
		if not a["ok"] or not b["ok"]:
			failures.append("%s: build failed" % id)
			continue
		var ha: int = _scan_column(a["generator"], 0, 0)["top"]
		var hb: int = _scan_column(b["generator"], 0, 0)["top"]
		evidence.append("%s: surface y=%d (seed 12345) vs y=%d (seed 54321)" % [id, ha, hb])
		if ha == hb:
			# Not fatal on its own (two seeds could agree at one point), so check a second.
			var ha2: int = _scan_column(a["generator"], 512, -384)["top"]
			var hb2: int = _scan_column(b["generator"], 512, -384)["top"]
			evidence.append("%s: second column y=%d vs y=%d" % [id, ha2, hb2])
			if ha2 == hb2:
				failures.append("%s: two different seeds produced identical surfaces at two columns" % id)
	return TestHarness.result(SUITE, "S4k", "PASS" if failures.is_empty() else "FAIL",
		"the seed visibly changes the terrain for every adapter",
		"\n".join(evidence) if failures.is_empty() else "\n".join(failures))


func _recommendation_evidence() -> Dictionary:
	## Numbers for the report's "which adapter should M01 start from" question: cost per
	## chunk and terrain variety, measured the same way for both adapters.
	var lines: Array[String] = []
	for id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			lines.append("%s: build failed" % id)
			continue
		var t0 := Time.get_ticks_usec()
		var samples := _sample_surface(built["generator"], 3)
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		var chunks := 9 * ROWS
		var heights: Array = samples["heights"]
		var min_h: int = heights[0]
		var max_h: int = heights[0]
		for h_variant in heights:
			min_h = mini(min_h, int(h_variant))
			max_h = maxi(max_h, int(h_variant))
		lines.append("%-8s %d chunks in %.1f ms (%.3f ms/chunk) relief=%d ids=%s grass=%s" % [
			id, chunks, elapsed, elapsed / float(chunks), max_h - min_h, str(samples["ids"]), str(samples["grass_thickness"])])
	return TestHarness.ok(SUITE, "S4l", "per-adapter cost and variety measured identically (report input)", "\n".join(lines))
