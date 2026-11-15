class_name IColumnWriter
extends RefCounted
## src/spine/contracts/i_column_writer.gd
##
## M01-fix - The abstract voxel sink a TerrainPass / FeatureStamp writes through. The spine
## defines it; src/adapters/ implements it (over the native VoxelToolMultipassGenerator, over
## a self-hosted column array, or - in tests - over a Dictionary).
##
## COORDINATE CONVENTION (one, documented, everywhere):
##   * WORLD space: absolute block coordinates, y in [world_y_min, world_y_max).
##   * LOCAL space: lx/lz in [0,15] within the MAIN column, wy ABSOLUTE world row.
##     local -> world: world = main_min + Vector3(lx, wy - main_min.y, lz).
##   * Reads may use the whole EDITABLE area (main + neighbour extent of the current pass).
##   * Writes are MAIN-COLUMN-ONLY. Implementations clamp or record out-of-main writes;
##     overlapping neighbour-aware passes stay order-independent because of this rule.
##
## Bounds are reported in world space: bounds_main() / bounds_editable() return
## [min_inclusive, max_exclusive] as Vector3i pairs.

## Local-column write (legacy M01 API, kept for existing modules).
func set_type(_lx: int, _wy: int, _lz: int, _id: int) -> void:
	push_error("IColumnWriter.set_type not implemented")


func get_type(_lx: int, _wy: int, _lz: int) -> int:
	push_error("IColumnWriter.get_type not implemented")
	return 0


## World-space read; valid anywhere inside the editable area of the current pass.
func get_type_world(_pos: Vector3i) -> int:
	push_error("IColumnWriter.get_type_world not implemented")
	return 0


## World-space write; clamped to the main column by the implementation.
func set_type_world(_pos: Vector3i, _id: int) -> void:
	push_error("IColumnWriter.set_type_world not implemented")


## Bulk fill of an axis-aligned box, world-space, clamped to the main column.
## Used by FeatureStamp materialization and future strata passes.
func fill_box_world(_from: Vector3i, _to_exclusive: Vector3i, _id: int) -> void:
	push_error("IColumnWriter.fill_box_world not implemented")


## Vertical span fill at one WORLD (x, z): rows [y0, y1) half-open, clamped to the main
## column. The cheap primitive for heightfield surfaces: native backends implement it as a
## single engine box fill instead of one call per voxel.
func fill_span_world(_wx: int, _wz: int, _y0: int, _y1: int, _id: int) -> void:
	push_error("IColumnWriter.fill_span_world not implemented")


## [min_inclusive, max_exclusive] of the main column, world space.
func bounds_main() -> Array:
	push_error("IColumnWriter.bounds_main not implemented")
	return [Vector3i.ZERO, Vector3i.ZERO]


## [min_inclusive, max_exclusive] readable area of the current pass, world space.
func bounds_editable() -> Array:
	push_error("IColumnWriter.bounds_editable not implemented")
	return [Vector3i.ZERO, Vector3i.ZERO]


func column_origin() -> Vector3i:
	push_error("IColumnWriter.column_origin not implemented")
	return Vector3i.ZERO
