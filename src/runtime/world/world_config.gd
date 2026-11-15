class_name WorldConfig
extends RefCounted
## src/runtime/world/world_config.gd
##
## Typed, validated view of res://content/world_config.json.
##
## LAYER: runtime. Uses src/core (JsonData) only. Contains NO Voxel Tools references -
## the values are handed to src/adapters/, which is the only layer allowed to touch them.
##
## Instances are treated as immutable: the F3/F4/F5 debug keys produce a NEW WorldConfig
## via with_generator() / with_view_distance() / with_seed() instead of mutating shared
## state. That keeps "what generated this world" answerable at any moment, which the
## determinism harness depends on.

const DEFAULT_PATH := "res://content/world_config.json"
const VALID_TIERS: Array[String] = ["low", "medium", "high"]
## M01-fix: `native_cb` (the engine's own multipass callback, running the resolved module
## pipeline) is the default. `multipass` is GONE as an id: that backend was self-hosted and
## never the extension's MultipassCB, so it is now `experimental_columns`. `graph` and
## `noise2d` are frozen M00 baselines that do not execute modules; booting a world on one
## requires `allow_legacy_baseline` (see below).
const VALID_GENERATORS: Array[String] = ["native_cb", "graph", "noise2d", "experimental_columns"]
const DEFAULT_GENERATOR := "native_cb"

## M01 / Task 7 - quality tiers own CONCRETE budgets instead of being a label.
## M01-fix / T9 - every budget is now either WIRED or explicitly retracted, with the reason
## in TIER_BUDGET_STATUS (printed into the report, so a number in a config cannot pretend to
## do something it does not):
##   view_chunks              WIRED   effective_view_distance_chunks() -> VoxelViewer
##   field_cache_mb           WIRED   FieldCache budget (bytes) -> eviction
##   engine_threads           WIRED   VoxelEngine.set_thread_count(), capped by the CPU count
##   instance_density         UNUSED  no instanced features exist in M01 (trees are M08). The
##                                    number stays so M08 inherits the tier contract; the
##                                    report says "unused", not "wired".
##   max_gen_tasks_per_frame  BLOCKED the extension exposes no per-frame task budget:
##                                    VoxelEngine has only get/set_thread_count and get_stats
##                                    (verified tools/probe_native_cb7.gd). engine_threads is
##                                    the closest real lever and it is wired instead.
##   module quality_scaling   WIRED   a module whose factor for the active tier is <= 0 is
##                                    skipped by the executor and the skip is reported.
const TIER_BUDGETS := {
	"low":    {"view_chunks": 6,  "field_cache_mb": 24, "instance_density": 0.4, "max_gen_tasks_per_frame": 2, "engine_threads": 2},
	"medium": {"view_chunks": 8,  "field_cache_mb": 48, "instance_density": 0.7, "max_gen_tasks_per_frame": 4, "engine_threads": 4},
	"high":   {"view_chunks": 12, "field_cache_mb": 96, "instance_density": 1.0, "max_gen_tasks_per_frame": 8, "engine_threads": 8},
}
const TIER_BUDGET_STATUS := {
	"view_chunks": "wired (VoxelViewer.view_distance)",
	"field_cache_mb": "wired (FieldCache budget_bytes)",
	"engine_threads": "wired (VoxelEngine.set_thread_count, capped by OS.get_processor_count())",
	"instance_density": "UNUSED in M01 - no instanced features exist yet (trees are M08)",
	"max_gen_tasks_per_frame": "BLOCKED - the extension exposes no per-frame generation task budget (VoxelEngine has only get/set_thread_count and get_stats); engine_threads is the wired analogue",
	"quality_scaling": "wired (a module with factor <= 0 for the tier is skipped and reported)",
}
const VIEW_DISTANCE_CYCLE: Array[int] = [6, 8, 12]

# --- world shape (T4) -----------------------------------------------------------------
var seed_value: int = 0
var block_size: float = 1.0
var world_y_min: int = -64
var world_y_max: int = 320          # EXCLUSIVE: highest block index is 319
var sea_level: int = 64
var quality_tier: String = "low"

