class_name ChannelId
extends RefCounted
## src/core/channel_id.gd
##
## M01 / Task 1 - Namespaced identity for blackboard channels: "domain.name", plus a
## declared payload type and a producer-owned version.
##
## There is deliberately NO central enum of channels (Task 2: unknown channels are legal).
## What this class fixes is the *shape* of a name and the vocabulary of payload types, so
## that a typo fails at parse time with a helpful message instead of silently creating a
## second channel nobody reads.
##
## LAYER: core, pure.

const TYPES: Array[String] = ["FLOAT", "INT", "VEC2", "VEC4", "BYTES", "TILE_FLOAT", "TILE_INT"]

## Scalar types a module may declare for non-tile channels.
const SCALAR_TYPES: Array[String] = ["FLOAT", "INT", "VEC2", "VEC4", "BYTES"]


static func full_name(domain: String, name: String) -> String:
	return "%s.%s" % [domain, name]


## Parse "domain.name". Returns {"ok": bool, "error": String, "domain": String, "name": String}.
static func parse(full: String) -> Dictionary:
	var out := {"ok": false, "error": "", "domain": "", "name": ""}
	var parts := full.split(".")
	if parts.size() != 2:
		out["error"] = (
			"channel '%s' must be exactly 'domain.name' (one dot); got %d dot-separated part%s"
			% [full, parts.size(), "" if parts.size() == 1 else "s"])
		return out
	var d := parts[0]
	var n := parts[1]
	var problems := _name_problems(d, "domain")
	problems.append_array(_name_problems(n, "name"))
	if not problems.is_empty():
		out["error"] = "channel '%s': %s" % [full, "; ".join(problems)]
		return out
	out["ok"] = true
	out["domain"] = d
	out["name"] = n
	return out


static func is_valid_type(type_name: String) -> bool:
	return type_name in TYPES


## Validate a declared channel (as written in a module's provides/requires metadata).
## Returns a list of problems (empty = valid), each actionable.
static func validate(full: String, type_name: String, version: int) -> Array[String]:
	var problems: Array[String] = []
	var parsed := parse(full)
	if not parsed["ok"]:
		problems.append(String(parsed["error"]))
	if not is_valid_type(type_name):
		problems.append("type '%s' is not one of %s" % [type_name, str(TYPES)])
	if version < 1:
		problems.append("version %d must be >= 1 (consumers match on it when a producer changes semantics)" % version)
	return problems


## The runtime type name the blackboard observes for a value; used in mismatch errors so
## both sides of a type conflict are named.
## NOTE: tiles are named by the spine blackboard (TILE_FLOAT / TILE_INT), not here: core
## must not depend on spine types (layering, ADR-0002).
static func type_name_of(value: Variant) -> String:
	if value is float:
		return "FLOAT"
	if value is int:
		return "INT"
	if value is Vector2:
		return "VEC2"
	if value is Vector4:
		return "VEC4"
	if value is PackedByteArray:
		return "BYTES"
	return "OTHER(%s)" % str(typeof(value))


static func _name_problems(part: String, what: String) -> Array[String]:
	var problems: Array[String] = []
	if part.is_empty():
		problems.append("%s is empty" % what)
		return problems
	if part != part.to_lower():
		problems.append("%s '%s' must be lowercase" % [what, part])
	for c in part:
		var ok_c := (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"
		if not ok_c:
			problems.append("%s '%s' contains illegal character '%s' (allowed: a-z 0-9 _)" % [what, part, c])
			break
	if part[0] >= "0" and part[0] <= "9":
		problems.append("%s '%s' must not start with a digit" % [what, part])
	return problems
