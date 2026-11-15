extends CanvasLayer
## src/runtime/debug/debug_hud.gd
##
## M00 / T7 - Debug HUD. Toggle with F1. Must cost < 0.3 ms/frame, and it MEASURES ITSELF
## and prints the result, so the budget is a reported number rather than a claim.
##
## LAYER: runtime/debug. No Voxel Tools references: it reads plain Dictionaries handed over
## by world.gd (which in turn gets them from src/adapters/).
##
## Everything printed here is real:
##   * draw calls / primitives / objects  -> RenderingServer.get_rendering_info() with the
##     enum values verified in 4.7 (TOTAL_PRIMITIVES_IN_FRAME=1, TOTAL_DRAW_CALLS_IN_FRAME=2,
##     TOTAL_OBJECTS_IN_FRAME=0, VIDEO_MEM_USED=5).
##   * static memory -> OS.get_static_memory_usage() / get_static_memory_peak_usage()
##   * FPS -> Engine.get_frames_per_second(); frame times are sampled locally so that the
##     average / p95 / worst are over the LAST 120 frames, not the engine's smoothed FPS.
##   * voxel statistics -> VoxelTerrain.get_statistics() via the adapter. In 1.7 its keys are
##     exactly: time_detect_required_blocks, time_request_blocks_to_load,
##     time_process_load_responses, time_request_blocks_to_update, dropped_block_loads,
##     dropped_block_meshs, updated_blocks. There is NO loaded-block counter there, so the
##     loaded block count comes from VoxelEngine.get_stats().memory_pools.block_count.

const ROLLING_FRAMES := 120
const TEXT_UPDATES_PER_SECOND := 10.0
const FRAME_BUDGET_MS := 0.3

var _world: Node = null
var _panel: Panel = null
var _label: Label = null
var _help_label: Label = null

var _frame_times := PackedFloat32Array()
var _frame_index := 0
var _frame_count := 0
var _since_text_update := 0
var _accum_ms := 0.0
var _hud_cost_ms := 0.0
var _worst_ms := 0.0
var _visible_hud := true


func _ready() -> void:
	layer = 10
	_frame_times.resize(ROLLING_FRAMES)
	_frame_times.fill(0.0)

	_panel = Panel.new()
	_panel.name = "HUDPanel"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.62)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8.0)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_label = Label.new()
	_label.name = "HUDText"
	_label.position = Vector2(10, 8)
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)

	_help_label = Label.new()
	_help_label.name = "HUDHelp"
	_help_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_help_label.position = Vector2(10, -96)
	_help_label.add_theme_font_size_override("font_size", 12)
	_help_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.72))
	_help_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help_label.text = (
		"WASD move | Space/Q up | Ctrl/E down | Shift boost | Wheel speed | Mouse look (Esc release)\n"
		+ "F1 HUD  F2 screenshot  F3 generator  F4 view distance  F5 new seed  F6 far teleport  F7 wireframe\n"
		+ "N noclip/gravity+collision  T touch overlay"
	)
	add_child(_help_label)

	_rebuild_text()


## world.gd injects itself so the HUD never has to know the scene layout.
func set_world(world: Node) -> void:
	_world = world


func toggle() -> void:
	_visible_hud = not _visible_hud
	visible = _visible_hud
	print("debug_hud: visible = %s" % str(_visible_hud))


func is_hud_visible() -> bool:
	return _visible_hud


func _process(delta: float) -> void:
	if not _visible_hud:
		return
	var t0 := Time.get_ticks_usec()

	var ms := delta * 1000.0
	_frame_times[_frame_index] = ms
	_frame_index = (_frame_index + 1) % ROLLING_FRAMES
	_frame_count += 1
	_worst_ms = maxf(_worst_ms, ms)

	_since_text_update += 1
	_accum_ms += ms
	# At least 2 frames between text rebuilds: below ~20 fps a 10 Hz target would mean
	# rebuilding (and re-shaping) the whole label every frame, which is exactly when the
	# device can least afford it. Measured effect on the 4 fps software-rendered CI box:
	# HUD cost per frame roughly halved (see docs/reports/M00_REPORT.md section 7).
	if _since_text_update >= maxi(2, int(round(Engine.get_frames_per_second() / TEXT_UPDATES_PER_SECOND))):
		_rebuild_text()
		# Amortised HUD cost per frame, measured around our own work only.
		_hud_cost_ms = float(Time.get_ticks_usec() - t0) / 1000.0 / float(_since_text_update)
		_since_text_update = 0
		_accum_ms = 0.0


