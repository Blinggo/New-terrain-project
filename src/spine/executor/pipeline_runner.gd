class_name PipelineRunner
extends RefCounted
## src/spine/executor/pipeline_runner.gd
##
## M01-fix - Executes a resolved pipeline. GENERIC: it knows the three executable contracts
## (FieldProvider, TerrainPass, FeatureStamp) and nothing else. No module id, no content
## class, no Voxel Tools type appears in this file (hard rule: no content ids in spine).
##
##   ensure_region(r)   for every FieldProvider, compute its REGION tiles unless FieldCache
##                      already holds them under the full fingerprint (channel, region,
##                      producer id+version, params fingerprint, spacing, halo, world fp),
##                      then flush the blackboard's tiles into the cache.
##   run_modules(o,w,m) make the region's tiles readable, open a COLUMN scope, run every
##                      provider's compute_column (exact per-column refinement), then run the
##                      given module list: TerrainPass.apply, FeatureStamp candidate loop.
##   run_column(o,w)    ensure_region + run_modules with EVERY tier-active module: the
##                      single-pass form used by self-hosted backends and by tests.
##
## A backend that runs several engine passes (the native multipass backend) calls
## run_modules() once per pass with that pass's module list; providers re-run per pass so
## every pass sees exact column data.
##
## Timing: around each module call, using ctx.profiler (injected; the spine never reads a
## clock itself - hard rule #3). Accumulates into ctx.timings per module id.
##
## LAYER: spine, pure GDScript.

const REGION_BLOCKS := GenBlackboard.REGION_BLOCKS

var ctx: GenContext = null
var scheduler: PipelineScheduler = null
var _declarations_applied := false
## provider id -> true once its WORLD-scope channels have been attempted. World channels are
## not region-keyed, so FieldCache cannot hold them; the blackboard's WORLD scope can, and this
## set stops a provider that publishes nothing conditionally from being re-run per column.
var _world_attempted := {}


static func region_of(column_origin: Vector3i) -> Vector2i:
	return Vector2i(
		int(floor(float(column_origin.x) / float(REGION_BLOCKS))) * REGION_BLOCKS,
		int(floor(float(column_origin.z) / float(REGION_BLOCKS))) * REGION_BLOCKS)


## True when `provider` still owes WORLD-scope channels. Asked separately from the region
## check because a provider can have world channels and NO region channels at all - and M01's
## executor skipped exactly that provider, so the module resolved, was listed in the pipeline
## dump, and never ran (evidence E2 in spine form; caught by test_extensibility X1).
func _owes_world(provider: FieldProvider) -> bool:
	if _world_attempted.has(String(provider.id)):
		return false
	for ch_variant in provider.world_channels():
		if not ctx.blackboard.has(StringName(ch_variant)):
			return true
	return false


## Modules that actually run in the active quality tier (T9: quality_scaling is wired - a
## non-positive factor retracts the module and the skip is reported).
func active_modules() -> Array:
	var out: Array = []
	for m_variant in scheduler.order:
		var m := m_variant as ModuleDefinition
		if m == null:
			continue
		if not m.runs_at_tier(ctx.quality_tier):
			ctx.skipped[String(m.id)] = "quality_tier '%s' factor %s <= 0" % [ctx.quality_tier, str(m.quality_factor(ctx.quality_tier))]
			continue
		out.append(m)
	return out


## One-time installation of the plan's channel declarations into the blackboard, so publish
## and typed reads are checked against what producers declared (T7).
func ensure_declarations() -> void:
	if _declarations_applied or ctx == null or ctx.blackboard == null:
		return
	ctx.blackboard.apply_declarations(scheduler.order)
	_declarations_applied = true


func ensure_region(region: Vector2i) -> void:
	ensure_declarations()
	ctx.region_origin = region
	for m_variant in active_modules():
		var provider := m_variant as FieldProvider
		if provider == null:
			continue
		var region_channels := provider.region_channels()
		var world_channels := provider.world_channels()
		# Every REGION tile this provider publishes must already be cached, else compute.
		var missing := false
		for ch_variant in region_channels:
			if ctx.cache.get_tile(ch_variant, region, provider) == null:
				missing = true
				break
		# A provider with world channels and no (uncached) region channels still has to run once.
		var owes_world := _owes_world(provider)
		if not missing and not owes_world:
			continue
		ctx.blackboard.begin_region(region)
		var t0 := ctx.tick_usec()
		provider.compute_region(ctx)
		_accum_timing(provider.id, t0)
		_count(provider.id)
		var tiles := ctx.blackboard.take_region_tiles()
		for ch_variant in tiles:
			ctx.cache.put(ch_variant, region, provider, tiles[ch_variant])
			ctx.cache.note_recompute()
		if owes_world:
			_world_attempted[String(provider.id)] = true
		# Fail loud, not silent: a provider that DECLARED channels and published none of them is
		# the E2 defect class. The check is per scope of this call - column channels are owed by
		# compute_column(), not here.
		_verify_published(provider, region_channels, world_channels, region, "compute_region")


