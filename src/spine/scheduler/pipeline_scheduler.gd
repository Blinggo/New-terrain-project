class_name PipelineScheduler
extends RefCounted
## src/spine/scheduler/pipeline_scheduler.gd
##
## M01-fix - Resolves the module pipeline from declared requires/provides ONLY.
##
## Rules:
##   * Bands run in ascending `phase_order` (a plain int: a module with an unplanned stage
##     picks a new number+name without editing the contract file, C16).
##   * WITHIN a band, topological order over requires/provides edges whose producer is in
##     the same band. Cross-band edges are satisfied by band order; a dependency on a LATER
##     band is a resolve error.
##   * Tiebreak: priority ascending, then id lexicographic. The ready set is re-sorted from
##     a plain Array at every step, so the result cannot depend on Dictionary iteration
##     order (X4).
##   * Channel declarations validated with ChannelId: name shape, known type, version >= 1;
##     consumer declaration must match producer declaration type+scope (C15).
##   * Cycle -> error printing the actual path "a -> b -> c -> a" (X5).
##   * Missing producer for a requires -> error naming consumer, channel, pipeline (X6).
##   * Two producers of one channel -> error naming both (X7-family).
##   * Extents: each TerrainPass's extent feeds the TOTAL COLUMN MULTIPLICATION FACTOR,
##     sum over passes of (1 + 2*extent)^2, so neighbour awareness is a budgeted decision.
##
## LAYER: spine, pure.

var order: Array = []                 # resolved ModuleDefinition, execution order
var errors: Array[String] = []
var _dump: Array = []
var _pass_factors: Dictionary = {}    # module id -> (1+2*extent)^2
var _column_factor: int = 0


func resolve(mods: Array) -> bool:
	order.clear()
	errors.clear()
	_dump.clear()
	_pass_factors.clear()
	_column_factor = 0

	_check_declarations(mods)
	var providers := _build_provider_map(mods)
	_check_requires(mods, providers)
	if not errors.is_empty():
		return false

	var bands := _band_orders(mods)
	for band in bands:
		var band_mods := _mods_in_band(mods, band)
		if band_mods.is_empty():
			continue
		var sorted := _topo_within_band(band_mods, providers, band)
		if sorted.is_empty():
			return false   # cycle error already recorded
		order.append_array(sorted)

	_build_dump()
	return errors.is_empty()


func pipeline_dump() -> Array:
	return _dump


func pass_factors() -> Dictionary:
	return _pass_factors


## Sum over TerrainPass modules of (1+2*extent)^2: column-touches per output column.
func column_factor() -> int:
	return _column_factor


# --- declarations ------------------------------------------------------------------------

func _check_declarations(mods: Array) -> void:
	for m in mods:
		var def := m as ModuleDefinition
		for ch_variant in def.channel_declarations:
			var ch := StringName(String(ch_variant))
			var meta: Dictionary = def.channel_declarations[ch_variant]
			var type_name := String(meta.get("type", ""))
			var version := int(meta.get("version", 1))
			for problem in ChannelId.validate(String(ch), type_name, version):
				errors.append("scheduler: module '%s' declares channel '%s' badly: %s" % [
					String(def.id), String(ch), problem])
			var scope := String(meta.get("scope", ""))
			if not (scope in ["world", "region", "column"]):
				errors.append("scheduler: module '%s' declares channel '%s' with scope '%s' (must be world|region|column)" % [
					String(def.id), String(ch), scope])
		# every requires/provides entry must be declared by this module
		for ch in def.provides:
			if not def.channel_declarations.has(ch):
				errors.append("scheduler: module '%s' provides '%s' without a channel declaration {type, scope, version}" % [
					String(def.id), String(ch)])
		for ch in def.requires:
			if not def.channel_declarations.has(ch):
				errors.append("scheduler: module '%s' requires '%s' without a channel declaration {type, scope, version}" % [
					String(def.id), String(ch)])


func _check_types_against_producer(mods: Array, providers: Dictionary) -> void:
	for m in mods:
		var def := m as ModuleDefinition
		for ch in def.requires:
			var producer: ModuleDefinition = providers.get(ch)
			if producer == null:
				continue
			var pm: Dictionary = producer.channel_declarations.get(ch, {})
			var cm: Dictionary = def.channel_declarations.get(ch, {})
			if String(pm.get("type", "")) != String(cm.get("type", "")):
				errors.append("scheduler: channel '%s' type mismatch: producer '%s' declares %s, consumer '%s' declares %s" % [
					String(ch), String(producer.id), String(pm.get("type", "?")), String(def.id), String(cm.get("type", "?"))])
			if String(pm.get("scope", "")) != String(cm.get("scope", "")):
				errors.append("scheduler: channel '%s' scope mismatch: producer '%s' declares %s, consumer '%s' declares %s" % [
					String(ch), String(producer.id), String(pm.get("scope", "?")), String(def.id), String(cm.get("scope", "?"))])
			if int(pm.get("version", 1)) != int(cm.get("version", 1)):
				errors.append("scheduler: channel '%s' version mismatch: producer '%s' v%s, consumer '%s' expects v%s (bump the consumer or the producer, deliberately)" % [
					String(ch), String(producer.id), str(pm.get("version", 1)), String(def.id), str(cm.get("version", 1))])


# --- graph --------------------------------------------------------------------------------

