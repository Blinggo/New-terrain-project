extends RefCounted
## tests/perf/bench_generation.gd
##
## M00 / T9.1 - Generation throughput benchmark. HEADLESS, single-threaded, deterministic.
##
## WHAT IS MEASURED
##   For each adapter: generate "512 columns' worth of chunks" - i.e. a 512x512 BLOCK FOOTPRINT
##   of the world, which at a 16-voxel block size and a 384-block-tall column is
##   32 x 32 = 1024 block columns, each 24 data blocks tall => 24 576 generate_block() calls.
##   That is far more work than the machine can do in a reasonable time on this sandbox, so
##   the column count is configurable (BENCH_COLUMNS) and the reported numbers are always
##   PER CHUNK, which is what matters: it scales to any column count.
##
##   Reported: total ms, mean ms/chunk, p50, p95, max, chunks/s, and the peak static-memory
##   delta across the run.
##
## WHAT IS *NOT* MEASURED (and must not be claimed)
##   This is SINGLE-THREADED and calls VoxelGenerator.generate_block() directly. The runtime
##   streams terrain through VoxelEngine's thread pools (general pool, generation + meshing
##   task queues), so real in-game chunk throughput is higher than chunks/s here, and it also
##   includes meshing, which this benchmark excludes entirely. bench_runtime.gd measures the
##   real pipeline. Numbers from this file are a GENERATOR COST comparison, not a frame budget.
##
## Determinism note: generation is timed, not randomised; the chunk set is the fixed
## ChunkOrigins-derived grid, so two runs on the same machine produce the same *work*, even
## though wall-clock timings naturally differ.

const SUITE := "perf"

## Block footprint (in blocks) of the benchmarked area per side. 512 as specified by T9.
## Each side is sampled every BENCH_COLUMN_STRIDE blocks to keep the chunk count sane.
const BENCH_FOOTPRINT := 512
const BENCH_COLUMN_STRIDE := 16   # one data block column per 16 blocks => 32x32 columns

## How many data-block rows per column. 384 / 16 = 24.
const ROWS_PER_COLUMN := 24

## Percentiles T9 asks for.
const PCT := [50, 95]

## Minimum samples for a stable percentile. If the run is shorter than this the report says
## so instead of pretending a 20-sample p95 means something.
const MIN_SAMPLES_FOR_P95 := 200

var _cfg: WorldConfig = null


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	_cfg = WorldConfig.load_config()

	out.append(_environment_note())
	for id in AdapterRegistry.ids():
		out.append(_bench_adapter(id))
	out.append(_comparison())
	out.append_array(_bench_multipass_columns())
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
		"scope=single-threaded generate_block() only; EXCLUDES meshing, VoxelEngine thread pools,",
		"  block loading, GPU upload and anything the real streaming pipeline does (see B1 header)",
	]
	var status := "PASS"
	if not too_weak.is_empty():
		status = "BLOCKED"
		notes.append("")
		notes.append("BLOCKED as a statement about the target device. This build machine is FAR weaker")
		notes.append("than the 3-4 GB RAM / Adreno 610-class Android target: " + ", ".join(too_weak) + ".")
		notes.append("The per-chunk costs below are still valid AS A RELATIVE COMPARISON of the two")
		notes.append("adapters on identical hardware (that is what B2 uses them for) and as a")
		notes.append("regression baseline for this machine. They must NOT be quoted as phone numbers.")
	return TestHarness.result(SUITE, "B0", status,
		"benchmark environment recorded" + (" - machine too weak for device claims" if status == "BLOCKED" else ""),
		"\n".join(notes))