# --- what to build --------------------------------------------------------------------
var generator_id: String = DEFAULT_GENERATOR
## M01-fix / T8 - Fail closed. `graph` and `noise2d` are legacy M00 baselines that execute
## their own fixed maths and IGNORE which modules are enabled. Selecting one is allowed (they
## are the golden reference and the cheapest backend measured) but only when this flag says
## the operator knows it: otherwise the world refuses to boot with an error that names the
## backend, the capability it lacks and the two ways forward. Default false.
var allow_legacy_baseline: bool = false
## Debug flag, default false: when true a build error in the module pipeline is reported but
## the world still boots on the legacy graph baseline. Exists so the M00 comparison can be
## reproduced while a module is broken; it never hides the error, it only stops it from being
## fatal. Fail-closed is the default because a silently flat world is the bug class this
## project is built to prevent.
var allow_broken_pipeline: bool = false
## >0 = explicit override of the tier's default view distance; <=0 = "use the tier default".
## M01 / Task 7: the tier owns the budget, the config may override it, and the HUD says
## which one won (view_distance_source).
var view_distance_chunks: int = 8
var gen_params: Dictionary = {}

# --- M01 worldgen -----------------------------------------------------------------------
var worldgen_version: int = 1
## Per-id module overrides: {"planet.hills_v1": {"enabled": false, "params": {...}}}.
var modules_overrides: Dictionary = {}

# --- streaming knobs ------------------------------------------------------------------
var view_distance_vertical_ratio: float = 1.0
var bounds_half_extent_xz: int = 16777216
var mesh_block_size: int = 16
var generate_collisions: bool = true
var automatic_loading_enabled: bool = true
var type_depth_bits: int = 8
var occlusion_darkness: float = 0.45

# --- provenance -----------------------------------------------------------------------
var source_path: String = ""
var config_version: int = 0
var validation_errors: Array[String] = []
var validation_warnings: Array[String] = []


## Height of the world in blocks. M00 contract: 384.
func world_height() -> int:
	return world_y_max - world_y_min


## Number of 16-block data blocks stacked in one column. M00 contract: 24.
func column_block_count() -> int:
	if mesh_block_size <= 0:
		return 0
	return int(ceil(float(world_height()) / float(mesh_block_size)))


static func load_config(path: String = DEFAULT_PATH) -> WorldConfig:
	var cfg := WorldConfig.new()
	cfg.source_path = path
	var data := JsonData.load_file(path)
	if data.is_empty():
		cfg.validation_errors.append("could not read %s - falling back to hard defaults" % path)
		cfg._validate()
		return cfg

	cfg.config_version = JsonData.get_int(data, "config_version", 1)
	cfg.worldgen_version = JsonData.get_int(data, "worldgen_version", 1)
	cfg.modules_overrides = JsonData.get_dict(data, "modules")
	cfg.seed_value = JsonData.get_int(data, "seed", 0)
	cfg.generator_id = JsonData.get_string(data, "generator", DEFAULT_GENERATOR)
	cfg.allow_legacy_baseline = JsonData.get_bool(data, "allow_legacy_baseline", false)
	cfg.allow_broken_pipeline = JsonData.get_bool(data, "allow_broken_pipeline", false)
	cfg.view_distance_chunks = JsonData.get_int(data, "view_distance_chunks", 8)
	cfg.block_size = JsonData.get_float(data, "block_size", 1.0)
	cfg.world_y_min = JsonData.get_int(data, "world_y_min", -64)
	cfg.world_y_max = JsonData.get_int(data, "world_y_max", 320)
	cfg.sea_level = JsonData.get_int(data, "sea_level", 64)
	cfg.quality_tier = JsonData.get_string(data, "quality_tier", "low")
	cfg.gen_params = JsonData.get_dict(data, "gen_params")

	var streaming := JsonData.get_dict(data, "streaming")
	cfg.view_distance_vertical_ratio = JsonData.get_float(streaming, "view_distance_vertical_ratio", 1.0)
	cfg.bounds_half_extent_xz = JsonData.get_int(streaming, "bounds_half_extent_xz", 16777216)
	cfg.mesh_block_size = JsonData.get_int(streaming, "mesh_block_size", 16)
	cfg.generate_collisions = JsonData.get_bool(streaming, "generate_collisions", true)
	cfg.automatic_loading_enabled = JsonData.get_bool(streaming, "automatic_loading_enabled", true)
	cfg.type_depth_bits = JsonData.get_int(streaming, "type_depth_bits", 8)
	cfg.occlusion_darkness = JsonData.get_float(streaming, "occlusion_darkness", 0.45)

	cfg._validate()
	return cfg


