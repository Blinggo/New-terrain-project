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
const VALID_GENERATORS: Array[String] = ["noise2d", "graph"]
const VIEW_DISTANCE_CYCLE: Array[int] = [6, 8, 12]

# --- world shape (T4) -----------------------------------------------------------------
var seed_value: int = 0
var block_size: float = 1.0
var world_y_min: int = -64
var world_y_max: int = 320          # EXCLUSIVE: highest block index is 319
var sea_level: int = 64
var quality_tier: String = "low"

# --- what to build --------------------------------------------------------------------
var generator_id: String = "noise2d"
var view_distance_chunks: int = 8
var gen_params: Dictionary = {}

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
	cfg.seed_value = JsonData.get_int(data, "seed", 0)
	cfg.generator_id = JsonData.get_string(data, "generator", "noise2d")
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
	if view_distance_chunks <= 0:
		validation_errors.append("view_distance_chunks must be > 0")
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


func clone() -> WorldConfig:
	var c := WorldConfig.new()
	c.seed_value = seed_value
	c.block_size = block_size
	c.world_y_min = world_y_min
	c.world_y_max = world_y_max
	c.sea_level = sea_level
	c.quality_tier = quality_tier
	c.generator_id = generator_id
	c.view_distance_chunks = view_distance_chunks
	c.gen_params = gen_params.duplicate(true)
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
		"world_y_min": world_y_min,
		"world_y_max": world_y_max,
		"sea_level": sea_level,
		"block_size": block_size,
		"mesh_block_size": mesh_block_size,
	}


func to_terrain_context() -> Dictionary:
	return {
		"view_distance_chunks": view_distance_chunks,
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
	return "seed=%d gen=%s vd=%d (vratio=%.2f) y=[%d,%d) h=%d sea=%d tier=%s block=%fm mesh=%d" % [
		seed_value, generator_id, view_distance_chunks, view_distance_vertical_ratio,
		world_y_min, world_y_max, world_height(), sea_level, quality_tier, block_size, mesh_block_size,
	]
