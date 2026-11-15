extends RefCounted
## tests/perf/bench_generation.gd
##
## M00 / T9.1, rewritten in the M01 fix - Generation cost benchmark. HEADLESS, deterministic.
##
## WHAT IS MEASURED
##   B1  per-adapter generation cost over a fixed 512x512-block footprint (32x32 = 1024 data
##       block columns, each 24 blocks tall). Every adapter is timed through the SAME entry
##       point the determinism harness uses (ChunkHasher.source_kind dispatch), because the
##       backends no longer share one API:
##         * legacy "block" generators (graph, noise2d) implement generate_block();
##         * the modular backends produce a whole 384-block column per call, and the native
##           one's generate_block() is "Not implemented" in the extension (measured, not
##           assumed - see docs/adr/ADR-0004). Timing those through generate_block() would
##           have produced a number for an empty buffer, i.e. a fabricated speed.
##   B2  one normalised table: ms/column, ms per 16^3 chunk equivalent, columns/s.
##   B3  the engine's OWN cost estimate where it exposes one (compiled graph only).
##   B4  expressiveness: which distinct voxel ids each backend actually writes.
##   B5  neighbour-pass cost: the same backends with a throwaway extent-1 module installed,
##       which is the only way to price a cliff/erosion-style pass before M02 needs one.
##   B6  the engine-native path for the default backend: debug_generate_test_column(), which
##       runs _generate_pass against a real VoxelToolMultipassGenerator (do_box spans), i.e.
##       the cost the streaming engine actually pays - not the GDScript MemoryColumnWriter
##       the harness uses.
##   B7  the recommendation, with the gate results it rests on.
##
## WHAT IS *NOT* MEASURED (and must not be claimed)
##   B1/B2/B5/B6 are single-threaded caller-side timings. The runtime streams terrain through
##   VoxelEngine's thread pools, so real in-game throughput is higher (X22 measures the live
##   path with 4 worker threads and compares voxels, not times). Meshing, block loading and
##   GPU upload are excluded entirely; bench_runtime.gd measures the real pipeline. Numbers
##   here are a GENERATOR COST comparison on this machine, not a frame budget and never a
##   phone number (B0 says so loudly).

const SUITE := "perf"

## Block footprint (in blocks) of the benchmarked area per side. 512 as specified by T9.
const BENCH_FOOTPRINT := 512
const BENCH_COLUMN_STRIDE := 16   # one data block column per 16 blocks => 32x32 columns

## How many data-block rows per column. 384 / 16 = 24. Used ONLY to normalise a column cost
## into the M00 per-chunk figure so old and new numbers stay comparable.
const ROWS_PER_COLUMN := 24

## Percentiles T9 asks for.
const PCT := [50, 95]

## Minimum samples for a stable percentile.
const MIN_SAMPLES_FOR_P95 := 200

## Columns timed for B5 (neighbour passes). The extent-1 fixture reads neighbouring columns,
## so this is the expensive measurement in the file; 64 columns keeps it inside the suite's
## time budget while still being far more than one column's worth of noise.
const BENCH_CLIFF_COLUMNS := 64

var _cfg: WorldConfig = null
## id -> {"ms_per_column": float, "ms_per_chunk_equiv": float, "columns_per_s": float,
##        "source_kind": String, "count": int}
var _results := {}


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	_cfg = WorldConfig.load_config()
	ModuleFixtures.clear()

	out.append(_environment_note())
	for id in AdapterRegistry.ids():
		out.append(_bench_adapter(id))
	out.append(_comparison())
	out.append(_engine_estimate())
	out.append(_expressiveness_check())
	out.append_array(_bench_neighbour_passes())
	out.append(_bench_engine_native_path())
	out.append(_recommendation())
	ModuleFixtures.clear()
	return out


