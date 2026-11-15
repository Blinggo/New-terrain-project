extends SceneTree
## tools/generate_placeholder_atlas.gd
##
## M00 / T3.1 - Generate the placeholder block texture atlas deterministically.
##
## We have no art assets yet, so we synthesise a readable, natural-looking 16x16-per-tile
## atlas. Every pixel comes from Hash64.hash_range(x, y, tile_index) - an FNV-1a derived
## integer hash. There is NO randf()/randi() anywhere in this file, so the PNG is
## byte-identical on every machine and every run (milestone hard rule #5).
##
## Layout: 4 x 4 tile grid = 64 x 64 px. 11 tiles are used, indices match
## res://content/blocks/blocks.json and the atlas_tiles list below. A power-of-two texture
## keeps mipmapping and mobile GPU sampling happy.
##
## Run:
##   godot --headless --path <project> --script res://tools/generate_placeholder_atlas.gd

const OUT_PATH := "res://content/textures/blocks_atlas.png"
const TILE_PX := 16
const GRID := 4
const IMG_PX := TILE_PX * GRID  # 64

## Tile index -> name. Order is the contract used by content/blocks/blocks.json.
const TILE_NAMES: Array[String] = [
	"grass_top",  # 0
	"grass_side", # 1
	"dirt",       # 2
	"stone",      # 3
	"sand",       # 4
	"gravel",     # 5
	"snow",       # 6
	"water",      # 7
	"log_side",   # 8
	"log_top",    # 9
	"leaves",     # 10
]

## Base colours: desaturated and natural, deliberately not neon. sRGB 0..255.
const BASE_COLORS := {
	"grass_top": [104, 148, 62, 255],
	"grass_side": [134, 96, 67, 255],
	"dirt": [134, 96, 67, 255],
	"stone": [126, 126, 129, 255],
	"sand": [214, 203, 160, 255],
	"gravel": [128, 124, 121, 255],
	"snow": [238, 244, 248, 255],
	"water": [54, 108, 176, 158],
	"log_side": [102, 78, 47, 255],
	"log_top": [158, 126, 80, 255],
	"leaves": [62, 112, 46, 255],
}


func _init() -> void:
	var img := Image.create(IMG_PX, IMG_PX, false, Image.FORMAT_RGBA8)
	if img == null:
		push_error("generate_placeholder_atlas: Image.create failed")
		quit(1)
		return

	for tile in TILE_NAMES.size():
		_paint_tile(img, tile, TILE_NAMES[tile])

	var err := img.save_png(ProjectSettings.globalize_path(OUT_PATH))
	if err != OK:
		push_error("generate_placeholder_atlas: save_png failed (%d)" % err)
		quit(1)
		return

	print("generate_placeholder_atlas: wrote %s (%dx%d, %d tiles)" % [OUT_PATH, IMG_PX, IMG_PX, TILE_NAMES.size()])
	for i in TILE_NAMES.size():
		var t := TILE_NAMES[i]
		print("   tile %2d = %-11s at (%d,%d) base rgb(%d,%d,%d) a=%d" % [
			i, t, (i % GRID) * TILE_PX, (i / GRID) * TILE_PX,
			BASE_COLORS[t][0], BASE_COLORS[t][1], BASE_COLORS[t][2], BASE_COLORS[t][3],
		])
	quit(0)


func _paint_tile(img: Image, tile: int, tile_name: String) -> void:
	var base: Array = BASE_COLORS[tile_name]
	var ox := (tile % GRID) * TILE_PX
	var oy := (tile / GRID) * TILE_PX

	for ly in TILE_PX:
		for lx in TILE_PX:
			var c := _pixel(tile, tile_name, lx, ly, base)
			img.set_pixel(ox + lx, oy + ly, Color8(c[0], c[1], c[2], c[3]))


## Per-pixel colour. All variation is integer-hashed from (x, y, tile).
func _pixel(tile: int, tile_name: String, x: int, y: int, base: Array) -> Array:
	var r := int(base[0])
	var g := int(base[1])
	var b := int(base[2])
	var a := int(base[3])

	# Two hashed jitter layers: fine per-pixel grain (+/-6) and a coarser 4x4 blotch
	# (+/-9) so the tiles read as texture rather than noise when seen from a distance.
	var grain := Hash64.hash_range(x, y, tile, 1) % 13 - 6
	var blotch := Hash64.hash_range(x >> 2, y >> 2, tile, 2) % 19 - 9
	var d := grain + blotch
	r = _clamp8(r + d)
	g = _clamp8(g + d)
	b = _clamp8(b + int(d * 0.7))

	match tile_name:
		"grass_side":
			# Top 4 rows are grass, with a ragged 1px boundary; the rest is dirt.
			var edge := 4 + (Hash64.hash_range(x, 0, tile, 3) % 2)
			if y < edge:
				var gb: Array = BASE_COLORS["grass_top"]
				r = _clamp8(int(gb[0]) + d)
				g = _clamp8(int(gb[1]) + d)
				b = _clamp8(int(gb[2]) + int(d * 0.7))
		"stone":
			# Sparse darker speckles so strata/faces stay readable at distance (M02+).
			if Hash64.hash_range(x, y, tile, 4) % 11 == 0:
				r = _clamp8(r - 26)
				g = _clamp8(g - 26)
				b = _clamp8(b - 24)
		"gravel":
			if Hash64.hash_range(x, y, tile, 5) % 5 == 0:
				var e := 22
				r = _clamp8(r + e)
				g = _clamp8(g + e)
				b = _clamp8(b + e)
		"water":
			# Horizontal banding + slightly variable alpha, reads as a liquid surface.
			var band := (Hash64.hash_range(y, 0, tile, 6) % 9) - 4
			r = _clamp8(r + band)
			g = _clamp8(g + band)
			b = _clamp8(b + band * 2)
			a = 150 + (Hash64.hash_range(x, y, tile, 7) % 17)
		"log_side":
			# Vertical bark streaks: variation depends on x only, not y.
			var streak := (Hash64.hash_range(x, 0, tile, 8) % 34) - 17
			r = _clamp8(r + streak)
			g = _clamp8(g + int(streak * 0.8))
			b = _clamp8(b + int(streak * 0.6))
		"log_top":
			# Concentric growth rings around the tile centre.
			var dx := x - 7
			var dy := y - 7
			var dist := int(sqrt(float(dx * dx + dy * dy)))
			var ring := (dist % 4) * 7 - 10
			r = _clamp8(r + ring)
			g = _clamp8(g + ring)
			b = _clamp8(b + ring)
		"leaves":
			# Leaf clumps; a few near-black pixels give the canopy depth without needing
			# alpha-test cutout (transparent foliage is deferred to the art lock).
			if Hash64.hash_range(x >> 1, y >> 1, tile, 9) % 7 == 0:
				r = _clamp8(r - 30)
				g = _clamp8(g - 24)
				b = _clamp8(b - 26)
		"snow":
			# Very low contrast: snow should read as a flat bright cap.
			r = _clamp8(int(base[0]) + int(d * 0.25))
			g = _clamp8(int(base[1]) + int(d * 0.25))
			b = _clamp8(int(base[2]) + int(d * 0.25))

	return [r, g, b, a]


func _clamp8(v: int) -> int:
	if v < 0:
		return 0
	if v > 255:
		return 255
	return v
