class_name FieldCache
extends RefCounted
## src/spine/fields/field_cache.gd
##
## M01 / Task 6 - Bounded LRU cache of REGION field tiles.
##
## KEY (M01-fix / T5). A cached tile is a pure function of EVERYTHING that can change it,
## so the key carries all of it, not just the channel:
##
##   channel | region | producer_id | producer_version | params_fingerprint | tile_spacing
##           | tile_halo | world_fingerprint(seed, worldgen_version, quality_tier, ...)
##
## The M01 key was `channel@region#version`. That is wrong in four separate ways, each of
## which serves a stale tile silently: a different world SEED, a different producer id for
## the same channel name, different module PARAMETERS (an override via content/world_config.json
## or a modded .tres), and a different tile geometry (spacing/halo) all produced the SAME key.
## Every one of those is a tile-changing input, so every one is in the key now.
##
## THREAD SAFETY (M01-fix / T4). Generation runs on engine worker threads, so the cache has
## its own Mutex and every public entry point takes it. The lock is held around the table
# operation only - never around compute_region(), which happens in the caller.
##
## Eviction is LRU by use counter. The EFFECT of eviction must be invisible: a miss simply
## recomputes, and because every provider is a pure function of (seed, region, params) the
## recomputed tile is bit-identical - X8 asserts exactly that.
##
## No disk cache yet (that is M02); `stats()` and the key format are already what a disk
## layer would need.
##
## LAYER: spine, pure GDScript (Mutex is engine-generic; no Voxel Tools types - X9 lint).

var budget_bytes: int = 24 * 1024 * 1024
## Fingerprint of the world-level inputs (seed, worldgen_version, quality tier, ...).
## Set by configure_world(); every key includes it.
var world_fingerprint: int = 0

var _entries := {}                 # key String -> {"tile": FieldTile, "last_use": int}
var _clock := 0
var _hits := 0
var _misses := 0
var _evictions := 0
var _recomputes := 0
var _mutex := Mutex.new()


## World-level part of every key. `extra` lets a backend add anything else that changes
## tile content (e.g. a config knob a module reads), so the key can never be narrower than
## the inputs.
static func make_world_fingerprint(world_seed: int, worldgen_version: int, quality_tier: String, extra: Dictionary = {}) -> int:
	var h := Hash64.hash_string("world_fp:v1")
	h = Hash64.hash_combine(h, Hash64.hash_int(world_seed))
	h = Hash64.hash_combine(h, Hash64.hash_int(worldgen_version))
	h = Hash64.hash_combine(h, Hash64.hash_string(quality_tier))
	h = Hash64.hash_combine(h, Hash64.hash_variant(extra))
	return h


func configure_world(world_seed: int, worldgen_version: int, quality_tier: String, extra: Dictionary = {}) -> void:
	var fp := make_world_fingerprint(world_seed, worldgen_version, quality_tier, extra)
	if fp != world_fingerprint:
		# A different world cannot inherit another world's tiles. Clearing is the fail-safe
		# direction: a miss recomputes, a false hit would be invisible corruption.
		clear()
	world_fingerprint = fp


func configure_budget(bytes: int) -> void:
	_mutex.lock()
	budget_bytes = maxi(1024, bytes)
	_evict_until_fits_locked()
	_mutex.unlock()


## The full key. Written by hand (not str() of a Dictionary) so the format cannot drift with
## an engine change to Variant formatting.
static func key_for(channel: StringName, region: Vector2i, producer_id: StringName,
		producer_version: int, params_fp: int, spacing: float, halo: int, world_fp: int) -> String:
	return "%s@%d,%d#%s:v%d:p%s:s%s:h%d:w%s" % [
		String(channel), region.x, region.y, String(producer_id), producer_version,
		Hash64.to_hex(params_fp), str(spacing), halo, Hash64.to_hex(world_fp)]


## Key for one region tile of `provider` (geometry + fingerprint read from the module itself,
## so a modded .tres cannot end up sharing a key with the shipped one).
static func key_of(channel: StringName, region: Vector2i, provider: FieldProvider, world_fp: int) -> String:
	return key_for(channel, region, provider.id, provider.version, provider.params_fingerprint(),
		float(provider.tile_spacing), provider.tile_halo, world_fp)


func put(channel: StringName, region: Vector2i, provider: FieldProvider, tile: FieldTile) -> void:
	_mutex.lock()
	var k := key_of(channel, region, provider, world_fingerprint)
	_clock += 1
	_entries[k] = {"tile": tile, "last_use": _clock}
	_evict_until_fits_locked()
	_mutex.unlock()


## NOT named get(): RefCounted inherits Object.get(StringName), and shadowing a native
## method is a warnings-as-errors compile failure in this project.
func get_tile(channel: StringName, region: Vector2i, provider: FieldProvider) -> FieldTile:
	_mutex.lock()
	var k := key_of(channel, region, provider, world_fingerprint)
	if _entries.has(k):
		_hits += 1
		_clock += 1
		_entries[k]["last_use"] = _clock
		var tile: FieldTile = _entries[k]["tile"]
		_mutex.unlock()
		return tile
	_misses += 1
	_mutex.unlock()
	return null


func contains(channel: StringName, region: Vector2i, provider: FieldProvider) -> bool:
	_mutex.lock()
	var has := _entries.has(key_of(channel, region, provider, world_fingerprint))
	_mutex.unlock()
	return has


func erase(channel: StringName, region: Vector2i, provider: FieldProvider) -> void:
	_mutex.lock()
	_entries.erase(key_of(channel, region, provider, world_fingerprint))
	_mutex.unlock()


func clear() -> void:
	_mutex.lock()
	_entries.clear()
	_mutex.unlock()


func used_bytes() -> int:
	_mutex.lock()
	var total := _used_bytes_locked()
	_mutex.unlock()
	return total


func entry_count() -> int:
	_mutex.lock()
	var n := _entries.size()
	_mutex.unlock()
	return n


func note_recompute() -> void:
	_mutex.lock()
	_recomputes += 1
	_mutex.unlock()


func stats() -> Dictionary:
	_mutex.lock()
	var out := {
		"entries": _entries.size(),
		"used_bytes": _used_bytes_locked(),
		"budget_bytes": budget_bytes,
		"hits": _hits,
		"misses": _misses,
		"evictions": _evictions,
		"recomputes": _recomputes,
		"world_fingerprint": Hash64.to_hex(world_fingerprint),
	}
	_mutex.unlock()
	return out


## Every live key, sorted: used by the T5 test to prove which inputs actually change a key.
func debug_keys() -> Array:
	_mutex.lock()
	var out: Array = _entries.keys()
	_mutex.unlock()
	out.sort()
	return out


func _used_bytes_locked() -> int:
	var total := 0
	for k in _entries:
		total += (_entries[k]["tile"] as FieldTile).memory_bytes()
	return total


func _evict_until_fits_locked() -> void:
	while _used_bytes_locked() > budget_bytes and not _entries.is_empty():
		var oldest_key := ""
		var oldest_use := 0x7FFFFFFFFFFFFFFF
		for k in _entries:
			var lu: int = _entries[k]["last_use"]
			if lu < oldest_use:
				oldest_use = lu
				oldest_key = String(k)
		_entries.erase(oldest_key)
		_evictions += 1