func _validate() -> void:
	validation_errors.clear()
	validation_warnings.clear()

	if world_height() != 384:
		validation_errors.append(
			"world height must be 384 blocks (y %d..%d exclusive) but is %d"
			% [world_y_min, world_y_max, world_height()]
		)
	if world_height() % mesh_block_size != 0:
		validation_errors.append(
			"world height %d is not a multiple of mesh_block_size %d - the top column block would be partial"
			% [world_height(), mesh_block_size]
		)
	if sea_level < world_y_min or sea_level >= world_y_max:
		validation_errors.append("sea_level %d is outside the world column" % sea_level)
	if not quality_tier in VALID_TIERS:
		validation_errors.append("quality_tier '%s' must be one of %s" % [quality_tier, str(VALID_TIERS)])
	if not generator_id in VALID_GENERATORS:
		validation_errors.append("generator '%s' must be one of %s" % [generator_id, str(VALID_GENERATORS)])
	if generator_id in AdapterRegistry.LEGACY_IDS and not allow_legacy_baseline:
		validation_errors.append(
			"generator '%s' is a legacy M00 baseline: it executes its own fixed maths and IGNORES which modules are enabled (capabilities.executes_all_modules = false). Either use '%s' (the module pipeline backend), or set \"allow_legacy_baseline\": true in %s to say you know the modules will not run."
			% [generator_id, DEFAULT_GENERATOR, source_path if source_path != "" else DEFAULT_PATH])
	if view_distance_chunks < 0:
		validation_errors.append(
			"view_distance_chunks must be >= 0 (0 or omitted = use the quality tier default; got %d)"
			% view_distance_chunks
		)
	for mod_id in modules_overrides:
		var entry: Dictionary = modules_overrides[mod_id]
		for key in entry:
			if not (key in ["enabled", "params"]):
				validation_warnings.append(
					"modules['%s'] has unknown key '%s' (expected 'enabled' and/or 'params'); ignored"
					% [String(mod_id), String(key)]
				)
		if entry.has("enabled") and not (entry["enabled"] is bool):
			validation_errors.append("modules['%s'].enabled must be a bool" % String(mod_id))
		if entry.has("params") and not (entry["params"] is Dictionary):
			validation_errors.append("modules['%s'].params must be an object" % String(mod_id))
	if block_size <= 0.0:
		validation_errors.append("block_size must be > 0 (M00 contract: 1 block = 1 metre)")
	elif not is_equal_approx(block_size, 1.0):
		validation_warnings.append("block_size %f != 1.0; the M00 contract is 1 block = 1 metre" % block_size)
	if view_distance_vertical_ratio <= 0.0:
		validation_errors.append("view_distance_vertical_ratio must be > 0")
	if view_distance_vertical_ratio > 2.0:
		validation_warnings.append(
			"view_distance_vertical_ratio %f > 2.0: measured (tools/probe_vratio.gd) 2.0 is the minimum that keeps the surface streamed while flying ~200 m up; anything larger multiplies loaded blocks on low-end hardware for no measured gain"
			% view_distance_vertical_ratio
		)


func is_valid() -> bool:
	return validation_errors.is_empty()


# --- M01 tier budgets -------------------------------------------------------------------

func tier_budget() -> Dictionary:
	return TIER_BUDGETS.get(quality_tier, TIER_BUDGETS["low"])


func tier_view_distance_chunks() -> int:
	return int(tier_budget()["view_chunks"])


func tier_field_cache_bytes() -> int:
	return int(tier_budget()["field_cache_mb"]) * 1024 * 1024


func tier_instance_density() -> float:
	return float(tier_budget()["instance_density"])


func tier_max_gen_tasks_per_frame() -> int:
	return int(tier_budget()["max_gen_tasks_per_frame"])


## Engine generation/meshing threads this tier asks for, capped by the machine.
func tier_engine_threads() -> int:
	return clampi(int(tier_budget().get("engine_threads", 2)), 1, maxi(1, OS.get_processor_count()))


func tier_budget_status() -> Dictionary:
	return TIER_BUDGET_STATUS.duplicate()


## The view distance the world actually streams at: config override if set, else tier.
func effective_view_distance_chunks() -> int:
	return view_distance_chunks if view_distance_chunks > 0 else tier_view_distance_chunks()