## Records the machine the numbers came from. A perf number without its hardware is a
## fabrication risk, so this is part of the evidence rather than a comment.
func _environment_note() -> Dictionary:
	var mem: Dictionary = OS.get_memory_info()
	var threads := OS.get_processor_count()
	var godot := Engine.get_version_info()
	var ve: Object = ClassDB.instantiate("VoxelEngine")
	var vt := "%s.%s.%s %s" % [ve.call("get_version_major"), ve.call("get_version_minor"),
		ve.call("get_version_patch"), ve.call("get_version_edition")]
	ve.free()

	var display := DisplayServer.get_name()
	var gpu := RenderingServer.get_video_adapter_name()
	var gpu_vendor := RenderingServer.get_video_adapter_vendor()
	var renderer := String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))

	# Honest verdict on whether these numbers mean anything for the target device.
	var too_weak: Array[String] = []
	if threads <= 2:
		too_weak.append("only %d CPU threads" % threads)
	if int(mem.get("physical", 0)) < 3 * 1024 * 1024 * 1024:
		too_weak.append("%s MiB RAM" % _mib(int(mem.get("physical", 0))))
	if gpu.is_empty():
		too_weak.append("no GPU reported by RenderingServer (software rasterisation)")

	var notes: Array[String] = [
		"os=%s (%s) arch=%s" % [OS.get_name(), OS.get_distribution_name(),
			"arm64" if OS.has_feature("arm64") else ("x86_64" if OS.has_feature("x86_64") else "?")],
		"cpu=%s x%d threads" % [OS.get_processor_name(), threads],
		"ram_total=%s MiB ram_available=%s MiB" % [_mib(int(mem.get("physical", 0))), _mib(int(mem.get("available", 0)))],
		"gpu=%s vendor=%s" % [gpu if not gpu.is_empty() else "<none>", gpu_vendor if not gpu_vendor.is_empty() else "<none>"],
		"renderer=%s display_server=%s headless=%s" % [renderer, display, str(display == "headless")],
		"godot=%s hash=%s" % [godot.get("string"), godot.get("hash")],
		"voxel_tools=%s" % vt,
		"scope=caller-thread generator cost only; EXCLUDES meshing, VoxelEngine thread pools,",
		"  block loading, GPU upload and anything the real streaming pipeline does",
	]
	var status := "PASS"
	if not too_weak.is_empty():
		status = "BLOCKED"
		notes.append("")
		notes.append("BLOCKED as a statement about the target device. This build machine is FAR weaker")
		notes.append("than the 3-4 GB RAM / Adreno 610-class Android target: " + ", ".join(too_weak) + ".")
		notes.append("The per-column costs below are still valid AS A RELATIVE COMPARISON of the")
		notes.append("backends on identical hardware (that is what B2/B7 use them for) and as a")
		notes.append("regression baseline for this machine. They must NOT be quoted as phone numbers.")
	return TestHarness.result(SUITE, "B0", status,
		"benchmark environment recorded" + (" - machine too weak for device claims" if status == "BLOCKED" else ""),
		"\n".join(notes))


# --- B1 ------------------------------------------------------------------------------------

