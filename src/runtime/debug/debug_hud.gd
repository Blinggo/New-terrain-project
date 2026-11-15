extends CanvasLayer
## src/runtime/debug/debug_hud.gd
##
## M00 / T7, reworked in M01 (reviewer Task 0.4): the M00 HUD covered ~40% of a 1280x720
## frame, which on a phone is unusable. It now has four modes, cycled by F1 or by tapping
## the panel on touch devices:
##
##   COMPACT (default)  4 lines: fps (+HUD self-cost), frame p95, position, loaded blocks
##   FULL               everything M00 showed, incl. the raw VoxelTerrain statistics dict
##   PIPELINE           M01: resolved module order, id/version/phase, published channels,
##                      per-module timing
##   OFF                hidden
##
## The whole panel scales with the viewport (font size, margins, padding) via
## compute_scale_for(), so a 720p desktop and a 360p-ish phone portrait window both get a
## readable, proportionate overlay.
##
## It still MEASURES ITSELF: _hud_cost_ms is the amortised cost per frame of our own text
## work, printed in every mode that shows text, against FRAME_BUDGET_MS.
##
## LAYER: runtime/debug. No Voxel Tools references: everything arrives as plain Dictionaries
## from world.gd (which gets them from src/adapters/).

const ROLLING_FRAMES := 120
const TEXT_UPDATES_PER_SECOND := 10.0
const FRAME_BUDGET_MS := 0.3

enum Mode { COMPACT, FULL, PIPELINE, OFF }
const MODE_NAMES := ["compact", "full", "pipeline", "off"]

## Reference design size; the scale factor is relative to this.
const REF_VIEWPORT := Vector2(1280.0, 720.0)
const MIN_SCALE := 0.55
const MAX_SCALE := 2.0
const BASE_FONT_COMPACT := 15.0
const BASE_FONT_FULL := 13.0
const BASE_FONT_HELP := 12.0

var _world: Node = null
var _panel: Panel = null
var _label: Label = null
var _help_label: Label = null

var _mode: int = Mode.COMPACT
var _touch_active := false

var _frame_times := PackedFloat32Array()
var _frame_index := 0
var _frame_count := 0
var _since_text_update := 0
var _accum_ms := 0.0
var _hud_cost_ms := 0.0
var _worst_ms := 0.0


func _ready() -> void:
	layer = 10
	_frame_times.resize(ROLLING_FRAMES)
	_frame_times.fill(0.0)

	_panel = Panel.new()
	_panel.name = "HUDPanel"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.62)
	sb.set_corner_radius_all(4)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	# IGNORE on desktop so the panel never eats mouse-look clicks; STOP on touch devices so
	# a tap on the HUD cycles the mode (Task 0.4).
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.gui_input.connect(_on_panel_gui_input)
	add_child(_panel)

	_label = Label.new()
	_label.name = "HUDText"
	_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)

	_help_label = Label.new()
	_help_label.name = "HUDHelp"
	_help_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_help_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.72))
	_help_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help_label.text = (
		"WASD move | Space/Q up | Ctrl/E down | Shift boost | Wheel speed | Mouse look (Esc release)\n"
		+ "F1 HUD mode  F2 screenshot  F3 generator  F4 view distance  F5 new seed  F6 far teleport  F7 wireframe\n"
		+ "N noclip/gravity+collision  T touch overlay"
	)
	add_child(_help_label)

	get_viewport().size_changed.connect(_apply_scale)
	_apply_scale()
	_rebuild_text()


## world.gd injects itself so the HUD never has to know the scene layout.
func set_world(world: Node) -> void:
	_world = world


func set_touch_active(active: bool) -> void:
	_touch_active = active
	if _panel != null:
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP if active else Control.MOUSE_FILTER_IGNORE
	_apply_scale()


func cycle_mode() -> void:
	_mode = (_mode + 1) % Mode.size()
	_apply_visibility()
	_rebuild_text()
	print("debug_hud: mode = %s" % mode_name())


func set_mode(m: int) -> void:
	_mode = clampi(int(m), 0, Mode.size() - 1)
	_apply_visibility()
	_rebuild_text()


func get_mode() -> int:
	return _mode


func mode_name() -> String:
	return MODE_NAMES[_mode]


