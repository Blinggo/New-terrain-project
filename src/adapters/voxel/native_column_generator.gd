class_name NativeColumnGenerator
extends VoxelGeneratorMultipassCB
## src/adapters/voxel/native_column_generator.gd
##
## M01-fix / T1 - The NATIVE multipass backend: a GDScript subclass of the extension's own
## VoxelGeneratorMultipassCB. This is the pattern the M01 review proved exists and that the
## first M01 pass wrongly declared impossible (evidence E1):
##
##   * Subclass VoxelGeneratorMultipassCB itself (NOT VoxelToolMultipassGenerator, which is a
##     virtual class GDScript cannot inherit, and which was the only thing M01 probed).
##   * Implement `_generate_pass(tool, pass_index)`: the engine hands you a
##     VoxelToolMultipassGenerator whose main area is ONE column and whose editable area is
##     the main area grown by that pass' extent. Neighbour columns' earlier passes are
##     readable (measured: tools/probe_native_cb7.gd, pass 1 extent 1 read ids written by
##     pass 0 in the columns on both sides).
##   * Implement `_generate_block_fallback(buffer, origin)` and `_get_used_channels_mask()`.
##   * `generate_block()` on this class is "Not implemented" and does NOT route to the
##     fallback (tools/probe_native_cb8.gd): columns are driven by the engine's streaming, so
##     the determinism harness reads a column through debug_column_memory() below instead.
##   * Limits: MAX_PASSES 4, MAX_PASS_EXTENT 2 columns, column height <= 32 blocks, no LOD.
##     MultipassPassPlan enforces all of them at build time and fails closed.
##
## WHAT RUNS: the resolved module pipeline, through PipelineRunner, generically. This file
## names no module id and no worldgen class - only the three executable contracts, via the
## plan. Every enabled module that the plan cannot execute is a build error (evidence E2).
##
## THREAD SAFETY (T4): `_generate_pass` is called concurrently on engine worker threads
## (measured: distinct OS.get_thread_caller_id() values during live streaming). Therefore
##   * each worker thread gets its OWN blackboard / GenContext / PipelineRunner / writer /
##     noise instance (a per-worker pool keyed by thread id, guarded by a Mutex),
##   * the shared FieldCache has its own internal Mutex and tiles in it are never mutated
##     after put() (a recomputed tile is a new object),
##   * nothing in a value-producing path reads a clock or a random generator: the profiler is
##     an injected Callable and every RNG stream is seeded from the explicit world seed.
##
## LAYER: adapters (may name Voxel Tools classes).

const VOXELS_PER_BLOCK := 16

var plan: MultipassPassPlan = null
var config: Dictionary = {}
var world_seed: int = 0
var broken_reason := ""

var _mutex := Mutex.new()
var _workers := {}                 # thread id -> ColumnExec
var _cache: FieldCache = null
var _aggregate := GenContext.new()
var _writer_stats := {"span_fills": 0, "box_fills": 0, "clamped_writes": 0, "rejected_writes": 0, "unbound_writes": 0, "neighbour_reads": 0, "neighbour_misses": 0}
var _pass_calls := {}              # pass index -> count
## thread id -> pass calls on that thread. Direct evidence for T4: generation really does run
## on several engine worker threads, so the per-worker contexts are not decoration.
var _thread_calls := {}
var _noise_recipe: Dictionary = {}
var _base_y_voxels := -64
var _height_voxels := 384
var _fallback_calls := 0
## Blackboard errors from every per-worker board, aggregated (deduped). A publish that
## contradicts a declaration, or a read of an unpublished channel, must survive the worker
## context it happened in or it is invisible in the report.
var _board_errors: Array[String] = []
var _harness_columns := 0
var _harness_rejected_writes := 0
var _pipeline_scheduler: PipelineScheduler = null