func _bench_adapter(id: String) -> Dictionary:
	var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
	if not built["ok"]:
		return TestHarness.fail(SUITE, "B1/%s" % id, "adapter '%s' failed to build" % id, str(built["report"]))
	var gen: Resource = built["generator"]
	var kind := ChunkHasher.source_kind(gen)

	var origins := _bench_origins()
	var mem_before: int = OS.get_static_memory_peak_usage()
	var times: Array = []
	var t_all := Time.get_ticks_usec()
	for o_variant in origins:
		var o: Vector3i = o_variant
		var t0 := Time.get_ticks_usec()
		# One call = one unit of this backend's own work: a 16^3 block for "block" generators,
		# a whole 16x384x16 column for "column" generators. Never generate_block() on a
		# backend that does not implement it.
		if kind == "column":
			ColumnBench.generate_column(gen, o)
		else:
			ColumnBench.generate_block(gen, o, _cfg)
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	var total_ms := float(Time.get_ticks_usec() - t_all) / 1000.0
	var mem_after: int = OS.get_static_memory_peak_usage()

	var stats := _stats(times)
	var unit := "column (16x384x16)" if kind == "column" else "chunk (16x16x16)"
	var per_unit := total_ms / float(maxi(1, times.size()))
	var per_column := per_unit if kind == "column" else per_unit * float(ROWS_PER_COLUMN)
	var per_chunk_equiv := per_column / float(ROWS_PER_COLUMN)
	var units_per_s := float(times.size()) / maxf(0.000001, total_ms / 1000.0)
	var st: Dictionary = gen.call("stats") if gen.has_method("stats") else {}

	# A second timing over SCATTERED origins (the committed ChunkOrigins set, which includes
	# coordinates out to +/-1e6). The footprint above is contiguous, so one region field tile is
	# reused by ~64 columns and the region compute is amortised away; scattered columns each pay
	# it. Reporting only the warm number would understate the cost of a viewer teleporting, and
	# reporting only the cold one would overstate streaming. Both are measured, both are printed.
	var cold := _bench_cold(gen, kind)
	var cold_per_unit: float = cold["ms_per_unit"]
	var cold_per_column: float = cold_per_unit * (1.0 if kind == "column" else float(ROWS_PER_COLUMN))

	_results[id] = {
		"source_kind": kind,
		"cold_ms_per_unit": cold_per_unit,
		"cold_ms_per_column": cold_per_column,
		"cold_count": cold["count"],
		"count": times.size(),
		"ms_per_unit": per_unit,
		"ms_per_column": per_column,
		"ms_per_chunk_equiv": per_chunk_equiv,
		"columns_per_s": float(times.size()) / maxf(0.000001, per_column * float(times.size()) / 1000.0),
		"units_per_s": units_per_s,
		"total_ms": total_ms,
		"legacy": AdapterRegistry.is_legacy(id),
		"executes_all_modules": AdapterRegistry.executes_all_modules(id),
	}

	var lines: Array[String] = [
		"unit=%s  units=%d (%dx%d block footprint, CONTIGUOUS: region field tiles are cache-warm)" % [
			unit, times.size(), BENCH_FOOTPRINT / BENCH_COLUMN_STRIDE, BENCH_FOOTPRINT / BENCH_COLUMN_STRIDE],
		"total_ms=%.2f  mean_ms_per_%s=%.4f" % [total_ms, "column" if kind == "column" else "chunk", per_unit],
		"p50_ms=%.4f  p95_ms=%.4f  max_ms=%.4f" % [stats["p50"], stats["p95"], stats["max"]],
		"normalised: %.4f ms/column, %.4f ms per 16^3 chunk equivalent, %.1f columns/s" % [
			per_column, per_chunk_equiv, _results[id]["columns_per_s"]],
		"COLD region cache (%d scattered origins, one region tile per column): %.4f ms/%s = %.4f ms/column" % [
			cold["count"], cold_per_unit, "column" if kind == "column" else "chunk", cold_per_column],
		"  cold/warm ratio = %.2fx  <- the price of a region field tile that serves only one column" % (
			cold_per_unit / maxf(0.000001, per_unit)),
		"  a streaming viewer pays something between the two: it walks contiguous columns, but each new",
		"  region costs one cold tile (the cache hits/misses below are from the warm run)",
		"peak_static_memory_delta=%s MiB (before=%s after=%s)" % [
			_mib(mem_after - mem_before), _mib(mem_before), _mib(mem_after)],
		"capabilities: executes_all_modules=%s legacy=%s" % [
			str(AdapterRegistry.executes_all_modules(id)), str(AdapterRegistry.is_legacy(id))],
	]
	if not st.is_empty():
		lines.append("backend stats: executed=%s" % str(st.get("executed_counts", {})))
		lines.append("               cache=%s" % str(st.get("field_cache", {})))
		lines.append("               writer=%s" % str(st.get("writer", {})))
		if st.has("worker_thread_ids"):
			lines.append("               worker threads seen=%s pass_calls=%s" % [
				str(st.get("worker_thread_ids")), str(st.get("pass_calls"))])
	if stats["count"] < MIN_SAMPLES_FOR_P95:
		lines.append("WARNING: only %d samples - p95 is indicative, not statistically strong" % stats["count"])

	return TestHarness.ok(SUITE, "B1/%s" % id,
		"%s (%s): %.4f ms/%s mean over %d units = %.4f ms/column" % [
			id, kind, per_unit, "column" if kind == "column" else "chunk", times.size(), per_column],
		"\n".join(lines))


