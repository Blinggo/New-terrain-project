extends CharacterBody3D
## src/runtime/debug/fly_camera.gd
##
## M00 / T6 - Debug fly camera: desktop keyboard+mouse AND mobile touch. Noclip by default
## with a toggle into gravity+collision so terrain collision can be verified (A6).
##
## LAYER: runtime/debug. Contains NO Voxel Tools references - it only moves a
## CharacterBody3D and emits signals. world.gd decides what the F-keys mean.
##
## DESKTOP
##   W/A/S/D          planar move (camera-relative)
##   Space / Q        up          Ctrl / E       down
##   Shift            boost (x4)
##   Mouse            look (captured). Left click re-captures, Esc releases.
##   Mouse wheel      cycle speed presets 2 / 8 / 32 / 128 / 512 m/s
##   N                toggle noclip <-> gravity+collision
##   T                toggle the touch overlay (for testing mobile controls on desktop)
##
## MOBILE / TOUCH EMULATION
##   left half drag   virtual stick -> planar movement
##   right half drag  look
##   bottom-right buttons  ASCEND / DESCEND (held)
##   Works with the editor's "Emulate Touch From Mouse" (enabled in project.godot) and with
##   `godot --touch`.
##
## F-KEYS (all routed to world.gd as signals)
##   F1 HUD   F2 screenshot   F3 cycle generator   F4 cycle view distance 6/8/12
##   F5 new seed   F6 teleport to a far location (proves infinity)   F7 wireframe

signal hud_toggle_requested
signal screenshot_requested
signal cycle_generator_requested
signal cycle_view_distance_requested
signal regenerate_seed_requested
signal teleport_far_requested
signal noclip_changed(noclip: bool)

const SPEED_PRESETS: Array[float] = [2.0, 8.0, 32.0, 128.0, 512.0]
const DEFAULT_SPEED_INDEX := 2  # 32 m/s, the speed the runtime benchmark uses
const BOOST_FACTOR := 4.0
const MOUSE_SENSITIVITY := 0.0022
const TOUCH_LOOK_SENSITIVITY := 0.005
const GRAVITY := 24.0  # m/s^2, heavier than 9.81 so a fall onto terrain reads clearly
const JUMP_SPEED := 9.0
const TERMINAL_SPEED := 60.0
const ASCEND_BUTTON := Rect2(-1.0, -1.0, 0.0, 0.0)  # filled in _ready from the viewport size

var speed_index: int = DEFAULT_SPEED_INDEX
var noclip: bool = true
var touch_mode: bool = false

var _camera: Camera3D = null
var _pitch := 0.0
var _stick_active := false
var _stick_id := -1
var _stick_origin := Vector2.ZERO
var _stick_vector := Vector2.ZERO
var _look_id := -1
var _look_last := Vector2.ZERO
var _touch_drag_active := false
var _ascend_held := false
var _descend_held := false
var _ascend_id := -1
var _descend_id := -1
var _ascend_rect := Rect2()
var _descend_rect := Rect2()
var _touch_layer: CanvasLayer = null
var _overlay: Control = null
var _viewport_size := Vector2(1280, 720)


## Touch overlay drawn in code so no extra scene/asset is needed. Inner class on purpose:
## the overlay is an implementation detail of this camera, not a reusable component.
class TouchOverlay:
	extends Control

	var owner_camera: Node = null

	func _draw() -> void:
		if owner_camera == null:
			return
		var cam := owner_camera
		var size := _overlay_size()
		# Left-half virtual stick.
		var stick_origin: Vector2 = cam._stick_origin
		var stick_vector: Vector2 = cam._stick_vector
		var stick_visible: bool = cam._stick_active
		var centre := stick_origin if stick_visible else Vector2(size.x * 0.18, size.y * 0.72)
		draw_circle(centre, 78.0, Color(1, 1, 1, 0.10))
		draw_arc(centre, 78.0, 0.0, TAU, 48, Color(1, 1, 1, 0.35), 2.0)
		draw_circle(centre + stick_vector * 60.0, 30.0, Color(1, 1, 1, 0.45 if stick_visible else 0.22))
		# Right-half look hint.
		draw_string(ThemeDB.fallback_font, Vector2(size.x * 0.60, size.y * 0.94),
			"drag to look", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, 0.45))
		# Ascend / descend buttons.
		_draw_button(cam._ascend_rect, "UP", bool(cam._ascend_held))
		_draw_button(cam._descend_rect, "DOWN", bool(cam._descend_held))

	func _draw_button(r: Rect2, label: String, held: bool) -> void:
		if r.size.x <= 0.0:
			return
		draw_rect(r, Color(1, 1, 1, 0.30 if held else 0.12), true)
		draw_rect(r, Color(1, 1, 1, 0.6), false, 2.0)
		draw_string(ThemeDB.fallback_font, r.position + Vector2(14, r.size.y * 0.62),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 1, 1, 0.9))

	func _overlay_size() -> Vector2:
		return size


