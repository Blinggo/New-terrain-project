extends SceneTree
## M01-fix / T1+T4 gate: does the native multipass backend produce the SAME voxels through
## live engine streaming as through the determinism harness path, on worker threads?
func _init() -> void:
	_run()


func _run() -> void:
	var cfg := WorldConfig.load_config()
	# Force several engine worker threads so the concurrency claim is measured, not assumed:
	# with one thread a data race can hide for a whole test run.
	VoxelEngine.set_thread_count(4)
	print("LIVE engine_thread_count=%d" % VoxelEngine.get_thread_count())
	var built := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
	if not built["ok"]:
		print("LIVE BUILD_FAIL %s" % str(built["report"].get("error")))
		quit(1)
		return
	var gen: Object = built["generator"]
	var lib_result := BlockLibraryBuilder.build()
	var res := TerrainAdapter.new().create(cfg.to_terrain_context(), gen, lib_result)
	var terrain: Node3D = res["terrain"]
	var viewer: Node3D = res["viewer"]
	root.add_child(terrain)
	var holder := Node3D.new()
	root.add_child(holder)
	holder.add_child(viewer)
	holder.position = Vector3(8, 70, 8)
	for i in 240:
		await process_frame
	var blocks: int = TerrainAdapter.new().get_loaded_block_count()
	var st: Dictionary = gen.call("stats")
	print("LIVE loaded_blocks=%d threads=%s pass_calls=%s executed=%s" % [
		blocks, str(st.get("worker_thread_ids")), str(st.get("pass_calls")), str(st.get("executed_counts"))])

	# Compare engine-streamed voxels against the harness path over a grid of positions.
	var checked := 0
	var mismatched := 0
	var examples: Array = []
	var column: MemoryColumnWriter = gen.call("debug_column_memory", Vector3i(0, -64, 0))
	if not terrain.has_method("get_voxel_tool"):
		print("LIVE NO_READ_API: VoxelTerrain has no get_voxel_tool()")
		quit(1)
		return
	var tool: VoxelTool = terrain.call("get_voxel_tool")
	for lx in range(0, 16, 3):
		for lz in range(0, 16, 3):
			for wy in range(40, 96, 4):
				var pos := Vector3i(lx, wy, lz)
				var live: int = tool.get_voxel(pos)
				var harness: int = column.get_type_world(pos)
				checked += 1
				if live != harness:
					mismatched += 1
					if examples.size() < 6:
						examples.append("%s live=%d harness=%d" % [str(pos), live, harness])
	print("LIVE compare checked=%d mismatched=%d examples=%s" % [checked, mismatched, str(examples)])
	print("LIVE non_air_sample=%s" % str(_column_profile(tool)))
	quit(0 if mismatched == 0 and checked > 0 else 1)


func _column_profile(tool: VoxelTool) -> Dictionary:
	var out := {}
	for lx in [0, 7, 15]:
		var top := -999
		for wy in range(-64, 320):
			if tool.get_voxel(Vector3i(lx, wy, lx)) != 0:
				top = wy
		out["x%d_z%d_top" % [lx, lx]] = top
	return out