## Kept for the M00 test that toggled visibility; OFF mode is now the canonical hide.
func toggle() -> void:
	if _mode == Mode.OFF:
		set_mode(Mode.COMPACT)
	else:
		set_mode(Mode.OFF)


func is_hud_visible() -> bool:
	return _mode != Mode.OFF


## Pure so tests can assert the scaling law without a window.
static func compute_scale_for(vp: Vector2) -> float:
	if vp.x <= 0.0 or vp.y <= 0.0:
		return 1.0
	return clampf(minf(vp.x / REF_VIEWPORT.x, vp.y / REF_VIEWPORT.y), MIN_SCALE, MAX_SCALE)


func ui_scale() -> float:
	var vp := get_viewport()
	if vp == null:
		return 1.0
	return compute_scale_for(Vector2(vp.get_visible_rect().size))


func measured_cost_ms() -> float:
	return _hud_cost_ms


func _on_panel_gui_input(event: InputEvent) -> void:
	if not _touch_active:
		return
	if event is InputEventScreenTouch and event.pressed:
		cycle_mode()


func _apply_visibility() -> void:
	visible = _mode != Mode.OFF
	if _help_label != null:
		_help_label.visible = _mode == Mode.FULL


func _apply_scale() -> void:
	if _panel == null:
		return
	var s := ui_scale()
	var sb: StyleBoxFlat = _panel.get_theme_stylebox("panel")
	sb.set_content_margin_all(8.0 * s)
	_label.position = Vector2(10.0 * s, 8.0 * s)
	_label.add_theme_font_size_override("font_size", int(round(
		BASE_FONT_COMPACT * s if _mode == Mode.COMPACT else BASE_FONT_FULL * s)))
	_help_label.add_theme_font_size_override("font_size", int(round(BASE_FONT_HELP * s)))
	_help_label.position = Vector2(10.0 * s, -96.0 * s)


func _process(delta: float) -> void:
	if _mode == Mode.OFF:
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
	# device can least afford it.
	if _since_text_update >= maxi(2, int(round(Engine.get_frames_per_second() / TEXT_UPDATES_PER_SECOND))):
		_rebuild_text()
		_hud_cost_ms = float(Time.get_ticks_usec() - t0) / 1000.0 / float(_since_text_update)
		_since_text_update = 0
		_accum_ms = 0.0


# --- text -------------------------------------------------------------------------------

func _rebuild_text() -> void:
	if _label == null:
		return
	match _mode:
		Mode.COMPACT:
			_label.text = _compact_text()
		Mode.FULL:
			_label.text = _full_text()
		Mode.PIPELINE:
			_label.text = _pipeline_text()
		_:
			_label.text = ""
	_apply_scale()
	_resize_panel_to_label()


func _resize_panel_to_label() -> void:
	var s := ui_scale()
	var min_size: Vector2 = _label.get_minimum_size()
	_panel.size = min_size + Vector2(20.0 * s, 16.0 * s)


func _cost_tag() -> String:
	var over := _hud_cost_ms > FRAME_BUDGET_MS
	return "hud %.3f ms%s" % [_hud_cost_ms, " OVER" if over else ""]


func _compact_text() -> String:
	var fps := Engine.get_frames_per_second()
	var p95 := _percentile(95)
	var pos := Vector3.ZERO
	var blocks := 0
	if _world != null:
		var cam: Node3D = _world.fly_camera()
		if cam != null:
			pos = cam.global_position
		blocks = _world.loaded_block_count()
	return (
		"fps %.1f  (%s)\n" % [fps, _cost_tag()]
		+ "frame p95 %.1f ms\n" % p95
		+ "pos (%.0f, %.0f, %.0f)\n" % [pos.x, pos.y, pos.z]
		+ "blocks %d" % blocks
	)


