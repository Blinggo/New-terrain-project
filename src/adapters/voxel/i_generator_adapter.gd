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
## CONTRACT (implemented by every gen_*_adapter.gd in this folder):
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
##   capabilities() -> Dictionary       (M01-fix / T2)
##       Machine-readable truth about what the backend can do, so the runtime, the HUD, the
##       benchmarks and the report never have to guess - and so "the default backend runs the
##       modules" is a checked property instead of a claim:
##         id, label                     human strings
##         executes_all_modules  bool    every enabled resolved module is executed (E2's fix)
##         supports_neighbor_passes bool passes can read neighbour columns
##         max_passes            int     engine pass limit (0 = no limit / not pass based)
##         max_extent            int     engine neighbour extent limit, in columns
##         max_column_height_blocks int  engine column height limit (0 = unknown/unbounded)
##         supports_lod          bool    the backend sees a level-of-detail index
##         legacy                bool    a frozen baseline kept for comparison, not the path
##                                       new content is written against
##         notes                 String  the measured detail behind the booleans
##
##       The defaults below are the CONSERVATIVE ones: a new adapter that forgets to declare
##       capabilities is reported as "does not execute modules", which fails loudly in the
##       world boot instead of silently becoming the default.
##
## The base class holds the shared `_report` Dictionary every adapter fills in.
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


## Conservative defaults; every adapter overrides what it can actually do.
func capabilities() -> Dictionary:
	return {
		"id": get_id(),
		"label": "unknown",
		"executes_all_modules": false,
		"supports_neighbor_passes": false,
		"max_passes": 0,
		"max_extent": 0,
		"max_column_height_blocks": 0,
		"supports_lod": false,
		"legacy": false,
		"notes": "adapter did not declare capabilities",
	}
