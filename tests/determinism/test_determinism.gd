extends RefCounted
## tests/determinism/test_determinism.gd
##
## M00 / T8 - The determinism harness. Runnable headless.
##
##   D1  same seed, two runs IN ONE PROCESS -> identical hashes
##   D2  run in a SECOND PROCESS -> identical to the committed golden file
##   D3  order independence: chunk #40 alone == chunk #40 after #1..#39
##   D4  different seed -> different hashes (proves the seed is actually wired)
##   D5  lint: no banned non-deterministic calls in generation code
##
## tools/run_tests.gd runs D1/D3/D4/D5 in the main process and spawns a genuinely separate
## Godot process for D2, because D2 is meaningless if it shares a process with D1.
##
## Both generator adapters are covered: the golden file has a section per adapter.

const SUITE := "determinism"
const GOLDEN_PATH := "res://tests/determinism/golden_hashes.json"
## M01-fix: the modular backends (the ones that execute the resolved pipeline) have their own
## committed table. Renamed from golden_hashes_multipass.json - see the file's own header.
const GOLDEN_MODULAR_PATH := "res://tests/determinism/golden_hashes_modular.json"
const MODULAR_IDS: Array[String] = ["native_cb", "experimental_columns"]
const BLOCK_SIZE := 16

## Directories that must never contain non-deterministic calls (hard rule #5).
const LINT_DIRS: Array[String] = ["res://src/worldgen", "res://src/adapters", "res://src/core"]
const BANNED: Array[String] = ["randf(", "randi(", "Time.get_", "randomize("]
## Directories exempt from the lint because they are debug/UI, not generation. The lint only
## ever scans LINT_DIRS, so these are documented rather than special-cased in code.
const LINT_EXEMPT_NOTE := "src/runtime/debug and src/runtime/world may use Time.* (HUD timing, screenshot names, F5 seed); they are never scanned."

## Directories that must stay empty in M00 (hard rule #6: do not build later milestones).
const EMPTY_IN_M00: Array[String] = ["res://src/worldgen", "res://src/spine"]

var _cfg: WorldConfig = null


func run(ctx: Dictionary) -> Array:
	var phase := String(ctx.get("phase", "main"))
	_cfg = WorldConfig.load_config()
	var origins := ChunkOrigins.get_origins(_cfg.sea_level)

	if phase == "second_process":
		return [_d2_second_process(origins, ctx)]

	var out: Array = []
	out.append_array(_d1_same_process(origins))
	out.append(_d3_order_independence(origins))
	out.append(_d3b_order_independence_surface(origins))
	out.append(_d4_seed_is_wired(origins))
	out.append_array(_d5_lint())
	out.append(_d5b_empty_layers())
	out.append(_origin_coverage(origins))
	out.append(_hash_table(origins))
	out.append(_d6_graph_parity())
	return out


# --- D6 (M01-fix / T3, evidence E3) ------------------------------------------------------

