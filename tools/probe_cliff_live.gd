extends SceneTree
## tools/probe_cliff_live.gd
##
## M01-fix evidence: what does an extent-1 (neighbour-aware) module cost in the LIVE engine
## path, and does the stream still make progress?
##
## The open question this answers: with the throwaway cliff fixture installed, a 240-frame live
## run loaded 145 blocks where the same run without it loaded 998. Two explanations are
## possible and they mean very different things:
##   (a) a STALL - generation deadlocks or refuses columns, so the terrain never fills in; or
##   (b) a COST - every column is simply much more expensive (the fixture reads ~1400 neighbour
##       voxels per column and the engine grows the editable area), so 240 frames is not enough.
## The probe distinguishes them by sampling loaded blocks over a long window: a stall flattens,
## a cost keeps climbing.
##
## Run: godot --headless --path . --script res://tools/probe_cliff_live.gd

const SAMPLE_FRAMES := [100, 200, 400, 800, 1200, 1800]
const VIEWER_POS := Vector3(8, 70, 8)


func _init() -> void:
	_run()


func _run() -> void:
	var cfg := WorldConfig.load_config()
	VoxelEngine.set_thread_count(4)
	print("CLIFFLIVE engine_thread_count=%d frames sampled=%s" % [VoxelEngine.get_thread_count(), str(SAMPLE_FRAMES)])
	ModuleFixtures.clear()

	for with_cliff in [false, true]:
		ModuleFixtures.clear()
		if with_cliff:
			var installed: Dictionary = ModuleFixtures.install("cliff_pass")
			print("CLIFFLIVE fixture installed=%s" % str(installed))
		var built: Dictionary = AdapterRegistry.build_generator(
			AdapterRegistry.DEFAULT_ID, cfg.seed_value, cfg.to_gen_context())
		if not built["ok"]:
			print("CLIFFLIVE BUILD_FAIL with_cliff=%s %s" % [str(with_cliff), str(built["report"].get("error"))])
			ModuleFixtures.clear()
			quit(1)
			return
		var gen: Object = built["generator"]
		var plan: Dictionary = (built["report"].get("plan", {}) as Dictionary)
		print("CLIFFLIVE with_cliff=%s plan=%s" % [str(with_cliff), str(plan)])

		var ta := TerrainAdapter.new()
		var res: Dictionary = ta.create(cfg.to_terrain_context(), gen, BlockLibraryBuilder.build())
		var terrain: Node3D = res["terrain"]
		var viewer: Node3D = res["viewer"]
		root.add_child(terrain)
		var holder := Node3D.new()
		root.add_child(holder)
		holder.add_child(viewer)
		holder.position = VIEWER_POS

		var t0 := Time.get_ticks_msec()
		var frames := 0
		var series: Array[String] = []
		for target in SAMPLE_FRAMES:
			while frames < int(target):
				await process_frame
				frames += 1
			var elapsed := Time.get_ticks_msec() - t0
			var blocks := ta.get_loaded_block_count()
			var st: Dictionary = gen.call("stats")
			series.append("f=%-5d t=%6d ms blocks=%-5d pass_calls=%s" % [
				frames, elapsed, blocks, str(st.get("pass_calls"))])
			print("CLIFFLIVE   %s" % series[series.size() - 1])

		var st2: Dictionary = gen.call("stats")
		var total_ms := Time.get_ticks_msec() - t0
		print("CLIFFLIVE SUMMARY with_cliff=%s total_ms=%d blocks=%d pass_calls=%s threads=%s" % [
			str(with_cliff), total_ms, ta.get_loaded_block_count(), str(st2.get("pass_calls")),
			str(st2.get("worker_thread_ids"))])
		print("CLIFFLIVE SUMMARY   writer=%s" % str(st2.get("writer")))
		print("CLIFFLIVE SUMMARY   executed=%s" % str(st2.get("executed_counts")))
		print("CLIFFLIVE SUMMARY   timings_ms=%s" % str(st2.get("timings", {})))
		print("CLIFFLIVE SUMMARY   cache=%s" % str(st2.get("field_cache")))
		var calls := 0
		for k in (st2.get("pass_calls", {}) as Dictionary):
			calls += int((st2.get("pass_calls", {}) as Dictionary)[k])
		if calls > 0:
			print("CLIFFLIVE SUMMARY   ms per engine pass call = %.2f (%d calls in %d ms)" % [
				float(total_ms) / float(calls), calls, total_ms])

		# Read a few columns back so "blocks loaded" is not the only evidence of progress.
		var tool: Object = terrain.call("get_voxel_tool")
		var tops: Array[String] = []
		for bx in range(-2, 3):
			var wx := bx * 16 + 8
			var top := -999
			for y in range(120, 20, -1):
				if int(tool.call("get_voxel", Vector3i(wx, y, 8))) != 0:
					top = y
					break
			tops.append("x=%d top=%d id=%d" % [wx, top, int(tool.call("get_voxel", Vector3i(wx, top, 8)))])
		print("CLIFFLIVE SUMMARY   surface at z=8: %s" % str(tops))

		terrain.queue_free()
		holder.queue_free()
		ta.release()
		for i in 20:
			await process_frame

	ModuleFixtures.clear()
	print("CLIFFLIVE fixtures after clear=%s" % str(ModuleFixtures.installed()))
	quit(0)
