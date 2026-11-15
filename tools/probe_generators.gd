extends SceneTree
## tools/probe_generators.gd
##
## M00 verification probe. Run this BEFORE trusting any generator configuration: it
## answers questions the API dump cannot, because the dump shows signatures but not
## SEMANTICS. Questions answered here (all recorded in docs/reports/M00_REPORT.md):
##
##   P1 VoxelGeneratorNoise2D / VoxelGeneratorHeightmap: which voxel value does it write,
##      over what y range, and how do height_start / height_range / curve map to it?
##      Is the column solid all the way down, or a floating slab?
##   P2 Default VoxelFormat channel depths (what does generate_block write into?).
##   P3 Can a VoxelGeneratorGraph built 100% in code drive the TYPE channel via the
##      OutputType node (id 44, absent from the NodeTypeID enum), and does compile()
##      report success?
##   P4 Does VoxelBlockyLibrary.add_model() return the model index, and does bake() work?
##
## Run:
##   godot --headless --path <project> --script res://tools/probe_generators.gd

const BLOCK := 16


func _init() -> void:
	_probe_format()
	_probe_heightmap()
	_probe_graph()
	_probe_library()
	_probe_materials_and_format()
	quit(0)


func _new_buffer(size: int = BLOCK) -> VoxelBuffer:
	var b := VoxelBuffer.new()
	b.create(size, size, size)
	return b


func _probe_format() -> void:
	print("\n===== P2: VoxelFormat default channel depths =====")
	var fmt := VoxelFormat.new()
	for c in VoxelBuffer.MAX_CHANNELS:
		print("   channel %d depth = %s" % [c, _depth_name(fmt.get_channel_depth(c))])


func _depth_name(d: int) -> String:
	match d:
		VoxelBuffer.DEPTH_8_BIT: return "8-bit"
		VoxelBuffer.DEPTH_16_BIT: return "16-bit"
		VoxelBuffer.DEPTH_32_BIT: return "32-bit"
		VoxelBuffer.DEPTH_64_BIT: return "64-bit"
	return "unknown(%d)" % d


func _probe_heightmap() -> void:
	print("\n===== P1: VoxelGeneratorNoise2D semantics =====")
	var noise := FastNoiseLite.new()
	noise.seed = 20260814
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.0035
	noise.fractal_octaves = 5

	var gen := VoxelGeneratorNoise2D.new()
	gen.noise = noise
	gen.channel = VoxelBuffer.CHANNEL_TYPE

	for cfg in [
		{"height_start": -64.0, "height_range": 384.0, "curve": false},
		{"height_start": 40.0, "height_range": 60.0, "curve": false},
	]:
		gen.height_start = cfg["height_start"]
		gen.height_range = cfg["height_range"]
		print("   -- height_start=%.0f height_range=%.0f" % [gen.height_start, gen.height_range])
		print("      used_channels_mask is not exposed; generator class = %s" % gen.get_class())
		_print_column(gen, Vector3i(0, 0, 0))
		_print_column(gen, Vector3i(8192, 0, -4096))


func _print_column(gen: VoxelGenerator, xz: Vector3i) -> void:
	## Walk the full 384-block column in 16-block data blocks and report where solid starts
	## and stops. This is the only trustworthy way to learn the fill semantics.
	var first_solid := {}
	for row in 24:
		var origin := Vector3i(xz.x, -64 + row * BLOCK, xz.z)
		var b := _new_buffer()
		gen.generate_block(b, origin, 0)
		# Sample a few columns inside the block.
		for sx in [0, 5, 11]:
			for sz in [0, 7, 15]:
				var top := -999
				var bottom := 999
				for y in BLOCK:
					var v := b.get_voxel(sx, y, sz, VoxelBuffer.CHANNEL_TYPE)
					if v != 0:
						top = max(top, origin.y + y)
						bottom = min(bottom, origin.y + y)
				if top != -999:
					var key := "%d,%d" % [sx, sz]
					if not first_solid.has(key):
						first_solid[key] = {"top": top, "bottom": bottom}
					else:
						first_solid[key]["top"] = max(first_solid[key]["top"], top)
						first_solid[key]["bottom"] = min(first_solid[key]["bottom"], bottom)
	var parts: Array[String] = []
	for k in first_solid:
		parts.append("(sx,sz)=%s solid y %d..%d" % [k, first_solid[k]["bottom"], first_solid[k]["top"]])
	print("      at xz=(%d,%d): %s" % [xz.x, xz.z, "; ".join(parts) if not parts.is_empty() else "ALL AIR"])
	# Distinct voxel values seen, to learn which type id the generator writes.
	var vals := {}
	var b2 := _new_buffer()
	gen.generate_block(b2, Vector3i(xz.x, 64, xz.z), 0)
	for y in BLOCK:
		for x in BLOCK:
			for z in BLOCK:
				vals[b2.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)] = true
	var keys: Array = vals.keys()
	keys.sort()
	print("      distinct TYPE values in the y=64 block: ", keys)


