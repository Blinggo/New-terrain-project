class_name FieldProvider
extends ModuleDefinition
## src/spine/contracts/field_provider.gd
##
## M01 / Task 3 - A module that publishes field tiles (height, temperature, strata index...).
##
## TWO granularities, both first class (M01-fix / T3, evidence E3):
##   * compute_region(ctx) - once per REGION_BLOCKS x REGION_BLOCKS region, cached by
##     FieldCache under a fingerprinted key. This is the CHEAP, COARSE field: sample spacing
##     is `tile_spacing` blocks. A spacing-16 tile cannot answer "what is the height of this
##     exact block column", and using nearest-sampling to pretend it can produces half-column
##     plateaus (the M01 defect the reviewer measured as E3).
##   * WORLD-scope channels are published from compute_region() too (there is no third entry
##     point): the executor calls it once per world for a provider whose only channels are
##     world-scoped, and once per uncached region otherwise.
##   * compute_column(ctx) - once per 16x16 column, publishing an EXACT tile (spacing 1) for
##     that column. Surface passes must consume the exact channel: it is the only way a
##     GDScript backend reproduces the compiled graph's per-voxel decisions bit-for-bit.
##
## A provider publishes whatever channels its `provides` list declares; the two-granularity
## split is a convention this project follows, not a framework requirement. Both calls are
## pure: same (seed, region/column, params) -> bit-identical tiles (X8).
##
## LAYER: spine, pure GDScript. No Voxel Tools types (X9 lint), no rand*/Time (D5 lint).

## Region tile sample spacing in blocks. 16 = one sample per world column.
@export var tile_spacing: int = 16
## Halo samples added around the region tile core for stencils (erosion, cliffs, M02+).
@export var tile_halo: int = 0


## Publish one FieldTile per REGION-scope entry of `provides` into ctx.blackboard.
## The executor caches whatever the board flushes after this returns.
func compute_region(_ctx: GenContext) -> void:
	push_error("FieldProvider '%s' does not override compute_region()" % String(id))


## Publish the EXACT per-column refinement (spacing 1) for COLUMN-scope channels. Runs for
## every engine pass, before the passes' TerrainPasses, so a neighbour-aware pass still sees
## exact heights. Default: nothing to refine.
func compute_column(_ctx: GenContext) -> void:
	pass


## Which of `provides` are REGION-scope / COLUMN-scope, read from channel_declarations.
## The executor uses these to decide where to cache and what to publish per call.
func region_channels() -> Array:
	return _channels_with_scope("region")


func column_channels() -> Array:
	return _channels_with_scope("column")


## WORLD-scope entries of `provides`. A provider that publishes ONLY world channels is still a
## provider: the executor must run it once per world, or it resolves, appears in the pipeline
## dump and silently does nothing (the defect class the M01 review measured as E2 - here in a
## spine-shaped disguise, found by test_extensibility X1).
func world_channels() -> Array:
	return _channels_with_scope("world")


func _channels_with_scope(scope: String) -> Array:
	var out: Array = []
	for ch in provides:
		var meta: Dictionary = channel_declarations.get(ch, {})
		if String(meta.get("scope", "")) == scope:
			out.append(ch)
	return out
