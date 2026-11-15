class_name JsonData
extends RefCounted
## src/core/json_data.gd
##
## Tiny JSON reader/writer used by every data file in the project (blocks.json,
## world_config.json, golden_hashes.json). Kept in core so that tests, tools and runtime
## all load data the same way and report errors the same way.
##
## LAYER: core. No Voxel Tools references, no randomness, no time.


## Load and parse a res:// (or user://) JSON file. Returns {} and pushes an error on
## failure - callers must check for missing keys rather than trusting the result.
static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("JsonData: file not found: %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("JsonData: file is empty: %s" % path)
		return {}
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("JsonData: parse error in %s at line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return {}
	var data: Variant = json.data
	if data is Dictionary:
		return data
	push_error("JsonData: %s does not contain a JSON object at the top level" % path)
	return {}


## Load a JSON file whose top level is an array.
static func load_array(path: String) -> Array:
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("JsonData: parse error in %s: %s" % [path, json.get_error_message()])
		return []
	var data: Variant = json.data
	if data is Array:
		return data
	push_error("JsonData: %s does not contain a JSON array at the top level" % path)
	return []


static func save_file(path: String, data: Variant) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("JsonData: cannot write %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(data, "\t") + "\n")
	f.close()
	return true


## Typed getters with explicit defaults, so a missing or mistyped key in a data file can
## never silently become 0 or null deep inside generation code.
static func get_int(dict: Dictionary, key: String, fallback: int) -> int:
	if not dict.has(key):
		push_warning("JsonData: missing int key '%s', using %d" % [key, fallback])
		return fallback
	var v: Variant = dict[key]
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String and String(v).is_valid_int():
		return int(v)
	push_error("JsonData: key '%s' is not an int (got %s), using %d" % [key, typeof(v), fallback])
	return fallback


static func get_float(dict: Dictionary, key: String, fallback: float) -> float:
	if not dict.has(key):
		push_warning("JsonData: missing float key '%s', using %f" % [key, fallback])
		return fallback
	var v: Variant = dict[key]
	if v is float or v is int:
		return float(v)
	push_error("JsonData: key '%s' is not a number (got %s), using %f" % [key, typeof(v), fallback])
	return fallback


static func get_bool(dict: Dictionary, key: String, fallback: bool) -> bool:
	if not dict.has(key):
		push_warning("JsonData: missing bool key '%s', using %s" % [key, str(fallback)])
		return fallback
	var v: Variant = dict[key]
	if v is bool:
		return v
	push_error("JsonData: key '%s' is not a bool, using %s" % [key, str(fallback)])
	return fallback


static func get_string(dict: Dictionary, key: String, fallback: String) -> String:
	if not dict.has(key):
		push_warning("JsonData: missing string key '%s', using '%s'" % [key, fallback])
		return fallback
	var v: Variant = dict[key]
	if v is String:
		return v
	push_error("JsonData: key '%s' is not a string, using '%s'" % [key, fallback])
	return fallback


static func get_array(dict: Dictionary, key: String) -> Array:
	if not dict.has(key):
		push_warning("JsonData: missing array key '%s'" % key)
		return []
	var v: Variant = dict[key]
	if v is Array:
		return v
	push_error("JsonData: key '%s' is not an array" % key)
	return []


static func get_dict(dict: Dictionary, key: String) -> Dictionary:
	if not dict.has(key):
		push_warning("JsonData: missing object key '%s'" % key)
		return {}
	var v: Variant = dict[key]
	if v is Dictionary:
		return v
	push_error("JsonData: key '%s' is not an object" % key)
	return {}
