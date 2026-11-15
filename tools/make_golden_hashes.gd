extends SceneTree
## tools/make_golden_hashes.gd
##
## M00 / T8 - Regenerate the committed golden hash tables.
##
##   godot --headless --path <project> --script res://tools/make_golden_hashes.gd
##
## TWO files, on purpose:
##   tests/determinism/golden_hashes.json          the M00 baselines (noise2d, graph). Frozen:
##                                                 X10 asserts the M00 maths still reproduces.
##   tests/determinism/golden_hashes_modular.json  the backends that execute the resolved
##                                                 module pipeline (native_cb,
##                                                 experimental_columns). M01-fix renamed this
##                                                 file from golden_hashes_multipass.json:
##                                                 "multipass" was the self-hosted backend's
##                                                 old, wrong name (it is not the extension's
##                                                 MultipassCB), and both modular backends now
##                                                 share one table because they must agree.
##
## The golden files are COMMITTED EVIDENCE: D2 compares a fresh second process against them.
## Regenerate only when the terrain contract deliberately changes, and record a row in
## docs/WORLDGEN_CHANGELOG.md with the reason (hard rule: no silent golden regeneration).
##
## SAFETY NET BELOW: this script refuses to write the modular table unless native_cb and
## experimental_columns agree with each other AND with the committed graph goldens on every
## origin (neighbour passes disabled). That is the M01-fix acceptance criterion, checked at
## the moment the numbers are produced rather than only later in a test.

const OUT := "res://tests/determinism/golden_hashes.json"
const OUT_MODULAR := "res://tests/determinism/golden_hashes_modular.json"
const M00_IDS: Array[String] = ["noise2d", "graph"]
const MODULAR_IDS: Array[String] = ["native_cb", "experimental_columns"]
const BLOCK_SIZE := 16


