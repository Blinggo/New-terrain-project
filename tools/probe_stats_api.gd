extends SceneTree
func _init() -> void:
	print("--- RenderingServer RENDERING_INFO_* constants ---")
	for c in ClassDB.class_get_integer_constant_list("RenderingServer", true):
		var n := String(c)
		if n.begins_with("RENDERING_INFO"):
			print("   %-52s = %d" % [n, ClassDB.class_get_integer_constant("RenderingServer", n)])
	print("--- RenderingServer.get_rendering_info signature ---")
	for m in ClassDB.class_get_method_list("RenderingServer", true):
		if String(m["name"]) == "get_rendering_info":
			print("   args: ", m["args"])
	print("--- OS memory methods ---")
	for m in ClassDB.class_get_method_list("OS", true):
		var n := String(m["name"])
		if "memory" in n or "static" in n:
			print("   ", n)
	print("--- live values ---")
	print("   draw calls   = ", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	print("   primitives   = ", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	print("   static mem   = ", OS.get_static_memory_usage())
	print("   peak static  = ", OS.get_static_memory_peak_usage())
	print("   Engine.get_frames_per_second = ", Engine.get_frames_per_second())
	quit(0)