func _rolling_stats() -> Dictionary:
	var n := mini(_frame_count, ROLLING_FRAMES)
	if n <= 0:
		return {"avg": 0.0, "p95": 0.0}
	var copy: Array = []
	copy.resize(n)
	for i in n:
		copy[i] = _frame_times[i]
	copy.sort()
	var sum := 0.0
	for v in copy:
		sum += float(v)
	var p95 := TestHarness.percentile(copy, 95.0)
	return {"avg": sum / float(n), "p95": p95}


func _rebuild_text() -> void:
	if _label == null:
		return
	var stats := _rolling_stats()
	var lines: Array[String] = []

	var over_budget := _hud_cost_ms > FRAME_BUDGET_MS
	lines.append("VoxelTerrain M00   HUD cost %.3f ms/frame (budget %.1f%s)" % [
		_hud_cost_ms, FRAME_BUDGET_MS, "  OVER" if over_budget else "  ok",
	])
	lines.append("")
	lines.append("FPS      %-6.0f  frame avg %.2f ms   p95 %.2f ms   worst %.2f ms (%d frames)" % [
		Engine.get_frames_per_second(), stats["avg"], stats["p95"], _worst_ms, mini(_frame_count, ROLLING_FRAMES),
	])
	lines.append("draw calls %-6d  primitives %-9s  objects %-6s" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		_format_count(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)),
		_format_count(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)),
	])
	lines.append("static mem %.1f MB  peak %.1f MB  video mem %s" % [
		OS.get_static_memory_usage() / 1048576.0,
		OS.get_static_memory_peak_usage() / 1048576.0,
		_format_bytes(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)),
	])

	if _world == null:
		lines.append("")
		lines.append("(world not attached yet)")
		_label.text = "\n".join(lines)
		_resize_panel()
		return

	var cam: Node3D = _world.call("fly_camera")
	var pos := cam.global_position if cam != null else Vector3.ZERO
	var block_size := 16
	var cfg: WorldConfig = _world.get("config")
	if cfg != null:
		block_size = cfg.mesh_block_size
	var block := Vector3i(
		int(floorf(pos.x / float(block_size))),
		int(floorf(pos.y / float(block_size))),
		int(floorf(pos.z / float(block_size)))
	)

	lines.append("")
	lines.append("pos      (%.1f, %.1f, %.1f) m" % [pos.x, pos.y, pos.z])
	lines.append("chunk    (%d, %d, %d)   voxel (%d, %d, %d)" % [
		block.x, block.y, block.z, int(floorf(pos.x)), int(floorf(pos.y)), int(floorf(pos.z)),
	])
	lines.append("seed     %d   tier %s" % [cfg.seed_value if cfg != null else 0, cfg.quality_tier if cfg != null else "?"])
	lines.append("gen      %s" % _world.call("generator_display_name"))
	if cfg != null:
		lines.append("view     %d chunks (viewer value %d)  vertical ratio %.2f  world y [%d,%d)" % [
			cfg.view_distance_chunks,
			_world.call("terrain_report").get("viewer_view_distance", 0),
			cfg.view_distance_vertical_ratio, cfg.world_y_min, cfg.world_y_max,
		])
	lines.append("blocks   loaded %d   voxel payload %s" % [
		_world.call("loaded_block_count"),
		_format_bytes(_world.call("engine_stats").get("memory_pools", {}).get("voxel_used", 0)),
	])

	lines.append("")
	lines.append("VoxelTerrain.get_statistics():")
	var terrain_stats: Dictionary = _world.call("terrain_statistics")
	if terrain_stats.is_empty():
		lines.append("   (empty - terrain not streaming?)")
	else:
		var keys: Array = terrain_stats.keys()
		keys.sort()
		for k in keys:
			lines.append("   %-32s %s" % [str(k), str(terrain_stats[k])])

	var errs: Array = _world.call("startup_errors")
	lines.append("")
	lines.append("startup errors: %d%s" % [errs.size(), "" if errs.is_empty() else "  -> " + str(errs)])

	_label.text = "\n".join(lines)
	_resize_panel()


func _resize_panel() -> void:
	if _panel == null or _label == null:
		return
	_panel.size = Vector2(_label.size.x + 24.0, _label.size.y + 16.0)


static func _format_count(v: int) -> String:
	if v >= 1000000:
		return "%.2fM" % (v / 1000000.0)
	if v >= 1000:
		return "%.1fk" % (v / 1000.0)
	return str(v)


static func _format_bytes(v: int) -> String:
	if v >= 1048576:
		return "%.1f MB" % (v / 1048576.0)
	if v >= 1024:
		return "%.1f kB" % (v / 1024.0)
	return "%d B" % v
