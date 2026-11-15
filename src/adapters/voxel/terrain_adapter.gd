class_name TerrainAdapter
extends RefCounted
## src/adapters/voxel/terrain_adapter.gd
##
## M00 / T4 - Creates and owns the Voxel Tools node graph for a streaming blocky world:
##
##     VoxelTerrain  (+ VoxelMesherBlocky + generated VoxelBlockyLibrary + VoxelFormat)
##     VoxelViewer   (the thing that tells the terrain where to load; parented to the camera)
##
## LAYER: adapters. Above this file, the terrain is only ever a `Node3D` and the generator
## only ever a `Resource`. That is the swap point promised in ADR-0002: if a C++ GDExtension
## ever replaces Voxel Tools, this file (plus the two generator adapters and the library
## builder) is what gets rewritten - not the runtime, not the worldgen modules.
##
## 1.7 SPECIFICS, all verified against docs/reports/voxel_api_dump.json:
##   * generator / mesher / stream / format live on VoxelNode, NOT on VoxelTerrain.
##   * view distance is requested by a VoxelViewer NODE (VoxelViewer.view_distance) and
##     clamped by VoxelTerrain.max_view_distance. There is no VoxelTerrain.view_distance.
##   * VoxelBlockyLibraryManager does NOT exist in 1.7 (the class is absent from ClassDB).
##   * `stream` is left UNSET on purpose: persistence is deferred to M12. Nothing in M00
##     saves or loads.

## Whether VoxelViewer.view_distance is expressed in voxels (true) or in data blocks
## (false). Determined empirically with tools/probe_streaming.gd, not assumed - see the
## M00 report section 3.
const VIEW_DISTANCE_IN_VOXELS := true

const COLLISION_LAYER := 1
const COLLISION_MASK := 1

var _terrain: Node3D = null
var _viewer: Node3D = null
var _mesher: Resource = null
var _library: Resource = null
var _report := {}
## VoxelEngine is a plain Object (not RefCounted), so it must be freed explicitly.
var _engine: Object = null