## The modular backends must reproduce the LEGACY compiled graph EXACTLY - on the 64 committed
## origins plus 256 extra surface-band origins, with neighbour passes disabled.
##
## Why 320 and not 64: of the committed origins only 24 lie in the band where the surface
## varies, and the M01 defect (a spacing-16 region tile read with nearest sampling, so every
## block column in a 16x16 column shared one height) was visible in just 9 of 64. A parity
## claim about "exact per-block height" needs a sample where a plateau cannot hide.
func _d6_graph_parity() -> Dictionary:
	var origins := ChunkOrigins.get_graph_parity_origins(_cfg.sea_level, 256)
	var graph := AdapterRegistry.build_generator("graph", _cfg.seed_value, _cfg.to_gen_context())
	if not graph["ok"]:
		return TestHarness.fail(SUITE, "D6", "the legacy graph baseline failed to build, cannot compare",
			str(graph["report"].get("error", "?")))
	var detail := ChunkHasher.hash_all_detailed(graph["generator"], origins, BLOCK_SIZE, _cfg.type_depth_bits)
	var ref := {}
	var non_uniform := 0
	for rec in detail:
		ref[String(rec["key"])] = String(rec["dec"])
		if not rec["uniform"]:
			non_uniform += 1

	var lines: Array[String] = [
		"origins=%d (%d committed + 256 surface-band); %d contain a terrain surface (non-uniform)" % [
			origins.size(), origins.size() - 256, non_uniform],
		"reference = legacy 'graph' baseline, freshly generated in this process",
		"neighbour passes: disabled (content/modules holds only the two shipped modules; no fixtures installed: %s)" % str(ModuleFixtures.installed()),
	]
	var failed := false
	for id in MODULAR_IDS:
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			failed = true
			lines.append("%s: BUILD FAILED %s" % [id, str(built["report"].get("error", "?"))])
			continue
		var gen_obj: Object = built["generator"]
		if gen_obj.has_method("neighbour_passes_in_plan") and bool(gen_obj.call("neighbour_passes_in_plan")):
			failed = true
			lines.append("%s: plan contains a neighbour pass, so this comparison is not the extent-0 baseline" % id)
		var fresh := ChunkHasher.hash_all(gen_obj, origins, BLOCK_SIZE, _cfg.type_depth_bits)
		var mismatches: Array[String] = []
		for k in ref:
			if String(fresh.get(k, "?")) != String(ref[k]):
				mismatches.append(k)
		if not mismatches.is_empty():
			failed = true
		var executed: Dictionary = gen_obj.call("stats").get("executed_counts", {}) if gen_obj.has_method("stats") else {}
		lines.append("%s: %d/%d identical to the graph; mismatches=%s; modules executed=%s" % [
			id, ref.size() - mismatches.size(), ref.size(),
			str(mismatches.slice(0, 5)), str(executed)])

	return TestHarness.result(SUITE, "D6", "FAIL" if failed else "PASS",
		"modular backends reproduce the legacy compiled graph on %d origins (%d of them surface-bearing)" % [origins.size(), non_uniform],
		"\n".join(lines))


# --- D1 ---------------------------------------------------------------------------------

func _d1_same_process(origins: Array) -> Array:
	var out: Array = []
	for id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			out.append(TestHarness.fail(SUITE, "D1/%s" % id,
				"generator '%s' failed to build, cannot check determinism" % id,
				str(built["report"])))
			continue
		var a := ChunkHasher.hash_all(built["generator"], origins, BLOCK_SIZE, _cfg.type_depth_bits)
		# Second run in the SAME process, with a freshly built generator instance, so this
		# also proves the adapter's construction is itself deterministic.
		var built2 := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		var b := ChunkHasher.hash_all(built2["generator"], origins, BLOCK_SIZE, _cfg.type_depth_bits)
		var diffs := _diff(a, b)
		out.append(TestHarness.result(SUITE, "D1/%s" % id, "PASS" if diffs.is_empty() else "FAIL",
			"%d/%d chunk hashes identical across two runs in one process" % [origins.size() - diffs.size(), origins.size()],
			"first mismatch: %s" % str(diffs[0]) if not diffs.is_empty() else "seed=%d block=%d type_depth=%d-bit" % [_cfg.seed_value, BLOCK_SIZE, _cfg.type_depth_bits]))
	return out


# --- D2 ---------------------------------------------------------------------------------

func _d2_second_process(origins: Array, ctx: Dictionary = {}) -> Dictionary:
	var golden_path := String(ctx.get("golden_path", GOLDEN_PATH))
	var golden := JsonData.load_file(golden_path)
	if golden.is_empty():
		return TestHarness.fail(SUITE, "D2",
			"golden file missing or unreadable: %s" % golden_path,
			"run: godot --headless --path . --script res://tools/make_golden_hashes.gd")

	var res := GoldenCompare.compare(golden, origins, _cfg, ["noise2d", "graph"])
	# X11: the modular backends carry their OWN committed golden set, compared here in the
	# second process exactly like the M00 baselines.
	var mp_path := String(ctx.get("golden_modular_path", GOLDEN_MODULAR_PATH))
	var mp_golden: Dictionary = JsonData.load_file(mp_path)
	if mp_golden.is_empty():
		res["ok"] = false
		res["mismatches"].append("modular golden file missing: %s" % mp_path)
		res["per_gen"].append("modular: no golden file")
	else:
		var mp := GoldenCompare.compare(mp_golden, origins, _cfg, MODULAR_IDS)
		res["checked"] += mp["checked"]
		res["matched"] += mp["matched"]
		res["mismatches"].append_array(mp["mismatches"])
		res["per_gen"].append_array(mp["per_gen"])
		res["ok"] = res["ok"] and mp["ok"]
	return TestHarness.result(SUITE, "D2", "PASS" if res["ok"] else "FAIL",
		GoldenCompare.compose_message(res),
		GoldenCompare.compose_evidence(res, golden_path + " + " + mp_path))


