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
		return [_d2_second_process(origins)]

	var out: Array = []
	out.append_array(_d1_same_process(origins))
	out.append(_d3_order_independence(origins))
	out.append(_d3b_order_independence_surface(origins))
	out.append(_d4_seed_is_wired(origins))
	out.append_array(_d5_lint())
	out.append(_d5b_empty_layers())
	out.append(_origin_coverage(origins))
	out.append(_hash_table(origins))
	return out


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

func _d2_second_process(origins: Array) -> Dictionary:
	var golden := JsonData.load_file(GOLDEN_PATH)
	if golden.is_empty():
		return TestHarness.fail(SUITE, "D2",
			"golden file missing or unreadable: %s" % GOLDEN_PATH,
			"run: godot --headless --path . --script res://tools/make_golden_hashes.gd")

	var by_gen: Dictionary = golden.get("by_generator", {})
	var all_diffs: Array = []
	var checked := 0
	var per_gen: Array[String] = []

	for id in AdapterRegistry.ids():
		if not by_gen.has(id):
			all_diffs.append("%s: no golden section" % id)
			continue
		var built := AdapterRegistry.build_generator(id, int(golden.get("seed", _cfg.seed_value)), _cfg.to_gen_context())
		if not built["ok"]:
			all_diffs.append("%s: generator failed to build: %s" % [id, built["report"].get("error", "?")])
			continue
		var fresh := ChunkHasher.hash_all(built["generator"], origins, BLOCK_SIZE, int(golden.get("type_depth_bits", 8)))
		var gold: Dictionary = by_gen[id]
		var diffs := _diff(gold, fresh)
		checked += gold.size()
		all_diffs.append_array(diffs)
		per_gen.append("%s: %d/%d match" % [id, gold.size() - diffs.size(), gold.size()])

	var env_ok := _environment_matches(golden)
	var evidence := "process pid=%d\n%s\ngolden: %s\nenv match: %s" % [
		OS.get_process_id(), "\n".join(per_gen), GOLDEN_PATH, str(env_ok),
	]
	if not all_diffs.is_empty():
		evidence += "\nmismatches (%d): %s" % [all_diffs.size(), str(all_diffs.slice(0, 5))]

	return TestHarness.result(SUITE, "D2", "PASS" if all_diffs.is_empty() and checked > 0 else "FAIL",
		"second process reproduced %d committed golden hashes" % checked, evidence)


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
		var alone := ChunkHasher.hash_chunk(built["generator"], target, BLOCK_SIZE, _cfg.type_depth_bits)

		# Same generator instance: generate #0..#39 first, then #40 again. Results are
		# discarded on purpose - only the ORDER is being tested.
		var warmed: Resource = built["generator"]
		for i in 40:
			ChunkHasher.hash_chunk(warmed, origins[i], BLOCK_SIZE, _cfg.type_depth_bits)
		var after := ChunkHasher.hash_chunk(warmed, target, BLOCK_SIZE, _cfg.type_depth_bits)
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
		var alone := ChunkHasher.hash_chunk(built["generator"], target, BLOCK_SIZE, _cfg.type_depth_bits)
		var warmed: Resource = built["generator"]
		for i in ChunkOrigins.FIRST_SURFACE_INDEX + 24:
			ChunkHasher.hash_chunk(warmed, origins[i], BLOCK_SIZE, _cfg.type_depth_bits)
		var after := ChunkHasher.hash_chunk(warmed, target, BLOCK_SIZE, _cfg.type_depth_bits)
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
	var out: Array = []
	var hits: Array[String] = []
	var scanned := 0
	for dir_path in LINT_DIRS:
		for f in _list_scripts(dir_path):
			scanned += 1
			var lines := FileAccess.get_file_as_string(f).split("\n")
			for i in lines.size():
				var line: String = lines[i]
				var code := _strip_comment(line)
				for banned in BANNED:
					if code.contains(banned):
						hits.append("%s:%d  %s   | %s" % [f, i + 1, banned, code.strip_edges()])

	out.append(TestHarness.result(SUITE, "D5", "PASS" if hits.is_empty() else "FAIL",
		"no banned non-deterministic calls in generation code (%d scripts scanned)" % scanned,
		"\n".join(hits) if not hits.is_empty() else "banned: %s\ndirs: %s\n%s" % [str(BANNED), str(LINT_DIRS), LINT_EXEMPT_NOTE]))
	return out


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
	## Hard rule #6: M00 must NOT build later milestones. Prove src/worldgen and src/spine
	## still contain nothing but their README.
	var bad: Array[String] = []
	var found: Array[String] = []
	for dir_path in EMPTY_IN_M00:
		var files := _list_all_files(dir_path)
		for f in files:
			found.append(f)
			if not f.ends_with("README.md"):
				bad.append(f)
	return TestHarness.result(SUITE, "D5b", "PASS" if bad.is_empty() else "FAIL",
		"src/worldgen and src/spine are still empty in M00 (no later milestones built)",
		"files present: %s" % (str(found) if not found.is_empty() else "(none)"))


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