## Configure from a RESOLVED pipeline. Returns true when the generator is usable; false means
## the caller must not build a world with it (fail closed - the adapter turns false into a
## null generator, and the runtime turns that into a loud boot error).
func setup(pipeline: Dictionary, cfg: Dictionary, seed_value: int) -> bool:
	config = cfg
	world_seed = seed_value
	broken_reason = ""

	var modules: Array = pipeline.get("modules", [])
	var scheduler: PipelineScheduler = pipeline.get("scheduler")
	if scheduler == null or modules.is_empty():
		broken_reason = "setup: resolved pipeline is missing or empty (%s)" % str(pipeline.get("errors", []))
		push_error("native_column_generator: %s" % broken_reason)
		return false

	_pipeline_scheduler = scheduler
	var tier := String(cfg.get("quality_tier", "low"))
	plan = MultipassPassPlan.compile(modules, tier)
	if not plan.errors.is_empty():
		broken_reason = "pass plan refused: %s" % "; ".join(plan.errors)
		push_error("native_column_generator: %s" % broken_reason)
		return false
	if not plan.executes_all(modules, tier):
		broken_reason = "pass plan does not execute every enabled module (plan=%s)" % str(plan.describe())
		push_error("native_column_generator: %s" % broken_reason)
		return false
	for w in plan.warnings:
		push_warning("native_column_generator: %s" % w)

	# --- world geometry, derived from config (never hardcoded here) ----------------------
	var y_min := int(cfg.get("world_y_min", -64))
	var y_max := int(cfg.get("world_y_max", 320))
	if y_min % VOXELS_PER_BLOCK != 0:
		broken_reason = "world_y_min %d is not a multiple of %d voxels, so it cannot be a column base" % [y_min, VOXELS_PER_BLOCK]
		push_error("native_column_generator: %s" % broken_reason)
		return false
	var height_blocks := int(ceil(float(y_max - y_min) / float(VOXELS_PER_BLOCK)))
	if height_blocks > MultipassPassPlan.MAX_COLUMN_HEIGHT_BLOCKS:
		broken_reason = "the world is %d blocks tall but VoxelGeneratorMultipassCB documents a %d-block column limit" % [
			height_blocks, MultipassPassPlan.MAX_COLUMN_HEIGHT_BLOCKS]
		push_error("native_column_generator: %s" % broken_reason)
		return false
	_base_y_voxels = y_min
	_height_voxels = height_blocks * VOXELS_PER_BLOCK
	column_base_y_blocks = int(floor(float(y_min) / float(VOXELS_PER_BLOCK)))
	column_height_blocks = height_blocks

	# --- engine pass configuration -------------------------------------------------------
	pass_count = plan.pass_count()
	for i in plan.pass_count():
		set_pass_extent_blocks(i, plan.extent_of(i))

	# --- shared cache, keyed by everything that can change a tile (T5) -------------------
	_noise_recipe = NoiseSamplerBuilder.first_recipe(modules)
	_cache = FieldCache.new()
	_cache.configure_budget(int(cfg.get("field_cache_budget_bytes", 24 * 1024 * 1024)))
	_cache.configure_world(seed_value, int(cfg.get("worldgen_version", 1)), tier, {
		"noise": NoiseSamplerBuilder.describe(_noise_recipe),
		"world_y_min": y_min,
		"world_y_max": y_max,
		"backend": "native_cb",
	})
	return true


## The runtime injects its clock for per-module timings; the spine never reads one itself.
func set_profiler(profiler: Callable) -> void:
	_aggregate.profiler = profiler
	_mutex.lock()
	for tid in _workers:
		((_workers[tid]) as ColumnExec).ctx.profiler = profiler
	_mutex.unlock()


# --- engine callbacks --------------------------------------------------------------------

func _generate_pass(tool: VoxelToolMultipassGenerator, index: int) -> void:
	if plan == null:
		return
	var exec := _acquire()
	exec.writer.bind(tool, index)
	var origin: Vector3i = tool.get_main_area_min()
	exec.runner.run_modules(origin, exec.writer, plan.modules_for(index))
	exec.writer.unbind()
	_merge(exec, index)