## Publish the cached REGION tiles of every provider into the board (no recompute).
func publish_region_tiles(region: Vector2i) -> void:
	for m_variant in active_modules():
		var provider := m_variant as FieldProvider
		if provider == null:
			continue
		for ch_variant in provider.region_channels():
			var tile: FieldTile = ctx.cache.get_tile(ch_variant, region, provider)
			if tile != null:
				ctx.blackboard.publish(ch_variant, tile, provider.id, GenBlackboard.Scope.REGION)


func run_modules(column_origin: Vector3i, writer: IColumnWriter, modules: Array) -> void:
	var region := region_of(column_origin)
	ensure_region(region)
	publish_region_tiles(region)

	ctx.blackboard.begin_column(column_origin)
	ctx.column_origin = column_origin
	ctx.writer = writer

	# Exact per-column refinement first: a surface pass must read per-block heights, never a
	# nearest-sampled coarse tile (T3 / evidence E3).
	for m_variant in active_modules():
		var provider := m_variant as FieldProvider
		if provider == null or provider.column_channels().is_empty():
			continue
		var t0 := ctx.tick_usec()
		provider.compute_column(ctx)
		_accum_timing(provider.id, t0)
		_count(provider.id)

	for m_variant in modules:
		var m := m_variant as ModuleDefinition
		if m == null:
			continue
		if not m.runs_at_tier(ctx.quality_tier):
			ctx.skipped[String(m.id)] = "quality_tier '%s' factor %s <= 0" % [ctx.quality_tier, str(m.quality_factor(ctx.quality_tier))]
			continue
		if m is TerrainPass:
			var t0 := ctx.tick_usec()
			(m as TerrainPass).apply(ctx)
			_accum_timing(m.id, t0)
			_count(m.id)
		elif m is FeatureStamp:
			_run_stamp(m as FeatureStamp)
		elif m is FieldProvider:
			pass   # already ran above (region + column); nothing left to do per pass
		else:
			# Fail closed: a resolved module with no executable contract would be silently
			# dropped, which is exactly the M01 defect (evidence E2).
			var msg := "pipeline_runner: module '%s' (%s) is not a FieldProvider, TerrainPass or FeatureStamp, so nothing can execute it" % [
				String(m.id), m.get_class()]
			if not ctx.errors.has(msg):
				ctx.errors.append(msg)
			push_error(msg)


## run_modules over every tier-active module: the single-pass form.
func run_column(column_origin: Vector3i, writer: IColumnWriter) -> void:
	run_modules(column_origin, writer, active_modules())


## After a provider call, every channel it declared for that scope must exist - on the board,
## or (for region tiles) in the cache. A declared-but-unpublished channel is reported loudly
## instead of being left for a consumer to discover as "flat terrain".
func _verify_published(provider: FieldProvider, channels: Array, extra: Array, region: Vector2i, call_name: String) -> void:
	var all_channels: Array = channels.duplicate()
	all_channels.append_array(extra)
	for ch_variant in all_channels:
		var ch := StringName(ch_variant)
		var on_board := ctx.blackboard.has(ch)
		var cached := ctx.cache.contains(ch, region, provider)
		if on_board or cached:
			continue
		var msg := ("pipeline_runner: FieldProvider '%s' declared channel '%s' but %s() published neither it "
			+ "nor anything the cache could hold - the module resolved and ran, yet nothing downstream can "
			+ "read it. Publish it in %s(), or drop it from provides/channel_declarations.") % [
			String(provider.id), String(ch), call_name, call_name]
		if not ctx.errors.has(msg):
			ctx.errors.append(msg)
		push_error(msg)


func _run_stamp(stamp: FeatureStamp) -> void:
	var t0 := ctx.tick_usec()
	var candidates := stamp.candidates_near(ctx)
	var placed := 0
	for c_variant in candidates:
		var center := c_variant as Vector3i
		if center == null:
			continue
		if stamp.evaluate(ctx, center) < stamp.density_threshold:
			continue
		stamp.materialize(ctx, center, ctx.writer)
		placed += 1
	ctx.stamp_placements[String(stamp.id)] = int(ctx.stamp_placements.get(String(stamp.id), 0)) + placed
	_accum_timing(stamp.id, t0)
	_count(stamp.id)


func _count(id: StringName) -> void:
	ctx.executed_counts[String(id)] = int(ctx.executed_counts.get(String(id), 0)) + 1


func _accum_timing(id: StringName, t0: int) -> void:
	var t1 := ctx.tick_usec()
	if t0 > 0 and t1 > 0:
		ctx.timings[String(id)] = float(ctx.timings.get(String(id), 0.0)) + float(t1 - t0)
