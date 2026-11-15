class_name FieldTile
extends RefCounted
## src/spine/fields/field_tile.gd
##
## M01 / Task 6 - A rectangular sample grid of one blackboard REGION channel.
##
## Layout: `width` samples per side INCLUDING a `halo` margin on every side, so a pass that
## needs neighbours (erosion in M02, cliff detection later) can compute the halo, run its
## stencil over the core, and crop seam-free. `spacing` is the block distance between
## samples (1 = per-column exact; 4 = a soft field meant for bilinear reads).
## `origin` is the WORLD block coordinate of sample (0, 0), i.e. already shifted by the halo.
##
## Storage is a flat packed array: PackedFloat64Array for FLOAT tiles, PackedInt32Array for
## INT tiles. Quantised decisions read INT tiles; continuous maths reads FLOAT tiles.
##
## FLOAT is 64-bit ON PURPOSE (M01-fix / T3, evidence E3): GDScript floats are float64, the
## compiled graph evaluates its height in double precision, and a float32 tile silently
## rounds a surface height so that a boundary voxel (depth exactly 0 or exactly grass_depth)
## can flip side. Storing float32 made "exact per-block height" unachievable; storing
## float64 makes a tile a lossless copy of what the provider computed.
##
## LAYER: spine. Pure GDScript, no Voxel Tools types (X9 lint).

var type: String = "FLOAT"          # "FLOAT" | "INT"
var width: int = 0                  # samples per side, halo included
var spacing: float = 1.0
var origin := Vector2(0.0, 0.0)     # world block coord of sample (0,0)
var halo: int = 0
var data_f := PackedFloat64Array()
var data_i := PackedInt32Array()


## core_width = samples per side excluding halo.
func core_width() -> int:
	return maxi(0, width - 2 * halo)


static func make_float(core_width: int, spacing_blocks: float, core_origin: Vector2, halo_samples: int = 0) -> FieldTile:
	var t := FieldTile.new()
	t.type = "FLOAT"
	t.spacing = spacing_blocks
	t.halo = maxi(0, halo_samples)
	t.width = core_width + 2 * t.halo
	t.origin = core_origin - Vector2(spacing_blocks, spacing_blocks) * float(t.halo)
	t.data_f.resize(t.width * t.width)
	t.data_f.fill(0.0)
	return t


static func make_int(core_width: int, spacing_blocks: float, core_origin: Vector2, halo_samples: int = 0) -> FieldTile:
	var t := FieldTile.new()
	t.type = "INT"
	t.spacing = spacing_blocks
	t.halo = maxi(0, halo_samples)
	t.width = core_width + 2 * t.halo
	t.origin = core_origin - Vector2(spacing_blocks, spacing_blocks) * float(t.halo)
	t.data_i.resize(t.width * t.width)
	t.data_i.fill(0)
	return t


func index(i: int, j: int) -> int:
	return j * width + i


func set_f(i: int, j: int, v: float) -> void:
	data_f[index(i, j)] = v


func get_f(i: int, j: int) -> float:
	return data_f[index(i, j)]


func set_i(i: int, j: int, v: int) -> void:
	data_i[index(i, j)] = v


func get_i(i: int, j: int) -> int:
	return data_i[index(i, j)]


## Sample index (float) for a world block coordinate.
func u_of(wx: float) -> float:
	return (wx - origin.x) / spacing


func v_of(wz: float) -> float:
	return (wz - origin.y) / spacing


func sample_nearest(wx: float, wz: float) -> float:
	var i := clampi(int(roundf(u_of(wx))), 0, width - 1)
	var j := clampi(int(roundf(v_of(wz))), 0, width - 1)
	return data_f[index(i, j)] if type == "FLOAT" else float(data_i[index(i, j)])


func sample_nearest_int(wx: float, wz: float) -> int:
	var i := clampi(int(roundf(u_of(wx))), 0, width - 1)
	var j := clampi(int(roundf(v_of(wz))), 0, width - 1)
	return data_i[index(i, j)] if type == "INT" else int(roundf(data_f[index(i, j)]))


func sample_bilinear(wx: float, wz: float) -> float:
	var u := clampf(u_of(wx), 0.0, float(width - 1))
	var v := clampf(v_of(wz), 0.0, float(width - 1))
	var i0 := int(floor(u))
	var j0 := int(floor(v))
	var i1 := mini(i0 + 1, width - 1)
	var j1 := mini(j0 + 1, width - 1)
	var fu := u - float(i0)
	var fv := v - float(j0)
	var a := _at(i0, j0)
	var b := _at(i1, j0)
	var c := _at(i0, j1)
	var d := _at(i1, j1)
	return lerp(lerp(a, b, fu), lerp(c, d, fu), fv)


func _at(i: int, j: int) -> float:
	return data_f[index(i, j)] if type == "FLOAT" else float(data_i[index(i, j)])


func memory_bytes() -> int:
	return (data_f.size() * 8) + (data_i.size() * 4) + 64


## True when (wx, wz) lands INSIDE the sampled grid (no clamping needed). Consumers that
## must not silently read an edge sample - e.g. a feature stamp centred outside the current
## column - check this first and fall back to a coarser channel instead.
func covers(wx: float, wz: float) -> bool:
	if width <= 0:
		return false
	var u := u_of(wx)
	var v := v_of(wz)
	return u >= -0.5 and u <= float(width - 1) + 0.5 and v >= -0.5 and v <= float(width - 1) + 0.5


func dimensions() -> Dictionary:
	return {
		"type": type,
		"width": width,
		"core_width": core_width(),
		"halo": halo,
		"spacing": spacing,
		"origin": [origin.x, origin.y],
		"bytes": memory_bytes(),
	}


## Bit-level equality, used by X8 (evict + recompute must be identical).
func equals(other: FieldTile) -> bool:
	if other == null:
		return false
	if type != other.type or width != other.width or halo != other.halo:
		return false
	if not is_equal_approx(spacing, other.spacing) or origin != other.origin:
		return false
	if type == "FLOAT":
		return data_f == other.data_f
	return data_i == other.data_i