## Timing over the committed scattered origin set (ChunkOrigins: 8 special coordinates,
## 24 surface-band and 32 wide-range, including negative and >1e6 values). Every column lands
## in a different region, so this is the COLD field-cache cost.
func _bench_cold(gen: Resource, kind: String) -> Dictionary:
	var origins := ChunkOrigins.get_origins(_cfg.sea_level)
	var t0 := Time.get_ticks_usec()
	for o_variant in origins:
		if kind == "column":
			ColumnBench.generate_column(gen, o_variant)
		else:
			ColumnBench.generate_block(gen, o_variant, _cfg)
	var total_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var per_unit := total_ms / float(maxi(1, origins.size()))
	return {"count": origins.size(), "total_ms": total_ms, "ms_per_unit": per_unit}


## The fixed benchmark grid: every data-block column of a 512x512 block footprint centred on
## the origin. Deterministic by construction (arithmetic loops, no hashing, no randomness).
func _bench_origins() -> Array:
	return _column_grid(BENCH_FOOTPRINT / BENCH_COLUMN_STRIDE)


func _column_grid(cols: int) -> Array:
	var out: Array = []
	for xi in cols:
		for zi in cols:
			out.append(Vector3i(
				(xi - cols / 2) * BENCH_COLUMN_STRIDE, _cfg.world_y_min, (zi - cols / 2) * BENCH_COLUMN_STRIDE))
	return out


## Column origins for B5/B6: a compact square so the field cache is warm and the neighbour
## reads are mostly hits - the situation a real streamer is in.
func _cliff_origins(count: int) -> Array:
	var side := int(ceil(sqrt(float(count))))
	var all := _column_grid(side)
	return all.slice(0, mini(count, all.size()))


# --- B2 ------------------------------------------------------------------------------------

func _comparison() -> Dictionary:
	var lines: Array[String] = [
		"%-20s %-7s %-11s %-13s %-13s %-13s %s" % [
			"backend", "kind", "legacy", "ms/column", "ms/chunk-equiv", "cold ms/col", "columns/s"],
	]
	var fastest_modular := ""
	var fastest_modular_ms := INF
	var default_id := AdapterRegistry.DEFAULT_ID
	for id in AdapterRegistry.ids():
		var r: Dictionary = _results.get(id, {})
		if r.is_empty():
			lines.append("%-20s <no measurement>" % id)
			continue
		lines.append("%-20s %-7s %-11s %-13.4f %-13.4f %-13.4f %.1f%s" % [
			id, String(r["source_kind"]), str(bool(r["legacy"])),
			float(r["ms_per_column"]), float(r["ms_per_chunk_equiv"]), float(r["cold_ms_per_column"]),
			float(r["columns_per_s"]), "   <= DEFAULT" if String(id) == default_id else ""])
		if not bool(r["legacy"]) and float(r["ms_per_column"]) < fastest_modular_ms:
			fastest_modular_ms = float(r["ms_per_column"])
			fastest_modular = String(id)

	lines.append("")
	if _results.has(default_id) and fastest_modular != "" and fastest_modular != default_id:
		var ratio := float(_results[default_id]["ms_per_column"]) / maxf(0.000001, fastest_modular_ms)
		lines.append("The DEFAULT backend '%s' is %.2fx the cost of the cheapest modular backend '%s'." % [
			default_id, ratio, fastest_modular])
		lines.append("That premium buys engine-side column generation (worker threads, do_box spans,")
		lines.append("no per-block GDScript dispatch) and is the subject of the B7 gate table.")
	elif fastest_modular == default_id:
		lines.append("The DEFAULT backend '%s' is also the cheapest modular backend measured here." % default_id)
	lines.append("'ms/column' is the CONTIGUOUS footprint (region field tiles cache-warm, the streaming case);")
	lines.append("'cold ms/col' is the scattered ChunkOrigins set (one region tile per column, the teleport case).")
	lines.append("Quoting either alone would misrepresent the backend; the ratio between them is the amortisation")
	lines.append("the region cache buys.")
	lines.append("M00 reference (same machine, per 16^3 chunk): noise2d 0.0047 ms, graph 0.0409 ms.")
	lines.append("Those were BLOCK generators; the ms/chunk-equiv column above is what compares to them.")
	return TestHarness.ok(SUITE, "B2", "per-backend generation cost normalised to one table", "\n".join(lines))


