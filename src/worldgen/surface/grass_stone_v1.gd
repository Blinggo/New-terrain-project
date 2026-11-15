@tool
class_name GrassStoneV1
extends TerrainPass
## src/worldgen/surface/grass_stone_v1.gd
##
## M01 / Task 8 - The M00 surface rule as a TerrainPass: consumes the EXACT height channel
## and writes air / grass / stone with the SAME comparisons the M00 graph encoded as two
## Select nodes:
##
##   depth = height - y
##   depth <  0            -> air
##   depth >= grass_depth  -> stone
##   otherwise             -> grass
##
## M01-fix / T3 (evidence E3): it reads `field.height_exact` (spacing 1, per block column),
## NOT the coarse region tile. Reading a spacing-16 tile with nearest sampling made every
## 16x16 block column share one height - visible as half-column plateaus and as 9/64 golden
## columns disagreeing with the compiled graph.
##
## M01-fix / T1: writes go through two `fill_span_world` calls per block column instead of
## one `set_type` per voxel (384 rows x 256 columns). On the native multipass backend a span
## is one engine box fill, which is what brings a GDScript column to the compiled graph's
## cost instead of 30x it (measured: tools/probe_native_cb5.gd, 3.4 ms -> 1.0 ms per column).
##
## Row algebra, derived from the graph's comparisons so the two agree on boundaries:
##   stone  <=> y <= h - grass_depth      -> highest stone row  = floor(h - grass_depth)
##   grass  <=> h - grass_depth < y <= h  -> highest grass row  = floor(h)
## Both inclusive; spans below are half-open [y0, y1).
##
## extent 0: each column decides from its own height only. Neighbour-aware surface rules
## (cliffs, beaches) arrive as new passes with extent > 0 on the multipass backends, without
## touching this file.
##
## LAYER: worldgen. Pure GDScript (X9 / D5 clean).

@export var grass_depth: int = 3
@export var air_id: int = 0
@export var grass_id: int = 1
@export var stone_id: int = 3

const CHANNEL_HEIGHT_EXACT := &"field.height_exact"


func _init() -> void:
	id = &"surface.grass_stone_v1"
	version = 1
	use_known_phase(Phase.SURFACE)
	priority = 10
	extent = 0
	requires = [CHANNEL_HEIGHT_EXACT]
	provides = []
	channel_declarations = {
		CHANNEL_HEIGHT_EXACT: {"type": "TILE_FLOAT", "scope": "column", "version": 1},
	}


func apply(ctx: GenContext) -> void:
	var tile: FieldTile = ctx.blackboard.read_typed(CHANNEL_HEIGHT_EXACT, "TILE_FLOAT", null) as FieldTile
	if tile == null:
		push_error("grass_stone_v1: %s missing or not a TILE_FLOAT at column %s (the exact-height provider did not run)" % [
			String(CHANNEL_HEIGHT_EXACT), str(ctx.column_origin)])
		return

	var bounds := ctx.writer.bounds_main()
	var bmin: Vector3i = bounds[0]
	var bmax: Vector3i = bounds[1]
	var y_min: int = maxi(int(ctx.cfg("world_y_min", -64)), bmin.y)
	var y_max: int = mini(int(ctx.cfg("world_y_max", 320)), bmax.y)
	if y_max <= y_min:
		return
	var gd := float(grass_depth)

	for wz in range(bmin.z, bmax.z):
		for wx in range(bmin.x, bmax.x):
			var h: float = tile.sample_nearest(float(wx), float(wz))
			var top := int(floorf(h))                # highest solid row, inclusive
			var stone_top := int(floorf(h - gd))     # highest stone row, inclusive
			var solid_to := mini(top + 1, y_max)      # half-open end of all solid rows
			if solid_to <= y_min:
				if air_id != 0:
					ctx.writer.fill_span_world(wx, wz, y_min, y_max, air_id)
				continue
			var stone_to := clampi(stone_top + 1, y_min, solid_to)
			if stone_to > y_min:
				ctx.writer.fill_span_world(wx, wz, y_min, stone_to, stone_id)
			if solid_to > stone_to:
				ctx.writer.fill_span_world(wx, wz, stone_to, solid_to, grass_id)
			# Air above `top` needs no write when air_id is the buffer's clear value (0);
			# any other air id is written explicitly so the rule stays correct.
			if air_id != 0 and y_max > solid_to:
				ctx.writer.fill_span_world(wx, wz, solid_to, y_max, air_id)
