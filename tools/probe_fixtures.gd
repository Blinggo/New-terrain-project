extends SceneTree
## M01-fix scratch check of the fixture modules through the DEFAULT backend.
func _init() -> void:
	_run()
func _run() -> void:
	var cfg := WorldConfig.load_config()
	ModuleFixtures.clear()
	var origins := ChunkOrigins.get_origins(cfg.sea_level)

	var base := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
	var base_hashes := ChunkHasher.hash_all(base["generator"], origins, 16, cfg.type_depth_bits)
	print("FIX baseline native_cb built=%s hashes=%d" % [str(base["ok"]), base_hashes.size()])

	# 1. marker pass must change output
	ModuleFixtures.install("marker_pass")
	var m := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
	if not m["ok"]:
		print("FIX marker build FAIL %s" % str(m["report"].get("error")))
	else:
		var mh := ChunkHasher.hash_all(m["generator"], origins, 16, cfg.type_depth_bits)
		var changed := 0
		for k in base_hashes:
			if mh.get(k, "") != base_hashes[k]:
				changed += 1
		var col: MemoryColumnWriter = m["generator"].call("debug_column_memory", Vector3i(0, -64, 0))
		print("FIX marker: changed=%d/%d marker_voxels_at_row96=%d executed=%s" % [
			changed, base_hashes.size(), _count_id(col, ModuleFixtures.MARKER_ID), str((m["generator"].call("stats") as Dictionary).get("executed_counts"))])
	ModuleFixtures.uninstall("marker_pass")

	# 2. no-op pass must NOT change output
	ModuleFixtures.install("no_op_pass")
	var n := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
	var nh := ChunkHasher.hash_all(n["generator"], origins, 16, cfg.type_depth_bits)
	var same := 0
	for k in base_hashes:
		if nh.get(k, "") == base_hashes[k]:
			same += 1
	print("FIX noop: identical=%d/%d executed=%s" % [same, base_hashes.size(), str((n["generator"].call("stats") as Dictionary).get("executed_counts"))])
	ModuleFixtures.uninstall("no_op_pass")

	# 3. bare module must be refused loudly
	ModuleFixtures.install("bare_module")
	var b := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
	print("FIX bare: built=%s error=%s" % [str(b["ok"]), str(b["report"].get("error", ""))])
	ModuleFixtures.uninstall("bare_module")

	# 4. cliff pass (extent 1) must compile into 2 engine passes and still generate
	ModuleFixtures.install("cliff_pass")
	var c := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
	if not c["ok"]:
		print("FIX cliff build FAIL %s" % str(c["report"].get("error")))
	else:
		var st: Dictionary = c["generator"].call("stats")
		var ch := ChunkHasher.hash_all(c["generator"], origins, 16, cfg.type_depth_bits)
		var changed2 := 0
		for k in base_hashes:
			if ch.get(k, "") != base_hashes[k]:
				changed2 += 1
		print("FIX cliff: built pass_count=%s plan=%s changed=%d/%d" % [
			str(st.get("pass_count")), str((st.get("plan") as Dictionary).get("passes")), changed2, base_hashes.size()])
	ModuleFixtures.uninstall("cliff_pass")

	# 5. stamp probe must execute and write its box
	ModuleFixtures.install("stamp_probe")
	var s := AdapterRegistry.build_generator("native_cb", cfg.seed_value, cfg.to_gen_context())
	if not s["ok"]:
		print("FIX stamp build FAIL %s" % str(s["report"].get("error")))
	else:
		var col2: MemoryColumnWriter = s["generator"].call("debug_column_memory", Vector3i(0, -64, 0))
		var st2: Dictionary = s["generator"].call("stats")
		print("FIX stamp: markers=%d placements=%s executed=%s" % [
			_count_id(col2, ModuleFixtures.MARKER_ID), str(st2.get("stamp_placements")), str(st2.get("executed_counts"))])
	ModuleFixtures.uninstall("stamp_probe")

	ModuleFixtures.clear()
	print("FIX leftover files: %s" % str(ModuleFixtures.installed()))
	quit(0)

func _count_id(col: MemoryColumnWriter, id: int) -> int:
	var n := 0
	var b: Array = col.bounds_main()
	var bmin: Vector3i = b[0]
	var bmax: Vector3i = b[1]
	for y in range(bmin.y, bmax.y):
		for z in range(bmin.z, bmax.z):
			for x in range(bmin.x, bmax.x):
				if col.get_type_world(Vector3i(x, y, z)) == id:
					n += 1
	return n