## For the HUD: who won, the override or the tier.
var view_distance_source: String = "" :
	get:
		return "config override" if view_distance_chunks > 0 else "tier '%s' default" % quality_tier


func clone() -> WorldConfig:
	var c := WorldConfig.new()
	c.seed_value = seed_value
	c.block_size = block_size
	c.world_y_min = world_y_min
	c.world_y_max = world_y_max
	c.sea_level = sea_level
	c.quality_tier = quality_tier
	c.generator_id = generator_id
	c.allow_legacy_baseline = allow_legacy_baseline
	c.allow_broken_pipeline = allow_broken_pipeline
	c.view_distance_chunks = view_distance_chunks
	c.gen_params = gen_params.duplicate(true)
	c.worldgen_version = worldgen_version
	c.modules_overrides = modules_overrides.duplicate(true)
	c.view_distance_vertical_ratio = view_distance_vertical_ratio
	c.bounds_half_extent_xz = bounds_half_extent_xz
	c.mesh_block_size = mesh_block_size
	c.generate_collisions = generate_collisions
	c.automatic_loading_enabled = automatic_loading_enabled
	c.type_depth_bits = type_depth_bits
	c.occlusion_darkness = occlusion_darkness
	c.source_path = source_path
	c.config_version = config_version
	c.validation_errors = validation_errors.duplicate()
	c.validation_warnings = validation_warnings.duplicate()
	return c


func with_seed(new_seed: int) -> WorldConfig:
	var c := clone()
	c.seed_value = new_seed
	return c


func with_view_distance(chunks: int) -> WorldConfig:
	var c := clone()
	c.view_distance_chunks = chunks
	return c


func with_generator(id: String) -> WorldConfig:
	var c := clone()
	c.generator_id = id
	return c


## Next value in the F4 cycle, wrapping.
func next_view_distance() -> int:
	var i := VIEW_DISTANCE_CYCLE.find(view_distance_chunks)
	if i < 0:
		return VIEW_DISTANCE_CYCLE[0]
	return VIEW_DISTANCE_CYCLE[(i + 1) % VIEW_DISTANCE_CYCLE.size()]


## Plain-Dictionary handoff to src/adapters/. Adapters take data, never runtime classes,
## so the dependency arrow stays runtime -> adapters and never the reverse.
func to_gen_context() -> Dictionary:
	return {
		"seed": seed_value,
		"gen_params": gen_params.duplicate(true),
		"quality_tier": quality_tier,
		"worldgen_version": worldgen_version,
		"modules_overrides": modules_overrides.duplicate(true),
		"field_cache_budget_bytes": tier_field_cache_bytes(),
		"view_distance_chunks": effective_view_distance_chunks(),
		"world_y_min": world_y_min,
		"world_y_max": world_y_max,
		"sea_level": sea_level,
		"block_size": block_size,
		"mesh_block_size": mesh_block_size,
		"allow_legacy_baseline": allow_legacy_baseline,
		"allow_broken_pipeline": allow_broken_pipeline,
		"engine_threads": tier_engine_threads(),
	}


func to_terrain_context() -> Dictionary:
	return {
		"view_distance_chunks": effective_view_distance_chunks(),
		"view_distance_source": view_distance_source,
		"view_distance_vertical_ratio": view_distance_vertical_ratio,
		"bounds_half_extent_xz": bounds_half_extent_xz,
		"mesh_block_size": mesh_block_size,
		"generate_collisions": generate_collisions,
		"automatic_loading_enabled": automatic_loading_enabled,
		"world_y_min": world_y_min,
		"world_y_max": world_y_max,
		"block_size": block_size,
		"type_depth_bits": type_depth_bits,
		"occlusion_darkness": occlusion_darkness,
	}


func describe() -> String:
	return "seed=%d gen=%s%s vd=%d (vratio=%.2f) y=[%d,%d) h=%d sea=%d tier=%s block=%fm mesh=%d" % [
		seed_value, generator_id, " (legacy baseline)" if generator_id in AdapterRegistry.LEGACY_IDS else "",
		view_distance_chunks, view_distance_vertical_ratio,
		world_y_min, world_y_max, world_height(), sea_level, quality_tier, block_size, mesh_block_size,
	]