# --- B3 ------------------------------------------------------------------------------------

func _engine_estimate() -> Dictionary:
	var lines: Array[String] = []
	var found := 0
	for id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			lines.append("%-20s build failed" % id)
			continue
		var gen: Resource = built["generator"]
		if not gen.has_method("debug_measure_microseconds_per_voxel"):
			lines.append("%-20s no debug_measure_microseconds_per_voxel() on %s" % [id, gen.get_class()])
			continue
		var v: float = gen.call("debug_measure_microseconds_per_voxel", true)
		found += 1
		lines.append("%-20s %.3f us/voxel (the engine's own estimate of its compiled graph)" % [id, v])
	return TestHarness.ok(SUITE, "B3",
		"engine-internal cost estimate recorded where the generator exposes one (%d of %d backends)" % [
			found, AdapterRegistry.ids().size()],
		"\n".join(lines))


# --- B4 ------------------------------------------------------------------------------------

func _expressiveness_check() -> Dictionary:
	var lines: Array[String] = []
	var origins := _bench_origins().slice(0, 64)
	for id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			lines.append("%-20s build failed" % id)
			continue
		var gen: Resource = built["generator"]
		var kind := ChunkHasher.source_kind(gen)
		var ids := {}
		for o_variant in origins:
			var o: Vector3i = o_variant
			var bytes := ColumnBench.sample_bytes(gen, o, kind, _cfg)
			for i in bytes.size():
				ids[int(bytes[i])] = true
		var key_list: Array = ids.keys()
		key_list.sort()
		lines.append("%-20s distinct voxel ids over %d %s = %s" % [
			id, origins.size(), "columns" if kind == "column" else "chunks", str(key_list)])
		_results[id]["distinct_ids"] = key_list
	return TestHarness.ok(SUITE, "B4", "expressiveness measured from generated data, not from docs",
		"\n".join(lines))


# --- B5 ------------------------------------------------------------------------------------

