class_name FieldCache
extends RefCounted
## src/spine/fields/field_cache.gd
##
## M01 / Task 6 - Bounded LRU cache of REGION field tiles.
##
## Key: (channel, region_coords, producer_version). The producer version in the key is what
## makes a module update invalidate its tiles automatically instead of silently serving the
## old field.
##
## Eviction is LRU by use counter. The EFFECT of eviction must be invisible: a miss simply
## recomputes, and because every provider is a pure function of (seed, region, params) the
## recomputed tile is bit-identical - X8 asserts exactly that.
##
## No disk cache yet (that is M02); `stats()` and the key format are already what a disk
## layer would need.
##
## LAYER: spine, pure GDScript.

var budget_bytes: int = 24 * 1024 * 1024

var _entries := {}                 # key String -> {"tile": FieldTile, "last_use": int}
var _clock := 0
var _hits := 0
var _misses := 0
var _evictions := 0
var _recomputes := 0


static func key(channel: StringName, region: Vector2i, producer_version: int) -> String:
	return "%s@%d,%d#v%d" % [String(channel), region.x, region.y, producer_version]


func configure_budget(bytes: int) -> void:
	budget_bytes = maxi(1024, bytes)
	_evict_until_fits()


func put(channel: StringName, region: Vector2i, producer_version: int, tile: FieldTile) -> void:
	var k := key(channel, region, producer_version)
	_clock += 1
	_entries[k] = {"tile": tile, "last_use": _clock}
	_evict_until_fits()


## NOT named get(): RefCounted inherits Object.get(StringName), and shadowing a native
## method is a warnings-as-errors compile failure in this project.
func get_tile(channel: StringName, region: Vector2i, producer_version: int) -> FieldTile:
	var k := key(channel, region, producer_version)
	if _entries.has(k):
		_hits += 1
		_clock += 1
		_entries[k]["last_use"] = _clock
		return _entries[k]["tile"]
	_misses += 1
	return null


func contains(channel: StringName, region: Vector2i, producer_version: int) -> bool:
	return _entries.has(key(channel, region, producer_version))


func erase(channel: StringName, region: Vector2i, producer_version: int) -> void:
	_entries.erase(key(channel, region, producer_version))


func clear() -> void:
	_entries.clear()


func used_bytes() -> int:
	var total := 0
	for k in _entries:
		total += (_entries[k]["tile"] as FieldTile).memory_bytes()
	return total


func entry_count() -> int:
	return _entries.size()


func note_recompute() -> void:
	_recomputes += 1


func stats() -> Dictionary:
	return {
		"entries": _entries.size(),
		"used_bytes": used_bytes(),
		"budget_bytes": budget_bytes,
		"hits": _hits,
		"misses": _misses,
		"evictions": _evictions,
		"recomputes": _recomputes,
	}


func _evict_until_fits() -> void:
	while used_bytes() > budget_bytes and not _entries.is_empty():
		var oldest_key := ""
		var oldest_use := 0x7FFFFFFFFFFFFFFF
		for k in _entries:
			var lu: int = _entries[k]["last_use"]
			if lu < oldest_use:
				oldest_use = lu
				oldest_key = String(k)
		_entries.erase(oldest_key)
		_evictions += 1
