class_name TerrainPass
extends ModuleDefinition
## src/spine/contracts/terrain_pass.gd
##
## M01 / Task 3 - A module that writes voxels for one 16x16 column, in scheduler order,
## after every FieldProvider it requires has published.
##
## `extent` is how many NEIGHBOUR COLUMNS the pass reads (0 = looks only at its own column).
## The scheduler turns extents into the column multiplication factor it reports, so the
## cost of neighbour awareness is visible BEFORE anyone adds it. Backends honour extent
## differently: the multipass backend gets true cross-chunk reads; the graph backend can
## only run extent-0 passes (see docs/reports/M01_REPORT.md section 9).

## Neighbour columns read on each side. 0 = none.
@export var extent: int = 0


## Write this column's voxels through ctx.writer (IColumnWriter; the adapter implements it).
func apply(_ctx: GenContext) -> void:
	push_error("TerrainPass '%s' does not override apply()" % String(id))
