class_name ExperimentalColumnGenerator
extends VoxelGeneratorScript
## src/adapters/voxel/experimental_column_generator.gd
##
## M01-fix / T1 - RENAMED. This file was `multipass_column_generator.gd`, and calling it
## "multipass" was the second half of the M01 naming defect: it is NOT the extension's
## multipass callback, it is a SELF-HOSTED column compiler on top of VoxelGeneratorScript.
## The native thing is `native_column_generator.gd` (a VoxelGeneratorMultipassCB subclass),
## and this one is `experimental_columns`: an experiment that prices neighbour-aware
## generation in pure GDScript, with no engine pass/extent limits.
##
## WHAT IT DOES
##   * A COLUMN is 16 x world_height x 16 TYPE bytes, compiled by running the resolved module
##     pipeline through PipelineRunner - the same generic path the native backend uses, so
##     with the same plan the two backends must produce the same voxels (a cross-check the
##     determinism suite runs).
##   * Passes are grouped by declared extent (MultipassPassPlan, compiled with unlimited
##     limits) and run in ascending extent order. A pass with extent > 0 reads neighbour
##     columns compiled with the EARLIER passes only, which is the engine's own guarantee,
##     reproduced in GDScript.
##   * Compiled columns live in one LRU table (shared, mutexed) so a neighbour read is a
##     lookup, not a recompile.
##   * generate_block() copies the requested 16-voxel row out of the compiled column.
##
## WHY IT STILL EXISTS: the engine's native callback caps you at 4 passes and 2 columns of
## extent, and it is the fast path. This backend is the fallback for a pipeline that does not
## fit those limits, and the honest price list for neighbour-aware rules before anyone spends
## them (B3). It is NOT the default and it is NOT called "MultipassCB" anywhere.
##
## THREAD SAFETY (T4): `_generate_block` runs on engine worker threads, so each thread gets
## its own blackboard / GenContext / PipelineRunner / noise instance; the shared FieldCache
## and the shared column LRU have their own mutexes and are never held across a compile.
##
## DETERMINISM: no rand*, no clocks in value-producing paths (the profiler Callable is
## injected and may be invalid), no iteration over unordered containers.

const COLUMN_CACHE_MAX := 768
const VOXELS_PER_BLOCK := 16

var plan: MultipassPassPlan = null
var config: Dictionary = {}
var world_seed: int = 0
var broken_reason := ""

var _mutex := Mutex.new()
var _workers := {}                 # thread id -> ColumnExec
var _cols := {}                    # "cx,cz#passes" -> NeighbourColumnWriter
var _col_order: Array[String] = []
var _cache: FieldCache = null
var _aggregate := GenContext.new()
var _pipeline_scheduler: PipelineScheduler = null
var _noise_recipe: Dictionary = {}
var _base_y_voxels := -64
var _height_voxels := 384
## Blackboard errors aggregated from every per-worker board (see the native backend: a worker
## context is reset after each column, so an unaggregated error would vanish).
var _board_errors: Array[String] = []
var _column_compiles := 0
var _neighbour_reads := 0
## Counters of the columns handed out by debug_column_memory() (the harness path), in the same
## shape the native backend reports, so B1/B5 can print one table for both modular backends.
var _writer_stats := {"span_fills": 0, "box_fills": 0, "clamped_writes": 0, "rejected_writes": 0,
	"neighbour_reads": 0, "neighbour_misses": 0, "oob_reads": 0}


