extends SceneTree
func _init() -> void:
	var cfg := WorldConfig.load_config()
	var built := AdapterRegistry.build_generator("multipass", 12345, cfg.to_gen_context())
	var gen: MultipassColumnGenerator = built["generator"]
	var col: Dictionary = gen._column(0, 0, true)
	var data: PackedByteArray = col["data"]
	var heights: PackedInt32Array = col["height"]
	print("heights[0..3]=", heights[0], heights[1], heights[2], heights[3])
	var vals: Array = []
	for wy in range(58, 72):
		vals.append(data[(wy + 64) * 256 + 0])
	print("col(0,0) ids y58..71=", vals)
	var vals2: Array = []
	for wy in range(310, 320):
		vals2.append(data[(wy + 64) * 256 + 0])
	print("ids y310..319=", vals2)
	print("board errors=", gen._board.errors.slice(0, 4))
	print("stats=", gen.stats()["column_compiles"], gen.stats()["pass_b_applications"])
	quit(0)
