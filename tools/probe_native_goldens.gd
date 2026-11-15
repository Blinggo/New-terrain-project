extends SceneTree
## M01-fix scratch probe: does the native multipass backend reproduce the compiled graph's
## golden hashes over the 64 committed origins, and over 256 extra surface-band origins?
func _init() -> void:
	var cfg := WorldConfig.load_config()
	var origins := ChunkOrigins.get_graph_parity_origins(cfg.sea_level, 256)
	print("ORIGINS %d (%s)" % [origins.size(), ChunkOrigins.describe(cfg.sea_level)])
	var golden := JsonData.load_file("res://tests/determinism/golden_hashes.json")
	var graph_gold: Dictionary = golden["by_generator"]["graph"]

	var results := {}
	for id in ["graph", "native_cb", "experimental_columns"]:
		var built := AdapterRegistry.build_generator(id, cfg.seed_value, cfg.to_gen_context())
		if not built["ok"]:
			print("BUILD_FAIL %s: %s" % [id, str(built["report"])])
			continue
		var t0 := Time.get_ticks_usec()
		var fresh := ChunkHasher.hash_all(built["generator"], origins, 16, cfg.type_depth_bits)
		var elapsed := Time.get_ticks_usec() - t0
		print("BACKEND %s: %d origins in %.1f ms (%.3f ms per 16^3 block, %.2f ms per 24-block column)" % [
			id, origins.size(), elapsed / 1000.0, elapsed / 1000.0 / origins.size(), elapsed / 1000.0 / (origins.size() / 24.0)])
		results[id] = fresh
		var match_graph := 0
		for k in graph_gold:
			if fresh.get(k, "?") == graph_gold[k]:
				match_graph += 1
		print("BACKEND %s: %d/%d match the committed graph goldens" % [id, match_graph, graph_gold.size()])
		if id != "graph":
			var mismatches: Array = []
			for k in graph_gold:
				if fresh.get(k, "?") != graph_gold[k]:
					mismatches.append(k)
			print("BACKEND %s mismatched committed-golden origins: %s" % [id, str(mismatches)])
			# Full parity: every one of the 320 origins against a FRESH graph run.
			var graph_fresh: Dictionary = results.get("graph", {})
			var parity_mismatch: Array = []
			var non_air := 0
			for k in fresh:
				if graph_fresh.get(k, "?") != fresh[k]:
					parity_mismatch.append(k)
			print("BACKEND %s parity vs fresh graph over %d origins: %d mismatches %s" % [
				id, fresh.size(), parity_mismatch.size(), str(parity_mismatch.slice(0, 8))])
		var gen: Object = built["generator"]
		if gen.has_method("stats"):
			var st: Dictionary = gen.call("stats")
			print("BACKEND %s stats: executed=%s writer=%s plan_passes=%s cache=%s" % [
				id, str(st.get("executed_counts")), str(st.get("writer")),
				str((st.get("plan") as Dictionary).get("pass_count")), str(st.get("field_cache"))])
	quit(0)