## Build the terrain + viewer nodes. They are returned NOT parented; the caller (runtime)
## adds them to the scene tree.
##   generator: a plain Resource (a VoxelGenerator, but the type is not named here so this
##              file's callers stay clean).
## Returns {"ok": bool, "terrain": Node3D, "viewer": Node3D, "report": Dictionary}.
func create(context: Dictionary, generator: Resource, library_result: Dictionary) -> Dictionary:
	_report = {
		"errors": [] as Array[String],
		"notes": [] as Array[String],
		"terrain_class": "",
		"mesher_class": "",
		"viewer_class": "",
		"stream": "unset (persistence deferred to M12)",
	}

	var ok := true
	if generator == null:
		_report["errors"].append("no generator supplied")
		ok = false

	var lib: Variant = library_result.get("library", null)
	if lib == null:
		_report["errors"].append("block library is null; nothing would render")
		ok = false
	_library = lib

	var mesh_block_size := int(context.get("mesh_block_size", 16))
	var view_distance_chunks := int(context.get("view_distance_chunks", 8))
	var vertical_ratio := float(context.get("view_distance_vertical_ratio", 1.0))
	var world_y_min := int(context.get("world_y_min", -64))
	var world_y_max := int(context.get("world_y_max", 320))
	var half_extent := int(context.get("bounds_half_extent_xz", 16777216))
	var type_depth_bits := int(context.get("type_depth_bits", 8))

	# --- format ------------------------------------------------------------------------
	# The engine default for the TYPE channel is 16-bit (verified: VoxelFormat.type_depth
	# defaults to DEPTH_16_BIT). M00 has 10 block ids, so 8-bit halves the memory and the
	# streaming bandwidth of the biggest channel in a 384-block-tall world. Ceiling: 255
	# ids - revisit when attribute variants push the id map past that (M09+).
	var format := VoxelFormat.new()
	format.type_depth = VoxelBuffer.DEPTH_8_BIT if type_depth_bits <= 8 else VoxelBuffer.DEPTH_16_BIT

	# --- mesher ------------------------------------------------------------------------
	var mesher := VoxelMesherBlocky.new()
	mesher.library = lib
	mesher.occlusion_enabled = true
	# Vertex ambient occlusion. Verified default and range with tools/probe_generators.gd.
	mesher.occlusion_darkness = float(context.get("occlusion_darkness", 0.45))
	_mesher = mesher

	# --- terrain -----------------------------------------------------------------------
	var terrain := VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.format = format
	terrain.generator = generator
	terrain.mesher = mesher
	# stream deliberately left null. See the class comment.
	terrain.generate_collisions = bool(context.get("generate_collisions", true))
	terrain.collision_layer = COLLISION_LAYER
	terrain.collision_mask = COLLISION_MASK
	terrain.automatic_loading_enabled = bool(context.get("automatic_loading_enabled", true))
	terrain.set_mesh_block_size(mesh_block_size)
	# Bounds: effectively infinite in X/Z, exactly the 384-block column in Y. Blocks
	# outside the bounds are never generated even with an infinite generator.
	var bounds := AABB(
		Vector3(-half_extent, world_y_min, -half_extent),
		Vector3(half_extent * 2, world_y_max - world_y_min, half_extent * 2)
	)
	terrain.set_bounds(bounds)
	terrain.set_max_view_distance(_max_view_distance_voxels(view_distance_chunks, mesh_block_size))

	# --- viewer ------------------------------------------------------------------------
	# VoxelViewer is a Node3D; the runtime parents it to the fly camera so it follows the
	# player exactly. requires_visuals + requires_collisions = local player.
	var viewer := VoxelViewer.new()
	viewer.name = "VoxelViewer"
	viewer.requires_visuals = true
	viewer.requires_collisions = bool(context.get("generate_collisions", true))
	viewer.view_distance = _view_distance_value(view_distance_chunks, mesh_block_size)
	viewer.view_distance_vertical_ratio = vertical_ratio

	_terrain = terrain
	_viewer = viewer

	_report["terrain_class"] = terrain.get_class()
	_report["mesher_class"] = mesher.get_class()
	_report["viewer_class"] = viewer.get_class()
	_report["library_class"] = lib.get_class() if lib != null else "null"
	_report["type_depth"] = _depth_name(format.get_channel_depth(VoxelBuffer.CHANNEL_TYPE))
	_report["mesh_block_size"] = mesh_block_size
	_report["bounds"] = "%s size %s" % [str(bounds.position), str(bounds.size)]
	_report["viewer_view_distance"] = viewer.view_distance
	_report["viewer_vertical_ratio"] = viewer.view_distance_vertical_ratio
	_report["terrain_max_view_distance"] = terrain.get_max_view_distance()
	_report["occlusion_enabled"] = mesher.occlusion_enabled
	_report["occlusion_darkness"] = mesher.occlusion_darkness
	_report["generate_collisions"] = terrain.generate_collisions
	_report["max_view_distance_note"] = (
		"VoxelTerrain.max_view_distance is documented in voxels; VoxelViewer.view_distance units "
		+ ("treated as voxels" if VIEW_DISTANCE_IN_VOXELS else "treated as data blocks")
	)

	return {"ok": ok and _report["errors"].is_empty(), "terrain": terrain, "viewer": viewer, "report": _report}


func _view_distance_value(chunks: int, mesh_block_size: int) -> int:
	if VIEW_DISTANCE_IN_VOXELS:
		return chunks * mesh_block_size
	return chunks


func _max_view_distance_voxels(chunks: int, mesh_block_size: int) -> int:
	# Generous ceiling so the F4 cycle (6/8/12) never gets clamped mid-session.
	return max(chunks, 16) * mesh_block_size * 2


## Change view distance at runtime (F4). Applies to the viewer and re-clamps the terrain.
func apply_view_distance(chunks: int, mesh_block_size: int = 16, vertical_ratio: float = 1.0) -> int:
	if not is_instance_valid(_viewer):
		push_error("TerrainAdapter.apply_view_distance: no viewer was created")
		return 0
	var value := _view_distance_value(chunks, mesh_block_size)
	_viewer.set("view_distance", value)
	_viewer.set("view_distance_vertical_ratio", vertical_ratio)
	if is_instance_valid(_terrain):
		_terrain.call("set_max_view_distance", _max_view_distance_voxels(chunks, mesh_block_size))
	return value


## Swap the generator (F3 / F5). VoxelTerrain re-generates its loaded blocks.
func set_generator(generator: Resource) -> void:
	if not is_instance_valid(_terrain):
		push_error("TerrainAdapter.set_generator: no terrain was created")
		return
	_terrain.set("generator", generator)


