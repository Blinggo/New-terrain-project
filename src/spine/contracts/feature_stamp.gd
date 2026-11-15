class_name FeatureStamp
extends ModuleDefinition
## src/spine/contracts/feature_stamp.gd
##
## M01-fix - Executable contract for point features (trees M08, structures M10, boulders).
## M01 declared the contract but nothing could run it; the generic executor now
## materializes stamps after the TerrainPasses of the same engine pass:
##
##   for candidate in candidates_near(ctx):          # deterministic 3x3 cell lookup
##       if evaluate(ctx, candidate) >= density_threshold:
##           materialize(ctx, candidate, writer)     # writes through the abstract writer
##
## The minimal generic knobs a stamp needs live here as exports: material_id (which block it
## writes), density_threshold (analytic cutoff), y_span (vertical extent relative to the
## candidate's surface row, which the stamp finds via the blackboard height channel it
## requires) and radius (horizontal half-extent of the materialized box). A stamp that needs
## a different shape overrides materialize() and ignores the box helper.
##
## No real landmarks exist in M01; tests prove execution with a throwaway marker stamp.

## Cell edge in blocks. Candidates are looked up in the 3x3 cells around a query column.
@export var cell_size: int = 64
@export var material_id: int = 1
@export var density_threshold: float = 0.5
@export var radius: int = 1
## Vertical span of the default materialization: [surface + y0, surface + y1).
@export var y_span: Array[int] = [0, 1]
## Channel the default materialize() reads to find the surface row ("" = use column base).
@export var surface_channel: StringName = &"field.height_exact"
## Coarser channel used when the exact one does not cover the stamp's centre (a stamp whose
## radius reaches outside the main column). "" = no fallback.
@export var fallback_channel: StringName = &"field.height"


## Deterministic candidate sites in the 3x3 cells around ctx.column_origin.
## Must depend only on (seed, cell coords, params) - typically ctx.chance per cell.
func candidates_near(_ctx: GenContext) -> Array:
	push_error("FeatureStamp '%s' does not override candidates_near()" % String(id))
	return []


## Analytic density contribution at a world position (0 = none). Pure maths, no state.
func evaluate(_ctx: GenContext, _pos: Vector3i) -> float:
	push_error("FeatureStamp '%s' does not override evaluate()" % String(id))
	return 0.0


## Write the feature at `center` through the writer. The default implementation fills a
## (2*radius+1) wide box over y_span above the surface row read from surface_channel.
func materialize(ctx: GenContext, center: Vector3i, writer: IColumnWriter) -> void:
	var surface := ctx.column_origin.y
	var tile: FieldTile = ctx.blackboard.try_read(surface_channel, null) as FieldTile
	if tile != null and tile.covers(float(center.x), float(center.z)):
		# Exact per-column surface, no clamping: a stamp centred outside this column must not
		# silently read an edge sample (that is how a feature ends up floating or buried).
		surface = int(roundf(tile.sample_nearest(float(center.x), float(center.z))))
	elif fallback_channel != &"":
		var coarse: FieldTile = ctx.blackboard.try_read(fallback_channel, null) as FieldTile
		if coarse != null:
			surface = int(roundf(coarse.sample_nearest(float(center.x), float(center.z))))
	var y0 := surface + int(y_span[0]) if y_span.size() > 0 else surface
	var y1 := surface + int(y_span[1]) if y_span.size() > 1 else surface + 1
	var from := Vector3i(center.x - radius, y0, center.z - radius)
	var to := Vector3i(center.x + radius + 1, y1, center.z + radius + 1)
	writer.fill_box_world(from, to, material_id)