func setup(pipeline: Dictionary, cfg: Dictionary, seed_value: int) -> bool:
	config = cfg
	world_seed = seed_value
	broken_reason = ""
	var modules: Array = pipeline.get("modules", [])
	var scheduler: PipelineScheduler = pipeline.get("scheduler")
	if scheduler == null or modules.is_empty():
		broken_reason = "setup: resolved pipeline is missing or empty (%s)" % str(pipeline.get("errors", []))
		push_error("experimental_column_generator: %s" % broken_reason)
		return false
	_pipeline_scheduler = scheduler

	var tier := String(cfg.get("quality_tier", "low"))
	# Unlimited passes/extent: that is the entire point of self-hosting.
	plan = MultipassPassPlan.compile(modules, tier, 1 << 20, 1 << 20)
	if not plan.errors.is_empty():
		broken_reason = "pass plan refused: %s" % "; ".join(plan.errors)
		push_error("experimental_column_generator: %s" % broken_reason)
		return false
	if not plan.executes_all(modules, tier):
		broken_reason = "pass plan does not execute every enabled module (%s)" % str(plan.describe())
		push_error("experimental_column_generator: %s" % broken_reason)
		return false

	var y_min := int(cfg.get("world_y_min", -64))
	var y_max := int(cfg.get("world_y_max", 320))
	if y_min % VOXELS_PER_BLOCK != 0:
		broken_reason = "world_y_min %d is not a multiple of %d voxels" % [y_min, VOXELS_PER_BLOCK]
		push_error("experimental_column_generator: %s" % broken_reason)
		return false
	_base_y_voxels = y_min
	_height_voxels = maxi(VOXELS_PER_BLOCK, y_max - y_min)

	_noise_recipe = NoiseSamplerBuilder.first_recipe(modules)
	_cache = FieldCache.new()
	_cache.configure_budget(int(cfg.get("field_cache_budget_bytes", 24 * 1024 * 1024)))
	_cache.configure_world(seed_value, int(cfg.get("worldgen_version", 1)), tier, {
		"noise": NoiseSamplerBuilder.describe(_noise_recipe),
		"world_y_min": y_min,
		"world_y_max": y_max,
		"backend": "experimental_columns",
	})
	return true


func set_profiler(profiler: Callable) -> void:
	_aggregate.profiler = profiler
	_mutex.lock()
	for tid in _workers:
		((_workers[tid]) as ColumnExec).ctx.profiler = profiler
	_mutex.unlock()


# --- engine callback -----------------------------------------------------------------------

func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE


func _generate_block(buffer: VoxelBuffer, origin: Vector3i, _lod: int) -> void:
	if plan == null:
		return
	var cx := int(floor(float(origin.x) / float(VOXELS_PER_BLOCK)))
	var cz := int(floor(float(origin.z) / float(VOXELS_PER_BLOCK)))
	var column := _column(cx, cz, plan.pass_count())
	if column == null:
		return
	var row := int(floor(float(origin.y - _base_y_voxels) / float(VOXELS_PER_BLOCK)))
	if row < 0 or row >= _height_voxels / VOXELS_PER_BLOCK:
		return
	for y in buffer.get_size().y:
		for z in buffer.get_size().z:
			for x in buffer.get_size().x:
				buffer.set_voxel(
					column.get_type_world(origin + Vector3i(x, y, z)), x, y, z, VoxelBuffer.CHANNEL_TYPE)


## Harness entry point, identical in meaning to the native backend's: the whole column, all
## passes, in memory. ChunkHasher dispatches on this method's existence.
func debug_column_memory(column_origin: Vector3i) -> MemoryColumnWriter:
	if plan == null:
		push_error("experimental_column_generator: debug_column_memory on an unconfigured generator (%s)" % broken_reason)
		return null
	var cx := int(floor(float(column_origin.x) / float(VOXELS_PER_BLOCK)))
	var cz := int(floor(float(column_origin.z) / float(VOXELS_PER_BLOCK)))
	var column := _column(cx, cz, plan.pass_count())
	# Top-level only: _column() recurses into neighbours, and folding every level in would
	# multiply the same reads several times over.
	var sink: Dictionary = column.stats()
	_mutex.lock()
	for k in sink:
		if sink[k] is int:
			_writer_stats[k] = int(_writer_stats.get(k, 0)) + int(sink[k])
	_mutex.unlock()
	return column


func neighbour_passes_in_plan() -> bool:
	return plan != null and plan.max_extent() > 0


# --- column compilation --------------------------------------------------------------------