## Called by the engine when a single block is needed outside column streaming. Runs the whole
## plan for that block's column into memory and copies the requested 16-voxel row out.
## Neighbour-aware passes see no neighbours here (there is no editable area), which is why
## the report says so loudly instead of pretending the fallback is pass-complete.
func _generate_block_fallback(buffer: VoxelBuffer, origin: Vector3i) -> void:
	_mutex.lock()
	_fallback_calls += 1
	_mutex.unlock()
	var column := debug_column_memory(Vector3i(origin.x, _base_y_voxels, origin.z))
	if column == null:
		return
	for y in buffer.get_size().y:
		for z in buffer.get_size().z:
			for x in buffer.get_size().x:
				buffer.set_voxel(column.get_type_world(origin + Vector3i(x, y, z)), x, y, z, VoxelBuffer.CHANNEL_TYPE)


func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE


# --- harness / debug entry point ----------------------------------------------------------

## The whole column at `column_origin` as in-memory voxels, produced by the SAME plan,
## runner and modules the engine calls - only the sink differs (MemoryColumnWriter instead of
## the engine tool). The determinism harness hashes 16^3 slices of this; the live-terrain
## test proves the two sinks agree (tests/smoke/test_spine.gd X-new "streaming == harness").
##
## Passes run sequentially in one context, so a pass with extent > 0 reads zeros outside the
## column: goldens are therefore taken with neighbour passes DISABLED, as the M01-fix
## acceptance criteria require, and `neighbour_passes_in_plan` says whether that applied.
## The whole column at `column_origin` as in-memory voxels, produced by the SAME plan, runner
## and modules the engine calls - only the sink differs (MemoryColumnWriter instead of the
## engine tool). The determinism harness hashes 16^3 slices of this; the live-terrain test
## proves the two sinks agree (X-new "native CB: live streaming == harness").
##
## Every call compiles the column from scratch (no memo): a determinism check that could hit a
## cache would be measuring the cache. Passes run sequentially in one context, so a pass with
## extent > 0 reads zeros outside the column - goldens are therefore taken with neighbour
## passes DISABLED, as the M01-fix acceptance criteria require, and
## `neighbour_passes_in_plan()` says whether that applied.
func debug_column_memory(column_origin: Vector3i) -> MemoryColumnWriter:
	if plan == null:
		push_error("native_column_generator: debug_column_memory called on an unconfigured generator (%s)" % broken_reason)
		return null
	var origin := Vector3i(column_origin.x, _base_y_voxels, column_origin.z)
	var exec := _acquire()
	var writer := MemoryColumnWriter.new()
	writer.setup(origin, VOXELS_PER_BLOCK, _height_voxels, VOXELS_PER_BLOCK)
	for i in plan.pass_count():
		exec.runner.run_modules(origin, writer, plan.modules_for(i))
	_merge(exec, -1)
	_merge_sink(writer.stats())
	_mutex.lock()
	_harness_columns += 1
	_harness_rejected_writes += writer.rejected_writes
	_mutex.unlock()
	return writer


## Fold one sink's counters into the aggregate the report prints. Called for BOTH sinks: the
## engine's NativeColumnWriter (from `_merge`, via `_generate_pass`) and the in-memory
## MemoryColumnWriter (from `debug_column_memory`). Without the second call the harness path
## reports neighbour_reads = 0 while an extent-1 module is in fact reading a wall of air -
## which is exactly the kind of number that must not appear in a report (M01-fix / T4).
func _merge_sink(sink_stats: Dictionary) -> void:
	_mutex.lock()
	for k in sink_stats:
		if sink_stats[k] is int:
			_writer_stats[k] = int(_writer_stats.get(k, 0)) + int(sink_stats[k])
	_mutex.unlock()


## True when the plan contains a pass with extent > 0: the in-memory path cannot reproduce
## neighbour reads, so callers must say so rather than treat its output as authoritative.
func neighbour_passes_in_plan() -> bool:
	return plan != null and plan.max_extent() > 0


# --- per-worker execution contexts ---------------------------------------------------------

func _acquire() -> ColumnExec:
	var tid := OS.get_thread_caller_id()
	_mutex.lock()
	var exec: ColumnExec = _workers.get(tid)
	if exec == null:
		exec = _make_exec()
		_workers[tid] = exec
	_mutex.unlock()
	return exec


