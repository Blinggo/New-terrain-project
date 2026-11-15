class_name FieldProvider
extends ModuleDefinition
## src/spine/contracts/field_provider.gd
##
## M01 / Task 3 - A module that publishes REGION-scale field tiles (height, temperature,
## rock-strata index, ...). compute_region() runs once per 1024x1024 region (cached by
## FieldCache, keyed by channel+region+version); compute_column() is an optional per-column
## refinement for providers that need exact local values.
##
## Implementations live in src/worldgen/ and must stay pure: same (seed, region, params) ->
## bit-identical tiles (X8 relies on this).

## Publish one FieldTile per entry of `provides` into ctx.blackboard (REGION scope).
## The executor caches whatever the board flushes after this returns.
func compute_region(_ctx: GenContext) -> void:
	push_error("FieldProvider '%s' does not override compute_region()" % String(id))


## Optional. Runs per column with REGION tiles already readable from the blackboard.
func compute_column(_ctx: GenContext) -> void:
	pass
