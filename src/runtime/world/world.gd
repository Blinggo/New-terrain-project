extends Node3D
## src/runtime/world/world.gd
##
## M00 / T4 - The world root. Loads configuration, asks src/adapters/ to build the voxel
## terrain, and wires the debug layer to it.
##
## LAYER: runtime. HARD CONSTRAINT (ADR-0002, docs/CONVENTIONS.md): this file must not name
## a single Voxel Tools class. The terrain is a `Node3D`, the generator is a `Resource`,
## statistics are a `Dictionary`. Everything Voxel-specific lives in src/adapters/voxel/.
##
## WHY THE VoxelTerrain NODE IS NOT IN world.tscn
## ----------------------------------------------
## T4 sketches VoxelTerrain inside world.tscn, but a .tscn that names VoxelTerrain,
## VoxelMesherBlocky and VoxelBlockyLibrary would put Voxel Tools types in the runtime
## layer and break the "only src/adapters/ touches Voxel Tools" rule that every later
## milestone depends on. So world.tscn contains a plain Node3D called `VoxelRoot`, and
## TerrainAdapter creates the real VoxelTerrain + VoxelViewer under it at _ready().
## Consequence: the scene still loads even if the extension is missing, and world.gd can
## report that failure instead of failing to parse.

const SPAWN := Vector3(8.0, 90.0, 8.0)
const SUN_ROTATION_DEG := Vector3(-52.0, -35.0, 0.0)
const SCREENSHOT_DIR_RES := "res://docs/reports/screenshots/"

@onready var _fly_camera: CharacterBody3D = $FlyCamera
@onready var _voxel_root: Node3D = $VoxelRoot
@onready var _sun: DirectionalLight3D = $DirectionalLight3D
@onready var _hud: CanvasLayer = $DebugHUD

var config: WorldConfig = null
var terrain_adapter := TerrainAdapter.new()

var _terrain: Node3D = null
var _viewer: Node3D = null
var _generator: Resource = null
var _generator_report := {}
var _library_report := {}
var _startup_errors: Array[String] = []
var _shot_counter := 0


func _ready() -> void:
	_sun.rotation_degrees = SUN_ROTATION_DEG
	_fly_camera.position = SPAWN

	_startup_log("M00 world boot")

	config = WorldConfig.load_config()
	for w in config.validation_warnings:
		push_warning("world: config warning: %s" % w)
	for e in config.validation_errors:
		push_error("world: config error: %s" % e)
		_startup_errors.append(e)

	_build_world(config)

	# Debug layer wiring. fly_camera.gd owns the F-keys and mouse/touch; world.gd owns the
	# world-level consequences, because only this layer knows about config and adapters.
	_fly_camera.hud_toggle_requested.connect(_on_hud_toggle)
	_fly_camera.screenshot_requested.connect(_on_screenshot_requested)
	_fly_camera.cycle_generator_requested.connect(_on_cycle_generator)
	_fly_camera.cycle_view_distance_requested.connect(_on_cycle_view_distance)
	_fly_camera.regenerate_seed_requested.connect(_on_regenerate_seed)
	_fly_camera.teleport_far_requested.connect(_on_teleport_far)
	_fly_camera.noclip_changed.connect(_on_noclip_changed)

	if _hud.has_method("set_world"):
		_hud.call("set_world", self)

	_startup_log("boot complete")
	print("world: startup errors = ", _startup_errors.size())


## Build (or rebuild) the whole voxel world for `cfg`. Called at boot and again by F3/F5.
func _build_world(cfg: WorldConfig) -> void:
	_teardown_world()

	var library_result := BlockLibraryBuilder.build()
	_library_report = library_result["report"]
	for e in _library_report["errors"]:
		push_error("world: block library: %s" % e)
		_startup_errors.append("block library: %s" % e)

	var gen_result := AdapterRegistry.build_generator(cfg.generator_id, cfg.seed_value, cfg.to_gen_context())
	_generator = gen_result["generator"]
	_generator_report = gen_result["report"]
	if not gen_result["ok"]:
		# Never leave the player staring at nothing: fall back to the guaranteed generator
		# and say so loudly.
		var fallback_id := AdapterRegistry.DEFAULT_ID
		push_error("world: generator '%s' failed to build (%s) - falling back to '%s'" % [
			cfg.generator_id, _generator_report.get("error", "unknown"), fallback_id,
		])
		_startup_errors.append("generator '%s' failed: %s" % [cfg.generator_id, _generator_report.get("error", "unknown")])
		if cfg.generator_id != fallback_id:
			gen_result = AdapterRegistry.build_generator(fallback_id, cfg.seed_value, cfg.to_gen_context())
			_generator = gen_result["generator"]
			_generator_report = gen_result["report"]
			cfg = cfg.with_generator(fallback_id)
			config = cfg

	var res := terrain_adapter.create(cfg.to_terrain_context(), _generator, library_result)
	for e in res["report"]["errors"]:
		push_error("world: terrain: %s" % e)
		_startup_errors.append("terrain: %s" % e)

	_terrain = res["terrain"]
	_viewer = res["viewer"]
	if _terrain != null:
		_voxel_root.add_child(_terrain)
	if _viewer != null:
		# The viewer rides along with the fly camera, so streaming always centres on the
		# player - and only on the player (hard rule #5: generation never depends on the
		# player position; *streaming* legitimately does).
		_fly_camera.add_child(_viewer)

	_fly_camera.apply_config(cfg)
	print("world: terrain ready - %s" % cfg.describe())
	print("world: generator = %s" % generator_display_name())
	print("world: library = %s" % str(_library_report))
	print("world: terrain = %s" % str(res["report"]))