## Prices a neighbour-aware (extent 1) module on both modular backends. The fixture is a
## THROWAWAY module written to user://modules and removed again, so the shipped content set
## and every committed golden are untouched (B17).
func _bench_neighbour_passes() -> Array:
	var out: Array = []
	var origins := _cliff_origins(BENCH_CLIFF_COLUMNS)
	ModuleFixtures.clear()
	ModuleFixtures.install("cliff_pass")

	var lines: Array[String] = []
	var failed := false
	for id in AdapterRegistry.ids():
		if AdapterRegistry.is_legacy(id):
			continue
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			failed = true
			lines.append("%-20s build failed with the extent-1 fixture: %s" % [id, str(built["report"].get("error"))])
			continue
		var gen: Resource = built["generator"]
		var has_neighbour := gen.has_method("neighbour_passes_in_plan") and bool(gen.call("neighbour_passes_in_plan"))
		var t0 := Time.get_ticks_usec()
		var times: Array = []
		for o_variant in origins:
			var t1 := Time.get_ticks_usec()
			ColumnBench.generate_column(gen, o_variant)
			times.append(float(Time.get_ticks_usec() - t1) / 1000.0)
		var total_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var st: Dictionary = gen.call("stats") if gen.has_method("stats") else {}
		var writer: Dictionary = st.get("writer", {})
		var baseline_ms := float(_results.get(id, {}).get("ms_per_column", 0.0))
		var mean_ms := total_ms / float(maxi(1, times.size()))
		var ratio := mean_ms / maxf(0.000001, baseline_ms)
		if not has_neighbour:
			failed = true
		lines.append("%-20s neighbour pass in plan=%s  %d columns in %.1f ms  mean=%.3f ms/column (%.2fx the extent-0 baseline %.3f)" % [
			id, str(has_neighbour), times.size(), total_ms, mean_ms, ratio, baseline_ms])
		lines.append("%-20s   plan=%s" % ["", str(st.get("plan", {}))])
		lines.append("%-20s   sink counters over the %d harness columns: %s" % ["", times.size(), str(writer)])
		lines.append("%-20s   pass_calls=%s (empty here on purpose: the engine only counts a pass when it" % [
			"", str(st.get("pass_calls"))])
		lines.append("%-20s   calls _generate_pass; the harness path runs the same plan through PipelineRunner)" % "")
		lines.append("%-20s   READ THIS BEFORE QUOTING: the harness sink holds ONE column, so every neighbour" % "")
		lines.append("%-20s   read it serves is a MISS returning air - neighbour_misses above says how many. B5 is" % "")
		lines.append("%-20s   therefore a COST measurement of extent-1 machinery, not a correctness one. Extent-1" % "")
		lines.append("%-20s   CORRECTNESS is measured where neighbours really exist: experimental_columns through" % "")
		lines.append("%-20s   NeighbourColumnWriter (tools/probe_cliff.gd: changed=9/64 columns, neighbour_reads" % "")
		lines.append("%-20s   served from generated columns) and native_cb through the live engine tool" % "")
		lines.append("%-20s   (tools/probe_cliff.gd: neighbour_reads=70749, neighbour_misses=0)." % "")
		lines.append("%-20s   executed=%s" % ["", str(st.get("executed_counts", {}))])
		_results[id]["cliff_ms_per_column"] = mean_ms
		_results[id]["cliff_ratio"] = ratio

	ModuleFixtures.clear()
	out.append(TestHarness.result(SUITE, "B5", "PASS" if not failed else "FAIL",
		"neighbour-pass (extent 1) cost measured on both modular backends with a throwaway fixture",
		"\n".join(lines) + "\nfixture removed; installed now = %s" % str(ModuleFixtures.installed())))
	return out


# --- B6 ------------------------------------------------------------------------------------