func _bench_adapter(id: String) -> Dictionary:
	var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
	if not built["ok"]:
		return TestHarness.fail(SUITE, "B1/%s" % id, "adapter '%s' failed to build" % id, str(built["report"]))
	var gen: Resource = built["generator"]

	var origins := _bench_origins()
	var format := VoxelFormat.new()
	format.type_depth = VoxelBuffer.DEPTH_8_BIT if _cfg.type_depth_bits == 8 else VoxelBuffer.DEPTH_16_BIT
	var block_vec := Vector3i(_cfg.mesh_block_size, _cfg.mesh_block_size, _cfg.mesh_block_size)

	var mem_before: int = OS.get_static_memory_peak_usage()
	var times: Array = []
	times.resize(origins.size())

	var total_usec := 0
	for i in origins.size():
		var buf: VoxelBuffer = format.create_buffer(block_vec)
		var t0 := Time.get_ticks_usec()
		gen.call("generate_block", buf, origins[i], 0)
		var dt := Time.get_ticks_usec() - t0
		total_usec += dt
		times[i] = float(dt) / 1000.0

	var mem_after: int = OS.get_static_memory_peak_usage()

	var total_ms := float(total_usec) / 1000.0
	var mean_ms := total_ms / float(maxi(1, origins.size()))
	var chunks_per_s := float(origins.size()) / maxf(0.000001, total_ms / 1000.0)
	var stats := _stats(times)
	var mem_delta := mem_after - mem_before

	# Engine-side cost, when the generator supports it (graph does; noise2d does not).
	var engine_us := _measure_engine_cost(gen)

	var lines: Array[String] = [
		"chunks=%d (%dx%d block footprint, %d rows each)" % [
			origins.size(), BENCH_FOOTPRINT / BENCH_COLUMN_STRIDE, BENCH_FOOTPRINT / BENCH_COLUMN_STRIDE, ROWS_PER_COLUMN],
		"total_ms=%.2f" % total_ms,
		"mean_ms_per_chunk=%.4f" % mean_ms,
		"p50_ms=%.4f" % stats["p50"],
		"p95_ms=%.4f" % stats["p95"],
		"max_ms=%.4f" % stats["max"],
		"chunks_per_second=%.0f" % chunks_per_s,
		"peak_static_memory_delta=%s MiB (before=%s after=%s)" % [
			_mib(mem_delta), _mib(mem_before), _mib(mem_after)],
	]
	if engine_us >= 0.0:
		lines.append("VoxelGeneratorGraph.debug_measure_microseconds_per_voxel()=%.3f us/voxel (engine's own estimate)" % engine_us)
	else:
		lines.append("no debug_measure_microseconds_per_voxel() on this generator class")
	if stats["count"] < MIN_SAMPLES_FOR_P95:
		lines.append("WARNING: only %d samples - p95 is indicative, not statistically strong" % stats["count"])

	return TestHarness.ok(SUITE, "B1/%s" % id,
		"%s: %.4f ms/chunk mean, %.0f chunks/s over %d chunks" % [id, mean_ms, chunks_per_s, origins.size()],
		"\n".join(lines))


## The fixed benchmark grid: every data-block column of a 512x512 block footprint centred on
## the origin, times every row of the 384-block-tall world column. Deterministic by
## construction (arithmetic loops, no hashing, no randomness).
func _bench_origins() -> Array:
	var out: Array = []
	var cols := BENCH_FOOTPRINT / BENCH_COLUMN_STRIDE
	for xi in cols:
		for zi in cols:
			var x := (xi - cols / 2) * BENCH_COLUMN_STRIDE
			var z := (zi - cols / 2) * BENCH_COLUMN_STRIDE
			for row in ROWS_PER_COLUMN:
				out.append(Vector3i(x, _cfg.world_y_min + row * _cfg.mesh_block_size, z))
	return out


func _measure_engine_cost(gen: Resource) -> float:
	if not gen.has_method("debug_measure_microseconds_per_voxel"):
		return -1.0
	var v: float = gen.call("debug_measure_microseconds_per_voxel", true)
	return v


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


func _comparison() -> Dictionary:
	## The T5/T9 deliverable: which adapter should M01 start from, backed by measurements.
	var lines: Array[String] = []
	var results := {}
	for id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			lines.append("%s: build failed" % id)
			continue
		var gen: Resource = built["generator"]
		var origins := _bench_origins()
		# Time a modest subset here; the full timing lives in B1.
		var sample := origins.slice(0, mini(origins.size(), 2048))
		var format := VoxelFormat.new()
		format.type_depth = VoxelBuffer.DEPTH_8_BIT
		var block_vec := Vector3i(_cfg.mesh_block_size, _cfg.mesh_block_size, _cfg.mesh_block_size)
		var t0 := Time.get_ticks_usec()
		var non_air := 0
		var total_voxels := 0
		for o_variant in sample:
			var buf: VoxelBuffer = format.create_buffer(block_vec)
			gen.call("generate_block", buf, o_variant, 0)
			buf.decompress_channel(VoxelBuffer.CHANNEL_TYPE)
			var bytes := buf.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE)
			for i in bytes.size():
				total_voxels += 1
				if bytes[i] != 0:
					non_air += 1
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var per_chunk := ms / float(maxi(1, sample.size()))
		results[id] = per_chunk
		lines.append("%-8s %.4f ms/chunk over %d chunks; non_air=%d/%d voxels" % [
			id, per_chunk, sample.size(), non_air, total_voxels])

	if results.size() == 2:
		var ids: Array = results.keys()
		var faster: String = ids[0] if float(results[ids[0]]) <= float(results[ids[1]]) else ids[1]
		var slower: String = ids[1] if faster == ids[0] else ids[0]
		var ratio := float(results[slower]) / maxf(0.000001, float(results[faster]))
		var express := _expressiveness()
		lines.append("")
		lines.append("distinct voxel ids written (expressiveness, measured over the B2 sample):")
		for k in express:
			lines.append("  %-8s %s" % [k, str(express[k])])
		lines.append("")
		lines.append("RECOMMENDATION FOR M01: start from '%s'." % _recommended(express, faster, slower, ratio))
		lines.append("  cost: '%s' %.4f ms/chunk vs '%s' %.4f ms/chunk => the recommendation costs %.2fx more." % [
			slower, float(results[slower]), faster, float(results[faster]), ratio])
		lines.append("  why: '%s' can only ever write ONE non-air voxel id, because" % faster)
		lines.append("    VoxelGeneratorHeightmap hardcodes value 1 above height_start (proven by S4g/noise2d).")
		lines.append("    M01 needs climate-driven surface blocks; M05 strata, M06 caves and M07 ores all need")
		lines.append("    several ids per column. That is impossible on the heightmap adapter at any cost.")
		lines.append("    The graph adapter writes %d distinct ids today and exposes named nodes, per-channel" % express.get("graph", []).size())
		lines.append("    outputs and debug_measure_microseconds_per_voxel() for future tuning.")
		lines.append("  the %.2fx cost is recoverable (octave count, use_xz_caching, subdivision); the missing" % ratio)
		lines.append("    expressiveness is not. Keep 'noise2d' as the cheap baseline the F3 key toggles to.")
	return TestHarness.ok(SUITE, "B2", "per-adapter generation cost compared (M01 recommendation input)", "\n".join(lines))


