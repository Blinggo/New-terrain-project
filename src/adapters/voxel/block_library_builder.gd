class_name BlockLibraryBuilder
extends RefCounted
## src/adapters/voxel/block_library_builder.gd
##
## M00 / T3.3 - Builds the blocky voxel library IN CODE from res://content/blocks/blocks.json.
## There is deliberately no hand-authored .tres library in this project: the library must be
## reproducible from data so that adding a block is a JSON edit, not an editor session.
##
## LAYER: adapters. This file (and the generator adapters / terrain adapter) are the ONLY
## places in the project that may name a Voxel Tools class.
##
## WHY VoxelBlockyLibrary AND NOT VoxelBlockyTypeLibrary (1.7 has both, verified in
## docs/reports/voxel_api_dump.json):
##   * Both extend VoxelBlockyLibraryBase, which is the type VoxelMesherBlocky.library
##     accepts, so either is legal.
##   * VoxelBlockyLibrary.models is a plain Array[VoxelBlockyModel] whose INDEX IS THE VOXEL
##     ID, and add_model() returns that index. That is a 1:1 match for blocks.json.
##   * VoxelBlockyTypeLibrary is the 1.7-native path with VoxelBlockyType entries, attributes
##     (rotation / axis / fluid level) and a serialisable ID map. It is the right base for
##     M09 flora and M10 structures, and is recorded as Deferred in the M00 report. Using it
##     in M00 would add an attribute/ID-map layer with nothing to drive it yet.
##
## MATERIALS - verified with tools/probe_materials.gd (cases A-F) and tools/probe_generators.gd (P5):
##   * VoxelMesherBlocky has NO material property in 1.7 (props: library, occlusion_enabled,
##     occlusion_darkness, tint_mode, shadow_occluder_*). The atlas material therefore travels
##     through the library: VoxelBlockyLibraryBase.bake() collects every model's material
##     override into get_materials(), and the mesher turns that list into mesh surfaces.
##   * set_material_override(index, material) `index` IS THE MODEL'S SURFACE INDEX, NOT a
##     material slot. VoxelBlockyModelCube has exactly ONE surface, so index 0 is the only
##     usable value. Declaring index 1 instead leaves get_materials()[0] null (probe case F),
##     and two models declaring 0 and 1 produce a 2-entry list whose second entry is still
##     null (probe case B) - it does NOT select a second material. So a cube model can only
##     ever carry one material, and that material becomes get_materials()[0].
##   * Consequence for M00: the whole blocky terrain is drawn with ONE material (the atlas,
##     opaque). Alpha-blended water cannot share that material - an alpha blend on every block
##     would push all terrain through the transparent pass, which is exactly what a 3-4 GB
##     Adreno 610 phone cannot afford. So water is a solid opaque cube in M00, and true
##     translucency is recorded as Deferred with the mechanism that would enable it below.
##   * Mechanism for later milestones (recorded, NOT built): VoxelBlockyModelMesh exists in 1.7
##     and carries an external ArrayMesh. A hand-built 2-surface mesh (opaque + translucent)
##     can then declare material overrides 0 and 1 and bake() yields two real materials. That
##     is the upgrade path for M04 water and M09 foliage.

const BLOCKS_PATH := "res://content/blocks/blocks.json"
const ATLAS_PATH := "res://content/textures/blocks_atlas.png"

## VoxelBlockyModelCube has exactly one surface, so this is the only legal material index.
## See the MATERIALS block above: an index other than 0 makes bake() return a null material.
const CUBE_SURFACE_INDEX := 0

## Face keys accepted in blocks.json, mapped to the real VoxelBlockyModel.Side enum.
## NOTE: VoxelBlockyModel.Side and VoxelMesherBlocky.Side are DIFFERENT enums with
## DIFFERENT values in 1.7 (model: +X=0,-X=1,-Y=2,+Y=3,-Z=4,+Z=5; mesher: -X=0,+X=1,...).
## set_tile() takes the MODEL enum, so only that one is used here.
const FACE_KEYS := {
	"positive_x": VoxelBlockyModel.SIDE_POSITIVE_X,
	"negative_x": VoxelBlockyModel.SIDE_NEGATIVE_X,
	"negative_y": VoxelBlockyModel.SIDE_NEGATIVE_Y,
	"positive_y": VoxelBlockyModel.SIDE_POSITIVE_Y,
	"negative_z": VoxelBlockyModel.SIDE_NEGATIVE_Z,
	"positive_z": VoxelBlockyModel.SIDE_POSITIVE_Z,
}
const HORIZONTAL_SIDES := [
	VoxelBlockyModel.SIDE_POSITIVE_X,
	VoxelBlockyModel.SIDE_NEGATIVE_X,
	VoxelBlockyModel.SIDE_POSITIVE_Z,
	VoxelBlockyModel.SIDE_NEGATIVE_Z,
]


