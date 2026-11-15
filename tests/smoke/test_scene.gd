extends RefCounted
## tests/smoke/test_scene.gd
##
## S5 - The check that matters most in M00: does pressing Play actually produce a streaming
## 3D voxel world? This instantiates res://src/runtime/world/world.tscn in a live tree,
## waits for streaming, and asserts on what is really there.
##
## Also asserts the T1/T4 configuration that must be true at runtime (renderer, filters,
## shadows, environment effects) rather than merely present in project.godot.
##
## NOTE: this file lives in tests/, not src/, but it still refuses to name Voxel Tools
## classes - it compares get_class() strings. Keeping the discipline here means the lint
## rule has no "except tests" hole to grow into.

const SUITE := "smoke"
const STREAM_FRAMES := 260
const SCENE := "res://src/runtime/world/world.tscn"


func run(ctx: Dictionary) -> Array:
	var out: Array = []
	var tree: SceneTree = ctx.get("tree")
	if tree == null:
		out.append(TestHarness.blocked(SUITE, "S5", "no SceneTree in ctx - cannot instantiate the world"))
		return out

	out.append_array(_project_settings_checks())

	if not ResourceLoader.exists(SCENE):
		out.append(TestHarness.fail(SUITE, "S5a", "world.tscn does not exist", SCENE))
		return out

	var scene: PackedScene = load(SCENE)
	if scene == null:
		out.append(TestHarness.fail(SUITE, "S5a", "world.tscn failed to load", SCENE))
		return out
	out.append(TestHarness.ok(SUITE, "S5a", "world.tscn loads", "load_steps ok, can_instantiate=%s" % str(scene.can_instantiate())))

	var world: Node = scene.instantiate()
	tree.root.add_child(world)

	# Let the world build its terrain and stream blocks.
	for i in STREAM_FRAMES:
		await tree.process_frame

	out.append_array(await _scene_checks(world))
	out.append_array(await _movement_checks(world, tree))
	out.append_array(await _collision_checks(world, tree))

	world.queue_free()
	for i in 3:
		await tree.process_frame
	return out


