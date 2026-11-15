class_name PipelineBootstrap
extends RefCounted
## src/spine/pipeline_bootstrap.gd
##
## M01 - One entry point that turns "scan disk + resolve deps" into a usable pipeline, for
## the adapters, the runtime and the tests alike. Applies the config's per-id module
## overrides (enable/disable, param overrides) on DUPLICATES, so the on-disk resources are
## never mutated and two worlds with different overrides cannot leak into each other.
##
## Returns:
##   {"ok": bool, "registry": ModuleRegistry, "scheduler": PipelineScheduler,
##    "modules": Array (resolved, override-applied), "errors": Array[String]}

static func build(config: Dictionary) -> Dictionary:
	var registry := ModuleRegistry.new()
	registry.scan()
	var errors: Array = registry.errors.duplicate()

	var mods := registry.active()
	mods = _apply_overrides(mods, config.get("modules_overrides", {}), errors)

	var scheduler := PipelineScheduler.new()
	if not scheduler.resolve(mods):
		errors.append_array(scheduler.errors)

	return {
		"ok": errors.is_empty(),
		"registry": registry,
		"scheduler": scheduler,
		"modules": scheduler.order,
		"errors": errors,
	}


## Overrides shape: {"planet.hills_v1": {"enabled": false, "params": {"noise_octaves": 4}}}.
## Unknown ids are an error (a typo must not silently do nothing); unknown param keys are a
## warning-level error entry so they surface in the boot log.
static func _apply_overrides(mods: Array, overrides: Dictionary, errors: Array) -> Array:
	if overrides.is_empty():
		return mods
	var by_id := {}
	for m in mods:
		by_id[(m as ModuleDefinition).id] = m
	var out := mods.duplicate()
	for id_variant in overrides:
		var id := StringName(String(id_variant))
		var entry: Dictionary = overrides[id_variant]
		if not by_id.has(id):
			errors.append("config modules override references unknown module id '%s' (known: %s)" % [
				String(id), str(by_id.keys())])
			continue
		var original: ModuleDefinition = by_id[id]
		var dup := original.duplicate() as ModuleDefinition
		if entry.has("enabled"):
			dup.enabled = bool(entry["enabled"])
		if entry.has("params"):
			var p: Dictionary = dup.params.duplicate(true)
			for k in entry["params"]:
				# Typed @export fields are the single source of truth for the parameters a
				# module declares; `params` holds free-form extras. An override therefore
				# lands on the property when it exists, so graph and GDScript backends both
				# see it, and in params otherwise.
				if dup.get_property_list().any(func(pr): return pr["name"] == String(k)):
					dup.set(String(k), entry["params"][k])
				else:
					p[k] = entry["params"][k]
			dup.params = p
		var idx := out.find(original)
		if dup.enabled:
			out[idx] = dup
		else:
			out.remove_at(idx)
	return out
