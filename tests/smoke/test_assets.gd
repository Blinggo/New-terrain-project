extends RefCounted
## tests/smoke/test_assets.gd
##
## S3 - The generated atlas and the data-driven block library are correct, importable and
## reproducible. T3 in full.

const SUITE := "smoke"
const ATLAS := "res://content/textures/blocks_atlas.png"
const ATLAS_IMPORT := "res://content/textures/blocks_atlas.png.import"
const BLOCKS := "res://content/blocks/blocks.json"

## sha256 of the committed atlas. Produced by tools/generate_placeholder_atlas.gd, which is
## deterministic (FNV-1a derived per-pixel jitter, no randf). If this value changes without
## an intentional art change, the generator is no longer reproducible.
## Regenerate with:  sha256sum content/textures/blocks_atlas.png
const ATLAS_SHA256 := "087f907b64a40127abf2b03acaca1ae94a5fbc60a8a12a19a225c23c2b56fab7"

## Block ids required verbatim by T3.3.
const REQUIRED_IDS := {
	0: "air", 1: "grass", 2: "dirt", 3: "stone", 4: "sand",
	5: "gravel", 6: "snow", 7: "water", 8: "log", 9: "leaves",
}


func run(_ctx: Dictionary) -> Array:
	var out: Array = []

	# S3a - the atlas exists with the right geometry.
	if not FileAccess.file_exists(ATLAS):
		out.append(TestHarness.fail(SUITE, "S3a", "atlas PNG missing",
			"run: godot --headless --path . --script res://tools/generate_placeholder_atlas.gd"))
		return out

	var tex: Texture2D = load(ATLAS)
	var img := tex.get_image() if tex != null else null
	if img == null:
		out.append(TestHarness.fail(SUITE, "S3a", "atlas could not be loaded as an Image"))
		return out
	var size_ok := img.get_width() == 64 and img.get_height() == 64
	out.append(TestHarness.result(SUITE, "S3a", "PASS" if size_ok else "FAIL",
		"atlas is 64x64 (4x4 grid of 16px tiles)",
		"size=%s format=%s" % [str(img.get_size()), str(img.get_format())]))

	# S3b - pixel-art import settings actually took effect.
	var mip_ok := img.has_mipmaps() and img.get_mipmap_count() >= 5
	out.append(TestHarness.result(SUITE, "S3b", "PASS" if mip_ok else "FAIL",
		"atlas imported WITH mipmaps (needed for use_nearest_mipmap_filter)",
		"has_mipmaps=%s mipmap_count=%d" % [str(img.has_mipmaps()), img.get_mipmap_count()]))

	var cfg := ConfigFile.new()
	var import_ok := cfg.load(ATLAS_IMPORT) == OK
	var compress_mode: Variant = cfg.get_value("params", "compress/mode", -1) if import_ok else -1
	var detect3d: Variant = cfg.get_value("params", "detect_3d/compress_to", -1) if import_ok else -1
	var params_ok := import_ok and int(compress_mode) == 0 and int(detect3d) == 0
	out.append(TestHarness.result(SUITE, "S3c", "PASS" if params_ok else "FAIL",
		"atlas import is lossless with no 3D auto-recompress",
		"compress/mode=%s (0=Lossless) detect_3d/compress_to=%s (0=off)" % [str(compress_mode), str(detect3d)]))

	# S3d - the generator is reproducible: same bytes as the committed golden sha256.
	var sha := FileAccess.get_sha256(ProjectSettings.globalize_path(ATLAS))
	out.append(TestHarness.result(SUITE, "S3d", "PASS" if sha == ATLAS_SHA256 else "FAIL",
		"atlas PNG matches the committed sha256 (deterministic generation)",
		"actual=%s\nexpect=%s" % [sha, ATLAS_SHA256]))

	# S3e - water tile is semi-transparent, solids are not.
	var water_px := img.get_pixel(48 + 8, 16 + 8)   # tile 7 = water, at grid (3,1)
	var stone_px := img.get_pixel(48 + 8, 0 + 8)    # tile 3 = stone, at grid (3,0)
	var alpha_ok := water_px.a < 0.95 and water_px.a > 0.2 and stone_px.a > 0.99
	out.append(TestHarness.result(SUITE, "S3e", "PASS" if alpha_ok else "FAIL",
		"water tile is semi-transparent, stone is opaque",
		"water=%s stone=%s" % [str(water_px), str(stone_px)]))

	# S3f - blocks.json declares exactly the T3.3 ids and names.
	var data := JsonData.load_file(BLOCKS)
	var blocks: Array = JsonData.get_array(data, "blocks")
	var names := {}
	for b_variant in blocks:
		var b: Dictionary = b_variant
		names[int(JsonData.get_int(b, "id", -1))] = JsonData.get_string(b, "name", "?")
	var id_problems: Array[String] = []
	for id in REQUIRED_IDS:
		if not names.has(id):
			id_problems.append("missing id %d (%s)" % [id, REQUIRED_IDS[id]])
		elif String(names[id]) != REQUIRED_IDS[id]:
			id_problems.append("id %d is '%s', expected '%s'" % [id, names[id], REQUIRED_IDS[id]])
	for id in names:
		if not REQUIRED_IDS.has(id):
			id_problems.append("unexpected id %d (%s)" % [id, names[id]])
	out.append(TestHarness.result(SUITE, "S3f", "PASS" if id_problems.is_empty() else "FAIL",
		"blocks.json declares exactly ids 0..9 with the required names",
		"\n".join(id_problems) if not id_problems.is_empty() else str(names)))

	# S3g - the library builds from data, in code, with the right shape.
	var built := BlockLibraryBuilder.build()
	var report: Dictionary = built["report"]
	var lib: VoxelBlockyLibrary = built["library"]
	out.append(TestHarness.result(SUITE, "S3g", "PASS" if built["ok"] and lib != null else "FAIL",
		"block library builds in code from blocks.json",
		"ok=%s models=%s materials=%s errors=%s" % [
			str(built["ok"]), str(report.get("model_count")), str(report.get("materials")), str(report["errors"])]))
	if lib == null:
		return out

	# S3h - model index == block id, and air is an empty model.
	var index_ok := true
	for id in REQUIRED_IDS:
		var model: VoxelBlockyModel = lib.get_model(id)
		if model == null:
			index_ok = false
			continue
		if int(id) == 0 and not (model is VoxelBlockyModelEmpty):
			index_ok = false
	out.append(TestHarness.result(SUITE, "S3h", "PASS" if index_ok else "FAIL",
		"models[id] == block id for all 10 blocks; id 0 is VoxelBlockyModelEmpty (air)",
		"model(0)=%s model(1)=%s" % [lib.get_model(0).get_class(), lib.get_model(1).get_class()]))

	# S3i - per-face tiles differ where they should (grass: top vs bottom vs side).
	var grass: VoxelBlockyModelCube = lib.get_model(1)
	var top := grass.get_tile(VoxelBlockyModel.SIDE_POSITIVE_Y)
	var bottom := grass.get_tile(VoxelBlockyModel.SIDE_NEGATIVE_Y)
	var side := grass.get_tile(VoxelBlockyModel.SIDE_POSITIVE_X)
	var tiles_ok := top != bottom and side != top and side != bottom and top == Vector2i(0, 0)
	out.append(TestHarness.result(SUITE, "S3i", "PASS" if tiles_ok else "FAIL",
		"grass has distinct top/bottom/side tiles mapped from the atlas grid",
		"top=%s bottom=%s side=%s (expect (0,0) (2,0) (1,0))" % [str(top), str(bottom), str(side)]))

	# S3j - collision follows the data: solids collide, air and water do not.
	var collision_problems: Array[String] = []
	for id in REQUIRED_IDS:
		var model: VoxelBlockyModel = lib.get_model(id)
		var wants_collision: bool = String(JsonData.get_string(_block_entry(blocks, id), "collision", "full")) == "full"
		var has_collision := model.is_mesh_collision_enabled(0)
		if has_collision != wants_collision:
			collision_problems.append("%s: enabled=%s expected=%s" % [REQUIRED_IDS[id], str(has_collision), str(wants_collision)])
	out.append(TestHarness.result(SUITE, "S3j", "PASS" if collision_problems.is_empty() else "FAIL",
		"per-block collision matches blocks.json (full for solids, none for air/water)",
		"\n".join(collision_problems) if not collision_problems.is_empty() else "all 10 blocks correct"))

	# S3k - materials. VoxelMesherBlocky has no material property, so the atlas material must
	# arrive through lib.get_materials(). Exactly ONE entry is correct: probe_materials.gd
	# proved a cube model can only carry surface index 0, and a second slot always bakes null.
	var mats: Array = lib.get_materials()
	var mat_ok := mats.size() == 1
	var details: Array[String] = []
	for i in mats.size():
		var m: Material = mats[i]
		if m is StandardMaterial3D:
			var sm := m as StandardMaterial3D
			details.append("slot %d: %s filter=%d transparency=%d vertex_color_as_albedo=%s tex=%s" % [
				i, sm.resource_name, sm.texture_filter, sm.transparency,
				str(sm.vertex_color_use_as_albedo), str(sm.albedo_texture != null)])
			if sm.texture_filter != BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
				mat_ok = false
			if sm.albedo_texture == null:
				mat_ok = false
		else:
			mat_ok = false
			details.append("slot %d: %s (not a StandardMaterial3D)" % [i, str(m)])
	out.append(TestHarness.result(SUITE, "S3k", "PASS" if mat_ok else "FAIL",
		"library bakes exactly 1 non-null atlas material with nearest-mipmap filtering",
		"\n".join(details)))

	return out


func _block_entry(blocks: Array, id: int) -> Dictionary:
	for b_variant in blocks:
		var b: Dictionary = b_variant
		if JsonData.get_int(b, "id", -1) == id:
			return b
	return {}
