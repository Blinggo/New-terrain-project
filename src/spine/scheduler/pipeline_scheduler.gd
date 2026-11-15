class_name PipelineScheduler
extends RefCounted
## src/spine/scheduler/pipeline_scheduler.gd
##
## M01 / Task 5 - Resolves the module pipeline from declared requires/provides ONLY.
##
## Rules:
##   * Phases run in the fixed enum order (PLANET ... DECORATE).
##   * WITHIN a phase, topological order over requires/provides edges whose producer is in
##     the same phase. Cross-phase edges are satisfied by phase order; a dependency on a
##     LATER phase is a resolve error (it could never be satisfied).
##   * Tiebreak: priority ascending, then id lexicographic. The ready set is re-sorted from
##     a plain Array at every step, so the result cannot depend on Dictionary iteration
##     order (X4 shuffles the input 50 times and demands an identical dump).
##   * Cycle -> error printing the actual path, e.g. "a -> b -> c -> a" (X5).
##   * Missing producer for a requires -> error naming consumer, channel and the resolved
##     pipeline so far (X6).
##   * Two producers of one channel -> error naming both.
##
## Also computes each TerrainPass's extent and the TOTAL COLUMN MULTIPLICATION FACTOR:
## the number of column-touches per output column, sum over passes of (1 + 2*extent)^2.
## That single number is what makes neighbour-aware passes a budgeted decision (Task 5).
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

	var providers := _build_provider_map(mods)
	_check_requires(mods, providers)
	if not errors.is_empty():
		return false

	for phase in ModuleDefinition.PHASE_NAMES.size():
		var phase_mods := _mods_in_phase(mods, phase)
		if phase_mods.is_empty():
			continue
		var sorted := _topo_within_phase(phase_mods, providers, phase)
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


# --- internals --------------------------------------------------------------------------

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
	for m in mods:
		var def := m as ModuleDefinition
		for ch in def.requires:
			if not providers.has(ch):
				errors.append(
					"scheduler: module '%s' requires channel '%s' but NO enabled module provides it. Resolved pipeline so far: [%s]"
					% [String(def.id), String(ch), ", ".join(_ids_of(mods))])
				continue
			var producer: ModuleDefinition = providers[ch]
			if producer.phase > def.phase:
				errors.append(
					"scheduler: module '%s' (phase %s) requires channel '%s' from '%s' (phase %s), which runs LATER; phases cannot reach backwards"
					% [String(def.id), def.phase_name(), String(ch), String(producer.id), producer.phase_name()])


func _mods_in_phase(mods: Array, phase: int) -> Array:
	var out := []
	for m in mods:
		if (m as ModuleDefinition).phase == phase:
			out.append(m)
	return out


func _topo_within_phase(phase_mods: Array, providers: Dictionary, phase: int) -> Array:
	# Edges: consumer -> producer, same phase only.
	var deps := {}          # id -> Array of provider ids in this phase
	var by_id := {}
	for m in phase_mods:
		var def := m as ModuleDefinition
		by_id[def.id] = def
		deps[def.id] = []
	for m in phase_mods:
		var def := m as ModuleDefinition
		for ch in def.requires:
			var producer: ModuleDefinition = providers.get(ch)
			if producer != null and producer.phase == phase and by_id.has(producer.id):
				if not deps[def.id].has(producer.id):
					deps[def.id].append(producer.id)

	var done := {}
	var out := []
	var remaining: Array = phase_mods.duplicate()
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
			errors.append("scheduler: dependency cycle in phase %s: %s" % [
				ModuleDefinition.PHASE_NAMES[phase], _cycle_path(remaining, deps)])
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
	var color := {}     # 0 unseen, 1 in stack, 2 done
	var stack: Array = []
	var cycle: Array = []

	for start in remaining:
		var start_id: StringName = (start as ModuleDefinition).id
		if color.get(start_id, 0) != 0:
			continue
		var found := _dfs(start_id, deps, in_set, color, stack, cycle)
		if found:
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
			"phase": def.phase_name(),
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
