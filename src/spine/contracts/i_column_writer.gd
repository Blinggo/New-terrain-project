class_name IColumnWriter
extends RefCounted
## src/spine/contracts/i_column_writer.gd
##
## M01 / Task 3 - The abstract voxel sink a TerrainPass writes through. The spine defines
## it; src/adapters/ implements it (over a VoxelBuffer, a MultipassCB context, ...); tests
## implement an in-memory version. Coordinates: (lx, lz) are LOCAL to the column (0..15),
## wy is an ABSOLUTE world block row, so a pass never has to know where its column lives.

func set_type(_lx: int, _wy: int, _lz: int, _id: int) -> void:
	push_error("IColumnWriter.set_type not implemented")


func get_type(_lx: int, _wy: int, _lz: int) -> int:
	push_error("IColumnWriter.get_type not implemented")
	return 0


func column_origin() -> Vector3i:
	push_error("IColumnWriter.column_origin not implemented")
	return Vector3i.ZERO
