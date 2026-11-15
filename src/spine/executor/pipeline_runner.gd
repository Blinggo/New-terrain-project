class_name PipelineRunner
extends RefCounted
## src/spine/executor/pipeline_runner.gd
##
## M01 - Executes a resolved pipeline for one region / one column:
##
##   ensure_region(r):  for every FieldProvider in order, compute its REGION tiles unless
##                      FieldCache already holds them (keyed channel+region+version), then
##                      flush the blackboard's tiles into the cache.
##   run_column(o, w):  make the region's tiles readable, open a COLUMN scope, then run every
##                      TerrainPass in resolved order against the abstract writer w.
##
## Timing: around each module call, using ctx.profiler (injected; the spine never reads a
## clock itself - hard rule #3). Accumulates into ctx.timings per module id.
##
## LAYER: spine, pure GDScript. The multipass adapter (src/adapters/) drives this with a
## writer over the MultipassCB context; tests drive it with an in-memory writer.

const REGION_BLOCKS := GenBlackboard.REGION_BLOCKS

var ctx: GenContext = null
var scheduler: PipelineScheduler = null


static func region_of(column_origin: Vector3i) -> Vector2i:
	return Vector2i(
		int(floor(float(column_origin.x) / float(REGION_BLOCKS))) * REGION_BLOCKS,
		int(floor(float(column_origin.z) / float(REGION_BLOCKS))) * REGION_BLOCKS)


func ensure_region(region: Vector2i) -> void:
	ctx.region_origin = region
	for m in scheduler.order:
		if not (m is FieldProvider):
			continue
		var provider := m as FieldProvider
		# Every tile this provider publishes must already be cached, else compute.
		var missing := false
		for ch in provider.provides:
			if ctx.cache.get_tile(ch, region, provider.version) == null:
				missing = true
				break
		if not missing:
			continue
		ctx.blackboard.begin_region(region)
		var t0 := ctx.tick_usec()
		provider.compute_region(ctx)
		_accum_timing(provider.id, t0)
		var tiles := ctx.blackboard.take_region_tiles()
		for ch in tiles:
			ctx.cache.put(ch, region, provider.version, tiles[ch])


func run_column(column_origin: Vector3i, writer: IColumnWriter) -> void:
	var region := region_of(column_origin)
	ensure_region(region)

	# Make cached region tiles readable in the REGION scope without recomputing them;
	# publish() overwrites same-type entries, so a new region simply replaces the old tiles.
	for m in scheduler.order:
		if not (m is FieldProvider):
			continue
		var provider := m as FieldProvider
		for ch in provider.provides:
			var tile: FieldTile = ctx.cache.get_tile(ch, region, provider.version)
			if tile != null:
				ctx.blackboard.publish(ch, tile, provider.id, GenBlackboard.Scope.REGION)

	ctx.blackboard.begin_column(column_origin)
	ctx.column_origin = column_origin
	ctx.writer = writer

	for m in scheduler.order:
		if m is FieldProvider:
			var t0 := ctx.tick_usec()
			(m as FieldProvider).compute_column(ctx)
			_accum_timing((m as FieldProvider).id, t0)
		elif m is TerrainPass:
			var t0 := ctx.tick_usec()
			(m as TerrainPass).apply(ctx)
			_accum_timing((m as TerrainPass).id, t0)


func _accum_timing(id: StringName, t0: int) -> void:
	var t1 := ctx.tick_usec()
	if t0 > 0 and t1 > 0:
		ctx.timings[String(id)] = float(ctx.timings.get(String(id), 0.0)) + float(t1 - t0)