func _build_provider_map(mods: Array) -> Dictionary:
	var providers := {}
	for m in mods:
		var def := m as ModuleDefinition
		for ch in def.provides:
			if providers.has(ch):
				var other: ModuleDefinition = providers[ch]
				errors.append(
					"scheduler: channel '%s' is provided by BOTH '%s' and '%s'; a channel has exactly one producer"
					% [String(ch), String(other.id), String(def.id)])
			else:
				providers[ch] = def
	return providers


func _check_requires(mods: Array, providers: Dictionary) -> void:
	_check_types_against_producer(mods, providers)
	for m in mods:
		var def := m as ModuleDefinition
		for ch in def.requires:
			if not providers.has(ch):
				errors.append(
					"scheduler: module '%s' requires channel '%s' but NO enabled module provides it. Resolved pipeline so far: [%s]"
					% [String(def.id), String(ch), ", ".join(_ids_of(mods))])
				continue
			var producer: ModuleDefinition = providers[ch]
			if producer.phase_order > def.phase_order:
				errors.append(
					"scheduler: module '%s' (band %d/%s) requires channel '%s' from '%s' (band %d/%s), which runs LATER; bands cannot reach backwards"
					% [String(def.id), def.phase_order, String(def.phase_name), String(ch),
						String(producer.id), producer.phase_order, String(producer.phase_name)])


func _band_orders(mods: Array) -> Array:
	var seen := {}
	for m in mods:
		seen[(m as ModuleDefinition).phase_order] = true
	var out: Array = seen.keys()
	out.sort()
	return out


func _mods_in_band(mods: Array, band: int) -> Array:
	var out := []
	for m in mods:
		if (m as ModuleDefinition).phase_order == band:
			out.append(m)
	return out


func _topo_within_band(band_mods: Array, providers: Dictionary, band: int) -> Array:
	var deps := {}
	var by_id := {}
	for m in band_mods:
		var def := m as ModuleDefinition
		by_id[def.id] = def
		deps[def.id] = []
	for m in band_mods:
		var def := m as ModuleDefinition
		for ch in def.requires:
			var producer: ModuleDefinition = providers.get(ch)
			if producer != null and producer.phase_order == band and by_id.has(producer.id):
				if not deps[def.id].has(producer.id):
					deps[def.id].append(producer.id)

	var done := {}
	var out := []
	var remaining: Array = band_mods.duplicate()
	while not remaining.is_empty():
		var ready := []
		for m in remaining:
			var def := m as ModuleDefinition
			var satisfied := true
			for d in deps[def.id]:
				if not done.has(d):
					satisfied = false
					break
			if satisfied:
				ready.append(m)
		if ready.is_empty():
			errors.append("scheduler: dependency cycle in band %d: %s" % [band, _cycle_path(remaining, deps)])
			return []
		ready.sort_custom(_tiebreak)
		for m in ready:
			var def := m as ModuleDefinition
			out.append(m)
			done[def.id] = true
			remaining.erase(m)
	return out


func _tiebreak(a: Resource, b: Resource) -> bool:
	var da := a as ModuleDefinition
	var db := b as ModuleDefinition
	if da.priority != db.priority:
		return da.priority < db.priority
	return String(da.id) < String(db.id)


## DFS over the unresolved subgraph to print an actual cycle path "a -> b -> c -> a".
func _cycle_path(remaining: Array, deps: Dictionary) -> String:
	var in_set := {}
	for m in remaining:
		in_set[(m as ModuleDefinition).id] = true
	var color := {}
	var stack: Array = []
	var cycle: Array = []
	for start in remaining:
		var start_id: StringName = (start as ModuleDefinition).id
		if color.get(start_id, 0) != 0:
			continue
		if _dfs(start_id, deps, in_set, color, stack, cycle):
			break
	if cycle.is_empty():
		return "(cycle exists but path extraction failed; unresolved: %s)" % str(_ids_of(remaining))
	var names: Array[String] = []
	for id in cycle:
		names.append(String(id))
	return " -> ".join(names)


func _dfs(id: StringName, deps: Dictionary, in_set: Dictionary, color: Dictionary, stack: Array, cycle: Array) -> bool:
	color[id] = 1
	stack.append(id)
	for d in deps.get(id, []):
		if not in_set.has(d):
			continue
		var c: int = color.get(d, 0)
		if c == 1:
			var idx := stack.find(d)
			cycle.assign(stack.slice(idx) + [d])
			return true
		if c == 0 and _dfs(d, deps, in_set, color, stack, cycle):
			return true
	stack.pop_back()
	color[id] = 2
	return false


func _build_dump() -> void:
	for m in order:
		var def := m as ModuleDefinition
		var factor := 0
		if def is TerrainPass:
			factor = _extent_factor((def as TerrainPass).extent)
			_pass_factors[String(def.id)] = factor
			_column_factor += factor
		_dump.append({
			"id": String(def.id),
			"version": def.version,
			"phase": String(def.phase_name),
			"phase_order": def.phase_order,
			"priority": def.priority,
			"requires": def.requires.map(func(r): return String(r)),
			"provides": def.provides.map(func(p): return String(p)),
			"extent": (def as TerrainPass).extent if def is TerrainPass else -1,
			"column_factor": factor,
		})


static func _extent_factor(extent: int) -> int:
	var e := maxi(0, extent)
	var side := 1 + 2 * e
	return side * side


func _ids_of(mods: Array) -> Array:
	var out: Array[String] = []
	for m in mods:
		out.append(String((m as ModuleDefinition).id))
	return out
