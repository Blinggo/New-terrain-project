class_name LayerLint
extends RefCounted
## src/core/layer_lint.gd
##
## M01 / hard rule #2, mechanised (B10, X9): the layering rules are checked by code on every
## test run, not by review.
##
##   1. Banned non-determinism: `randf(`, `randi(`, `randomize(` as UNQUALIFIED calls and any
##      `Time.get_` in core/spine/worldgen/adapters. Instance calls on an injected RNG
##      (`rng.randf()`) are legal - that IS the RngStreams API - so the pattern rejects a
##      bare call only (start of line or after a non-`.` character).
##   2. Layering: no `Voxel` / `ZN_` identifier anywhere in core/, spine/, worldgen/.
##      Only src/adapters/ may name Voxel Tools classes (ADR-0002).
##
## Comments are stripped before matching so prose like "never call randf()" in a header
## cannot fail the build, while code still can.

const BANNED_CALLS: Array[String] = ["randf(", "randi(", "randomize(", "Time.get_"]
const BANNED_IDENTIFIERS: Array[String] = ["Voxel", "ZN_"]

## The lint implementation itself contains the banned tokens as DATA (its constant tables),
## so it must not scan its own file - the one deliberate self-exclusion.
const SELF_PATH := "res://src/core/layer_lint.gd"

## Directories scanned for banned calls (generation-facing code).
const GEN_DIRS: Array[String] = ["res://src/core", "res://src/spine", "res://src/worldgen", "res://src/adapters"]
## Directories that must never name a Voxel Tools class.
const PURE_DIRS: Array[String] = ["res://src/core", "res://src/spine", "res://src/worldgen"]


## Returns one string per hit: "path:line: what".
static func banned_call_hits(dirs: Array = GEN_DIRS) -> Array:
	var hits := []
	for path in _list_gd(dirs):
		var lines := _code_lines(path)
		for i in lines.size():
			var line: String = lines[i]
			for banned in BANNED_CALLS:
				if _contains_unqualified(line, String(banned)):
					hits.append("%s:%d: banned call %s" % [path, i + 1, banned])
	return hits


static func identifier_hits(dirs: Array = PURE_DIRS) -> Array:
	var hits := []
	for path in _list_gd(dirs):
		var lines := _code_lines(path)
		for i in lines.size():
			var line: String = lines[i]
			for banned in BANNED_IDENTIFIERS:
				if line.find(String(banned)) >= 0:
					hits.append("%s:%d: layering violation, identifier '%s'" % [path, i + 1, banned])
	return hits


## True when `needle` occurs in `line` as a bare call, i.e. not preceded by '.' or an
## identifier character (so `rng.randf()` passes but `randf()` fails).
static func _contains_unqualified(line: String, needle: String) -> bool:
	var idx := line.find(needle)
	while idx >= 0:
		var before := "" if idx == 0 else line[idx - 1]
		var is_member := before == "."
		var is_ident := (before >= "a" and before <= "z") or (before >= "A" and before <= "Z") or (before >= "0" and before <= "9") or before == "_"
		if not is_member and not is_ident:
			return true
		idx = line.find(needle, idx + 1)
	return false


## File content without comments, so documentation prose cannot trip the lint.
static func _code_lines(path: String) -> Array:
	var out: Array[String] = []
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := String(raw)
		var stripped := line.strip_edges()
		if stripped.begins_with("#"):
			continue
		var hash := line.find("#")
		if hash > 0:
			# keep string literals safe enough: only cut when # starts a comment token
			if hash + 1 < line.length() and line[hash + 1] == " ":
				line = line.substr(0, hash)
			elif hash + 1 >= line.length():
				line = line.substr(0, hash)
		out.append(line)
	return out


static func _list_gd(dirs: Array) -> Array:
	var out := []
	for root in dirs:
		out.append_array(_list_dir(String(root)))
	out = out.filter(func(p): return String(p) != SELF_PATH)
	out.sort()
	return out


static func _list_dir(root: String) -> Array:
	var out := []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir():
			out.append_array(_list_dir(root + "/" + n))
		elif n.ends_with(".gd"):
			out.append(root + "/" + n)
		n = dir.get_next()
	dir.list_dir_end()
	return out