func _full_text() -> String:
	var lines: Array[String] = []
	var fps := Engine.get_frames_per_second()
	var over := _hud_cost_ms > FRAME_BUDGET_MS
	lines.append("VoxelTerrain M01   HUD cost %.3f ms/frame (budget %.1f%s)   mode=full" % [
		_hud_cost_ms, FRAME_BUDGET_MS, "  OVER" if over else "  ok"])
	lines.append("")
	lines.append("FPS    %.0f    frame avg %.2f ms   p95 %.2f ms   worst %.2f ms (%d frames)" % [
		fps, _mean_frame(), _percentile(95), _worst_ms, ROLLING_FRAMES])
	var info_draw := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var info_prim := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var info_obj := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	lines.append("draw calls %d    primitives %.1fk    objects %.1fk" % [
		int(info_draw), float(info_prim) / 1000.0, float(info_obj) / 1000.0])
	lines.append("static mem %.1f MB  peak %.1f MB  video mem %.1f MB" % [
		float(OS.get_static_memory_usage()) / 1048576.0,
		float(OS.get_static_memory_peak_usage()) / 1048576.0,
		float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0])
	lines.append("")

	if _world == null:
		lines.append("(no world bound)")
		return "\n".join(lines)

	var cam: Node3D = _world.fly_camera()
	var cfg: WorldConfig = _world.config
	lines.append("pos    %s m" % str(cam.global_position))
	lines.append("chunk  %s   voxel %s" % [
		str(_chunk_of(cam.global_position)), str(_voxel_of(cam.global_position))])
	lines.append("seed   %d   tier %s" % [cfg.seed_value, cfg.quality_tier])
	lines.append("gen    %s" % _world.generator_display_name())
	lines.append("view   %d chunks (%s; tier '%s' default %d)   vertical ratio %.2f   world y [%d,%d)" % [
		cfg.effective_view_distance_chunks(), cfg.view_distance_source, cfg.quality_tier,
		cfg.tier_view_distance_chunks(), cfg.view_distance_vertical_ratio, cfg.world_y_min, cfg.world_y_max])
	lines.append("blocks loaded %d   voxel payload %.1f MB" % [
		_world.loaded_block_count(), _world.loaded_block_count() * 4096.0 / 1048576.0])
	lines.append("")
	lines.append("VoxelTerrain.get_statistics():")
	var stats: Dictionary = _world.terrain_statistics()
	for k in stats:
		lines.append("  %-28s %s" % [k, str(stats[k])])
	lines.append("")
	lines.append("startup errors: %d" % _world.startup_errors().size())
	return "\n".join(lines)


func _pipeline_text() -> String:
	var lines: Array[String] = []
	lines.append("resolved worldgen pipeline   (%s)" % _cost_tag())
	if _world == null or not _world.has_method("pipeline_dump"):
		lines.append("(world exposes no pipeline)")
		return "\n".join(lines)
	var dump: Array = _world.pipeline_dump()
	if dump.is_empty():
		lines.append("(pipeline not resolved - registry empty?)")
		return "\n".join(lines)
	var timings: Dictionary = _world.pipeline_timings() if _world.has_method("pipeline_timings") else {}
	lines.append("order  id (v)                    phase     provides")
	for i in dump.size():
		var m: Dictionary = dump[i]
		lines.append("  %2d   %-24s v%d  %-9s %s" % [
			i + 1, String(m.get("id", "?")), int(m.get("version", 0)),
			String(m.get("phase", "?")), str(m.get("provides", []))])
	lines.append("")
	lines.append("column multiplication factor: %s" % str(_world.pipeline_column_factor() if _world.has_method("pipeline_column_factor") else "?"))
	lines.append("per-module timing (last region/column batch):")
	if timings.is_empty():
		lines.append("  (none recorded yet - the graph backend compiles modules, it does not run them)")
	for k in timings:
		lines.append("  %-24s %.3f ms" % [k, float(timings[k]) / 1000.0])
	return "\n".join(lines)


# --- stats helpers ----------------------------------------------------------------------

func _mean_frame() -> float:
	var sum := 0.0
	var n := 0
	for i in _frame_count if _frame_count < ROLLING_FRAMES else ROLLING_FRAMES:
		sum += _frame_times[i]
		n += 1
	return sum / float(maxi(1, n))


func _percentile(p: int) -> float:
	var taken := mini(_frame_count, ROLLING_FRAMES)
	if taken == 0:
		return 0.0
	var sorted := PackedFloat32Array()
	for i in taken:
		sorted.append(_frame_times[i])
	sorted.sort()
	var idx := clampi(int(float(taken - 1) * float(p) / 100.0), 0, taken - 1)
	return sorted[idx]


func _chunk_of(pos: Vector3) -> Vector3i:
	return Vector3i(int(floor(pos.x / 16.0)), int(floor(pos.y / 16.0)), int(floor(pos.z / 16.0)))


func _voxel_of(pos: Vector3) -> Vector3i:
	return Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