func force_full_update() -> void:
	## Nudge the terrain to rebuild everything around the viewer. Used after a seed change
	## (F5) or a far teleport (F6) so stale blocks do not linger.
	if is_instance_valid(_terrain) and _terrain.has_method("reset_ground_chunks"):
		_terrain.call("reset_ground_chunks")


## VoxelTerrain.get_statistics() - the real 1.7 statistics method (verified in the dump).
func get_statistics() -> Dictionary:
	if not is_instance_valid(_terrain):
		return {}
	if not _terrain.has_method("get_statistics"):
		return {}
	var stats: Variant = _terrain.call("get_statistics")
	if stats is Dictionary:
		return stats
	return {}


## VoxelEngine.get_stats() - global engine counters. Verified structure (1.7):
##   {"memory_pools": {block_count, voxel_used, voxel_total, std_allocated, ...},
##    "tasks": {generation, meshing, streaming, main_thread, gpu},
##    "thread_pools": {general: {active_threads, tasks, thread_count, task_names}}}
## Loaded data blocks are NOT children of the terrain node in 1.7 (get_child_count() == 0),
## so memory_pools.block_count is the only real "how many blocks are loaded" metric.
func get_engine_stats() -> Dictionary:
	if _engine == null:
		_engine = ClassDB.instantiate("VoxelEngine")
	if _engine == null:
		return {}
	var s: Variant = _engine.call("get_stats")
	return s if s is Dictionary else {}


## M01-fix / T9 - Apply the quality tier's engine thread budget. VoxelEngine exposes exactly
## two scheduling knobs to GDScript: get_thread_count()/set_thread_count() (verified with
## tools/probe_native_cb7.gd - the full method list is get_stats, get/set_thread_count,
## get/set_threaded_graphics_resource_building_enabled and the version getters). There is NO
## per-frame task budget, which is why WorldConfig reports `max_gen_tasks_per_frame` as
## BLOCKED and wires this instead. Returns the thread count actually in effect afterwards.
func apply_engine_threads(count: int) -> int:
	if _engine == null:
		_engine = ClassDB.instantiate("VoxelEngine")
	if _engine == null:
		_report["engine_threads"] = {"requested": count, "applied": -1, "error": "VoxelEngine could not be instantiated"}
		return -1
	var wanted := clampi(count, 1, 64)
	_engine.call("set_thread_count", wanted)
	var applied := int(_engine.call("get_thread_count"))
	_report["engine_threads"] = {"requested": wanted, "applied": applied}
	return applied


func get_engine_thread_count() -> int:
	if _engine == null:
		_engine = ClassDB.instantiate("VoxelEngine")
	if _engine == null:
		return -1
	return int(_engine.call("get_thread_count"))


func get_loaded_block_count() -> int:
	var pools: Dictionary = get_engine_stats().get("memory_pools", {})
	return int(pools.get("block_count", 0))


func get_voxel_memory_used() -> int:
	var pools: Dictionary = get_engine_stats().get("memory_pools", {})
	return int(pools.get("voxel_used", 0))


func get_pending_task_counts() -> Dictionary:
	return get_engine_stats().get("tasks", {})


func get_terrain() -> Node3D:
	return _terrain


func get_viewer() -> Node3D:
	return _viewer


func get_report() -> Dictionary:
	return _report


func set_debug_draw_enabled(enabled: bool) -> void:
	if is_instance_valid(_terrain):
		_terrain.call("debug_set_draw_enabled", enabled)


## Free the non-RefCounted VoxelEngine handle. The terrain/viewer nodes themselves are
## owned by the runtime scene tree, not by this adapter.
func release() -> void:
	if _engine != null:
		_engine.free()
		_engine = null
	_terrain = null
	_viewer = null
	_mesher = null
	_library = null


static func _depth_name(d: int) -> String:
	match d:
		VoxelBuffer.DEPTH_8_BIT: return "8-bit"
		VoxelBuffer.DEPTH_16_BIT: return "16-bit"
		VoxelBuffer.DEPTH_32_BIT: return "32-bit"
		VoxelBuffer.DEPTH_64_BIT: return "64-bit"
	return "unknown(%d)" % d
