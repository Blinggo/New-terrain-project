@tool
class_name HillsV1
extends FieldProvider
## src/worldgen/planet/hills_v1.gd
##
## M01 / Task 8 - The M00 hills, re-expressed as a spine module. This is the proof that the
## refactor changed STRUCTURE, not maths: the parameters below are byte-for-byte the M00
## `gen_params` values, and the remap formula is the same one the M00 graph encoded as
## Remap(min0=-1, max0=1, min1=base-amp/2, max1=base+amp/2).
##
## The graph backend pushes these params into its named nodes; the multipass backend runs
## compute_region() + the surface pass in GDScript. Both therefore evaluate identical maths
## from identical numbers, and the M00 golden hashes must reproduce bit-for-bit (X10).
##
## LAYER: worldgen. Pure GDScript: no Voxel Tools types (X9), no rand*/Time (D5). The noise
## itself arrives as ctx.noise_2d, injected by the adapter, so this file never names a noise
## class either.

@export var noise_frequency: float = 0.0035
@export var noise_octaves: int = 5
@export var noise_lacunarity: float = 2.0
@export var noise_gain: float = 0.5
@export var height_base: float = 64.0
@export var height_amplitude: float = 42.0

## Sample spacing of the published tile, in blocks. 16 = exactly ONE sample per world column,
## which is the native resolution of a height field: sample_nearest() then returns the exact
## column height, so the surface pass reproduces the graph's per-voxel decisions bit-for-bit
## while compute_region costs ~5k noise calls per region instead of ~1M (measured: a spacing-1
## tile made the determinism suite exceed its 900 s budget on the 2-thread CI box).
@export var tile_spacing: int = 16
@export var tile_halo: int = 2

const CHANNEL_HEIGHT := &"field.height"


func _init() -> void:
	id = &"planet.hills_v1"
	version = 1
	phase = Phase.PLANET
	priority = 10
	provides = [CHANNEL_HEIGHT]
	requires = []


func height_min() -> float:
	return height_base - height_amplitude * 0.5


func height_max() -> float:
	return height_base + height_amplitude * 0.5


## The M00 remap, verbatim: noise in [-1, 1] -> height in [height_min, height_max].
func height_from_noise(n: float) -> float:
	return height_min() + (n + 1.0) * 0.5 * (height_max() - height_min())


## Exact analytic height of one world column. Used by tests and by backends that do not
## want to pay for a tile lookup.
func height_at(ctx: GenContext, x: int, z: int) -> float:
	var n: float = ctx.noise_2d.call(x, z)
	return height_from_noise(n)


func compute_region(ctx: GenContext) -> void:
	var region := ctx.region_origin
	var spacing := float(maxi(1, tile_spacing))
	var tile := FieldTile.make_float(
		GenBlackboard.REGION_BLOCKS / int(spacing), spacing, Vector2(region), tile_halo)
	for j in tile.width:
		var wz := tile.origin.y + float(j) * spacing
		for i in tile.width:
			var wx := tile.origin.x + float(i) * spacing
			var n: float = ctx.noise_2d.call(int(roundf(wx)), int(roundf(wz)))
			tile.set_f(i, j, height_from_noise(n))
	ctx.publish(CHANNEL_HEIGHT, tile, id, GenBlackboard.Scope.REGION)
