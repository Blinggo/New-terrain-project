extends SceneTree

class PassProbe extends VoxelToolMultipassGenerator:
	var calls := 0
	var ctx_class := ""
	var ctx_methods: Array = []
	func _generate_block(ctx: VoxelBuffer) -> void:
		pass
	func _generate_block2(ctx: Variant) -> void:
		calls += 1
		ctx_class = String(ctx.get_class()) if ctx is Object else str(typeof(ctx))
		if ctx is Object:
			ctx_methods = (ctx as Object).get_method_list().map(func(m): return m["name"])

func _init() -> void:
	print("=== probe_multipass2 ===")
	var gen := VoxelGeneratorMultipassCB.new()
	var plist: Array = gen.get_property_list()
	print("instance props:", plist.map(func(p): return String(p["name"])))
	gen.set_pass_count(2)
	var probe := PassProbe.new()
	for cand in ["passes", "pass_list", "tools", "passes_array"]:
		if gen.get(cand) != null or cand in gen:
			print("dynamic prop found:", cand, "=", gen.get(cand))
	# brute force: try setting
	var ok := false
	for cand in ["passes"]:
		gen.set(cand, [probe, probe])
		ok = true
		print("set", cand, "->", gen.get(cand))
	print("ok=", ok)
	var buf := VoxelBuffer.new()
	buf.create(16, 16, 16)
	gen.generate_block(buf, Vector3i(0, 0, 0), 0)
	print("probe calls=", probe.calls, " ctx_class=", probe.ctx_class)
	print("ctx methods=", probe.ctx_methods)
	quit(0)