func _probe_graph() -> void:
	print("\n===== P3: VoxelGeneratorGraph built entirely in code =====")
	var gen := VoxelGeneratorGraph.new()
	var fn: VoxelGraphFunction = gen.get_main_function()
	print("   main function: ", fn, " node_type_count=", fn.get_node_type_count())
	fn.clear()

	var t_noise := _find_node_type(fn, "FastNoise2D")
	var t_x := _find_node_type(fn, "InputX")
	var t_z := _find_node_type(fn, "InputZ")
	var t_y := _find_node_type(fn, "InputY")
	var t_remap := _find_node_type(fn, "Remap")
	var t_sub := _find_node_type(fn, "Subtract")
	var t_sel := _find_node_type(fn, "Select")
	var t_out := _find_node_type(fn, "OutputType")
	print("   resolved type ids: FastNoise2D=%d InputX=%d InputZ=%d InputY=%d Remap=%d Subtract=%d Select=%d OutputType=%d"
		% [t_noise, t_x, t_z, t_y, t_remap, t_sub, t_sel, t_out])

	var noise := ZN_FastNoiseLite.new()
	noise.seed = 20260814
	noise.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2
	noise.fractal_octaves = 5
	noise.period = 1.0 / 0.0035

	var n_noise := fn.create_node(t_noise, Vector2(0, 0), 1)
	var n_x := fn.create_node(t_x, Vector2(-200, -60), 2)
	var n_z := fn.create_node(t_z, Vector2(-200, 60), 3)
	var n_y := fn.create_node(t_y, Vector2(-200, 180), 4)
	var n_remap := fn.create_node(t_remap, Vector2(200, 0), 5)
	var n_sub := fn.create_node(t_sub, Vector2(400, 90), 6)
	var n_sel := fn.create_node(t_sel, Vector2(600, 90), 7)
	var n_out := fn.create_node(t_out, Vector2(800, 90), 8)
	print("   created nodes: noise=%d x=%d z=%d y=%d remap=%d sub=%d sel=%d out=%d"
		% [n_noise, n_x, n_z, n_y, n_remap, n_sub, n_sel, n_out])

	fn.set_node_param_by_name(n_noise, "noise", noise)
	fn.set_node_param_by_name(n_remap, "min0", -1.0)
	fn.set_node_param_by_name(n_remap, "max0", 1.0)
	fn.set_node_param_by_name(n_remap, "min1", 22.0)
	fn.set_node_param_by_name(n_remap, "max1", 106.0)
	fn.set_node_param_by_name(n_sel, "threshold", 0.0)
	fn.set_node_name(n_noise, "terrain_noise")
	fn.set_node_name(n_remap, "height_remap")
	fn.set_node_name(n_sub, "height_minus_y")
	fn.set_node_name(n_sel, "solid_select")
	fn.set_node_name(n_out, "output_type")

	fn.add_connection(n_x, 0, n_noise, 0)
	fn.add_connection(n_z, 0, n_noise, 1)
	fn.add_connection(n_noise, 0, n_remap, 0)
	fn.add_connection(n_remap, 0, n_sub, 0)
	fn.add_connection(n_y, 0, n_sub, 1)
	# Select(a, b, t): a and b stay UNCONNECTED so their default inputs act as constants.
	# t is connected exactly once - connecting it twice raises
	# "Cannot create the same connection twice" (verified).
	fn.set_node_default_input_by_name(n_sel, "a", 0.0)
	fn.set_node_default_input_by_name(n_sel, "b", 3.0)
	fn.add_connection(n_sub, 0, n_sel, 2)
	fn.add_connection(n_sel, 0, n_out, 0)

	var report: Dictionary = gen.compile()
	print("   compile() -> ", report)

	var b := _new_buffer()
	gen.generate_block(b, Vector3i(0, 64, 0), 0)
	var counts := {}
	for y in BLOCK:
		for x in BLOCK:
			for z in BLOCK:
				var v := b.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
				counts[v] = int(counts.get(v, 0)) + 1
	print("   TYPE histogram of block at (0,64,0): ", counts)
	print("   is_uniform(TYPE) = ", b.is_uniform(VoxelBuffer.CHANNEL_TYPE))
	print("   byte array size = ", b.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE).size())
	_print_graph_column(gen, Vector3i(0, 0, 0))


func _print_graph_column(gen: VoxelGenerator, xz: Vector3i) -> void:
	var first_top := -999
	var first_bottom := 999
	for row in 24:
		var origin := Vector3i(xz.x, -64 + row * BLOCK, xz.z)
		var b := _new_buffer()
		gen.generate_block(b, origin, 0)
		for y in BLOCK:
			if b.get_voxel(8, y, 8, VoxelBuffer.CHANNEL_TYPE) != 0:
				first_top = max(first_top, origin.y + y)
				first_bottom = min(first_bottom, origin.y + y)
	if first_top == -999:
		print("   column at xz=(%d,%d): ALL AIR" % [xz.x, xz.z])
	else:
		print("   column at xz=(%d,%d): solid y %d..%d" % [xz.x, xz.z, first_bottom, first_top])