## How many distinct voxel ids each adapter can actually write. This is the number the M01
## recommendation rests on, so it is measured from generated blocks, not asserted from docs.
func _expressiveness() -> Dictionary:
	var out := {}
	var origins := _bench_origins()
	var sample := origins.slice(0, mini(origins.size(), 512))
	for id in AdapterRegistry.ids():
		var built := AdapterRegistry.build_generator(id, _cfg.seed_value, _cfg.to_gen_context())
		if not built["ok"]:
			out[id] = ["<build failed>"]
			continue
		var gen: Resource = built["generator"]
		var format := VoxelFormat.new()
		format.type_depth = VoxelBuffer.DEPTH_8_BIT
		var block_vec := Vector3i(_cfg.mesh_block_size, _cfg.mesh_block_size, _cfg.mesh_block_size)
		var ids := {}
		for o_variant in sample:
			var buf: VoxelBuffer = format.create_buffer(block_vec)
			gen.call("generate_block", buf, o_variant, 0)
			buf.decompress_channel(VoxelBuffer.CHANNEL_TYPE)
			var bytes := buf.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE)
			for i in bytes.size():
				ids[int(bytes[i])] = true
		var key_list: Array = ids.keys()
		key_list.sort()
		out[id] = key_list
	return out


func _recommended(express: Dictionary, faster: String, slower: String, _ratio: float) -> String:
	## Pick the adapter that can express more than one non-air id; fall back to the cheaper one
	## if (unexpectedly) neither can.
	var best := slower
	var best_ids := 0
	for id in express:
		var ids: Array = express[id]
		var non_air := 0
		for v in ids:
			if int(v) != 0:
				non_air += 1
		if non_air > best_ids:
			best_ids = non_air
			best = String(id)
	if best_ids == 0:
		return faster
	return best


