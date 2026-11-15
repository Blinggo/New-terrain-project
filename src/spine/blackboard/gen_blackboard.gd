class_name GenBlackboard
extends RefCounted
## src/spine/blackboard/gen_blackboard.gd
##
## M01 / Task 2 - The blackboard: modules never call each other. They publish named, typed
## channels and read them back by name. This is the mechanism that makes "an idea nobody
## planned for" a two-file change: a producer publishes `field.ice_thickness`, a consumer
## requires it, and no central enum, registration list or existing file learns about it.
##
## Three scopes:
##   WORLD   one value per world (constants, derived globals). Lives as long as the board.
##   REGION  FieldTile grids per 1024x1024 block region. Survive across columns of the same
##           region; the executor flushes them into FieldCache after compute_region().
##   COLUMN  one value per 16x16 column. Cleared by begin_column().
##
## Failure modes, all loud:
##   * publish/read type mismatch  -> error naming BOTH type names (observed vs declared).
##   * read of a channel nobody published -> error naming the channel (the *load-time*
##     version of this, naming module + channel + pipeline, lives in PipelineScheduler).
##   * publishing the same channel from two producers with different observed types -> error.
##
## LAYER: spine. Pure GDScript (X9 lint: no Voxel*/ZN_* identifiers anywhere in this file).

enum Scope { WORLD, REGION, COLUMN }
const SCOPE_NAMES := ["world", "region", "column"]

## region size in blocks; matches PipelineRunner REGION_BLOCKS.
const REGION_BLOCKS := 1024

## channel StringName -> {"type": String, "scope": String, "version": int, "producer": StringName}
## Loaded from the resolved plan (M01-fix / T7): declarations are ENFORCED here, on every
## publish and every typed read, instead of being documentation nobody checks.
var _declarations := {}

var errors: Array[String] = []
## When false, failures are recorded in `errors` WITHOUT push_error(). Tests that exercise
## the failure modes on purpose set this so a green suite does not spray ERROR lines.
var loud := true

var _world := {}      # channel StringName -> entry Dictionary
var _region := {}
var _column := {}
var _region_origin := Vector2i(0, 0)
var _column_origin := Vector3i(0, 0, 0)
var _region_flushed := {}   # tiles handed to the executor/cache after compute_region


# --- scope lifecycle --------------------------------------------------------------------

## Install the plan's channel declarations. Idempotent; call once per resolved pipeline.
func apply_declarations(mods: Array) -> void:
	_declarations.clear()
	for m_variant in mods:
		var m := m_variant as ModuleDefinition
		if m == null:
			continue
		for ch_variant in m.channel_declarations:
			var ch := StringName(String(ch_variant))
			var meta: Dictionary = m.channel_declarations[ch_variant]
			var prev: Dictionary = _declarations.get(ch, {})
			var entry := {
				"type": String(meta.get("type", "")),
				"scope": String(meta.get("scope", "")),
				"version": int(meta.get("version", 1)),
				"producer": String(m.id) if ch in m.provides else String(prev.get("producer", "")),
			}
			if not prev.is_empty() and (prev["type"] != entry["type"] or prev["version"] != entry["version"]):
				var msg := ("blackboard: channel '%s' declared inconsistently (%s v%s by '%s' vs %s v%s)"
					% [String(ch), prev["type"], str(prev["version"]), str(prev.get("producer", "?")),
						entry["type"], str(entry["version"])])
				errors.append(msg)
				if loud:
					push_error(msg)
			_declarations[ch] = entry


func declaration_of(channel: StringName) -> Dictionary:
	return _declarations.get(channel, {})


func begin_region(origin: Vector2i) -> void:
	_region.clear()
	_region_flushed.clear()
	_region_origin = origin


func begin_column(origin: Vector3i) -> void:
	_column.clear()
	_column_origin = origin


func region_origin() -> Vector2i:
	return _region_origin


func column_origin() -> Vector3i:
	return _column_origin


# --- publish / read ---------------------------------------------------------------------

