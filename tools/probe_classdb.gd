extends SceneTree

func _names(cls: String) -> Array:
	var out := []
	for m in ClassDB.class_get_method_list(cls, true):
		out.append(String(m["name"]))
	out.sort()
	return out

func _init() -> void:
	print("VERSION INFO: ", Engine.get_version_info())
	print("--- ClassDB scriptable methods ---")
	print(_names("ClassDB"))
	print("--- Engine version-ish methods ---")
	var e := _names("Engine")
	for n in e:
		if "version" in n or "info" in n:
			print("   ", n)
	print("--- VoxelTerrain exists: ", ClassDB.class_exists("VoxelTerrain"))
	print("--- VoxelEngine exists: ", ClassDB.class_exists("VoxelEngine"))
	print("--- parent of VoxelTerrain: ", ClassDB.get_parent_class("VoxelTerrain"))
	quit(0)
