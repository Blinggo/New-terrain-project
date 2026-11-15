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
## TWO channels, on purpose (M01-fix / T3, evidence E3):
##   field.height        REGION tile, spacing `tile_spacing` (16) + halo. Cheap, coarse. A
##                       spacing-16 tile holds ONE sample per world column, so nearest
##                       sampling inside a column returns the same height for all 256 block
##                       columns - the "half-column plateau" defect the reviewer measured.
##   field.height_exact  COLUMN tile, spacing 1: the exact analytic height of every one of the
##                       256 block columns in the current column. Surface passes read THIS.
##
## Both are computed from the same function of the same injected noise, so they can never
## disagree about a sample point; they differ only in resolution.
##
## LAYER: worldgen. Pure GDScript: no Voxel Tools types (X9), no rand*/Time (D5). The noise
## itself arrives as ctx.noise_2d, injected by the adapter from noise_sampler_recipe(), so
## this file never names a noise class either.

@export var noise_frequency: float = 0.0035
@export var noise_octaves: int = 5
@export var noise_lacunarity: float = 2.0
@export var noise_gain: float = 0.5
@export var height_base: float = 64.0
@export var height_amplitude: float = 42.0

const CHANNEL_HEIGHT := &"field.height"
const CHANNEL_HEIGHT_EXACT := &"field.height_exact"


func _init() -> void:
	id = &"planet.hills_v1"
	version = 1
	use_known_phase(Phase.PLANET)
	priority = 10
	provides = [CHANNEL_HEIGHT, CHANNEL_HEIGHT_EXACT]
	requires = []
	channel_declarations = {
		CHANNEL_HEIGHT: {"type": "TILE_FLOAT", "scope": "region", "version": 1},
		CHANNEL_HEIGHT_EXACT: {"type": "TILE_FLOAT", "scope": "column", "version": 1},
	}
	tile_spacing = 16
	tile_halo = 2


## What the injected sampler must be. Adapters read this (not our id, not our class) to build
## the one noise implementation every backend shares, so GDScript passes and graph nodes
## evaluate identical maths.
func noise_sampler_recipe() -> Dictionary:
	return {
		"type": "open_simplex_2",
		"fractal": "fbm",
		"octaves": noise_octaves,
		"lacunarity": noise_lacunarity,
		"gain": noise_gain,
		"frequency": noise_frequency,
	}


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


## Exact per-block-column heights for the column being generated (256 samples, spacing 1).
## This is the channel a surface pass consumes: no nearest-sampling, no plateaus.
func compute_column(ctx: GenContext) -> void:
	var o := ctx.column_origin
	var tile := FieldTile.make_float(16, 1.0, Vector2(float(o.x), float(o.z)), 0)
	for j in 16:
		for i in 16:
			var n: float = ctx.noise_2d.call(o.x + i, o.z + j)
			tile.set_f(i, j, height_from_noise(n))
	ctx.publish(CHANNEL_HEIGHT_EXACT, tile, id, GenBlackboard.Scope.COLUMN)
