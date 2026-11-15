class_name ModuleRegistry
extends RefCounted
## src/spine/registry/module_registry.gd
##
## M01 / Task 4 - Discovers modules by SCANNING DISK. There is no hardcoded module list
## anywhere in the project (B3): add a .tres under content/modules/ and the next boot or
## reload() picks it up.
##
## Roots, in order:
##   1. res://content/modules/**   - shipped modules (M01: exactly two, see B17)
##   2. user://modules/**          - modding hook. Implemented and scanned, intentionally
##                                   empty in-repo; the extensibility tests (X1, X2) write
##                                   throwaway modules here and reload().
##
## Failure handling, all as `errors` entries (boot refuses loudly, never crashes):
##   * duplicate id        -> error naming BOTH file paths (X7)
##   * unloadable .tres    -> error naming the path
##   * script that is not a ModuleDefinition subclass -> clear "unknown script type" error
##   * enabled = false     -> skipped by active(), still present in debug_dump()
##
## LAYER: spine. Resource loading is engine-generic; no Voxel Tools types (X9).

const ROOTS: Array[String] = ["res://content/modules", "user://modules"]

## All loaded definitions, sorted by source path (scan determinism).
var modules: Array = []
var errors: Array[String] = []
var _by_id := {}


func scan() -> void:
	modules.clear()
	errors.clear()
	_by_id.clear()
	for root in ROOTS:
		for path in _list_tres(String(root)):
			_load_one(path)
	# Deterministic presentation order regardless of filesystem enumeration order.
	modules.sort_custom(func(a, b): return String(a.get_meta("source_path")) < String(b.get_meta("source_path")))


## Re-scan and let the caller re-resolve the pipeline. Used at runtime by the extensibility
## tests and, later, by mod loaders.
func reload() -> void:
	scan()


## NOT named get(): Object.get(StringName) is native; shadowing it is a compile error here.
func lookup(id: StringName) -> ModuleDefinition:
	return _by_id.get(id)


func has(id: StringName) -> bool:
	return _by_id.has(id)


## Enabled modules only, in a stable order (id), for the scheduler.
func active() -> Array:
	var out := []
	for m in modules:
		if (m as ModuleDefinition).enabled:
			out.append(m)
	out.sort_custom(func(a, b): return String((a as ModuleDefinition).id) < String((b as ModuleDefinition).id))
	return out


func debug_dump() -> Array:
	var out := []
	for m in modules:
		var d := m as ModuleDefinition
		out.append({
			"id": String(d.id),
			"version": d.version,
			"phase": d.phase_label(),
			"phase_order": d.phase_order,
			"enabled": d.enabled,
			"requires": d.requires.map(func(r): return String(r)),
			"provides": d.provides.map(func(p): return String(p)),
			"path": String(d.get_meta("source_path", "?")),
		})
	return out


func _load_one(path: String) -> void:
	var res: Resource = load(path)
	if res == null:
		errors.append("module registry: could not load %s" % path)
		return
	if not (res is ModuleDefinition):
		var script: Script = res.get_script()
		errors.append(
			"module registry: %s is not a ModuleDefinition (got %s%s) - a module .tres must instance a subclass of src/spine/contracts/module_definition.gd"
			% [path, res.get_class(), "" if script == null else (" with script " + String(script.resource_path))])
		return
	var def := res as ModuleDefinition
	if def.id == &"":
		errors.append("module registry: %s has an empty id - set id = &\"domain.name\" in the .tres" % path)
		return
	if _by_id.has(def.id):
		var other: ModuleDefinition = _by_id[def.id]
		errors.append(
			"module registry: duplicate module id '%s' in BOTH %s and %s - ids are globally unique; bump one of them"
			% [String(def.id), String(other.get_meta("source_path")), path])
		return
	def.set_meta("source_path", path)
	_by_id[def.id] = def
	modules.append(def)


func _list_tres(root: String) -> Array:
	var out := []
	var dir := DirAccess.open(root)
	if dir == null:
		return out   # missing root is legal (user://modules starts absent)
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		var rel := n
		if dir.current_is_dir():
			out.append_array(_list_tres(root + "/" + rel))
		elif rel.ends_with(".tres"):
			out.append(root + "/" + rel)
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out