func _project_settings_checks() -> Array:
	var out: Array = []
	var checks := [
		["S5-cfg-renderer", "rendering/renderer/rendering_method", "mobile"],
		["S5-cfg-nearest-mip", "rendering/textures/default_filters/use_nearest_mipmap_filter", true],
		["S5-cfg-msaa", "rendering/anti_aliasing/quality/msaa_3d", 0],
		["S5-cfg-shadow-size", "rendering/lights_and_shadows/directional_shadow/size", 2048],
		["S5-cfg-shadow-quality", "rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 0],
		["S5-cfg-physics-hz", "physics/common/physics_ticks_per_second", 60],
		["S5-cfg-main-scene", "application/run/main_scene", "res://src/runtime/world/world.tscn"],
		["S5-cfg-app-name", "application/config/name", "VoxelTerrain"],
	]
	for c in checks:
		var got: Variant = ProjectSettings.get_setting(c[1])
		var ok := _same(got, c[2])
		out.append(TestHarness.result(SUITE, String(c[0]), "PASS" if ok else "FAIL",
			"%s = %s" % [c[1], str(got)], "expected %s" % str(c[2])))
	return out


func _same(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == b
	if a is float or b is float:
		return is_equal_approx(float(a), float(b))
	return a == b


func _scene_checks(world: Node) -> Array:
	var out: Array = []

	var voxel_root: Node = world.get_node_or_null("VoxelRoot")
	out.append(TestHarness.result(SUITE, "S5b", "PASS" if voxel_root != null else "FAIL",
		"world.tscn contains the VoxelRoot placeholder", str(voxel_root)))

	var terrain: Node = null
	if voxel_root != null and voxel_root.get_child_count() > 0:
		terrain = voxel_root.get_child(0)
	var cls := terrain.get_class() if terrain != null else "(none)"
	out.append(TestHarness.result(SUITE, "S5c", "PASS" if cls == "VoxelTerrain" else "FAIL",
		"adapter created a VoxelTerrain under VoxelRoot", "class=%s" % cls))

	var mesher: Variant = terrain.get("mesher") if terrain != null else null
	var library: Variant = mesher.get("library") if mesher != null else null
	out.append(TestHarness.result(SUITE, "S5d",
		"PASS" if mesher != null and library != null else "FAIL",
		"terrain has a blocky mesher with a generated library",
		"mesher=%s library=%s models=%s materials=%s" % [
			mesher.get_class() if mesher != null else "null",
			library.get_class() if library != null else "null",
			library.get("models").size() if library != null and library.get("models") != null else -1,
			library.call("get_materials").size() if library != null else -1,
		]))

	var generator: Variant = terrain.get("generator") if terrain != null else null
	out.append(TestHarness.result(SUITE, "S5e", "PASS" if generator != null else "FAIL",
		"terrain has a generator attached", str(generator.get_class()) if generator != null else "null"))

	var stream: Variant = terrain.get("stream") if terrain != null else null
	out.append(TestHarness.result(SUITE, "S5f", "PASS" if stream == null else "FAIL",
		"stream is UNSET in M00 (persistence deferred to M12)", str(stream)))

	# Viewer: in 1.7 streaming is driven by a VoxelViewer node, not a terrain property.
	var fly: Node = world.get_node_or_null("FlyCamera")
	var viewer: Node = null
	if fly != null:
		for c in fly.get_children():
			if c.get_class() == "VoxelViewer":
				viewer = c
	out.append(TestHarness.result(SUITE, "S5g", "PASS" if viewer != null else "FAIL",
		"a VoxelViewer node is parented to the fly camera", str(viewer)))

	# Environment / light settings required by T1 and T4.
	var env_node: Node = world.get_node_or_null("WorldEnvironment")
	var env: Environment = env_node.get("environment") if env_node != null else null
	if env == null:
		out.append(TestHarness.fail(SUITE, "S5h", "WorldEnvironment has no Environment"))
	else:
		var bad: Array[String] = []
		if env.background_mode != Environment.BG_SKY:
			bad.append("background_mode=%d (expected BG_SKY)" % env.background_mode)
		if env.sky == null:
			bad.append("no procedural sky")
		if not env.fog_enabled:
			bad.append("distance fog is off (T4 needs it for readable depth)")
		if env.glow_enabled:
			bad.append("glow is ON (T1 requires off)")
		if env.ssao_enabled:
			bad.append("SSAO is ON (T1 requires off)")
		if env.volumetric_fog_enabled:
			bad.append("volumetric fog is ON (T1 requires off)")
		out.append(TestHarness.result(SUITE, "S5h", "PASS" if bad.is_empty() else "FAIL",
			"environment: procedural sky + distance fog, glow/SSAO/volumetric fog off",
			"; ".join(bad) if not bad.is_empty() else "fog_density=%f aerial=%f" % [env.fog_density, env.fog_aerial_perspective]))

	var light: DirectionalLight3D = world.get_node_or_null("DirectionalLight3D")
	out.append(TestHarness.result(SUITE, "S5i",
		"PASS" if light != null and light.shadow_enabled else "FAIL",
		"DirectionalLight3D present with shadows enabled",
		"rotation=%s max_distance=%f" % [str(light.rotation_degrees) if light else "-", light.directional_shadow_max_distance if light else 0.0]))

	# Streaming really happened.
	var loaded: int = world.call("loaded_block_count")
	var stats: Dictionary = world.call("terrain_statistics")
	out.append(TestHarness.result(SUITE, "S5j", "PASS" if loaded > 0 else "FAIL",
		"terrain streamed %d data blocks in %d frames" % [loaded, STREAM_FRAMES],
		"statistics keys=%s values=%s" % [str(stats.keys()), str(stats)]))

	# HUD produced real content. M01: the default mode is COMPACT (phone-usable), so the
	# full-field assertion switches to FULL first - exactly what a player does with F1.
	var hud: Node = world.get_node_or_null("DebugHUD")
	var label: Label = null
	if hud != null:
		var panel: Node = hud.get_node_or_null("HUDPanel")
		if panel != null:
			label = panel.get_node_or_null("HUDText")
	if hud != null and hud.has_method("set_mode"):
		hud.call("set_mode", 1)   # FULL
		for i in 3:
			await world.get_tree().process_frame
	var text := label.text if label != null else ""
	var needed := ["FPS", "draw calls", "static mem", "seed", "gen", "view", "get_statistics"]
	var missing: Array[String] = []
	for n in needed:
		if not text.contains(n):
			missing.append(n)
	out.append(TestHarness.result(SUITE, "S5k",
		"PASS" if label != null and missing.is_empty() else "FAIL",
		"HUD FULL mode contains all required fields",
		"missing=%s\n%s" % [str(missing), text]))

	# --- S5p: phone usability (reviewer Task 0.4) ----------------------------------------
	var problems: Array[String] = []
	if hud == null or not hud.has_method("set_mode"):
		problems.append("HUD has no mode API")
	else:
		# default on a fresh HUD is COMPACT; cycle order must be compact->full->pipeline->off
		hud.call("set_mode", 0)
		var names: Array[String] = []
		for i in 4:
			names.append(String(hud.call("mode_name")))
			hud.call("cycle_mode")
		if names != ["compact", "full", "pipeline", "off"]:
			problems.append("cycle order is %s" % str(names))
		hud.call("set_mode", 0)
		for i in 3:
			await world.get_tree().process_frame
		var compact_text := String(label.text) if label != null else ""
		var compact_lines := compact_text.split("\n").size()
		if compact_lines > 4:
			problems.append("compact mode shows %d lines (max 4)" % compact_lines)
		if compact_text.find("hud ") < 0:
			problems.append("compact mode dropped the self-measured cost readout")
		# scaling law: smaller viewport -> smaller scale, clamped
		var s_small: float = hud.call("compute_scale_for", Vector2(640, 360))
		var s_ref: float = hud.call("compute_scale_for", Vector2(1280, 720))
		var s_big: float = hud.call("compute_scale_for", Vector2(3840, 2160))
		if not (s_small < s_ref and s_ref < s_big and s_big <= 2.0):
			problems.append("scale law broken: %f / %f / %f" % [s_small, s_ref, s_big])
		# pipeline page must render without crashing even for the graph backend
		hud.call("set_mode", 2)
		for i in 2:
			await world.get_tree().process_frame
		var pipe_text := String(label.text) if label != null else ""
		if pipe_text.find("pipeline") < 0:
			problems.append("pipeline page has no header")
		hud.call("set_mode", 1)
	out.append(TestHarness.result(SUITE, "S5p", "PASS" if problems.is_empty() else "FAIL",
		"HUD is phone-usable: compact 4-line default, 4-mode cycle, viewport scaling, pipeline page",
		"\n".join(problems) if not problems.is_empty() else "compact<=4 lines with cost readout; cycle compact->full->pipeline->off; scale 640x360 < 1280x720 < 3840x2160 <= 2.0"))

	var errs: Array = world.call("startup_errors")
	out.append(TestHarness.result(SUITE, "S5l", "PASS" if errs.is_empty() else "FAIL",
		"world reported no startup errors", str(errs)))

	return out


func _movement_checks(world: Node, tree: SceneTree) -> Array:
	var out: Array = []
	var fly: CharacterBody3D = world.get_node_or_null("FlyCamera")
	if fly == null:
		out.append(TestHarness.fail(SUITE, "S5m", "FlyCamera missing"))
		return out

	# --- keyboard: inject a real W press and let the camera's own polling move it ---------
	fly.noclip = true
	fly.speed_index = 3  # 128 m/s
	var before := fly.global_position
	Input.parse_input_event(_key(KEY_W, true))
	for i in 5:
		await tree.process_frame
	var polling_sees_key := Input.is_key_pressed(KEY_W)
	for i in 40:
		await tree.process_frame
	var after := fly.global_position
	Input.parse_input_event(_key(KEY_W, false))
	var moved := before.distance_to(after)

	out.append(TestHarness.result(SUITE, "S5m1", "PASS" if polling_sees_key else "FAIL",
		"an injected InputEventKey drives Input.is_key_pressed (the camera polls keys)",
		"is_key_pressed(KEY_W)=%s after Input.parse_input_event" % str(polling_sees_key)))
	out.append(TestHarness.result(SUITE, "S5m2", "PASS" if moved > 1.0 else "FAIL",
		"W moves the fly camera through its own _physics_process",
		"moved %.1f m in 40 frames (%.1f m/s expected)" % [moved, fly.call("current_speed")]))

	# --- mouse look ---------------------------------------------------------------------
	# Engine-level capture cannot be tested headless: Input.mouse_mode = MOUSE_MODE_CAPTURED
	# does not stick in --headless (verified with tools/probe_input_routing.gd: the value
	# reads back as 0/VISIBLE). So we unit-test the look maths directly here and prove the
	# real captured-mouse path in the windowed run (tools/capture_screenshots.gd).
	var yaw_before := fly.rotation.y
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(200.0, 0.0)
	fly.call("_apply_look", mm.relative * 0.0022)
	var yaw_after := fly.rotation.y
	out.append(TestHarness.result(SUITE, "S5m3", "PASS" if absf(yaw_after - yaw_before) > 0.001 else "FAIL",
		"mouse-look maths rotates yaw and clamps pitch",
		"yaw %.4f -> %.4f rad for relative=(200,0)" % [yaw_before, yaw_after]))

	var pitch_clamped := true
	for i in 40:
		fly.call("_apply_look", Vector2(0.0, 50.0))
	var cam_node: Camera3D = null
	for c in fly.get_children():
		if c is Camera3D:
			cam_node = c
	if cam_node != null:
		pitch_clamped = absf(cam_node.rotation_degrees.x) <= 90.0
	out.append(TestHarness.result(SUITE, "S5m3b", "PASS" if pitch_clamped else "FAIL",
		"pitch stays clamped to +/-90 degrees after sustained look input",
		"camera pitch = %s deg" % (str(cam_node.rotation_degrees.x) if cam_node != null else "no camera")))
	fly.call("_apply_look", Vector2(0.0, -4000.0))

	# --- captured-mouse routing ----------------------------------------------------------
	# Headless cannot hold MOUSE_MODE_CAPTURED (reads back VISIBLE; probe_input_routing.gd).
	# With a window we can ACTUALLY try: request capture, let a frame pass, then inject a
	# relative motion event and require the camera to rotate through the engine's own
	# routing (no direct handler calls). If the display server still refuses the capture
	# (Xvfb without a window manager focus, for instance) that is a BLOCKED with evidence,
	# not a PASS and not a FAIL of the camera code.
	if DisplayServer.get_name() == "headless":
		out.append(TestHarness.blocked(SUITE, "S5m3c",
			"captured-mouse routing needs a window (headless cannot hold MOUSE_MODE_CAPTURED)",
			"re-run windowed: xvfb-run -a godot --path . --script res://tools/run_module.gd -- res://tests/smoke/test_scene.gd"))
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		await tree.process_frame
		await tree.process_frame
		var held: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		if not held:
			out.append(TestHarness.blocked(SUITE, "S5m3c",
				"display server '%s' refused MOUSE_MODE_CAPTURED (reads back %d)" % [DisplayServer.get_name(), Input.mouse_mode],
				"capture needs a focused real desktop session; Xvfb has no window manager. Camera look maths are covered by S5m3/S5m3b."))
		else:
			var yaw0 := fly.rotation.y
			var mm2 := InputEventMouseMotion.new()
			mm2.relative = Vector2(120.0, 0.0)
			Input.parse_input_event(mm2)
			await tree.process_frame
			await tree.process_frame
			var rotated := absf(fly.rotation.y - yaw0) > 0.001
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			out.append(TestHarness.result(SUITE, "S5m3c", "PASS" if rotated else "FAIL",
				"captured mouse: an injected relative motion rotated the camera through engine routing",
				"display=%s mode held=CAPTURED yaw %.4f -> %.4f rad" % [DisplayServer.get_name(), yaw0, fly.rotation.y]))

	# --- touch controls: drive the handlers directly ------------------------------------
	# Injected touch delivery is unreliable in --headless (the engine routes some events and
	# drops others depending on the touch<->mouse emulation feedback), so the mobile control
	# LOGIC is unit-tested here and the real injected path is exercised in the windowed run.
	fly.call("set_touch_mode", true)
	var vp_size: Vector2 = fly.call("_effective_viewport_size")
	var stick_start := Vector2(vp_size.x * 0.2, vp_size.y * 0.7)

	fly.call("_handle_touch", _touch(0, true, stick_start))
	fly.call("_handle_drag", _drag(0, stick_start + Vector2(0.0, -60.0), Vector2(0.0, -60.0)))
	var stick: Vector2 = fly.get("_stick_vector")
	var planar: Vector2 = fly.call("_planar_input")
	out.append(TestHarness.result(SUITE, "S5m4", "PASS" if stick.length() > 0.2 else "FAIL",
		"left-half touch drag deflects the virtual stick and feeds planar input",
		"stick_vector=%s  _planar_input=%s (viewport %s)" % [str(stick), str(planar), str(vp_size)]))

	var look_yaw := fly.rotation.y
	var look_start := Vector2(vp_size.x * 0.8, vp_size.y * 0.4)
	fly.call("_handle_touch", _touch(1, true, look_start))
	fly.call("_handle_drag", _drag(1, look_start + Vector2(150.0, 0.0), Vector2(150.0, 0.0)))
	out.append(TestHarness.result(SUITE, "S5m5", "PASS" if absf(fly.rotation.y - look_yaw) > 0.001 else "FAIL",
		"right-half touch drag looks around", "yaw delta=%.4f rad" % absf(fly.rotation.y - look_yaw)))

	# Up / down buttons, by finger, including the "second finger must not cancel the first"
	# case that a naive implementation gets wrong.
	var asc: Rect2 = fly.get("_ascend_rect")
	var desc: Rect2 = fly.get("_descend_rect")
	fly.call("_handle_touch", _touch(0, false, stick_start))
	fly.call("_handle_touch", _touch(1, false, look_start))
	fly.call("_handle_touch", _touch(2, true, asc.position + asc.size * 0.5))
	var v_ascend: float = fly.call("_vertical_input")
	fly.call("_handle_touch", _touch(3, true, desc.position + desc.size * 0.5))
	var v_both: float = fly.call("_vertical_input")
	fly.call("_handle_touch", _touch(3, false, desc.position + desc.size * 0.5))
	var v_after_release: float = fly.call("_vertical_input")
	fly.call("_handle_touch", _touch(2, false, asc.position + asc.size * 0.5))
	var buttons_ok := is_equal_approx(v_ascend, 1.0) and is_equal_approx(v_both, 0.0) and is_equal_approx(v_after_release, 1.0)
	out.append(TestHarness.result(SUITE, "S5m6", "PASS" if buttons_ok else "FAIL",
		"on-screen UP/DOWN buttons drive vertical input per finger",
		"ascend=%f both=%f after_release=%f (expect 1, 0, 1)" % [v_ascend, v_both, v_after_release]))
	fly.call("set_touch_mode", false)

	out.append(TestHarness.ok(SUITE, "S5n", "fly camera reports state", String(fly.call("describe"))))
	return out


func _key(code: int, pressed: bool) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = pressed
	e.echo = false
	return e


func _touch(index: int, pressed: bool, pos: Vector2) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.pressed = pressed
	e.position = pos
	return e


func _drag(index: int, pos: Vector2, relative: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	# A real drag always carries its delta; without it the look branch cannot rotate.
	e.relative = relative
	return e


func _collision_checks(world: Node, tree: SceneTree) -> Array:
	var out: Array = []
	var fly: CharacterBody3D = world.get_node_or_null("FlyCamera")
	if fly == null:
		out.append(TestHarness.fail(SUITE, "S5o", "FlyCamera missing"))
		return out

	# Drop the camera from above the terrain with gravity+collision enabled. If the mesher
	# produced collision shapes, it must land instead of falling forever.
	fly.noclip = false
	fly.velocity = Vector3.ZERO
	fly.global_position = Vector3(8.0, 130.0, 8.0)
	var start_y := fly.global_position.y
	var min_y := start_y
	var landed := false
	var frames_used := 0
	for i in 420:
		frames_used = i + 1
		await tree.process_frame
		min_y = minf(min_y, fly.global_position.y)
		if fly.is_on_floor():
			landed = true
			break

	out.append(TestHarness.result(SUITE, "S5o", "PASS" if landed else "FAIL",
		"gravity+collision mode lands on generated terrain (A6)",
		"is_on_floor=%s start_y=%.1f final_y=%.1f min_y=%.1f frames=%d" % [
			str(landed), start_y, fly.global_position.y, min_y, frames_used,
		]))

	fly.noclip = true
	return out
