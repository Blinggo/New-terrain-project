class_name AdapterRegistry
extends RefCounted
## src/adapters/voxel/adapter_registry.gd
##
## M00 / T5 - The only place that knows WHICH generator adapters exist. Layers above
## src/adapters/ ask this registry for a generator by string id and receive a plain
## `Resource`; they never name a Voxel Tools class (ADR-0002).
##
## M01-fix / T1-T2 - It is also the only place that knows what each backend CAN do, as data:
## `capabilities(id)` returns executes_all_modules / supports_neighbor_passes / max_passes /
## max_extent / max_column_height_blocks / supports_lod / legacy. The runtime uses
## executes_all_modules + legacy to decide whether a world may boot on a backend at all
## (fail closed, evidence E2), and the report prints the table instead of prose.
##
## Adding a generator means: write src/adapters/voxel/gen_<x>_adapter.gd extending
## IGeneratorAdapter, add its id to ORDER, add it to VALID_GENERATORS in
## src/runtime/world/world_config.gd, and declare its capabilities. Nothing else changes.

## M01-fix: the default is the backend that actually runs the resolved module pipeline.
## The M00 baselines stay in the cycle for comparison and for the golden cross-check.
const DEFAULT_ID := "native_cb"

## Order matters: F3 cycles through this list in order (default first).
const ORDER: Array[String] = ["native_cb", "graph", "noise2d", "experimental_columns"]

## Backends kept as frozen M00 baselines. They do not execute modules; selecting one needs
## `allow_legacy_baseline` in the world config.
const LEGACY_IDS: Array[String] = ["graph", "noise2d"]


static func ids() -> Array[String]:
	return ORDER


static func has_id(id: String) -> bool:
	return id in ORDER


static func is_legacy(id: String) -> bool:
	return id in LEGACY_IDS


static func next_id(current: String) -> String:
	var i := ORDER.find(current)
	if i < 0:
		return ORDER[0]
	return ORDER[(i + 1) % ORDER.size()]


## True when `id` names a real adapter. Use this to probe a config value or an F3 cycle
## WITHOUT generating an engine error, e.g. from tests (a push_error during a green test run
## would be indistinguishable from a real bug in the logs).
static func is_known(id: String) -> bool:
	return id in ORDER


static func create(id: String) -> IGeneratorAdapter:
	match id:
		"native_cb":
			return GenNativeCBAdapter.new()
		"noise2d":
			return GenNoise2DAdapter.new()
		"graph":
			return GenGraphAdapter.new()
		"experimental_columns":
			return GenExperimentalColumnsAdapter.new()
	push_error("AdapterRegistry: unknown generator id '%s' (known: %s)" % [id, str(ORDER)])
	return null


## Like create(), but returns null for an unknown id without logging an engine error.
## Tests and config validation use this; runtime code uses create() so a bad id is loud.
static func try_create(id: String) -> IGeneratorAdapter:
	if not is_known(id):
		return null
	return create(id)


## Capability metadata for one backend, without building it.
static func capabilities(id: String) -> Dictionary:
	var adapter := try_create(id)
	if adapter == null:
		return {"id": id, "error": "unknown generator id"}
	return adapter.capabilities()


## The whole capability table, in ORDER: what the report and the HUD print.
static func capabilities_all() -> Array:
	var out: Array = []
	for id in ORDER:
		out.append(capabilities(id))
	return out


## True when `id` executes every enabled resolved module. The world boot checks this before
## accepting a backend as the world's generator (a backend that ignores modules cannot be
## the default of a module pipeline - that was M01's evidence E2).
static func executes_all_modules(id: String) -> bool:
	var caps := capabilities(id)
	return bool(caps.get("executes_all_modules", false))


## Build a generator for `id`. Returns:
##   {"ok": bool, "generator": Resource, "adapter": IGeneratorAdapter, "report": Dictionary}
## `generator` is typed Resource on purpose so callers above the adapter layer do not have
## to import a Voxel Tools type.
static func build_generator(id: String, seed_value: int, gen_context: Dictionary) -> Dictionary:
	var out := {"ok": false, "generator": null, "adapter": null, "report": {}}
	var adapter := create(id)
	if adapter == null:
		out["report"] = {"error": "unknown generator id '%s'" % id}
		return out

	out["adapter"] = adapter
	var gen: VoxelGenerator = adapter.build(seed_value, gen_context)
	out["report"] = adapter.get_last_build_report()
	if gen == null:
		if not out["report"].has("error"):
			out["report"]["error"] = "adapter '%s' returned no generator" % id
		return out

	out["ok"] = true
	out["generator"] = gen
	return out


## One-line descriptions, used by the HUD's F3 cycling and by the report.
static func describe_all(seed_value: int, gen_context: Dictionary) -> Array:
	var out := []
	for id in ORDER:
		var adapter := create(id)
		if adapter == null:
			continue
		var r := build_generator(id, seed_value, gen_context)
		out.append({
			"id": id,
			"display_name": adapter.get_display_name(),
			"built_ok": bool(r["ok"]),
			"capabilities": adapter.capabilities(),
			"report": r["report"],
		})
	return out
