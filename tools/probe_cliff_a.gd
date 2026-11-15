extends SceneTree
func _init() -> void:
	_run()
func _run() -> void:
	var cfg := WorldConfig.load_config()
	var origins := ChunkOrigins.get_origins(cfg.sea_level).slice(0, 4)
	ModuleFixtures.clear()
	ModuleFixtures.install("cliff_pass")
	var t0 := Time.get_ticks_msec()
	var cl := AdapterRegistry.build_generator("experimental_columns", cfg.seed_value, cfg.to_gen_context())
	print("A build ok=%s ms=%d" % [str(cl["ok"]), Time.get_ticks_msec() - t0])
	if not cl["ok"]:
		print("A BUILD FAIL %s" % str(cl["report"].get("error")))
		ModuleFixtures.clear()
		quit(1)
		return
	t0 = Time.get_ticks_msec()
	var col: MemoryColumnWriter = cl["generator"].call("debug_column_memory", Vector3i(0, -64, 0))
	print("A one column ms=%d changed_rows=%d" % [Time.get_ticks_msec() - t0, _top_profile(col)])
	t0 = Time.get_ticks_msec()
	var ch := ChunkHasher.hash_all(cl["generator"], origins, 16, cfg.type_depth_bits)
	print("A hash4 ms=%d n=%d" % [Time.get_ticks_msec() - t0, ch.size()])
	var st: Dictionary = cl["generator"].call("stats")
	print("A stats compiles=%s neighbour_reads=%s cache=%s" % [str(st.get("column_compiles")), str(st.get("neighbour_reads")), str(st.get("field_cache"))])
	ModuleFixtures.clear()
	quit(0)
func _top_profile(col: MemoryColumnWriter) -> int:
	var n := 0
	for x in range(0, 16, 4):
		var top := col.top_solid(x, x)
		if top > 0:
			n += 1
	return n