## The column at (cx, cz) with passes [0, passes) applied. Neighbour reads inside pass p use
## `_column(nx, nz, p)` - earlier passes only, exactly like the engine.
func _column(cx: int, cz: int, passes: int) -> NeighbourColumnWriter:
	var n := clampi(passes, 0, plan.pass_count())
	var key := "%d,%d#%d" % [cx, cz, n]
	_mutex.lock()
	var hit: NeighbourColumnWriter = _cols.get(key)
	if hit != null:
		_mutex.unlock()
		return hit
	_mutex.unlock()

	var exec := _acquire()
	var origin := Vector3i(cx * VOXELS_PER_BLOCK, _base_y_voxels, cz * VOXELS_PER_BLOCK)
	var writer := NeighbourColumnWriter.new()
	writer.setup(origin, VOXELS_PER_BLOCK, _height_voxels, VOXELS_PER_BLOCK)

	for i in n:
		var extent := plan.extent_of(i)
		writer.neighbours.clear()
		if extent > 0:
			for dz in range(-extent, extent + 1):
				for dx in range(-extent, extent + 1):
					if dx == 0 and dz == 0:
						continue
					# Earlier passes only: bounded recursion, and the same visibility rule the
					# engine enforces between its own passes.
					writer.neighbours[Vector2i(dx, dz)] = _column(cx + dx, cz + dz, i)
		exec.runner.run_modules(origin, writer, plan.modules_for(i))
		_neighbour_reads += writer.neighbour_reads

	_mutex.lock()
	if not _cols.has(key):
		_cols[key] = writer
		_col_order.append(key)
		_column_compiles += 1
		while _col_order.size() > COLUMN_CACHE_MAX:
			_cols.erase(_col_order[0])
			_col_order.pop_front()
	var stored: NeighbourColumnWriter = _cols[key]
	_mutex.unlock()
	_merge(exec)
	return stored


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
	exec.runner = PipelineRunner.new()
	exec.runner.ctx = exec.ctx
	exec.runner.scheduler = _pipeline_scheduler
	return exec


func _merge(exec: ColumnExec) -> void:
	_mutex.lock()
	_aggregate.absorb(exec.ctx)
	for e in exec.board.errors:
		if not _board_errors.has(e):
			_board_errors.append(e)
	exec.board.errors.clear()
	_mutex.unlock()
	exec.ctx.reset_counters()


func timings() -> Dictionary:
	_mutex.lock()
	var out := _aggregate.timings.duplicate()
	_mutex.unlock()
	return out


func stats() -> Dictionary:
	_mutex.lock()
	var out := {
		"backend": "experimental_columns",
		"generator_class": "VoxelGeneratorScript (self-hosted columns)",
		"workers": _workers.size(),
		"columns_cached": _cols.size(),
		"column_compiles": _column_compiles,
		"neighbour_reads": _neighbour_reads,
		"writer": _writer_stats.duplicate(),
		"executed_counts": _aggregate.executed_counts.duplicate(),
		"skipped": _aggregate.skipped.duplicate(),
		"stamp_placements": _aggregate.stamp_placements.duplicate(),
		"pipeline_errors": _aggregate.errors.duplicate(),
		"blackboard_errors": _board_errors.duplicate(),
		"field_cache": _cache.stats() if _cache != null else {},
		"plan": plan.describe() if plan != null else {},
		"noise_recipe": NoiseSamplerBuilder.describe(_noise_recipe),
		"neighbour_passes_in_plan": neighbour_passes_in_plan(),
		"broken_reason": broken_reason,
	}
	_mutex.unlock()
	return out


class ColumnExec extends RefCounted:
	var board: GenBlackboard = null
	var ctx: GenContext = null
	var runner: PipelineRunner = null
	var noise: ZN_FastNoiseLite = null

	func noise_at(x: int, z: int) -> float:
		if noise == null:
			push_error("experimental_column_generator: no noise sampler was built (does a module declare noise_sampler_recipe()?)")
			return 0.0
		return noise.get_noise_2d(float(x), float(z))