func _find_node_type(fn: VoxelGraphFunction, wanted: String) -> int:
	## Look the id up by NAME instead of using the NodeTypeID enum: the enum is missing
	## NODE_OUTPUT_TYPE (the OutputType node really is id 44), so any hard-coded enum
	## value would silently bind the wrong node type.
	for i in fn.get_node_type_count():
		var info: Dictionary = fn.get_node_type_info(i)
		if String(info.get("name", "")) == wanted:
			return i
	push_error("probe_generators: node type '%s' not found" % wanted)
	return -1


func _probe_library() -> void:
	print("\n===== P4: VoxelBlockyLibrary build + bake =====")
	var lib := VoxelBlockyLibrary.new()
	var air := VoxelBlockyModelEmpty.new()
	var i_air: int = lib.add_model(air)
	var cube := VoxelBlockyModelCube.new()
	cube.atlas_size_in_tiles = Vector2i(4, 4)
	cube.set_tile(VoxelBlockyModel.SIDE_POSITIVE_Y, Vector2i(0, 0))
	cube.set_tile(VoxelBlockyModel.SIDE_NEGATIVE_Y, Vector2i(2, 0))
	for side in [VoxelBlockyModel.SIDE_POSITIVE_X, VoxelBlockyModel.SIDE_NEGATIVE_X,
			VoxelBlockyModel.SIDE_POSITIVE_Z, VoxelBlockyModel.SIDE_NEGATIVE_Z]:
		cube.set_tile(side, Vector2i(1, 0))
	var aabbs: Array[AABB] = [AABB(Vector3.ZERO, Vector3.ONE)]
	cube.collision_aabbs = aabbs
	cube.set_mesh_collision_enabled(0, true)
	var i_cube: int = lib.add_model(cube)
	print("   add_model returns index: air=%d cube=%d (models.size()=%d)" % [i_air, i_cube, lib.get_models().size()])
	lib.bake()
	var mats: Array = lib.get_materials()
	print("   after bake(): materials count = ", mats.size())
	for m in mats:
		print("      material: ", m)
	print("   get_model(1) = ", lib.get_model(1))
	var mesher := VoxelMesherBlocky.new()
	mesher.library = lib
	print("   mesher.library accepted: ", mesher.library != null, " (", mesher.library.get_class() if mesher.library else "null", ")")
	print("   mesher.occlusion_enabled default = ", mesher.occlusion_enabled)


func _probe_materials_and_format() -> void:
	print("\n===== P5: how the atlas material reaches the mesher =====")
	# VoxelMesherBlocky has NO material property in 1.7 (verified in the API dump), so the
	# atlas texture must travel through the block library's baked material list.
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var tex := ImageTexture.create_from_image(img)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS

	var lib := VoxelBlockyLibrary.new()
	lib.add_model(VoxelBlockyModelEmpty.new())
	var cube := VoxelBlockyModelCube.new()
	cube.atlas_size_in_tiles = Vector2i(4, 4)
	cube.set_material_override(0, mat)
	lib.add_model(cube)
	print("   materials BEFORE bake: ", lib.get_materials().size(), " -> ", lib.get_materials())
	lib.bake()
	var mats: Array = lib.get_materials()
	print("   materials AFTER bake:  ", mats.size())
	for i in mats.size():
		print("      [%d] = %s" % [i, mats[i]])

	print("\n   --- does the model report its material without an override? ---")
	var cube2 := VoxelBlockyModelCube.new()
	print("      get_material_override(0) = ", cube2.get_material_override(0))

	print("\n===== P6: forcing the TYPE channel to 8-bit =====")
	var fmt := VoxelFormat.new()
	print("   default type_depth = ", fmt.type_depth, " (", _depth_name(fmt.type_depth), ")")
	fmt.type_depth = VoxelBuffer.DEPTH_8_BIT
	print("   after set  type_depth = ", fmt.type_depth, " (", _depth_name(fmt.type_depth), ")")
	var b: VoxelBuffer = fmt.create_buffer(Vector3i(16, 16, 16))
	print("   create_buffer -> size ", b.get_size(), " TYPE depth ", _depth_name(b.get_channel_depth(VoxelBuffer.CHANNEL_TYPE)))
	var gen := VoxelGeneratorNoise2D.new()
	var noise := FastNoiseLite.new()
	noise.seed = 7
	gen.noise = noise
	gen.channel = VoxelBuffer.CHANNEL_TYPE
	gen.height_start = 43.0
	gen.height_range = 42.0
	gen.generate_block(b, Vector3i(0, 0, 0), 0)
	b.decompress_channel(VoxelBuffer.CHANNEL_TYPE)
	print("   8-bit TYPE byte array size = ", b.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE).size(), " (expect 4096)")
	print("   memory saving vs 16-bit default: 50% of the TYPE channel")

	print("\n===== P7: BaseMaterial3D texture filter enum values =====")
	for e in ClassDB.class_get_enum_list("BaseMaterial3D", true):
		if String(e).begins_with("TextureFilter"):
			var cs := {}
			for c in ClassDB.class_get_enum_constants("BaseMaterial3D", String(e)):
				cs[String(c)] = ClassDB.class_get_integer_constant("BaseMaterial3D", String(c))
			print("   ", e, " = ", cs)
