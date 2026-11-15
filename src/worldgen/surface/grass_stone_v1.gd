@tool
class_name GrassStoneV1
extends TerrainPass
## src/worldgen/surface/grass_stone_v1.gd
##
## M01 / Task 8 - The M00 surface rule as a TerrainPass: consumes field.height, writes
## air / grass / stone with the SAME comparisons the M00 graph encoded as two Select nodes:
##
##   depth = height - y
##   depth <  0            -> air
##   depth >= grass_depth  -> stone
##   otherwise             -> grass
##
## extent 0: each column decides from its own height only, which is exactly what the graph
## backend can compile. Neighbour-aware surface rules (cliffs, beaches) arrive in M02+ as
## new passes with extent > 0 on the multipass backend, without touching this file.
##
## LAYER: worldgen. Pure GDScript (X9 / D5 clean).

@export var grass_depth: int = 3
@export var air_id: int = 0
@export var grass_id: int = 1
@export var stone_id: int = 3

const CHANNEL_HEIGHT := &"field.height"


func _init() -> void:
	id = &"surface.grass_stone_v1"
	version = 1
	phase = Phase.SURFACE
	priority = 10
	extent = 0
	requires = [CHANNEL_HEIGHT]
	provides = []


func apply(ctx: GenContext) -> void:
	var tile: FieldTile = ctx.read(CHANNEL_HEIGHT) as FieldTile
	if tile == null:
		push_error("grass_stone_v1: field.height missing or not a tile at column %s" % str(ctx.column_origin))
		return
	var y_min: int = int(ctx.cfg("world_y_min", -64))
	var y_max: int = int(ctx.cfg("world_y_max", 320))
	var ox := ctx.column_origin.x
	var oz := ctx.column_origin.z
	var gd := float(grass_depth)

	for lx in 16:
		for lz in 16:
			var h: float = tile.sample_nearest(float(ox + lx), float(oz + lz))
			for wy in range(y_min, y_max):
				var depth := h - float(wy)
				var id := air_id
				if depth >= 0.0:
					id = stone_id if depth >= gd else grass_id
				ctx.writer.set_type(lx, wy, lz, id)
