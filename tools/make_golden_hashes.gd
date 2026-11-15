extends SceneTree
## tools/make_golden_hashes.gd
##
## M00 / T8 - Regenerate res://tests/determinism/golden_hashes.json.
##
## The golden file is COMMITTED evidence: D2 compares a fresh second process against it.
## Regenerate it only when the terrain contract deliberately changes (new generator maths,
## new block ids, new block size, new channel depth, or an engine upgrade that changes
## generated data). Never regenerate it to make a failing test pass - that is exactly the
## mistake golden files exist to catch.
##
##   godot --headless --path <project> --script res://tools/make_golden_hashes.gd

const OUT := "res://tests/determinism/golden_hashes.json"
## M01 / X11: the multipass backend gets its OWN committed golden set. The M00 file keeps
## exactly the two M00 backends so X10 ("M00 graph goldens reproduce exactly") stays a
## statement about M00 maths, not about M01 additions.
const OUT_MULTIPASS := "res://tests/determinism/golden_hashes_multipass.json"
const M00_IDS: Array[String] = ["noise2d", "graph"]
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

	var by_gen := {}
	for id in M00_IDS:
		var built := AdapterRegistry.build_generator(id, cfg.seed_value, cfg.to_gen_context())
		if not built["ok"]:
			push_error("make_golden_hashes: generator '%s' failed: %s" % [id, built["report"].get("error", "?")])
			quit(1)
			return
		by_gen[id] = ChunkHasher.hash_all(built["generator"], origins, BLOCK_SIZE, cfg.type_depth_bits)
		print("hashed %d origins with '%s'" % [origins.size(), id])

	var by_gen_mp := {}
	for id in ["multipass"]:
		var built_mp := AdapterRegistry.build_generator(id, cfg.seed_value, cfg.to_gen_context())
		if not built_mp["ok"]:
			push_error("make_golden_hashes: generator '%s' failed: %s" % [id, built_mp["report"].get("error", "?")])
			quit(1)
			return
		by_gen_mp[id] = ChunkHasher.hash_all(built_mp["generator"], origins, BLOCK_SIZE, cfg.type_depth_bits)
		print("hashed %d origins with '%s'" % [origins.size(), id])

	var golden := {
		"_comment": [
			"COMMITTED GOLDEN VALUES for the D2 determinism check. Do not edit by hand.",
			"Regenerate with: godot --headless --path . --script res://tools/make_golden_hashes.gd",
			"Hash = FNV-1a/64 over the canonicalised TYPE channel of a 16^3 block, combined",
			"with block size, channel depth, uniformity and the chunk origin. See",
			"src/adapters/voxel/chunk_hasher.gd for the exact construction.",
		],
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
		"by_generator": by_gen,
	}
	if not JsonData.save_file(OUT, golden):
		quit(1)
		return
	print("wrote %s" % OUT)

	var golden_mp := {
		"_comment": [
			"COMMITTED GOLDEN VALUES for the self-hosted multipass backend (M01 / Task 9).",
			"Separate from golden_hashes.json on purpose: the multipass column passes apply a",
			"neighbour-aware cliff rule (pass B, extent 1), so its terrain is deliberately not",
			"bit-identical to the compiled graph. Compared by D2/X11 in a second process.",
		],
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
		"origins": golden["origins"],
		"by_generator": by_gen_mp,
	}
	if not JsonData.save_file(OUT_MULTIPASS, golden_mp):
		quit(1)
		return
	print("wrote %s" % OUT_MULTIPASS)
	print("   godot        = %s" % golden["godot"])
	print("   voxel_tools  = %s" % voxel_version)
	print("   seed         = %d" % cfg.seed_value)
	print("   origins      = %d" % origins.size())
	for id in by_gen:
		var first_key: String = golden["origins"][0]
		print("   %-8s %s -> %s" % [id, first_key, by_gen[id][first_key]])
	for id in by_gen_mp:
		var first_key: String = golden_mp["origins"][0]
		print("   %-8s %s -> %s" % [id, first_key, by_gen_mp[id][first_key]])
	quit(0)