## scope < 0 = infer: FieldTile -> REGION, else COLUMN. WORLD is always explicit.
func publish(channel: StringName, value: Variant, producer_id: StringName, scope: int = -1) -> bool:
	var sc := scope
	if sc < 0:
		sc = Scope.REGION if value is FieldTile else Scope.COLUMN
	var type_name := _type_name(value)
	var target: Dictionary = _scope_dict(sc)
	if target.has(channel):
		var observed: String = target[channel]["type"]
		if observed != type_name:
			var msg := (
				"blackboard: channel '%s' published by '%s' as %s but already holds %s (published by '%s')"
				% [String(channel), String(producer_id), type_name, observed, String(target[channel]["producer"])])
			errors.append(msg)
			if loud:
				push_error(msg)
			return false
	# Declaration enforcement (T7): observed type and scope must match what the producer
	# declared. An undeclared channel stays legal - unknown channels are the whole point of
	# the blackboard - but a DECLARED one cannot drift.
	var decl: Dictionary = _declarations.get(channel, {})
	if not decl.is_empty():
		var want_type: String = decl["type"]
		if want_type != "" and want_type != type_name:
			var msg := (
				"blackboard: channel '%s' is declared %s but '%s' published %s (declared by producer '%s')"
				% [String(channel), want_type, String(producer_id), type_name, String(decl.get("producer", "?"))])
			errors.append(msg)
			if loud:
				push_error(msg)
			return false
		var want_scope: String = decl["scope"]
		if want_scope != "" and want_scope != SCOPE_NAMES[sc]:
			var msg := (
				"blackboard: channel '%s' is declared scope '%s' but '%s' published it in scope '%s'"
				% [String(channel), want_scope, String(producer_id), SCOPE_NAMES[sc]])
			errors.append(msg)
			if loud:
				push_error(msg)
			return false
	target[channel] = _entry(value, producer_id, sc)
	if sc == Scope.REGION and value is FieldTile:
		_region_flushed[channel] = value
	return true


func has(channel: StringName) -> bool:
	return _column.has(channel) or _region.has(channel) or _world.has(channel)


## Returns null and records an error when absent: a silent zero would hide a missing
## producer as "flat terrain", which is exactly the bug class this spine exists to prevent.
func read(channel: StringName) -> Variant:
	for d in [_column, _region, _world]:
		if d.has(channel):
			return d[channel]["value"]
	var msg := "blackboard: read of unpublished channel '%s' (no producer ran in scope column/region/world)" % String(channel)
	errors.append(msg)
	push_error(msg)
	return null


func try_read(channel: StringName, default: Variant) -> Variant:
	for d in [_column, _region, _world]:
		if d.has(channel):
			return d[channel]["value"]
	return default


## Strict read for modules that want the mismatch caught at the read site.
func read_typed(channel: StringName, expected_type: String, default: Variant) -> Variant:
	for d in [_column, _region, _world]:
		if d.has(channel):
			var observed: String = d[channel]["type"]
			if observed != expected_type:
				var msg := "blackboard: channel '%s' holds %s but reader declared %s" % [String(channel), observed, expected_type]
				errors.append(msg)
				if loud:
					push_error(msg)
				return default
			return d[channel]["value"]
	var msg := "blackboard: read_typed of unpublished channel '%s' (declared %s)" % [String(channel), expected_type]
	errors.append(msg)
	if loud:
		push_error(msg)
	return default


func scope_of(channel: StringName) -> int:
	if _column.has(channel):
		return Scope.COLUMN
	if _region.has(channel):
		return Scope.REGION
	if _world.has(channel):
		return Scope.WORLD
	return -1


## Tiles published during the current region compute; the executor caches them.
func take_region_tiles() -> Dictionary:
	return _region_flushed.duplicate()


func producer_of(channel: StringName) -> StringName:
	for d in [_column, _region, _world]:
		if d.has(channel):
			return d[channel]["producer"]
	return &""


# --- debug ------------------------------------------------------------------------------

func debug_dump() -> Array:
	var out := []
	for pair in [[_world, Scope.WORLD], [_region, Scope.REGION], [_column, Scope.COLUMN]]:
		var d: Dictionary = pair[0]
		var sc: int = pair[1]
		for ch in d:
			var e: Dictionary = d[ch]
			var row := {
				"channel": String(ch),
				"producer": String(e["producer"]),
				"type": e["type"],
				"scope": SCOPE_NAMES[sc],
			}
			if e["value"] is FieldTile:
				row["dims"] = (e["value"] as FieldTile).dimensions()
			out.append(row)
	out.sort_custom(func(a, b): return String(a["channel"]) < String(b["channel"]))
	return out


# --- internals --------------------------------------------------------------------------

func _scope_dict(sc: int) -> Dictionary:
	match sc:
		Scope.WORLD:
			return _world
		Scope.REGION:
			return _region
		_:
			return _column


func _entry(value: Variant, producer_id: StringName, sc: int) -> Dictionary:
	return {"value": value, "producer": producer_id, "type": _type_name(value), "scope": sc}


func _type_name(value: Variant) -> String:
	if value is FieldTile:
		var t: String = (value as FieldTile).type
		return "TILE_FLOAT" if t == "FLOAT" else "TILE_INT"
	return ChannelId.type_name_of(value)
