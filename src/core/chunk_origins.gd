class_name ChunkOrigins
extends RefCounted
## src/core/chunk_origins.gd
##
## The FIXED list of 64 chunk origins used by the determinism harness (T8) and by
## tools/make_golden_hashes.gd. Both must agree byte-for-byte, so the list lives here in
## core and is derived deterministically - never from randi(), never from Dictionary
## iteration order, never from anything machine-specific.
##
## COVERAGE (T8 requires origin, negatives, and coordinates beyond +/- 1 000 000):
##   indices  0.. 7  SPECIAL      hand-written extremes: the origin itself, single-block
##                                 offsets, both ends of the world column, and coordinates
##                                 beyond +/-1 000 000 on X and Z.
##   indices  8..31  SURFACE BAND 24 origins inside the band where terrain actually varies.
##                                 This matters: in a 384-block-tall world the M00 terrain
##                                 only occupies roughly y=43..85, so a purely random origin
##                                 list is dominated by all-air or all-solid chunks. Those
##                                 hash identically for ANY seed, which made the original
##                                 D4 check change only 3 of 64 hashes - technically
##                                 passing, but nearly worthless as evidence. A third of the
##                                 list is therefore pinned to the surface band.
##   indices 32..63  WIDE RANGE   32 origins spread over +/-8 million blocks and over every
##                                 block row of the column, to catch coordinate cliffs,
##                                 float precision loss and y-dependent bugs.
##
## LAYER: core. Uses Hash64 only - no Voxel Tools, no time, no randomness API.

const COUNT := 64
const BLOCK := 16
const WORLD_Y_MIN := -64
const WORLD_Y_MAX_EXCLUSIVE := 320
const SPECIAL_COUNT := 8
const SURFACE_COUNT := 24
const WIDE_COUNT := 32

## Hand-written cases first so they are obvious in the report table. All values are exact
## multiples of BLOCK so they are valid data-block origins.
const SPECIAL: Array = [
	Vector3i(0, 0, 0),
	Vector3i(16, 0, 0),
	Vector3i(-16, 0, 0),
	Vector3i(0, -64, 0),
	Vector3i(0, 304, 0),
	Vector3i(1000000, 64, -1000000),
	Vector3i(-1000016, -64, 1000016),
	Vector3i(32752, 112, -49168),
]

## Index of the first surface-band origin. Tests use this to pick a chunk that actually
## contains varying terrain (see D3b in tests/determinism/test_determinism.gd).
const FIRST_SURFACE_INDEX := SPECIAL_COUNT


## Returns exactly COUNT Vector3i origins, in a stable order.
## `surface_y` is the height the terrain surface is expected to hover around (M00 default:
## sea level 64). Core does not read config, so the caller passes it in.
static func get_origins(surface_y: int = 64) -> Array:
	var out: Array = []
	for i in COUNT:
		if i < SPECIAL_COUNT:
			out.append(SPECIAL[i])
		elif i < SPECIAL_COUNT + SURFACE_COUNT:
			out.append(_surface_band(i, surface_y))
		else:
			out.append(_wide_range(i))
	assert(out.size() == COUNT, "ChunkOrigins must always return %d origins" % COUNT)
	return out


## Origins inside the terrain band: 5 block rows centred on surface_y, spread over a wide
## but reachable X/Z area so a human can also visit them with F6.
static func _surface_band(i: int, surface_y: int) -> Vector3i:
	var h := Hash64.hash_int(i * 7919 + 13)
	var centre_row := int(floorf(float(surface_y) / float(BLOCK)))
	var row := centre_row - 2 + (i % 5)
	row = clampi(row, WORLD_Y_MIN / BLOCK, (WORLD_Y_MAX_EXCLUSIVE / BLOCK) - 1)
	var x := _snap(_mod(int(Hash64.hash_combine(h, 11)), 200001) - 100000)
	var z := _snap(_mod(int(Hash64.hash_combine(h, 12)), 200001) - 100000)
	return Vector3i(x, row * BLOCK, z)


