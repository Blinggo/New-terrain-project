class_name NativeColumnWriter
extends IColumnWriter
## src/adapters/voxel/native_column_writer.gd
##
## M01-fix / T1 - IColumnWriter over the engine's own multipass tool
## (VoxelToolMultipassGenerator), which the extension hands to `_generate_pass` and which
## exists ONLY for the duration of that callback (so bind()/unbind() bracket every call and
## an unbound write is a loud error, never a silent no-op).
##
## WRITES ARE BOX FILLS, NOT VOXEL LOOPS (measured, tools/probe_native_cb5.gd):
##   per-voxel set_voxel over one column's heightfield  3.40 ms/column
##   one VoxelTool.do_box per (x, z) span               0.93 ms/column   <- 3.7x faster
## do_box is inclusive at both ends and uses the tool's `value` + `mode`, both set
## immediately before each call (the tool belongs to one pass on one worker thread, but
## setting them per call keeps the writer independent of that guarantee).
##
## Coordinates: the engine's areas are in VOXELS. main = one 16 x column_height x 16 column;
## editable = main grown by the current pass' extent. Writes are clamped to main (the
## documented IColumnWriter rule that keeps overlapping neighbour-aware passes
## order-independent); reads are legal anywhere in editable.
##
## LAYER: adapters (may name Voxel Tools classes).

var tool: VoxelToolMultipassGenerator = null
var main_min := Vector3i.ZERO
var main_max := Vector3i.ZERO          # exclusive
var editable_min := Vector3i.ZERO
var editable_max := Vector3i.ZERO      # exclusive
var pass_index := -1
var span_fills := 0
var box_fills := 0
var clamped_writes := 0
var rejected_writes := 0
var unbound_writes := 0
## Reads that landed OUTSIDE the main column: the direct, countable proof that a
## neighbour-aware pass really read another column through the engine's editable area
## (rather than silently reading zeros, which would look identical from the module's side).
var neighbour_reads := 0
var neighbour_misses := 0


func bind(t: VoxelToolMultipassGenerator, index: int) -> void:
	tool = t
	pass_index = index
	main_min = t.get_main_area_min()
	main_max = t.get_main_area_max()
	editable_min = t.get_editable_area_min()
	editable_max = t.get_editable_area_max()


## Drop the tool reference: it is owned by the engine and dies with the callback. Keeping it
## would leave a dangling Object reference in a long-lived per-worker object.
func unbind() -> void:
	tool = null
	pass_index = -1


func is_bound() -> bool:
	return tool != null and is_instance_valid(tool)


func set_type(lx: int, wy: int, lz: int, id: int) -> void:
	set_type_world(Vector3i(main_min.x + lx, wy, main_min.z + lz), id)


func get_type(lx: int, wy: int, lz: int) -> int:
	return get_type_world(Vector3i(main_min.x + lx, wy, main_min.z + lz))


func get_type_world(pos: Vector3i) -> int:
	if not is_bound():
		_fail("get_type_world")
		return 0
	if not _inside_main(pos):
		if _inside_editable(pos):
			neighbour_reads += 1
		else:
			# Outside even the editable area: the engine returns a default here, so the value
			# is meaningless. Counted, because a pass that reads beyond its extent is a bug
			# that would otherwise present as "the neighbour is air".
			neighbour_misses += 1
	return tool.get_voxel(pos)


func _inside_editable(pos: Vector3i) -> bool:
	return pos.x >= editable_min.x and pos.x < editable_max.x \
		and pos.y >= editable_min.y and pos.y < editable_max.y \
		and pos.z >= editable_min.z and pos.z < editable_max.z


func set_type_world(pos: Vector3i, id: int) -> void:
	if not is_bound():
		_fail("set_type_world")
		return
	if not _inside_main(pos):
		# Not clamped: smearing an out-of-column write onto the nearest edge voxel would put
		# terrain where no module asked for it. Dropped and counted, so it shows up in the
		# build report instead of disappearing.
		rejected_writes += 1
		return
	tool.value = id
	tool.mode = VoxelTool.MODE_ADD
	tool.set_voxel(pos, id)


func fill_box_world(from: Vector3i, to_exclusive: Vector3i, id: int) -> void:
	if not is_bound():
		_fail("fill_box_world")
		return
	box_fills += 1
	var box := _clip_box(from, to_exclusive)
	if box.is_empty():
		return
	tool.value = id
	tool.mode = VoxelTool.MODE_ADD
	tool.do_box(box[0], box[1])


## Rows [y0, y1) at one world (x, z). The heightfield primitive: one engine box fill.
func fill_span_world(wx: int, wz: int, y0: int, y1: int, id: int) -> void:
	if not is_bound():
		_fail("fill_span_world")
		return
	span_fills += 1
	if y1 <= y0:
		return
	# x/z are a SINGLE voxel, so the exclusive bound is +1 on those axes (passing wx again
	# makes an empty box and every span is silently clipped away - caught by the live
	# streaming check, tools/probe_native_live.gd, which is exactly why that check exists).
	var box := _clip_box(Vector3i(wx, y0, wz), Vector3i(wx + 1, y1, wz + 1))
	if box.is_empty():
		return
	tool.value = id
	tool.mode = VoxelTool.MODE_ADD
	tool.do_box(box[0], box[1])


func _inside_main(pos: Vector3i) -> bool:
	return pos.x >= main_min.x and pos.x < main_max.x \
		and pos.y >= main_min.y and pos.y < main_max.y \
		and pos.z >= main_min.z and pos.z < main_max.z


## Intersect a half-open world box with the MAIN area. Returns [] when nothing is left
## (counted as a rejected write), or [min_inclusive, max_inclusive] for do_box.
func _clip_box(from: Vector3i, to_exclusive: Vector3i) -> Array:
	var a := Vector3i(maxi(from.x, main_min.x), maxi(from.y, main_min.y), maxi(from.z, main_min.z))
	var b := Vector3i(mini(to_exclusive.x, main_max.x) - 1, mini(to_exclusive.y, main_max.y) - 1, mini(to_exclusive.z, main_max.z) - 1)
	if b.x < a.x or b.y < a.y or b.z < a.z:
		rejected_writes += 1
		return []
	if a != from or b != to_exclusive - Vector3i(1, 1, 1):
		clamped_writes += 1
	return [a, b]


func bounds_main() -> Array:
	return [main_min, main_max]


func bounds_editable() -> Array:
	return [editable_min, editable_max]


func column_origin() -> Vector3i:
	return main_min


func stats() -> Dictionary:
	return {
		"span_fills": span_fills,
		"box_fills": box_fills,
		"clamped_writes": clamped_writes,
		"rejected_writes": rejected_writes,
		"unbound_writes": unbound_writes,
		"neighbour_reads": neighbour_reads,
		"neighbour_misses": neighbour_misses,
	}


func _fail(op: String) -> void:
	unbound_writes += 1
	push_error("native_column_writer: %s called with no bound tool (the engine tool only exists during _generate_pass); pass=%d" % [op, pass_index])