## Viewport size, with a fallback. In --headless the root Window can report a 0x0 visible
## rect at _ready() time, which would make the left/right half split degenerate and send
## every touch to the look branch. Fall back to the project's window size, then to 1280x720.
func _effective_viewport_size() -> Vector2:
	var vp := get_viewport()
	if vp != null:
		var s := vp.get_visible_rect().size
		if s.x > 1.0 and s.y > 1.0:
			return s
	var w := int(ProjectSettings.get_setting("display/window/size/viewport_width", 1280))
	var h := int(ProjectSettings.get_setting("display/window/size/viewport_height", 720))
	if w > 1 and h > 1:
		return Vector2(w, h)
	return Vector2(1280, 720)


func _ready() -> void:
	for child in get_children():
		if child is Camera3D:
			_camera = child
	if _camera == null:
		_camera = Camera3D.new()
		add_child(_camera)
	_camera.current = true

	_viewport_size = _effective_viewport_size()
	_layout_touch_buttons()
	_build_overlay()

	_touch_mode_auto_detect()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if not touch_mode else Input.MOUSE_MODE_VISIBLE
	get_viewport().size_changed.connect(_on_viewport_resized)
	print("fly_camera: ready (noclip=%s, speed=%.0f m/s, touch=%s)" % [str(noclip), current_speed(), str(touch_mode)])


func apply_config(_cfg: WorldConfig) -> void:
	## Hook for config-driven camera tweaks. M00 keeps the camera independent of world
	## config so that a config rebuild (F3/F5) never moves the player.
	pass


func current_speed() -> float:
	return SPEED_PRESETS[clampi(speed_index, 0, SPEED_PRESETS.size() - 1)]