## Origins spread across the whole coordinate range and the whole world column.
static func _wide_range(i: int) -> Vector3i:
	var h := Hash64.hash_int(i * 104729 + 7)
	var x := _snap(_mod(int(Hash64.hash_combine(h, 1)), 16_000_001) - 8_000_000)
	var z := _snap(_mod(int(Hash64.hash_combine(h, 2)), 16_000_001) - 8_000_000)
	var rows := (WORLD_Y_MAX_EXCLUSIVE - WORLD_Y_MIN) / BLOCK  # 24
	var y := WORLD_Y_MIN + _mod(int(Hash64.hash_combine(h, 3)), rows) * BLOCK
	return Vector3i(x, y, z)


static func _mod(a: int, m: int) -> int:
	var r := a % m
	if r < 0:
		r += m
	return r


static func _snap(v: int) -> int:
	return int(floorf(float(v) / float(BLOCK))) * BLOCK


## Human-readable one-line form used in reports and logs. Written by hand (not str()) so
## the golden file format can never drift with an engine change to Variant formatting.
static func origin_to_key(o: Vector3i) -> String:
	return "%d,%d,%d" % [o.x, o.y, o.z]


## Composition summary, printed into the M00 report so the origin set is auditable.
static func describe(surface_y: int = 64) -> String:
	var o := get_origins(surface_y)
	var surface := 0
	var far := 0
	var negative := 0
	for v in o:
		var origin: Vector3i = v
		if absi(origin.x) > 1_000_000 or absi(origin.z) > 1_000_000:
			far += 1
		if origin.x < 0 or origin.y < 0 or origin.z < 0:
			negative += 1
	return "%d origins = %d special + %d surface-band + %d wide-range; %d with a negative coord, %d beyond +/-1e6" % [
		o.size(), SPECIAL_COUNT, SURFACE_COUNT, WIDE_COUNT, negative, far,
	]


## M01-fix / T3 (evidence E3) - `count` EXTRA origins inside the surface band, deterministic
## and independent of get_origins().
##
## Why a second set exists: of the 64 committed origins only 24 lie in the band where the
## surface actually varies (the rest are all-air or all-solid and hash identically for any
## height rule). Proving "the surface pass uses the exact per-block height, not a
## nearest-sampled spacing-16 tile" needs a sample big enough that a plateau defect cannot
## hide: at spacing 16 a wrong-nearest-sample error shows up in roughly half of the columns
## that straddle a sample boundary, so 256 band origins make a silent regression
## statistically impossible (the M01 defect was visible in 9 of 64).
##
## Deterministic by construction: Hash64 over (index, salt), no randi(), no Dictionary
## iteration, no machine-specific input. Both the harness and the second process derive the
## same list, which D2's cross-process comparison depends on.
static func get_surface_band_origins(count: int, surface_y: int = 64, salt: int = 977) -> Array:
	var out: Array = []
	var centre_row := int(floorf(float(surface_y) / float(BLOCK)))
	for i in maxi(0, count):
		var h := Hash64.hash_int(i * 15485863 + salt)
		var row := centre_row - 2 + _mod(int(Hash64.hash_combine(h, 5)), 5)
		row = clampi(row, WORLD_Y_MIN / BLOCK, (WORLD_Y_MAX_EXCLUSIVE / BLOCK) - 1)
		var x := _snap(_mod(int(Hash64.hash_combine(h, 11)), 400001) - 200000)
		var z := _snap(_mod(int(Hash64.hash_combine(h, 12)), 400001) - 200000)
		out.append(Vector3i(x, row * BLOCK, z))
	return out


## The comparison set for "a modular backend must reproduce the legacy compiled graph":
## the 64 committed origins plus `extra_band` surface-band origins.
static func get_graph_parity_origins(surface_y: int = 64, extra_band: int = 256) -> Array:
	var out := get_origins(surface_y)
	out.append_array(get_surface_band_origins(extra_band, surface_y))
	return out
