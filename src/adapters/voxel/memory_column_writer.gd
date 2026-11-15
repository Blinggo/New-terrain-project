class_name MemoryColumnWriter
extends IColumnWriter
## src/adapters/voxel/memory_column_writer.gd
##
## M01-fix / T1 - In-memory column sink implementing the spine's IColumnWriter over a flat
## PackedByteArray. Used by:
##   * the self-hosted experimental_columns backend (its whole column store),
##   * the native multipass backend's `_generate_block_fallback` (a block requested outside
##     the engine's column streaming),
##   * tests, which need voxel output without an engine terrain.
##
## Layout: data[(y - y_min) * stride_xz + (z - origin.z) * width + (x - origin.x)],
## width/height/depth in VOXELS, y from y_min. Writes outside the box are IGNORED and
## counted in `rejected_writes`, because a silently dropped write is how a module "runs but
## changes nothing" (the M01 defect, evidence E2) - so the counter is part of the report.
##
## READS outside the box are counted for the same reason (M01-fix / T4). This writer holds
## exactly ONE column, so a read at another column's x/z is a neighbour read this path cannot
## serve: it returns air (0) and records `neighbour_reads` + `neighbour_misses`. Without those
## counters an extent-1 module run through the in-memory harness silently reads a wall of air
## and still "passes", which is indistinguishable from a module that does nothing. A read
## outside only in y is an `oob_read`. Subclasses that DO hold neighbours
## (NeighbourColumnWriter) override get_type_world and serve them.
##
## LAYER: adapters (implements a spine contract; no Voxel Tools types needed here).

var data := PackedByteArray()
var origin := Vector3i.ZERO          # world coord of data[0]
var width := 16
var height := 384
var depth := 16
var y_min := -64
var rejected_writes := 0
var clamped_writes := 0
var span_fills := 0
var box_fills := 0
## Reads that asked for a column this writer does not hold (a neighbour pass on the in-memory
## path). Always a miss here, so both counters move together; NeighbourColumnWriter separates
## them because it can serve some of those reads.
var neighbour_reads := 0
var neighbour_misses := 0
## Reads outside the column vertically (above the world top / below the world floor).
var oob_reads := 0


func setup(column_origin: Vector3i, w: int, h: int, d: int) -> void:
	origin = column_origin
	y_min = column_origin.y
	width = w
	height = h
	depth = d
	data.resize(w * h * d)
	data.fill(0)


func _index(wx: int, wy: int, wz: int) -> int:
	return (wy - y_min) * (width * depth) + (wz - origin.z) * width + (wx - origin.x)


func _inside(wx: int, wy: int, wz: int) -> bool:
	return wx >= origin.x and wx < origin.x + width \
		and wy >= y_min and wy < y_min + height \
		and wz >= origin.z and wz < origin.z + depth


func set_type(lx: int, wy: int, lz: int, id: int) -> void:
	set_type_world(Vector3i(origin.x + lx, wy, origin.z + lz), id)


func get_type(lx: int, wy: int, lz: int) -> int:
	return get_type_world(Vector3i(origin.x + lx, wy, origin.z + lz))


func get_type_world(pos: Vector3i) -> int:
	if _inside(pos.x, pos.y, pos.z):
		return data[_index(pos.x, pos.y, pos.z)]
	if pos.x < origin.x or pos.x >= origin.x + width or pos.z < origin.z or pos.z >= origin.z + depth:
		neighbour_reads += 1
		neighbour_misses += 1
	else:
		oob_reads += 1
	return 0


## Counters, in the same shape NativeColumnWriter/NeighbourColumnWriter report, so a backend
## can aggregate whichever sink a call used without knowing which it was.
func stats() -> Dictionary:
	return {
		"span_fills": span_fills,
		"box_fills": box_fills,
		"clamped_writes": clamped_writes,
		"rejected_writes": rejected_writes,
		"neighbour_reads": neighbour_reads,
		"neighbour_misses": neighbour_misses,
		"oob_reads": oob_reads,
	}


func set_type_world(pos: Vector3i, id: int) -> void:
	if not _inside(pos.x, pos.y, pos.z):
		rejected_writes += 1
		return
	data[_index(pos.x, pos.y, pos.z)] = id


func fill_box_world(from: Vector3i, to_exclusive: Vector3i, id: int) -> void:
	box_fills += 1
	var x0 := maxi(from.x, origin.x)
	var x1 := mini(to_exclusive.x, origin.x + width)
	var y0 := maxi(from.y, y_min)
	var y1 := mini(to_exclusive.y, y_min + height)
	var z0 := maxi(from.z, origin.z)
	var z1 := mini(to_exclusive.z, origin.z + depth)
	if x1 <= x0 or y1 <= y0 or z1 <= z0:
		rejected_writes += 1
		return
	if x0 != from.x or y0 != from.y or z0 != from.z or x1 != to_exclusive.x or y1 != to_exclusive.y or z1 != to_exclusive.z:
		clamped_writes += 1
	# NOTE: PackedByteArray has no fill_range() in Godot 4.7 (verified: it is a parse error,
	# not a runtime one), so a box fill is an explicit triple loop over validated bounds.
	var stride := width * depth
	for z in range(z0, z1):
		var idx := (y0 - y_min) * stride + (z - origin.z) * width + (x0 - origin.x)
		for _y in range(y0, y1):
			var row_end := idx + (x1 - x0)
			while idx < row_end:
				data[idx] = id
				idx += 1
			idx += stride - (x1 - x0)


## Rows [y0, y1) at one world (x, z). The heightfield primitive. The vertical stride is
## width*depth, so this is a strided write, not a fill_range - but it validates ONCE and then
## writes straight into the packed array, which is what keeps a GDScript column compile in the
## low milliseconds instead of the tens (measured with tools/probe_native_goldens.gd).
func fill_span_world(wx: int, wz: int, y0: int, y1: int, id: int) -> void:
	span_fills += 1
	if wx < origin.x or wx >= origin.x + width or wz < origin.z or wz >= origin.z + depth or y1 <= y0:
		rejected_writes += 1
		return
	var a := maxi(y0, y_min)
	var b := mini(y1, y_min + height)
	if b <= a:
		rejected_writes += 1
		return
	if a != y0 or b != y1:
		clamped_writes += 1
	var stride := width * depth
	var idx := (a - y_min) * stride + (wz - origin.z) * width + (wx - origin.x)
	for _i in range(b - a):
		data[idx] = id
		idx += stride


func bounds_main() -> Array:
	return [origin, origin + Vector3i(width, height, depth)]


func bounds_editable() -> Array:
	return bounds_main()


func column_origin() -> Vector3i:
	return origin


## Topmost non-air row at a local (lx, lz), or y_min - 1 for an empty column. Used by the
## neighbour-aware spike, which derives its ids from the generated data instead of naming
## any content module.
func top_solid(lx: int, lz: int) -> int:
	for i in range(height - 1, -1, -1):
		if data[i * (width * depth) + lz * width + lx] != 0:
			return y_min + i
	return y_min - 1