## The engine-native path for the default backend. debug_generate_test_column() runs
## _generate_pass against a real VoxelToolMultipassGenerator, so the writes go through
## VoxelTool.do_box() spans instead of the harness's GDScript MemoryColumnWriter. This is
## the number the streaming engine actually pays; B1's native_cb number is the harness's.
func _bench_engine_native_path() -> Dictionary:
	var id := AdapterRegistry.DEFAULT_ID
	var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
	if not built["ok"]:
		return TestHarness.fail(SUITE, "B6", "default backend '%s' failed to build" % id, str(built["report"].get("error")))
	var gen: Resource = built["generator"]
	if not gen.has_method("debug_generate_test_column"):
		return TestHarness.blocked(SUITE, "B6",
			"'%s' exposes no debug_generate_test_column() - the engine-native column path cannot be timed here" % id,
			("generator class = %s; the live streaming cost is measured instead by bench_runtime.gd "
			+ "(R-series) and by tools/probe_native_live.gd") % gen.get_class())

	var origins := _cliff_origins(BENCH_CLIFF_COLUMNS)
	var times: Array = []
	var t0 := Time.get_ticks_usec()
	var calls := 0
	var first_error := -1
	for o_variant in origins:
		var o: Vector3i = o_variant
		var t1 := Time.get_ticks_usec()
		# Vector2i = column position in BLOCK coords (measured: Vector3i is a parse error).
		var ret: Variant = gen.call("debug_generate_test_column", Vector2i(int(o.x / 16), int(o.z / 16)))
		times.append(float(Time.get_ticks_usec() - t1) / 1000.0)
		calls += 1
		# Report a refused call instead of timing nothing: an Error return would otherwise
		# look like a very fast column.
		if ret is int and int(ret) != OK and first_error < 0:
			first_error = int(ret)
	if first_error >= 0:
		return TestHarness.blocked(SUITE, "B6",
			"debug_generate_test_column() returned error %d outside a streaming terrain" % first_error,
			("%d calls made on %s; the engine refuses the synchronous test column in this context, so the "
			+ "engine-native cost is measured by bench_runtime.gd (live streaming) instead. Harness-path cost "
			+ "for this backend stays in B1/B2.") % [calls, id])
	var total_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var stats := _stats(times)
	var mean_ms := total_ms / float(maxi(1, calls))
	var harness_ms := float(_results.get(id, {}).get("ms_per_column", 0.0))
	_results[id]["engine_ms_per_column"] = mean_ms

	var lines: Array[String] = [
		"debug_generate_test_column(Vector2i) x%d: total=%.1f ms mean=%.3f ms/column p50=%.3f p95=%.3f max=%.3f" % [
			calls, total_ms, mean_ms, stats["p50"], stats["p95"], stats["max"]],
		"harness path (GDScript MemoryColumnWriter, B1): %.3f ms/column" % harness_ms,
		"engine path / harness path = %.2fx" % (mean_ms / maxf(0.000001, harness_ms)),
		"",
		"The engine path writes through VoxelTool.do_box() spans on the caller thread here; during",
		"streaming the same _generate_pass runs on engine worker threads (X22 measures 4 of them).",
		"Reference measurement from the M01 write-cost probe: per-voxel set_voxel 3404 us/column vs",
		"do_box spans 958 us/column, i.e. the span writer is ~3.5x cheaper, which is what the",
		"shipped NativeColumnWriter uses.",
	]
	if stats["count"] < MIN_SAMPLES_FOR_P95:
		lines.append("WARNING: only %d samples" % stats["count"])
	return TestHarness.ok(SUITE, "B6",
		"%s engine-native column path: %.3f ms/column over %d columns (%.2fx the harness path)" % [
			id, mean_ms, calls, mean_ms / maxf(0.000001, harness_ms)],
		"\n".join(lines))


# --- B7 ------------------------------------------------------------------------------------