func teleport_to(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	# Keep the physics engine from interpolating across a 100 km jump. Guarded because the
	# method only exists in Godot 4.3+; a hard call would break on an older engine.
	if has_method("reset_physics_interpolation"):
		call("reset_physics_interpolation")


func set_touch_mode(enabled: bool) -> void:
	touch_mode = enabled
	if _overlay != null:
		_overlay.visible = enabled
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if enabled else Input.MOUSE_MODE_CAPTURED
	_layout_touch_buttons()
	if _overlay != null:
		_overlay.queue_redraw()
	print("fly_camera: touch mode = %s" % str(enabled))


## Auto-enable touch mode ONLY on real mobile platforms or when asked for explicitly.
##
## Deliberately does NOT use DisplayServer.is_touchscreen_available(): it returns true in
## --headless (verified with tools/probe_input_routing.gd) and on touch-capable laptops,
## which would silently disable mouse-look for desktop players. On desktop, press T (or run
## with --touch) and the editor's "Emulate Touch From Mouse" drives the mobile controls.
func _touch_mode_auto_detect() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var mobile := OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("web_android")
	if "--touch" in args:
		set_touch_mode(true)
	elif mobile:
		set_touch_mode(true)


func _on_viewport_resized() -> void:
	_viewport_size = _effective_viewport_size()
	_layout_touch_buttons()
	if _overlay != null:
		_overlay.queue_redraw()


func _layout_touch_buttons() -> void:
	var s := _viewport_size
	var b := Vector2(min(132.0, s.x * 0.16), min(132.0, s.x * 0.16))
	var margin := 18.0
	_descend_rect = Rect2(s.x - margin - b.x, s.y - margin - b.y, b.x, b.y)
	_ascend_rect = Rect2(s.x - margin - b.x, s.y - margin - b.y * 2.0 - 12.0, b.x, b.y)


func _build_overlay() -> void:
	_touch_layer = CanvasLayer.new()
	_touch_layer.name = "TouchControlsLayer"
	_touch_layer.layer = 5
	add_child(_touch_layer)
	_overlay = TouchOverlay.new()
	_overlay.name = "TouchOverlay"
	_overlay.owner_camera = self
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = touch_mode
	_touch_layer.add_child(_overlay)


# --- input ----------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)
	elif event is InputEventMouseButton and event.pressed:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_ESCAPE:
			if touch_mode:
				set_touch_mode(false)
			elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				print("fly_camera: mouse released (Esc). Left click to re-capture.")
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		KEY_F1:
			hud_toggle_requested.emit()
		KEY_F2:
			screenshot_requested.emit()
		KEY_F3:
			cycle_generator_requested.emit()
		KEY_F4:
			cycle_view_distance_requested.emit()
		KEY_F5:
			regenerate_seed_requested.emit()
		KEY_F6:
			teleport_far_requested.emit()
		KEY_F7:
			_toggle_wireframe()
		KEY_N:
			noclip = not noclip
			noclip_changed.emit(noclip)
			print("fly_camera: noclip = %s" % str(noclip))
		KEY_T:
			set_touch_mode(not touch_mode)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			speed_index = event.keycode - KEY_1
			print("fly_camera: speed preset %d m/s" % int(current_speed()))


func _toggle_wireframe() -> void:
	var vp := get_viewport()
	if vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
		vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED
		print("fly_camera: wireframe OFF")
	else:
		vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
		print("fly_camera: wireframe ON")


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if touch_mode:
		return
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_cycle_speed(1)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_cycle_speed(-1)


func _cycle_speed(dir: int) -> void:
	speed_index = clampi(speed_index + dir, 0, SPEED_PRESETS.size() - 1)
	if _overlay != null:
		_overlay.queue_redraw()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if touch_mode or _touch_drag_active:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	_apply_look(event.relative * MOUSE_SENSITIVITY)


func _apply_look(delta: Vector2) -> void:
	rotate_y(-delta.x)
	_pitch = clampf(_pitch - delta.y, -PI * 0.5 + 0.001, PI * 0.5 - 0.001)
	if _camera != null:
		_camera.rotation_degrees.x = rad_to_deg(_pitch)


func _handle_touch(event: InputEventScreenTouch) -> void:
	# Touch handling only runs in touch mode. With "Emulate Touch From Mouse" enabled (it is,
	# in project.godot) every desktop click ALSO arrives as a screen touch, so handling it
	# unconditionally would hijack the mouse-look path. Press T (or pass --touch) to switch.
	if not touch_mode:
		return
	var pos := event.position
	if event.pressed:
		if _ascend_rect.has_point(pos):
			_ascend_held = true
			_ascend_id = event.index
		elif _descend_rect.has_point(pos):
			_descend_held = true
			_descend_id = event.index
		elif pos.x < _effective_viewport_size().x * 0.5:
			_stick_active = true
			_stick_id = event.index
			_stick_origin = pos
			_stick_vector = Vector2.ZERO
		else:
			_look_id = event.index
			_look_last = pos
			_touch_drag_active = true
	else:
		if event.index == _stick_id:
			_stick_active = false
			_stick_id = -1
			_stick_vector = Vector2.ZERO
		if event.index == _look_id:
			_look_id = -1
			_touch_drag_active = false
		# Release only the button this finger was holding: a second finger lifting must not
		# cancel the first one's ascent.
		if event.index == _ascend_id:
			_ascend_held = false
			_ascend_id = -1
		if event.index == _descend_id:
			_descend_held = false
			_descend_id = -1
	if _overlay != null:
		_overlay.queue_redraw()


func _handle_drag(event: InputEventScreenDrag) -> void:
	if not touch_mode:
		return
	if event.index == _stick_id:
		var rel := event.position - _stick_origin
		var max_radius := 78.0
		if rel.length() > max_radius:
			rel = rel.normalized() * max_radius
		_stick_vector = rel / max_radius
	elif event.index == _look_id:
		_touch_drag_active = true
		_apply_look(event.relative * TOUCH_LOOK_SENSITIVITY)
	if _overlay != null:
		_overlay.queue_redraw()


# --- movement -------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var planar := _planar_input()
	var vertical := _vertical_input()

	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := global_transform.basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT

	var wish := (forward * -planar.y + right * planar.x)
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var speed := current_speed()
	if Input.is_key_pressed(KEY_SHIFT):
		# Boost changes magnitude only, never direction, so it cannot alter a flight path.
		speed *= BOOST_FACTOR

	var horizontal := wish * speed

	if noclip:
		# Noclip: pure integration, no physics, no collision. This is the default because
		# M00 needs to inspect terrain from any angle, including inside it.
		velocity = Vector3(horizontal.x, _vertical_input() * speed, horizontal.z)
		global_position += velocity * delta
		return

	# Gravity + collision mode (toggle with N): the only way to prove the mesher produced
	# real collision shapes (A6). Space jumps when grounded; falling is pure gravity.
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if is_on_floor():
		velocity.y = JUMP_SPEED if _vertical_input() > 0.0 else 0.0
	else:
		velocity.y = clampf(velocity.y - GRAVITY * delta, -TERMINAL_SPEED, TERMINAL_SPEED)
	move_and_slide()


## Returns Vector2(x = strafe, y = forward-negative) from keys and the virtual stick.
func _planar_input() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		v.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		v.x += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if _stick_active:
		v += Vector2(_stick_vector.x, -_stick_vector.y)
	return v.limit_length(1.0)


## Returns -1..1 vertical intent.
func _vertical_input() -> float:
	var v := 0.0
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_Q):
		v += 1.0
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_E):
		v -= 1.0
	if _ascend_held:
		v += 1.0
	if _descend_held:
		v -= 1.0
	return clampf(v, -1.0, 1.0)


func describe() -> String:
	return "pos=%s speed=%.0f noclip=%s touch=%s" % [
		str(global_position.round()), current_speed(), str(noclip), str(touch_mode)
	]
