extends SceneTree
## Neighbour-pass evidence: the self-hosted backend (harness path) and the native backend
## (live engine streaming) must BOTH show the extent-1 fixture changing terrain.
func _init() -> void:
	_run()
func _run() -> void:
	var cfg := WorldConfig.load_config()
	var origins := ChunkOrigins.get_origins(cfg.sea_level)
	ModuleFixtures.clear()

	# (a) experimental_columns: neighbours are compiled in-process, so the harness path works.
	var base := AdapterRegistry.build_generator("experimental_columns", cfg.seed_value, cfg.to_gen_context())
	if not base["ok"]:
		print("CLIFF baseline build FAILED")
		quit(1)
		return
	var bh := ChunkHasher.hash_all(base["generator"], origins, 16, cfg.type_depth_bits)
	ModuleFixtures.install("cliff_pass")
	var cl := AdapterRegistry.build_generator("experimental_columns", cfg.seed_value, cfg.to_gen_context())
	if not cl["ok"]:
		print("CLIFF cliff build FAILED %s" % str(cl["report"].get("error")))
		ModuleFixtures.clear()
		quit(1)
		return
	var ch := ChunkHasher.hash_all(cl["generator"], origins, 16, cfg.type_depth_bits)
	var changed := 0
	for k in bh:
		if ch.get(k, "") != bh[k]:
			changed += 1
	var st: Dictionary = cl["generator"].call("stats")
	print("CLIFF experimental_columns: changed=%d/%d neighbour_reads=%s passes=%s compiles=%s" % [
		changed, bh.size(), str(st.get("neighbour_reads")), str((st.get("plan") as Dictionary).get("pass_count")), str(st.get("column_compiles"))])
	ModuleFixtures.uninstall("cliff_pass")

	# (b) native_cb live: the engine supplies neighbours in the pass-1 editable area.
	for with_cliff in [false, true]:
		ModuleFixtures.clear()
		if with_cliff:
			ModuleFixtures.install("cliff_pass")
		var built := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
		if not built["ok"]:
			print("CLIFF native build FAILED %s" % str(built["report"].get("error")))
			ModuleFixtures.clear()
			quit(1)
			return
		var gen: Object = built["generator"]
		var ta := TerrainAdapter.new()
		var res := ta.create(cfg.to_terrain_context(), gen, BlockLibraryBuilder.build())
		var terrain: Node3D = res["terrain"]
		var viewer: Node3D = res["viewer"]
		root.add_child(terrain)
		var holder := Node3D.new()
		root.add_child(holder)
		holder.add_child(viewer)
		holder.position = Vector3(8, 70, 8)
		VoxelEngine.set_thread_count(4)
		var t0 := Time.get_ticks_msec()
		for i in 400:
			await process_frame
		var tool: VoxelTool = terrain.call("get_voxel_tool")
		var stone_tops := 0
		var grass_tops := 0
		var scanned := 0
		for bx in range(-3, 4):
			for bz in range(-3, 4):
				var wx := bx * 16 + 8
				var wz := bz * 16 + 8
				var top := -999
				for y in range(120, 20, -1):
					if tool.get_voxel(Vector3i(wx, y, wz)) != 0:
						top = y
						break
				if top < 21:
					continue
				scanned += 1
				var tid := tool.get_voxel(Vector3i(wx, top, wz))
				if tid == 3:
					stone_tops += 1
				elif tid == 1:
					grass_tops += 1
		var st2: Dictionary = gen.call("stats")
		print("CLIFF native_cb live with_cliff=%s ms=%d blocks=%d scanned=%d stone_tops=%d grass_tops=%d pass_calls=%s writer=%s threads=%s" % [
			str(with_cliff), Time.get_ticks_msec() - t0, ta.get_loaded_block_count(), scanned, stone_tops, grass_tops,
			str(st2.get("pass_calls")), str(st2.get("writer")), str(st2.get("worker_thread_ids"))])
		terrain.queue_free()
		holder.queue_free()
		for i in 10:
			await process_frame
	ModuleFixtures.clear()
	quit(0)
