extends SceneTree
## tools/probe_input_routing.gd
## Verifies (a) that injected events reach _unhandled_input headless, (b) whether
## Input.mouse_mode = CAPTURED actually sticks in --headless, and (c) whether the
## touch<->mouse emulation settings create feedback that cancels a held touch.

class Probe:
	extends Node
	var seen: Array = []
	func _unhandled_input(event: InputEvent) -> void:
		seen.append("%s%s" % [event.get_class(), "(touch idx %d pressed %s)" % [event.index, str(event.pressed)] if event is InputEventScreenTouch else ""])

func _initialize() -> void:
	_run()

func _run() -> void:
	var p := Probe.new()
	root.add_child(p)
	await process_frame
	print("(b) mouse_mode before set: ", Input.mouse_mode)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await process_frame
	print("(b) mouse_mode after  set: ", Input.mouse_mode, " (CAPTURED=", Input.MOUSE_MODE_CAPTURED, ")")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	print("(c) injecting touch press index 0, then waiting 3 frames")
	var st := InputEventScreenTouch.new(); st.index = 0; st.pressed = true; st.position = Vector2(256, 504)
	Input.parse_input_event(st)
	for i in 3: await process_frame
	for s in p.seen: print("      seen: ", s)
	p.seen.clear()
	print("(c) injecting touch release index 0")
	var sr := InputEventScreenTouch.new(); sr.index = 0; sr.pressed = false; sr.position = Vector2(256, 504)
	Input.parse_input_event(sr)
	for i in 3: await process_frame
	for s in p.seen: print("      seen: ", s)
	quit(0)
