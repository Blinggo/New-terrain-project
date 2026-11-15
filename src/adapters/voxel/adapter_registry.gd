class_name AdapterRegistry
extends RefCounted
## src/adapters/voxel/adapter_registry.gd
##
## M00 / T5 - The only place that knows WHICH generator adapters exist. Layers above
## src/adapters/ ask this registry for a generator by string id and receive a plain
## `Resource`; they never name a Voxel Tools class (ADR-0002).
##
## Adding a generator in M01+ means: write src/adapters/voxel/gen_<x>_adapter.gd extending
## IGeneratorAdapter, add its id to ORDER, and add it to VALID_GENERATORS in
## src/runtime/world/world_config.gd. Nothing else changes.

const DEFAULT_ID := "noise2d"

## Order matters: F3 cycles through this list in order.
const ORDER: Array[String] = ["noise2d", "graph", "multipass"]


static func ids() -> Array[String]:
	return ORDER


static func has_id(id: String) -> bool:
	return id in ORDER


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
		"noise2d":
			return GenNoise2DAdapter.new()
		"graph":
			return GenGraphAdapter.new()
		"multipass":
			return GenMultipassAdapter.new()
	push_error("AdapterRegistry: unknown generator id '%s' (known: %s)" % [id, str(ORDER)])
	return null


## Like create(), but returns null for an unknown id without logging an engine error.
## Tests and config validation use this; runtime code uses create() so a bad id is loud.
static func try_create(id: String) -> IGeneratorAdapter:
	match id:
		"noise2d":
			return GenNoise2DAdapter.new()
		"graph":
			return GenGraphAdapter.new()
	return null


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
			"report": r["report"],
		})
	return out
