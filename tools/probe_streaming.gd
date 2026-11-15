extends SceneTree
## tools/probe_streaming.gd
##
## Answers the questions the API dump cannot, by actually streaming blocks headless:
##
##   Q1 What are the real keys of VoxelTerrain.get_statistics()? The T7 HUD must print real
##      keys, and the M00 report must list what is actually available.
##   Q2 Is VoxelViewer.view_distance in VOXELS or in DATA BLOCKS? The class docs do not say.
##      We measure the loaded footprint radius for view_distance = 8 and for 128 (= 8*16).
##      Whichever value produces a ~17x17 block footprint is the real unit.
##   Q3 How many data blocks does a 384-tall column cost at a given view distance? This
##      number drives every performance decision in docs/ARCHITECTURE.md.
##   Q4 How are loaded blocks represented in the scene tree (for counting them in the
##      runtime benchmark), and what does VoxelEngine.get_stats() expose?
##
## Runs headless: godot --headless --path <project> --script res://tools/probe_streaming.gd

const SETTLE_FRAMES := 200
const SCAN_RADIUS := 12  # data blocks scanned around the viewer in X/Z

var _adapter := TerrainAdapter.new()
var _terrain: Node3D = null


func _initialize() -> void:
	# Do NOT override _process() here: that is SceneTree's own MainLoop virtual and replacing
	# it stops the tree from ticking. Drive the probe from a coroutine instead.
	_run()


func _run() -> void:
	var cfg := WorldConfig.load_config()
	print("config: ", cfg.describe())
	for w in cfg.validation_warnings:
		print("   warning: ", w)
	for e in cfg.validation_errors:
		print("   ERROR: ", e)

	var lib_result := BlockLibraryBuilder.build()
	print("library: ok=%s models=%s materials=%s errors=%s" % [
		lib_result["ok"], lib_result["report"].get("model_count"), lib_result["report"].get("materials"),
		lib_result["report"]["errors"],
	])

	var gen_result := AdapterRegistry.build_generator(cfg.generator_id, cfg.seed_value, cfg.to_gen_context())
	print("generator: id=%s ok=%s class=%s" % [
		cfg.generator_id, gen_result["ok"],
		gen_result["generator"].get_class() if gen_result["generator"] != null else "null",
	])

	var res := _adapter.create(cfg.to_terrain_context(), gen_result["generator"], lib_result)
	print("terrain: ok=%s report=%s" % [res["ok"], res["report"]])
	_terrain = res["terrain"]
	root.add_child(_terrain)

	var camera := Camera3D.new()
	root.add_child(camera)          # enter the tree FIRST ...
	camera.current = true
	camera.position = Vector3(8, 90, 8)   # ... then place it (global_* needs a tree)

	var viewer: Node3D = res["viewer"]
	camera.add_child(viewer)
	print("viewer in tree: ", viewer.is_inside_tree(), " transform=", viewer.global_transform.origin)

	print("\n===== Q4: VoxelEngine.get_stats() =====")
	var engine_stats := _voxel_engine_stats()
	_print_nested(engine_stats, "   ")

	await _settle(SETTLE_FRAMES)

	print("\n===== Q1: VoxelTerrain.get_statistics() keys =====")
	var stats := _adapter.get_statistics()
	_print_nested(stats, "   ")
	print("   key list: ", stats.keys())

	print("\n===== Q4b: scene-tree representation of loaded blocks =====")
	print("   terrain child count: ", _terrain.get_child_count())
	var kinds := {}
	for c in _terrain.get_children():
		kinds[c.get_class()] = int(kinds.get(c.get_class(), 0)) + 1
	print("   child classes: ", kinds)
	for i in mini(3, _terrain.get_child_count()):
		var c: Node = _terrain.get_child(i)
		print("      child[%d] %s name=%s" % [i, c.get_class(), c.name])

	print("\n===== Q2: view_distance units (footprint radius in data blocks) =====")
	for candidate: int in [8, 128]:
		viewer.set("view_distance", candidate)
		_terrain.call("set_max_view_distance", maxi(candidate, 256) * 2)
		await _settle(SETTLE_FRAMES)
		var fp := _scan_footprint(Vector3i.ZERO)
		print("   view_distance=%-4d -> %s" % [candidate, fp["summary"]])

	print("\n===== Q4c: VoxelEngine.get_stats() AFTER streaming settled =====")
	_print_nested(_voxel_engine_stats(), "   ")
	var mp: Dictionary = _voxel_engine_stats().get("memory_pools", {})
	print("   memory_pools.block_count = ", mp.get("block_count"))
	print("   memory_pools.voxel_used  = ", mp.get("voxel_used"))
	print("   -> this is the real 'max loaded blocks' metric for T7/T9")

	print("\n===== Q3: cost of a 384-tall column =====")
	print("   column_block_count = %d  (world height %d / mesh_block_size %d)" % [
		cfg.column_block_count(), cfg.world_height(), cfg.mesh_block_size])
	for vd: int in [6, 8, 12]:
		var blocks := (2 * vd + 1) * (2 * vd + 1) * cfg.column_block_count()
		print("   vd=%2d blocks -> %5d data blocks -> TYPE 8-bit %6.1f MB, 16-bit %6.1f MB (voxel payload only)" % [
			vd, blocks, blocks * 4096.0 / 1048576.0, blocks * 8192.0 / 1048576.0])

	quit(0)


func _settle(frames: int) -> void:
	for i in frames:
		await process_frame


func _voxel_engine_stats() -> Dictionary:
	var ve: Object = ClassDB.instantiate("VoxelEngine")
	if ve == null:
		return {}
	var s: Variant = ve.call("get_stats")
	ve.free()
	return s if s is Dictionary else {}


## Count loaded data blocks in a box around `centre` using the real VoxelTerrain API
## (has_data_block). Returns the footprint extents so the two candidate units can be told
## apart: a radius of ~8 blocks means view_distance was in blocks; ~0-1 means voxels.
func _scan_footprint(centre_block: Vector3i) -> Dictionary:
	## centre_block is in DATA BLOCK coordinates (16 voxels each); y comes from the row loop.
	var loaded := 0
	var scanned := 0
	var min_x := 999999
	var max_x := -999999
	var min_z := 999999
	var max_z := -999999
	var rows_loaded := {}
	for dx in range(-SCAN_RADIUS, SCAN_RADIUS + 1):
		for dz in range(-SCAN_RADIUS, SCAN_RADIUS + 1):
			for row in 24:
				var pos := Vector3i(centre_block.x + dx, -4 + row, centre_block.z + dz)
				scanned += 1
				if bool(_terrain.call("has_data_block", pos)):
					loaded += 1
					min_x = mini(min_x, pos.x)
					max_x = maxi(max_x, pos.x)
					min_z = mini(min_z, pos.z)
					max_z = maxi(max_z, pos.z)
					rows_loaded[pos.y] = true
	var summary := "loaded %d / %d scanned, x [%d..%d] z [%d..%d] rows %d" % [
		loaded, scanned, min_x, max_x, min_z, max_z, rows_loaded.size()
	]
	return {"loaded": loaded, "scanned": scanned, "summary": summary}


func _print_nested(d: Dictionary, indent: String) -> void:
	if d.is_empty():
		print(indent, "(empty)")
		return
	var keys: Array = d.keys()
	keys.sort()
	for k in keys:
		var v: Variant = d[k]
		if v is Dictionary:
			print(indent, str(k), ":")
			_print_nested(v, indent + "   ")
		else:
			print(indent, str(k), " = ", v)
