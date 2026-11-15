extends SceneTree
## tools/dump_graph_nodes.gd
##
## M00 / T2 (part 2) - The VoxelGeneratorGraph node API is NOT on VoxelGeneratorGraph in
## 1.7; it is on VoxelGraphFunction (reached via get_main_function()). This tool asks the
## engine for the authoritative description of every node type (params, input names,
## output names) so we never guess a parameter name.
##
## Writes: res://docs/reports/voxel_graph_nodes.json

const OUT_PATH := "res://docs/reports/voxel_graph_nodes.json"


func _init() -> void:
	var gen = ClassDB.instantiate("VoxelGeneratorGraph")
	if gen == null:
		push_error("dump_graph_nodes: cannot instantiate VoxelGeneratorGraph")
		quit(1)
		return

	var fn: Object = gen.call("get_main_function")
	if fn == null:
		push_error("dump_graph_nodes: get_main_function() returned null")
		gen.free()
		quit(1)
		return

	var type_count: int = fn.call("get_node_type_count")
	var out := {
		"source": "VoxelGraphFunction.get_node_type_info(id) on a live VoxelGeneratorGraph main function",
		"node_type_count": type_count,
		"node_types": {},
		"outputs_available": [],
	}

	for i in range(type_count):
		var info: Dictionary = fn.call("get_node_type_info", i)
		var rec := {}
		for k in info:
			rec[String(k)] = _jsonable(info[k])
		var name := String(info.get("name", "?"))
		out["node_types"][name] = rec
		if name.begins_with("Output") or name.begins_with("output"):
			out["outputs_available"].append({"id": i, "name": name})

	# Also record the generator's own channel usage API, which decides whether the graph
	# can write to the TYPE channel at all.
	out["voxel_generator_methods"] = []
	for m in ClassDB.class_get_method_list("VoxelGenerator", true):
		out["voxel_generator_methods"].append(String(m["name"]))
	out["voxel_generator_graph_methods"] = []
	for m in ClassDB.class_get_method_list("VoxelGeneratorGraph", true):
		out["voxel_generator_graph_methods"].append(String(m["name"]))

	var json := JSON.stringify(out, "\t")
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(json)
	f.close()

	print("dump_graph_nodes: wrote %s (%d bytes), %d node types" % [OUT_PATH, json.length(), type_count])
	print("--- OUTPUT NODES AVAILABLE ---")
	for o in out["outputs_available"]:
		print("   ", o["id"], " ", o["name"])
	print("--- ALL NODE TYPE NAMES ---")
	var names: Array = out["node_types"].keys()
	names.sort()
	print("   ", ", ".join(names))

	# NOTE: VoxelGeneratorGraph is a Resource (RefCounted) - calling free() on it raises
	# "Can't free a RefCounted object" and aborts the script before quit() runs. Just drop
	# the reference; RefCounted cleans itself up.
	quit(0)


func _jsonable(v) -> Variant:
	if v is Array:
		var out := []
		for e in v:
			out.append(_jsonable(e))
		return out
	if v is Dictionary:
		var outd := {}
		for k in v:
			outd[String(k)] = _jsonable(v[k])
		return outd
	if v is StringName:
		return String(v)
	return v