## Build everything. Returns:
##   {"ok": bool, "library": VoxelBlockyLibrary, "report": Dictionary}
## The report is printed into the M00 report and asserted on by the smoke tests.
static func build(blocks_path: String = BLOCKS_PATH, atlas_path: String = ATLAS_PATH) -> Dictionary:
	var report := {
		"blocks_path": blocks_path,
		"atlas_path": atlas_path,
		"errors": [] as Array[String],
		"warnings": [] as Array[String],
		"blocks": [] as Array[String],
		"materials": 0,
		"material_mode": "single_opaque_atlas",
		"translucent_deferred": [],
		"library_class": "",
		"atlas": {},
	}

	var data := JsonData.load_file(blocks_path)
	if data.is_empty():
		report["errors"].append("blocks.json could not be read or parsed: %s" % blocks_path)
		return {"ok": false, "library": null, "report": report}

	var atlas_cfg := JsonData.get_dict(data, "atlas")
	var tile_names: Array = JsonData.get_array(atlas_cfg, "tiles")
	var grid_cols := JsonData.get_int(atlas_cfg, "grid_columns", 4)
	var grid_rows := JsonData.get_int(atlas_cfg, "grid_rows", 4)
	var tile_px := JsonData.get_int(atlas_cfg, "tile_px", 16)
	var declared_texture := JsonData.get_string(atlas_cfg, "texture", atlas_path)

	# tile name -> Vector2i grid coordinate (column, row), row 0 = top row of the atlas.
	var tile_coords := {}
	for i in tile_names.size():
		tile_coords[String(tile_names[i])] = Vector2i(i % grid_cols, i / grid_cols)
	report["atlas"] = {
		"texture": declared_texture,
		"grid": "%dx%d" % [grid_cols, grid_rows],
		"tile_px": tile_px,
		"tiles": tile_coords.size(),
	}

	var materials := _build_materials(declared_texture, report)

	var lib := VoxelBlockyLibrary.new()
	var blocks: Array = JsonData.get_array(data, "blocks")
	if blocks.is_empty():
		report["errors"].append("blocks.json contains no blocks")
		return {"ok": false, "library": null, "report": report}

	for entry_variant in blocks:
		if not (entry_variant is Dictionary):
			report["errors"].append("blocks.json entry is not an object: %s" % str(entry_variant))
			continue
		var entry: Dictionary = entry_variant
		var id := JsonData.get_int(entry, "id", -1)
		var bname := JsonData.get_string(entry, "name", "?")
		if id < 0:
			report["errors"].append("block '%s' has no valid id" % bname)
			continue

		var model := _build_model(entry, tile_coords, Vector2i(grid_cols, grid_rows), materials, report)
		if model == null:
			report["errors"].append("block id %d ('%s') could not be built" % [id, bname])
			continue

		# Pad the array so that models[id] is always the right model; a gap is a data bug.
		var got: int = lib.add_model(model)
		if got != id:
			# add_model() appends, so an out-of-order or duplicate id in the JSON would
			# silently remap every voxel id. Fail loudly instead.
			report["errors"].append(
				"block '%s' got model index %d but blocks.json declares id %d - ids must be dense, ascending and start at 0"
				% [bname, got, id]
			)
		report["blocks"].append("%d=%s" % [id, bname])

	lib.bake()
	report["materials"] = lib.get_materials().size()
	report["library_class"] = lib.get_class()
	report["model_count"] = lib.get_models().size()
	report["expected_model_count"] = blocks.size()

	if lib.get_models().size() != blocks.size():
		report["errors"].append(
			"library holds %d models but blocks.json declares %d blocks"
			% [lib.get_models().size(), blocks.size()]
		)
	if report["materials"] != 1:
		report["errors"].append(
			"bake() produced %d materials, expected exactly 1 (a null entry means some model has no material and will not render)" % report["materials"]
		)

	return {"ok": report["errors"].is_empty(), "library": lib, "report": report}


