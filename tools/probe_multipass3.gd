extends SceneTree

class GenProbe extends VoxelGeneratorScript:
	var calls := 0
	func _generate_block(buffer: VoxelBuffer, origin: Vector3i, lod: int) -> void:
		calls += 1
		buffer.fill(1, VoxelBuffer.CHANNEL_TYPE)

func _init() -> void:
	print("=== probe_multipass3 ===")
	print("VoxelGeneratorScript exists=", ClassDB.class_exists("VoxelGeneratorScript"),
		" instantiable=", ClassDB.can_instantiate("VoxelGeneratorScript"))
	var g := GenProbe.new()
	print("genprobe class=", g.get_class(), " is VoxelGenerator=", g is VoxelGenerator)
	var buf := VoxelBuffer.new()
	buf.create(16, 16, 16)
	g.generate_block(buf, Vector3i(0, 0, 0), 0)
	print("calls=", g.calls, " voxel(0,0,0)=", buf.get_voxel(0, 0, 0, VoxelBuffer.CHANNEL_TYPE))
	# can a VoxelTerrain use it?
	print("VoxelGeneratorScript methods:", ClassDB.class_get_method_list("VoxelGeneratorScript", false).map(func(m): return m["name"]).filter(func(n): return String(n).begins_with("_")))
	quit(0)