func _environment_matches(golden: Dictionary) -> bool:
	# Not a pass/fail criterion - a hash difference across engine versions is INFORMATION, and
	# recording it here stops us from misreading a genuine engine change as a determinism bug.
	var now := {
		"godot": Engine.get_version_info().get("string"),
		"block_size": BLOCK_SIZE,
	}
	var then := {
		"godot": golden.get("godot"),
		"block_size": golden.get("block_size"),
	}
	return now == then


# --- D3 ---------------------------------------------------------------------------------

func _d3_order_independence(origins: Array) -> Dictionary:
	var id := AdapterRegistry.DEFAULT_ID
	# Also cover the graph adapter, which has an XZ cache and is the more likely place for
	# hidden state to leak between blocks.
	var results: Array[String] = []
	var failed := false
	for gen_id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(gen_id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			failed = true
			results.append("%s: build failed" % gen_id)
			continue
		var target: Vector3i = origins[40]
		var alone := ChunkHasher.hash_one(built["generator"], target, BLOCK_SIZE, _cfg.type_depth_bits)

		# Same generator instance: generate #0..#39 first, then #40 again. Results are
		# discarded on purpose - only the ORDER is being tested.
		var warmed: Resource = built["generator"]
		for i in 40:
			ChunkHasher.hash_one(warmed, origins[i], BLOCK_SIZE, _cfg.type_depth_bits)
		var after := ChunkHasher.hash_one(warmed, target, BLOCK_SIZE, _cfg.type_depth_bits)
		var ok: bool = alone["hash"] == after["hash"]
		if not ok:
			failed = true
		results.append("%s: alone=%s after40=%s %s" % [gen_id, alone["hex"], after["hex"], "MATCH" if ok else "DIFFER"])

	return TestHarness.result(SUITE, "D3", "FAIL" if failed else "PASS",
		"chunk #40 hashes identically alone and after generating #1..#39",
		"origin=%s\n%s" % [ChunkOrigins.origin_to_key(origins[40]), "\n".join(results)])


func _d3b_order_independence_surface(origins: Array) -> Dictionary:
	## Same as D3 but on a SURFACE-BAND chunk, where the data is not uniform. D3 as specified
	## uses origin #40, which in a 384-tall world is usually all-air or all-solid: both
	## generators then hash it identically and the check proves very little. This variant is
	## the one that would actually catch a generator caching state between blocks.
	var target: Vector3i = origins[ChunkOrigins.FIRST_SURFACE_INDEX + 4]
	var lines: Array[String] = []
	var failed := false
	for gen_id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(gen_id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			failed = true
			lines.append("%s: build failed" % gen_id)
			continue
		var alone := ChunkHasher.hash_one(built["generator"], target, BLOCK_SIZE, _cfg.type_depth_bits)
		var warmed: Resource = built["generator"]
		for i in ChunkOrigins.FIRST_SURFACE_INDEX + 24:
			ChunkHasher.hash_one(warmed, origins[i], BLOCK_SIZE, _cfg.type_depth_bits)
		var after := ChunkHasher.hash_one(warmed, target, BLOCK_SIZE, _cfg.type_depth_bits)
		var ok: bool = alone["hash"] == after["hash"]
		if not ok or alone["uniform"]:
			failed = true
		lines.append("%s: alone=%s after24=%s %s uniform=%s non_air=%d/%d" % [
			gen_id, alone["hex"], after["hex"], "MATCH" if ok else "DIFFER",
			str(alone["uniform"]), alone["non_air"], alone["total"],
		])
	return TestHarness.result(SUITE, "D3b", "PASS" if not failed else "FAIL",
		"order independence on a NON-UNIFORM surface-band chunk",
		"origin=%s\n%s" % [ChunkOrigins.origin_to_key(target), "\n".join(lines)])


# --- D4 ---------------------------------------------------------------------------------

func _d4_seed_is_wired(origins: Array) -> Dictionary:
	var failures: Array[String] = []
	var evidence: Array[String] = []
	for id in AdapterRegistry.ids():
		var a := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		var b := AdapterRegistry.build_generator(id, _cfg.seed_value + 1, _cfg.to_gen_context())
		if not a["ok"] or not b["ok"]:
			failures.append("%s: generator build failed" % id)
			continue
		var ha := ChunkHasher.hash_all(a["generator"], origins, BLOCK_SIZE, _cfg.type_depth_bits)
		var hb := ChunkHasher.hash_all(b["generator"], origins, BLOCK_SIZE, _cfg.type_depth_bits)
		var differing := 0
		for k in ha:
			if hb.has(k) and String(ha[k]) != String(hb[k]):
				differing += 1
		evidence.append("%s: %d/%d hashes changed when the seed changed by 1" % [id, differing, origins.size()])
		if differing == 0:
			failures.append("%s: seed %d and %d produced identical terrain - the seed is not wired" % [id, _cfg.seed_value, _cfg.seed_value + 1])

	# The 64 fixed origins are mostly all-air or all-solid chunks in a 384-tall world, so they
	# hash identically for ANY seed. Comparing "changed hashes" over all of them is a weak
	# statistic - measured on this build, FBM with height_amplitude=42 actually produces a
	# surface within only a few blocks of height_base, so even the surface-band rows are
	# usually uniform. The honest test is: of the chunks that DO contain a terrain surface
	# (non-uniform for seed A), how many change when the seed changes? That must be ~all.
	var surface_origins := origins.slice(ChunkOrigins.FIRST_SURFACE_INDEX, ChunkOrigins.FIRST_SURFACE_INDEX + ChunkOrigins.SURFACE_COUNT)
	for id2 in AdapterRegistry.ids():
		var a2 := AdapterRegistry.build_generator(id2, _cfg.seed_value, _cfg.to_gen_context())
		var b2 := AdapterRegistry.build_generator(id2, _cfg.seed_value + 1, _cfg.to_gen_context())
		if not a2["ok"] or not b2["ok"]:
			failures.append("%s: generator build failed (surface band)" % id2)
			continue
		var detail_a := ChunkHasher.hash_all_detailed(a2["generator"], surface_origins, BLOCK_SIZE, _cfg.type_depth_bits)
		var hb := ChunkHasher.hash_all(b2["generator"], surface_origins, BLOCK_SIZE, _cfg.type_depth_bits)

		var straddling := 0
		var differing := 0
		var same_examples: Array[String] = []
		var heights: Array[int] = []
		for rec in detail_a:
			if rec["uniform"]:
				continue
			straddling += 1
			var key: String = rec["key"]
			if String(hb.get(key, "")) != String(rec["dec"]):
				differing += 1
			elif same_examples.size() < 3:
				same_examples.append("%s (non_air %d/%d)" % [key, rec["non_air"], rec["total"]])

		evidence.append("%s: %d/%d surface-band chunks straddle the surface; %d of those changed with seed+1" % [id2, straddling, surface_origins.size(), differing])
		if straddling < 6:
			failures.append("%s: only %d non-uniform chunks in the surface band - the origin set cannot prove seed sensitivity" % [id2, straddling])
		elif differing < int(ceil(straddling * 0.9)):
			failures.append("%s: only %d/%d surface-straddling chunks changed with a new seed (expected >= 90%%)" % [id2, differing, straddling])
			if not same_examples.is_empty():
				evidence.append("   unchanged examples: %s" % str(same_examples))

	return TestHarness.result(SUITE, "D4", "PASS" if failures.is_empty() else "FAIL",
		"a different seed produces different hashes for every adapter",
		"\n".join(evidence) if failures.is_empty() else "\n".join(failures))


# --- D5 ---------------------------------------------------------------------------------

func _d5_lint() -> Array:
	# M01: the lint body moved to src/core/layer_lint.gd so the smoke suite (X9) and this
	# determinism gate share ONE implementation. Directories now include src/spine, and an
	# identifier scan enforces "only src/adapters/ names Voxel Tools classes" (hard rule #2).
	var call_hits: Array = LayerLint.banned_call_hits()
	var id_hits: Array = LayerLint.identifier_hits()
	var scanned := 0
	for dir_path in LayerLint.GEN_DIRS:
		scanned += _count_scripts(dir_path)
	var hits: Array[String] = []
	for h in call_hits:
		hits.append(String(h))
	for h in id_hits:
		hits.append(String(h))

	var out: Array = []
	out.append(TestHarness.result(SUITE, "D5", "PASS" if hits.is_empty() else "FAIL",
		"no banned non-deterministic calls and no Voxel identifiers outside adapters (%d scripts scanned)" % scanned,
		"\n".join(hits) if not hits.is_empty() else "banned calls: %s\nbanned identifiers outside adapters: %s\ndirs: %s\n%s" % [
			str(LayerLint.BANNED_CALLS), str(LayerLint.BANNED_IDENTIFIERS), str(LayerLint.GEN_DIRS), LINT_EXEMPT_NOTE]))
	# X9 is the layering half, reported under its own id so the acceptance table can point
	# at it directly (B10).
	out.append(TestHarness.result(SUITE, "X9", "PASS" if id_hits.is_empty() else "FAIL",
		"layering lint: no Voxel*/ZN_* identifier in core/, spine/, worldgen/",
		"\n".join(id_hits.map(func(h): return String(h))) if not id_hits.is_empty() else "scanned: %s" % str(LayerLint.PURE_DIRS)))
	return out


func _count_scripts(dir_path: String) -> int:
	return LayerLint._list_dir(dir_path).size()


## Remove a trailing # comment so that documentation mentioning randf() cannot fail the lint
## (this file's own comments, and the README rules, must be allowed to talk about the ban).
func _strip_comment(line: String) -> String:
	var in_string := false
	var quote := ""
	for i in line.length():
		var c := line[i]
		if in_string:
			if c == quote and (i == 0 or line[i - 1] != "\\"):
				in_string = false
		elif c == '"' or c == "'":
			in_string = true
			quote = c
		elif c == "#":
			return line.substr(0, i)
	return line


func _d5b_empty_layers() -> Dictionary:
	## M00's D5b asserted spine/worldgen were EMPTY. In M01 they hold the machinery, so the
	## guard becomes B17: no later-milestone CONTENT. Concretely: content/modules/ must hold
	## exactly the two M01 modules, and no worldgen file may declare biome/climate/cave/etc.
	var dir := DirAccess.open("res://content/modules")
	var found: Array[String] = []
	if dir != null:
		dir.list_dir_begin()
		var n := dir.get_next()
		while n != "":
			if n.ends_with(".tres"):
				found.append(n)
			n = dir.get_next()
		dir.list_dir_end()
	found.sort()
	var expected := ["planet_hills_v1.tres", "surface_grass_stone_v1.tres"]
	var ok := found == expected

	# Later-milestone vocabulary must not appear in worldgen/spine source.
	var banned_words := ["biome", "climate", "temperature", "precipitation", "erosion", "river",
		"waterfall", "cave", "strata", "volcano", "arch", "tree", "foliage", "structure",
		"weather", "cloud", "season", "save_game", "multiplayer"]
	var hits: Array[String] = []
	for root in ["res://src/worldgen", "res://src/spine"]:
		for path in _list_gd(root):
			var text := FileAccess.get_file_as_string(path).to_lower()
			for w in banned_words:
				# only identifier-ish occurrences, not prose in comments
				if text.find(w + "_") >= 0 or text.find("_" + w) >= 0 or text.find(w + "(") >= 0:
					hits.append("%s: %s" % [path, w])
	if not hits.is_empty():
		ok = false
	return TestHarness.result(SUITE, "D5b/B17", "PASS" if ok else "FAIL",
		"content/modules holds exactly the M01 module set; no later-milestone content in spine/worldgen",
		"modules=%s (expected %s)\nbanned-vocabulary hits=%s" % [str(found), str(expected), str(hits)])


func _list_gd(root: String) -> Array:
	var out := []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir():
			out.append_array(_list_gd(root + "/" + n))
		elif n.ends_with(".gd"):
			out.append(root + "/" + n)
		n = dir.get_next()
	dir.list_dir_end()
	return out


func _origin_coverage(origins: Array) -> Dictionary:
	## Prove the origin list really covers what T8 demands: origin, negatives, > +/-1e6, and
	## the full world height.
	var has_origin := Vector3i.ZERO in origins
	var has_negative := false
	var has_far := false
	var min_y := 1 << 30
	var max_y := -(1 << 30)
	for o_variant in origins:
		var o: Vector3i = o_variant
		if o.x < 0 or o.y < 0 or o.z < 0:
			has_negative = true
		if absi(o.x) > 1000000 or absi(o.z) > 1000000:
			has_far = true
		min_y = mini(min_y, o.y)
		max_y = maxi(max_y, o.y)
	var ok := has_origin and has_negative and has_far and origins.size() == ChunkOrigins.COUNT
	return TestHarness.result(SUITE, "D5c", "PASS" if ok else "FAIL",
		"%d chunk origins cover origin, negatives and |coord| > 1 000 000" % origins.size(),
		"origin=%s negatives=%s far=%s y=[%d..%d]" % [str(has_origin), str(has_negative), str(has_far), min_y, max_y])


func _hash_table(origins: Array) -> Dictionary:
	## The first 8 hashes, printed into the report (T8 requires a table of the first 8).
	var built := AdapterRegistry.build_generator(AdapterRegistry.DEFAULT_ID, _cfg.seed_value, _cfg.to_gen_context())
	if not built["ok"]:
		return TestHarness.fail(SUITE, "D-table", "could not build the default generator")
	var detailed := ChunkHasher.hash_all_detailed(built["generator"], origins.slice(0, 8), BLOCK_SIZE, _cfg.type_depth_bits)
	var lines: Array[String] = []
	lines.append("generator=%s seed=%d block=%d type_depth=%d-bit" % [AdapterRegistry.DEFAULT_ID, _cfg.seed_value, BLOCK_SIZE, _cfg.type_depth_bits])
	lines.append("%-24s %-18s %-8s %-7s %s" % ["origin", "hash (hex)", "bytes", "uniform", "non_air/total"])
	for r in detailed:
		lines.append("%-24s %-18s %-8d %-7s %d/%d" % [
			r["key"], r["hex"], r["bytes"], str(r["uniform"]), r["non_air"], r["total"],
		])
	return TestHarness.ok(SUITE, "D-table", "first 8 chunk hashes (%s)" % AdapterRegistry.DEFAULT_ID, "\n".join(lines))


# --- helpers ----------------------------------------------------------------------------

func _diff(a: Dictionary, b: Dictionary) -> Array:
	var out := []
	for k in a:
		if not b.has(k):
			out.append({"key": k, "a": a[k], "b": "(missing)"})
		elif String(a[k]) != String(b[k]):
			out.append({"key": k, "a": a[k], "b": b[k]})
	for k in b:
		if not a.has(k):
			out.append({"key": k, "a": "(missing)", "b": b[k]})
	return out


func _list_scripts(dir_path: String) -> Array:
	var out := []
	for f in _list_all_files(dir_path):
		if f.ends_with(".gd"):
			out.append(f)
	return out


func _list_all_files(dir_path: String) -> Array:
	var out := []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			out.append_array(_list_all_files(full))
		else:
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out
