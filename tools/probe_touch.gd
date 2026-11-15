extends SceneTree
## Focused probe: drive fly_camera.gd's touch path alone and watch its internal state.

const FLY := "res://src/runtime/debug/fly_camera.gd"

func _initialize() -> void:
	_run()

func _run() -> void:
	var script: GDScript = load(FLY)
	var fly: CharacterBody3D = script.new()
	root.add_child(fly)
	await process_frame
	print("viewport size (guarded): ", fly.call("_effective_viewport_size"))
	print("touch_mode: ", fly.touch_mode)
	fly.call("set_touch_mode", true)
	print("ascend_rect: ", fly.get("_ascend_rect"), " descend_rect: ", fly.get("_descend_rect"))

	var s := fly.call("_effective_viewport_size") as Vector2
	var start := Vector2(s.x * 0.2, s.y * 0.7)
	print("--- direct handler calls ---")
	fly.call("_handle_touch", _touch(0, true, start))
	print("   after press:   stick_active=", fly.get("_stick_active"), " stick_id=", fly.get("_stick_id"), " origin=", fly.get("_stick_origin"))
	fly.call("_handle_drag", _drag(0, start + Vector2(0, -60), Vector2(0, -60)))
	print("   after drag:    stick_vector=", fly.get("_stick_vector"))
	print("   _planar_input()=", fly.call("_planar_input"))

	print("--- injected events through the engine ---")
	fly.call("_handle_touch", _touch(0, false, start))
	print("   reset: stick_active=", fly.get("_stick_active"), " stick_vector=", fly.get("_stick_vector"))
	Input.parse_input_event(_touch(1, true, start))
	for i in 2: await process_frame
	print("   after injected press: stick_active=", fly.get("_stick_active"), " stick_id=", fly.get("_stick_id"))
	Input.parse_input_event(_drag(1, start + Vector2(0, -60), Vector2(0, -60)))
	for i in 2: await process_frame
	print("   after injected drag:  stick_vector=", fly.get("_stick_vector"))
	quit(0)

func _touch(index: int, pressed: bool, pos: Vector2) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new(); e.index = index; e.pressed = pressed; e.position = pos; return e

func _drag(index: int, pos: Vector2, rel: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new(); e.index = index; e.position = pos; e.relative = rel; return e