func _teardown_world() -> void:
	if _viewer != null and is_instance_valid(_viewer):
		_viewer.queue_free()
	if _terrain != null and is_instance_valid(_terrain):
		_terrain.queue_free()
	_viewer = null
	_terrain = null
	if is_instance_valid(terrain_adapter):
		terrain_adapter.release()
	terrain_adapter = TerrainAdapter.new()


# --- state exposed to the debug HUD (all plain types) ---------------------------------

func generator_id() -> String:
	return config.generator_id if config != null else "?"


func generator_display_name() -> String:
	var adapter: IGeneratorAdapter = AdapterRegistry.create(generator_id())
	return adapter.get_display_name() if adapter != null else generator_id()


func generator_report() -> Dictionary:
	return _generator_report


func library_report() -> Dictionary:
	return _library_report


func terrain_report() -> Dictionary:
	return terrain_adapter.get_report()


func terrain_statistics() -> Dictionary:
	return terrain_adapter.get_statistics()


func engine_stats() -> Dictionary:
	return terrain_adapter.get_engine_stats()


func loaded_block_count() -> int:
	return terrain_adapter.get_loaded_block_count()


func startup_errors() -> Array[String]:
	return _startup_errors


func terrain_node() -> Node3D:
	return _terrain


func fly_camera() -> CharacterBody3D:
	return _fly_camera


# --- F-key handlers -------------------------------------------------------------------

func _on_hud_toggle() -> void:
	if _hud.has_method("toggle"):
		_hud.call("toggle")


func _on_screenshot_requested() -> void:
	_shot_counter += 1
	await _save_screenshot("f2_%03d" % _shot_counter)


## Grab the viewport after the frame has been drawn. Falls back to user:// when res:// is
## read-only (exported build), because res:// only exists in the editor/CI.
func _save_screenshot(tag: String) -> String:
	await RenderingServer.frame_post_draw
	var viewport := get_viewport()
	if viewport == null:
		push_error("world: no viewport, cannot take a screenshot")
		return ""
	var image := viewport.get_texture().get_image()
	if image == null:
		push_error("world: viewport image is null")
		return ""

	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "")
	var name := "%s_%s_seed%d_%s.png" % [stamp, tag, config.seed_value if config else 0, generator_id()]

	var dir := DirAccess.open("res://")
	var target_dir := SCREENSHOT_DIR_RES
	if dir == null or not dir.file_exists(SCREENSHOT_DIR_RES.trim_suffix("/")):
		# Directory may not exist; try to create it, else fall back to user://.
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCREENSHOT_DIR_RES)) != OK:
			target_dir = "user://screenshots/"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target_dir))

	var path := target_dir + name
	var err := image.save_png(ProjectSettings.globalize_path(path))
	if err != OK:
		path = "user://screenshots/" + name
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://screenshots/"))
		err = image.save_png(ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("world: screenshot save failed (%d)" % err)
		return ""
	print("world: screenshot saved -> %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	return path


func _on_cycle_generator() -> void:
	if config == null:
		return
	rebuild_with_config(config.with_generator(AdapterRegistry.next_id(config.generator_id)), "F3")


## Rebuild the whole terrain from a new config. This is the one place the world can change
## generator or view distance at runtime, and it is what the benchmarks drive (T9.2 switches
## view distance through here, so the benchmark measures the same code path the player's F4
## key does rather than a test-only shortcut).
## `reason` is only used for the log line.
func rebuild_with_config(next: WorldConfig, reason: String = "api") -> void:
	if next == null:
		push_error("world: rebuild_with_config got a null config")
		return
	config = next
	_startup_log("%s -> rebuilding world with %s" % [reason, config.describe()])
	_build_world(config)


func _on_cycle_view_distance() -> void:
	if config == null:
		return
	set_view_distance(config.next_view_distance(), "F4")


## Apply a view distance through the same code path the F4 key uses. Public so benchmarks
## and the screenshot tool can drive exactly what the player can drive - no test-only route
## into the terrain.
func set_view_distance(chunks: int, reason: String = "api") -> int:
	if config == null:
		return -1
	config = config.with_view_distance(chunks)
	var applied := terrain_adapter.apply_view_distance(chunks, config.mesh_block_size, config.view_distance_vertical_ratio)
	print("world: %s -> view distance %d chunks (viewer distance value %d)" % [reason, chunks, applied])
	return applied


func _on_regenerate_seed() -> void:
	if config == null:
		return
	# A debug-only source of variety. This lives in the runtime/debug layer, never in
	# generation code: the seed is then an explicit integer input, as hard rule #5 requires.
	var new_seed := int(Time.get_ticks_usec() % 1000000007)
	config = config.with_seed(new_seed)
	print("world: F5 -> new seed %d" % new_seed)
	_build_world(config)


func _on_teleport_far() -> void:
	# Deterministic-ish far jump used to prove the world has no tiling or coordinate cliff.
	# The offsets are hashed from the current position, never random, so a replay of the
	# same session lands in the same places.
	var current := _fly_camera.global_position
	var hx := Hash64.hash_int(int(current.x))
	var hz := Hash64.hash_int(int(current.z))
	var x := float((hx % 200001) - 100000)
	var z := float((hz % 200001) - 100000)
	var target := Vector3(x, current.y, z)
	_fly_camera.teleport_to(target)
	print("world: F6 -> teleported to %s (|x|=%d, |z|=%d)" % [str(target), absi(int(x)), absi(int(z))])


func _on_noclip_changed(noclip: bool) -> void:
	print("world: noclip = %s (collision test %s)" % [str(noclip), "OFF" if noclip else "ON"])


func _startup_log(msg: String) -> void:
	print("world: %s" % msg)


func _exit_tree() -> void:
	_teardown_world()