static func _build_model(
	entry: Dictionary,
	tile_coords: Dictionary,
	atlas_grid: Vector2i,
	materials: Array,
	report: Dictionary
) -> VoxelBlockyModel:
	var bname := JsonData.get_string(entry, "name", "?")
	var kind := JsonData.get_string(entry, "kind", "cube")
	var transparent := JsonData.get_bool(entry, "transparent", false)
	var collision := JsonData.get_string(entry, "collision", "full")
	var culls := JsonData.get_bool(entry, "culls_neighbors", true)
	var transparency_index := JsonData.get_int(entry, "transparency_index", 0)
	var tiles := JsonData.get_dict(entry, "tiles")

	if kind == "empty":
		# Air. VoxelBlockyModelEmpty has no geometry and no collision of its own.
		var empty := VoxelBlockyModelEmpty.new()
		empty.resource_name = bname
		empty.culls_neighbors = false
		empty.set_transparency_index(transparency_index)
		empty.set_mesh_collision_enabled(0, false)
		return empty

	if kind != "cube":
		report["errors"].append("block '%s' has unknown kind '%s' (expected 'empty' or 'cube')" % [bname, kind])
		return null

	var cube := VoxelBlockyModelCube.new()
	cube.resource_name = bname
	cube.atlas_size_in_tiles = atlas_grid
	cube.culls_neighbors = culls
	cube.set_transparency_index(transparency_index)

	# Per-face tiles: most specific key wins (explicit face > "side" > "all").
	for face_key in FACE_KEYS:
		var side: int = FACE_KEYS[face_key]
		var tile_name := _resolve_tile_name(tiles, face_key, side)
		if tile_name.is_empty():
			report["errors"].append("block '%s' has no tile for face '%s'" % [bname, face_key])
			continue
		if not tile_coords.has(tile_name):
			report["errors"].append("block '%s' references unknown atlas tile '%s'" % [bname, tile_name])
			continue
		cube.set_tile(side, tile_coords[tile_name])

	# Collision: one full-cell AABB on surface 0, or none.
	if collision == "full":
		var aabbs: Array[AABB] = [AABB(Vector3.ZERO, Vector3.ONE)]
		cube.collision_aabbs = aabbs
		cube.set_mesh_collision_enabled(0, true)
	elif collision == "none":
		var none: Array[AABB] = []
		cube.collision_aabbs = none
		cube.set_mesh_collision_enabled(0, false)
	else:
		report["errors"].append("block '%s' has unknown collision mode '%s' (expected 'full' or 'none')" % [bname, collision])

	# One material for the whole library (probe-verified: a cube model can only carry one).
	if materials.size() >= 1 and materials[0] != null:
		cube.set_material_override(CUBE_SURFACE_INDEX, materials[0])
	else:
		report["warnings"].append("block '%s' got no material - it will not render" % bname)
	if transparent:
		# Honest record rather than a silent visual lie: the block is flagged transparent in
		# data, but M00 draws it opaque. Upgrading needs VoxelBlockyModelMesh (see above).
		report["translucent_deferred"].append(bname)

	return cube


## face_key is one of FACE_KEYS; side lets "side" apply only to the four horizontals.
static func _resolve_tile_name(tiles: Dictionary, face_key: String, side: int) -> String:
	if tiles.has(face_key):
		return String(tiles[face_key])
	if tiles.has("side") and side in HORIZONTAL_SIDES:
		return String(tiles["side"])
	if tiles.has("all"):
		return String(tiles["all"])
	return ""



## ONE material for the whole library. Deliberately a single-element array: see the
## MATERIALS header for the probe evidence that a second slot cannot be filled by cube models.
static func _build_materials(atlas_res_path: String, report: Dictionary) -> Array:
	var atlas: Texture2D = null
	if ResourceLoader.exists(atlas_res_path):
		atlas = load(atlas_res_path)
	if atlas == null:
		report["errors"].append(
			"atlas texture could not be loaded from %s - run tools/generate_placeholder_atlas.gd then reimport" % atlas_res_path
		)
		# Keep the world renderable so a missing atlas never looks like a renderer failure:
		# fall back to a flat 16x16 grey tile and say so loudly in the report.
		var fallback := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		fallback.fill(Color(0.6, 0.6, 0.62, 1.0))
		atlas = ImageTexture.create_from_image(fallback)
		report["warnings"].append("using a flat grey fallback texture")

	var opaque := StandardMaterial3D.new()
	_apply_atlas(opaque, atlas)
	opaque.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	opaque.resource_name = "blocks_opaque"

	return [opaque]


static func _apply_atlas(mat: StandardMaterial3D, atlas: Texture2D) -> void:
	mat.albedo_texture = atlas
	# Pixel-art filtering decided per material, not per project setting, so it cannot be
	# changed by accident in the editor. NEAREST_WITH_MIPMAPS = crisp texels up close and
	# no shimmer far away (pairs with use_nearest_mipmap_filter in project.godot).
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.texture_repeat = true
	mat.metallic = 0.0
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	# The blocky mesher writes ambient occlusion into vertex colours, so the material must
	# multiply them into the albedo or the AO is invisible (screenshot #3).
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = false
