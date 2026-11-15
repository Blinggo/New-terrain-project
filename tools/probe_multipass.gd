extends SceneTree
func _init() -> void:
	print("=== probe_multipass ===")
	var props: Array = ClassDB.class_get_property_list("VoxelGeneratorMultipassCB", true)
	print("CB props:", props.map(func(p): return String(p["name"]) + ":" + type_string(int(p["type"]))))
	var methods: Array = ClassDB.class_get_method_list("VoxelGeneratorMultipassCB", false)
	print("CB methods:", methods.map(func(m): return m["name"] + "(" + str(m["args"].size()) + ")"))
	var tmethods: Array = ClassDB.class_get_method_list("VoxelToolMultipassGenerator", false)
	print("Tool methods:", tmethods.map(func(m): return m["name"] + "(" + str(m["args"].size()) + ")"))
	var gen := VoxelGeneratorMultipassCB.new()
	gen.set_pass_count(2)
	print("pass_count=", gen.get_pass_count(), " base_y=", gen.get_column_base_y_blocks(), " height=", gen.get_column_height_blocks())
	print("extent0=", gen.get_pass_extent_blocks(0))
	# try a scripted pass
	var tool: VoxelToolMultipassGenerator = ClassDB.instantiate("VoxelToolMultipassGenerator")
	print("tool class=", tool.get_class(), " script settable=", tool.has_method("set_script"))
	print("tool has script:", tool.get_script() != null)
	# what does a GDScript subclass see as overridable?
	print("CB virtuals:", ClassDB.class_get_method_list("VoxelGeneratorMultipassCB", false).map(func(m): return m["name"]).filter(func(n): return String(n).begins_with("_")))
	quit(0)