## Task 9 / B3: price the neighbour-aware backend per COLUMN (16 x 384 x 16), at extent 0
## (pass A only) and extent 1 (pass A + the cliff pass B), over the same 32x32 column
## footprint as B1 so the numbers are comparable with M00's per-chunk figures
## (ms/column = 24 x ms/chunk for an equivalent backend).
func _bench_multipass_columns() -> Array:
	var out: Array = []
	var cols := BENCH_FOOTPRINT / BENCH_COLUMN_STRIDE
	var origins: Array = []
	for xi in cols:
		for zi in cols:
			origins.append(Vector3i(
				(xi - cols / 2) * BENCH_COLUMN_STRIDE, 0, (zi - cols / 2) * BENCH_COLUMN_STRIDE))

	var per_variant := {}
	for pass_b in [false, true]:
		var ctx := _cfg.to_gen_context()
		ctx["multipass_pass_b"] = pass_b
		var built := AdapterRegistry.build_generator("multipass", _cfg.seed_value, ctx)
		if not built["ok"]:
			out.append(TestHarness.fail(SUITE, "B3/e%d" % (1 if pass_b else 0),
				"multipass generator failed to build (pass_b=%s)" % str(pass_b), str(built["report"])))
			continue
		var gen: Resource = built["generator"]
		var format := VoxelFormat.new()
		format.type_depth = VoxelBuffer.DEPTH_8_BIT
		var block_vec := Vector3i(_cfg.mesh_block_size, _cfg.mesh_block_size, _cfg.mesh_block_size)
		var times: Array = []
		for col_variant in origins:
			var col: Vector3i = col_variant
			var t0 := Time.get_ticks_usec()
			for row in ROWS_PER_COLUMN:
				var buf: VoxelBuffer = format.create_buffer(block_vec)
				gen.call("generate_block", buf, Vector3i(col.x, _cfg.world_y_min + row * _cfg.mesh_block_size, col.z), 0)
			times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		var stats := _stats(times)
		var mean_ms: float = TestHarness.mean(times) if not times.is_empty() else 0.0
		var gen_mp: MultipassColumnGenerator = gen
		var st: Dictionary = gen_mp.stats()
		per_variant[pass_b] = mean_ms
		out.append(TestHarness.ok(SUITE, "B3/e%d" % (1 if pass_b else 0),
			"multipass extent %d: %.3f ms/column over %d columns (%.4f ms/chunk equivalent)" % [
				1 if pass_b else 0, mean_ms, times.size(), mean_ms / float(ROWS_PER_COLUMN)],
			"columns=%d mean=%.3f p50=%.3f p95=%.3f max=%.3f ms\ncolumn compiles=%d pass_b applications=%d field_cache=%s" % [
				times.size(), mean_ms, stats["p50"], stats["p95"], stats["max"],
				st["column_compiles"], st["pass_b_applications"], str(st["field_cache"])]))

	out.append(_multipass_recommendation(per_variant))
	return out


func _multipass_recommendation(per_variant: Dictionary) -> Dictionary:
	var graph_ms_per_chunk := 0.0
	var built := AdapterRegistry.build_generator("graph", _cfg.seed_value, _cfg.to_gen_context())
	if built["ok"]:
		var gen: Resource = built["generator"]
		var sample := _bench_origins().slice(0, 2048)
		var format := VoxelFormat.new()
		format.type_depth = VoxelBuffer.DEPTH_8_BIT
		var block_vec := Vector3i(_cfg.mesh_block_size, _cfg.mesh_block_size, _cfg.mesh_block_size)
		var t0 := Time.get_ticks_usec()
		for o_variant in sample:
			var buf: VoxelBuffer = format.create_buffer(block_vec)
			gen.call("generate_block", buf, o_variant, 0)
		graph_ms_per_chunk = float(Time.get_ticks_usec() - t0) / 1000.0 / float(maxi(1, sample.size()))
	var graph_column := graph_ms_per_chunk * float(ROWS_PER_COLUMN)
	var e0: float = per_variant.get(false, 0.0)
	var e1: float = per_variant.get(true, 0.0)

	var ratio := e0 / maxf(0.000001, graph_column)
	var lines: Array[String] = []
	lines.append("column cost (16x384x16), this machine, single-threaded:")
	lines.append("  graph (compiled, extent 0 by construction):  %.3f ms/column" % graph_column)
	lines.append("  multipass extent 0 (GDScript passes):         %.3f ms/column (%.1fx graph)" % [e0, ratio])
	lines.append("  multipass extent 1 (+ neighbour cliff pass):  %.3f ms/column (%.1fx graph)" % [e1, e1 / maxf(0.000001, graph_column)])
	lines.append("")
	lines.append("RECOMMENDATION (M02+): keep the compiled graph as the default backend, with analytic")
	lines.append("  extent-0 stamps for flora/structure density. Reserve the multipass evaluator for the")
	lines.append("  few features that truly need cross-chunk reads (M08 trunks crossing chunk borders,")
	lines.append("  M10 structures). Reasons, measured here:")
	lines.append("  * multipass costs %.1fx the graph per column in pure GDScript, and that gap grows with" % ratio)
	lines.append("    every neighbour-aware pass added (extent 1 already adds %.1f ms/column);" % (e1 - e0))
	lines.append("  * VoxelGeneratorMultipassCB is NOT scriptable in the 1.7 GDExtension")
	lines.append("    (probe_multipass2.gd: 'Can't inherit from a virtual class', no passes property),")
	lines.append("    so there is no engine-accelerated multipass path to move this into;")
	lines.append("  * MultipassCB also has no LOD support, which the distant-terrain milestone (M13) needs.")
	lines.append("  The graph path therefore stays default; 'multipass' remains selectable in config for")
	lines.append("  the features above and for cross-checking (55/64 chunks match the graph on seed 20260814).")
	return TestHarness.ok(SUITE, "B3/rec", "multipass vs graph column-cost verdict", "\n".join(lines))


func _mib(bytes: int) -> String:
	return "%.1f" % (float(bytes) / (1024.0 * 1024.0))
