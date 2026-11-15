class_name IGeneratorAdapter
extends RefCounted
## src/adapters/voxel/i_generator_adapter.gd
##
## M00 / T5 - The seam between "how we generate terrain" and "what Voxel Tools needs".
##
## LAYER: adapters. This is one of only a handful of files in the whole project allowed to
## name a Voxel Tools class (see docs/CONVENTIONS.md and ADR-0002). Everything above this
## folder passes generators around as plain `Resource` / `Node3D` references and never
## mentions VoxelTerrain, VoxelGeneratorGraph, VoxelMesherBlocky, etc. That is what keeps
## the "swap in a C++ GDExtension later" option cheap.
##
## CONTRACT (implemented by gen_noise2d_adapter.gd and gen_graph_adapter.gd):
##
##   get_id() -> String
##       Stable machine id, matches `generator` in content/world_config.json.
##
##   get_display_name() -> String
##       Human name for the HUD and reports.
##
##   build(seed_value: int, config: Dictionary) -> VoxelGenerator
##       Pure construction. MUST be deterministic: the returned generator may only depend
##       on `seed_value` and `config`. No randf()/randi(), no Time.*, no frame count, no
##       node order, no player position.
##
##   get_last_build_report() -> Dictionary
##       Diagnostics from the last build() call (compile result, node ids, warnings). Used
##       by tests/smoke/test_generators.gd and printed in the M00 report. Never null.
##
## `config` is the plain-Dictionary "generation context" produced by
## WorldConfig.to_gen_context():
##   {
##     "seed": int, "gen_params": Dictionary, "world_y_min": int, "world_y_max": int,
##     "sea_level": int, "block_size": float, "mesh_block_size": int
##   }

## Virtual. Override in subclasses.
func get_id() -> String:
	push_error("IGeneratorAdapter.get_id() must be overridden")
	return ""


## Virtual. Override in subclasses.
func get_display_name() -> String:
	push_error("IGeneratorAdapter.get_display_name() must be overridden")
	return ""


## Virtual. Override in subclasses.
func build(_seed_value: int, _config: Dictionary) -> VoxelGenerator:
	push_error("IGeneratorAdapter.build() must be overridden")
	return null


## Virtual. Override in subclasses if the build produces useful diagnostics.
func get_last_build_report() -> Dictionary:
	return {}


# --- shared helpers (deterministic, no Voxel Tools) -----------------------------------

## Read a generation parameter with a fallback, so a missing key in world_config.json can
## never silently become 0.0 and turn the terrain into a flat plane.
static func param(config: Dictionary, key: String, fallback: float) -> float:
	var p: Dictionary = config.get("gen_params", {})
	if not p.has(key):
		push_warning("generator: gen_params has no '%s', using %f" % [key, fallback])
		return fallback
	return JsonData.get_float(p, key, fallback)


static func param_int(config: Dictionary, key: String, fallback: int) -> int:
	var p: Dictionary = config.get("gen_params", {})
	if not p.has(key):
		push_warning("generator: gen_params has no '%s', using %d" % [key, fallback])
		return fallback
	return JsonData.get_int(p, key, fallback)