func _make_exec() -> ColumnExec:
	var exec := ColumnExec.new()
	exec.board = GenBlackboard.new()
	exec.ctx = GenContext.new()
	exec.ctx.blackboard = exec.board
	exec.ctx.cache = _cache
	exec.ctx.config = config
	exec.ctx.quality_tier = String(config.get("quality_tier", "low"))
	exec.ctx.world_seed = world_seed
	exec.ctx.profiler = _aggregate.profiler
	exec.noise = NoiseSamplerBuilder.build(_noise_recipe, world_seed)
	exec.ctx.noise_2d = Callable(exec, "noise_at")
	exec.writer = NativeColumnWriter.new()
	exec.runner = PipelineRunner.new()
	exec.runner.ctx = exec.ctx
	# The resolved scheduler itself: one resolution, one order, no second source of truth.
	exec.runner.scheduler = _pipeline_scheduler
	return exec


func _merge(exec: ColumnExec, index: int) -> void:
	_mutex.lock()
	_aggregate.absorb(exec.ctx)
	for e in exec.board.errors:
		if not _board_errors.has(e):
			_board_errors.append(e)
	exec.board.errors.clear()
	var ws := exec.writer.stats()
	for k in ws:
		_writer_stats[k] = int(_writer_stats.get(k, 0)) + int(ws[k])
	if index >= 0:
		_pass_calls[index] = int(_pass_calls.get(index, 0)) + 1
		var tid := OS.get_thread_caller_id()
		_thread_calls[tid] = int(_thread_calls.get(tid, 0)) + 1
	_mutex.unlock()
	exec.ctx.reset_counters()
	exec.writer.span_fills = 0
	exec.writer.box_fills = 0
	exec.writer.clamped_writes = 0
	exec.writer.rejected_writes = 0
	exec.writer.unbound_writes = 0
	exec.writer.neighbour_reads = 0
	exec.writer.neighbour_misses = 0


func timings() -> Dictionary:
	_mutex.lock()
	var out := _aggregate.timings.duplicate()
	_mutex.unlock()
	return out


func stats() -> Dictionary:
	_mutex.lock()
	var out := {
		"backend": "native_cb",
		"generator_class": "VoxelGeneratorMultipassCB (GDScript subclass)",
		"workers": _workers.size(),
		"pass_calls": _pass_calls.duplicate(),
		"worker_thread_ids": _thread_calls.keys(),
		"worker_thread_calls": _thread_calls.duplicate(),
		"fallback_calls": _fallback_calls,
		"harness_columns": _harness_columns,
		"harness_rejected_writes": _harness_rejected_writes,
		"executed_counts": _aggregate.executed_counts.duplicate(),
		"skipped": _aggregate.skipped.duplicate(),
		"stamp_placements": _aggregate.stamp_placements.duplicate(),
		"pipeline_errors": _aggregate.errors.duplicate(),
		"blackboard_errors": _board_errors.duplicate(),
		"writer": _writer_stats.duplicate(),
		"field_cache": _cache.stats() if _cache != null else {},
		"plan": plan.describe() if plan != null else {},
		"noise_recipe": NoiseSamplerBuilder.describe(_noise_recipe),
		"column_base_y_blocks": column_base_y_blocks,
		"column_height_blocks": column_height_blocks,
		"pass_count": pass_count,
		"neighbour_passes_in_plan": neighbour_passes_in_plan(),
		"broken_reason": broken_reason,
	}
	_mutex.unlock()
	return out


## One execution context per worker thread: nothing mutable is shared between threads except
## the internally-mutexed FieldCache.
class ColumnExec extends RefCounted:
	var board: GenBlackboard = null
	var ctx: GenContext = null
	var runner: PipelineRunner = null
	var writer: NativeColumnWriter = null
	var noise: ZN_FastNoiseLite = null

	func noise_at(x: int, z: int) -> float:
		if noise == null:
			push_error("native_column_generator: no noise sampler was built (does a module declare noise_sampler_recipe()?)")
			return 0.0
		return noise.get_noise_2d(float(x), float(z))
