class_name NeighbourColumnWriter
extends MemoryColumnWriter
## src/adapters/voxel/neighbour_column_writer.gd
##
## M01-fix / T1 - MemoryColumnWriter plus readable NEIGHBOUR columns, for the self-hosted
## `experimental_columns` backend, whose passes are GDScript and therefore not limited to the
## engine's MAX_PASS_EXTENT = 2.
##
## Semantics mirror the engine's multipass tool exactly:
##   * reads anywhere in `neighbours` (main area grown by the pass extent) return that
##     column's output from the EARLIER passes only - the same guarantee the engine gives, and
##     the reason a neighbour-aware pass cannot depend on another pass of its own index;
##   * writes stay main-column-only (inherited), so overlapping neighbour-aware passes are
##     order-independent.
##
## LAYER: adapters.

## Vector2i(dx, dz) column offset -> MemoryColumnWriter of that neighbour.
var neighbours: Dictionary = {}
## `neighbour_reads` / `neighbour_misses` are inherited from MemoryColumnWriter (M01-fix): the
## base counts a neighbour read it CANNOT serve, this subclass counts every neighbour read and
## only misses the ones with no generated column. Same key names, so a backend can aggregate
## either sink without a special case.


func get_type_world(pos: Vector3i) -> int:
	if _inside(pos.x, pos.y, pos.z):
		return data[_index(pos.x, pos.y, pos.z)]
	var cx := int(floor(float(pos.x - origin.x) / float(width)))
	var cz := int(floor(float(pos.z - origin.z) / float(depth)))
	var nb: MemoryColumnWriter = neighbours.get(Vector2i(cx, cz))
	neighbour_reads += 1
	if nb == null:
		neighbour_misses += 1
		return 0
	return nb.get_type_world(pos)


## True when a position is readable at all (main column or a known neighbour). Passes use it
## to tell "air" from "not generated", which is otherwise indistinguishable - and silently
## treating the two as the same is how a neighbour rule goes wrong at a world edge.
func is_readable(pos: Vector3i) -> bool:
	if _inside(pos.x, pos.y, pos.z):
		return true
	var cx := int(floor(float(pos.x - origin.x) / float(width)))
	var cz := int(floor(float(pos.z - origin.z) / float(depth)))
	return neighbours.has(Vector2i(cx, cz))


func stats() -> Dictionary:
	var out := super.stats()
	out["clamped_writes"] = clamped_writes
	out["neighbours"] = neighbours.size()
	out["neighbour_hit_rate"] = (float(neighbour_reads - neighbour_misses) / float(neighbour_reads)) \
		if neighbour_reads > 0 else 0.0
	return out