func _init() -> void:
	var cfg := WorldConfig.load_config()
	var origins := ChunkOrigins.get_origins(cfg.sea_level)
	var ve: Object = ClassDB.instantiate("VoxelEngine")
	var voxel_version := "?"
	if ve != null:
		voxel_version = "%s.%s.%s %s %s (%s)" % [
			ve.call("get_version_major"), ve.call("get_version_minor"), ve.call("get_version_patch"),
			ve.call("get_version_v"), ve.call("get_version_edition"), ve.call("get_version_git_hash"),
		]
		ve.free()

	var env := {
		"algorithm": "FNV-1a/64 (src/core/hash64.gd) over TYPE channel bytes + metadata + origin",
		"godot": Engine.get_version_info().get("string"),
		"godot_hash": Engine.get_version_info().get("hash"),
		"voxel_tools": voxel_version,
		"os": OS.get_name(),
		"seed": cfg.seed_value,
		"block_size": BLOCK_SIZE,
		"type_depth_bits": cfg.type_depth_bits,
		"origin_count": origins.size(),
		"origin_composition": ChunkOrigins.describe(cfg.sea_level),
		"origins": origins.map(func(o): return ChunkOrigins.origin_to_key(o)),
	}

	# --- M00 baselines -------------------------------------------------------------------
	var by_gen := {}
	for id in M00_IDS:
		var built := AdapterRegistry.build_generator(id, cfg.seed_value, cfg.to_gen_context())
		if not built["ok"]:
			push_error("make_golden_hashes: generator '%s' failed: %s" % [id, built["report"].get("error", "?")])
			quit(1)
			return
		by_gen[id] = ChunkHasher.hash_all(built["generator"], origins, BLOCK_SIZE, cfg.type_depth_bits)
		print("hashed %d origins with '%s' (source kind: %s)" % [
			origins.size(), id, ChunkHasher.source_kind(built["generator"])])

	var golden := env.duplicate()
	golden["_comment"] = [
		"COMMITTED GOLDEN VALUES for the D2 determinism check, M00 baseline backends. Do not edit by hand.",
		"Regenerate with: godot --headless --path . --script res://tools/make_golden_hashes.gd",
		"Hash = FNV-1a/64 over the canonicalised TYPE channel of a 16^3 block, combined",
		"with block size, channel depth, uniformity and the chunk origin. See",
		"src/adapters/voxel/chunk_hasher.gd for the exact construction.",
		"Both backends here are LEGACY baselines (capabilities.executes_all_modules = false):",
		"they encode the M00 maths directly and ignore which modules are enabled.",
	]
	golden["by_generator"] = by_gen
	if not JsonData.save_file(OUT, golden):
		quit(1)
		return
	print("wrote %s" % OUT)

	# --- modular backends ----------------------------------------------------------------
	ModuleFixtures.clear()   # never bake a throwaway test module into committed goldens
	var by_gen_mod := {}
	var reports := {}
	for id in MODULAR_IDS:
		var built_mod := AdapterRegistry.build_generator(id, cfg.seed_value, cfg.to_gen_context())
		if not built_mod["ok"]:
			push_error("make_golden_hashes: generator '%s' failed: %s" % [id, built_mod["report"].get("error", "?")])
			quit(1)
			return
		by_gen_mod[id] = ChunkHasher.hash_all(built_mod["generator"], origins, BLOCK_SIZE, cfg.type_depth_bits)
		var gen_obj: Object = built_mod["generator"]
		reports[id] = {
			"source_kind": ChunkHasher.source_kind(gen_obj),
			"executed_counts": gen_obj.call("stats").get("executed_counts") if gen_obj.has_method("stats") else {},
			"neighbour_passes_in_plan": gen_obj.call("neighbour_passes_in_plan") if gen_obj.has_method("neighbour_passes_in_plan") else false,
		}
		print("hashed %d origins with '%s' (source kind: %s)" % [
			origins.size(), id, ChunkHasher.source_kind(gen_obj)])

	# --- the agreement gate --------------------------------------------------------------
	var disagreements: Array[String] = []
	for id in MODULAR_IDS:
		for k in by_gen["graph"]:
			if by_gen_mod[id].get(k, "?") != by_gen["graph"][k]:
				disagreements.append("%s vs graph at %s" % [id, k])
	if by_gen_mod[MODULAR_IDS[0]] != by_gen_mod[MODULAR_IDS[1]]:
		disagreements.append("native_cb and experimental_columns disagree with each other")
	if not disagreements.is_empty():
		push_error("make_golden_hashes: REFUSING to write the modular golden table - the modular backends do not reproduce the compiled graph with neighbour passes disabled: %s" % str(disagreements.slice(0, 10)))
		quit(1)
		return
	print("agreement gate: native_cb == experimental_columns == graph on all %d origins" % origins.size())

	var golden_mod := env.duplicate()
	golden_mod["_comment"] = [
		"COMMITTED GOLDEN VALUES for the backends that EXECUTE the resolved module pipeline.",
		"Regenerate with: godot --headless --path . --script res://tools/make_golden_hashes.gd",
		"",
		"These tables are byte-identical to the 'graph' section of golden_hashes.json, and that",
		"is the point: with neighbour passes disabled the modular backends must reproduce the",
		"legacy compiled graph exactly (M01-fix acceptance criterion, evidence E3). The script",
		"refuses to write this file when they do not.",
		"",
		"Renamed from golden_hashes_multipass.json in the M01 fix: 'multipass' was the old name",
		"of the SELF-HOSTED backend, which is now 'experimental_columns' because it is not the",
		"extension's VoxelGeneratorMultipassCB. 'native_cb' is.",
		"",
		"Both backends were hashed with content/modules/ holding exactly the two shipped modules",
		"and no throwaway fixtures installed.",
	]
	golden_mod["by_generator"] = by_gen_mod
	golden_mod["agreement"] = {
		"matches_graph_goldens": true,
		"origin_count": origins.size(),
		"neighbour_passes_disabled": true,
		"backends": reports,
	}
	if not JsonData.save_file(OUT_MODULAR, golden_mod):
		quit(1)
		return
	print("wrote %s" % OUT_MODULAR)

	print("   godot        = %s" % golden["godot"])
	print("   voxel_tools  = %s" % voxel_version)
	print("   seed         = %d" % cfg.seed_value)
	print("   origins      = %d" % origins.size())
	var first_key: String = golden["origins"][0]
	for id in by_gen:
		print("   %-20s %s -> %s" % [id, first_key, by_gen[id][first_key]])
	for id in by_gen_mod:
		print("   %-20s %s -> %s" % [id, first_key, by_gen_mod[id][first_key]])
	quit(0)