func _recommendation() -> Dictionary:
	var id := AdapterRegistry.DEFAULT_ID
	var lines: Array[String] = []
	var problems: Array[String] = []
	var r: Dictionary = _results.get(id, {})
	if r.is_empty():
		problems.append("no B1 measurement for the default backend")

	# The gate table the M01 fix is judged on: correctness, concurrency, live streaming, cost.
	lines.append("GATE TABLE for the default backend '%s' (each row points at the check that decides it):" % id)
	lines.append("  correctness vs the legacy compiled graph : D6 - 320 origins (64 committed + 256 surface band),")
	lines.append("                                             neighbour passes disabled, 0 mismatches required")
	lines.append("  module execution                         : X13/X14/X15/X16/X17 - an added module changes the")
	lines.append("                                             output, a no-op does not, an unexecutable one is refused")
	lines.append("  concurrency                              : X22 - live terrain on 4 engine worker threads,")
	lines.append("                                             streamed voxels == harness voxels, 0 rejected writes")
	lines.append("  live streaming                           : X22 (same run) + tools/probe_native_live.gd")
	lines.append("  cost                                     : B1/B2/B5/B6 below")
	lines.append("")
	for k in AdapterRegistry.ids():
		var rr: Dictionary = _results.get(k, {})
		if rr.is_empty():
			continue
		var cliff: String = "%.3f ms/column (%.2fx)" % [float(rr["cliff_ms_per_column"]), float(rr["cliff_ratio"])] \
			if rr.has("cliff_ms_per_column") else "n/a (legacy baseline)"
		var engine: String = "%.3f ms/column" % float(rr["engine_ms_per_column"]) if rr.has("engine_ms_per_column") else "n/a"
		lines.append("  %-20s harness=%.3f ms/column (cold region %.3f)  cliff(extent1)=%s  engine-native=%s" % [
			k, float(rr["ms_per_column"]), float(rr.get("cold_ms_per_column", 0.0)), cliff, engine])
	lines.append("")

	# The honest verdict. Cost is the one gate a GDScript module pipeline cannot win against a
	# compiled graph, so it is stated as a ratio rather than hidden.
	var graph_ms := float(_results.get("graph", {}).get("ms_per_column", 0.0))
	var native_ms := float(r.get("ms_per_column", 0.0))
	if graph_ms > 0.0 and native_ms > 0.0:
		var ratio := native_ms / graph_ms
		lines.append("COST VERDICT: the default modular backend costs %.1fx the legacy compiled graph per column" % ratio)
		lines.append("on the HARNESS path (%.3f vs %.3f ms/column). The graph is a C++ compiled node graph with no" % [
			native_ms, graph_ms])
		lines.append("module pipeline at all, so this is the price of scriptability, not a regression: the graph")
		lines.append("cannot run a module from user://modules (evidence E2) and is gated behind")
		lines.append("allow_legacy_baseline for exactly that reason.")
		if ratio > 4.0:
			lines.append("")
			lines.append("That ratio is large enough to matter on the target device, so it is recorded as a KNOWN")
			lines.append("COST DEBT with the measured levers, not waved away:")
			lines.append("  * engine-native writes are already ~3.5x cheaper than per-voxel writes (do_box spans);")
			lines.append("  * the region field cache means one coarse tile serves 64 columns (cache stats in B1);")
			lines.append("  * the remaining harness cost is GDScript module dispatch, which only the engine path (B6)")
			lines.append("    and, later, a compiled graph generated FROM the module plan can remove;")
			lines.append("  * quality_scaling retraction (T9) is wired: a module with factor <= 0 is skipped.")
		if r.has("engine_ms_per_column"):
			lines.append("")
			lines.append("B6 measures the same backend through the engine's own column path: %.3f ms/column." % float(r["engine_ms_per_column"]))
	lines.append("")
	lines.append("RECOMMENDATION: keep '%s' as the default. It is the only backend that satisfies the" % id)
	lines.append("correctness, module-execution, concurrency and live-streaming gates at once; 'experimental_columns'")
	lines.append("(the self-hosted column generator, never the extension's MultipassCB) matches it on correctness but")
	lines.append("has no engine worker threads and no engine mesher integration, and the two legacy baselines fail")
	lines.append("the module-execution gate outright.")

	var status := "PASS" if problems.is_empty() else "FAIL"
	return TestHarness.result(SUITE, "B7", status,
		"generation cost recommendation for the default backend" + ("" if problems.is_empty() else " (%s)" % "; ".join(problems)),
		("\n".join(problems) + "\n" if not problems.is_empty() else "") + "\n".join(lines))


# --- helpers -------------------------------------------------------------------------------

func _stats(times: Array) -> Dictionary:
	var sorted := times.duplicate()
	sorted.sort()
	var out := {
		"count": sorted.size(),
		"min": sorted[0] if not sorted.is_empty() else 0.0,
		"max": sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0,
	}
	for p in PCT:
		out["p%d" % p] = TestHarness.percentile(sorted, p)
	return out


func _mib(bytes: int) -> String:
	return "%.1f" % (float(bytes) / (1024.0 * 1024.0))
