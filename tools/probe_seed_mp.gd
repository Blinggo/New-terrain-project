extends SceneTree
func _init() -> void:
	var cfg := WorldConfig.load_config()
	for seed_v in [12345, 54321]:
		var built := AdapterRegistry.build_generator("multipass", seed_v, cfg.to_gen_context())
		var gen: Resource = built["generator"]
		var tops: Array = []
		for co in [Vector3i(0, 0, 0), Vector3i(512, 0, -384), Vector3i(37568, 0, 51696)]:
			var format := VoxelFormat.new()
			format.type_depth = VoxelBuffer.DEPTH_8_BIT
			var buf := VoxelBuffer.new()
			buf.create(16, 16, 16)
			for row in range(0, 24):
				gen.call("generate_block", buf, Vector3i(co.x, -64 + row * 16, co.z), 0)
				for y in 16:
					if buf.get_voxel(0, y, 0, VoxelBuffer.CHANNEL_TYPE) != 0:
						pass
			# top solid over row scan
			var top := -65
			for row in range(0, 24):
				gen.call("generate_block", buf, Vector3i(co.x, -64 + row * 16, co.z), 0)
				for y in 16:
					if buf.get_voxel(0, y, 0, VoxelBuffer.CHANNEL_TYPE) != 0:
						top = maxi(top, -64 + row * 16 + y)
			tops.append(top)
		print("seed %d tops=%s stats=%s" % [seed_v, str(tops), str((gen as MultipassColumnGenerator).stats()["column_compiles"])])
	quit(0)
