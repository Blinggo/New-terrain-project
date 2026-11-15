extends SceneTree
## tools/capture_screenshots.gd
##
## M00 - Produces the five screenshots the acceptance checklist (A15) requires, by driving
## the REAL world scene and the REAL fly camera, then calling the same screenshot path the
## F2 key uses. Nothing here is a mock-up or an editor render.
##
##   Required set:
##     01 ground level looking at hills, HUD visible
##     02 ~200 m aerial looking at the horizon, HUD visible
##     03 close-up of block faces showing the atlas + ambient occlusion
##     04 after a far teleport, HUD showing large coordinates
##     05 touch controls visible (mobile emulation / --touch)
##
## REQUIRES A WINDOW. Under --headless the viewport has no backbuffer and the renderer reports
## zero draw calls, so the file would be a lie; this script refuses and says so.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" \
##     godot --path <project> --script res://tools/capture_screenshots.gd
##
## Every camera pose is a function of the world seed and the fixed shot list - no randomness,
## no frame-count dependence, no time-of-day. Re-running reproduces the same five views.

const WORLD_SCENE := "res://src/runtime/world/world.tscn"
const OUT_DIR := "res://docs/reports/screenshots/"
const SETTLE_FRAMES := 240          # let the streamer fill before framing a shot
const SHOT_SETTLE_MAX_FRAMES := 900   # ceiling for "settle until the world is meshed and stable"
const STABLE_WINDOW := 30            # compare against this many frames ago
const STABLE_BLOCK_TOL := 4          # the streamer churns boundary blocks forever; allow +/-4
const STABLE_PRIM_TOL := 0.02        # and 2% primitive jitter (shadow/cull alternation)
const MIN_BLOCKS_FOR_SHOT := 50      # a shot of an empty world is not a screenshot of terrain
const MIN_PRIMITIVES_FOR_SHOT := 5000  # loaded but UNMESHED blocks draw nothing (seen at 2 fps)

## Fixed shot list. `label` becomes part of the filename; the rest is the camera pose.
## yaw is in radians, 0 = looking down -Z.
const SHOTS := [
	{
		"label": "01_ground_level_hills",
		"desc": "ground level looking at hills, HUD visible",
		"pos": Vector3(8, 68, 8), "pitch_deg": -4.0, "yaw_deg": 0.0,
		"speed_index": 2, "touch": false, "noclip": true, "gravity": false,
	},
	{
		"label": "05_touch_controls",
		"desc": "touch controls visible (mobile emulation)",
		"pos": Vector3(8, 76, 8), "pitch_deg": -3.0, "yaw_deg": 15.0,
		"speed_index": 2, "touch": true, "noclip": true, "gravity": false,
		"view_distance": 8,
	},
	{
		"label": "02_aerial_200m_horizon",
		"desc": "~200 m aerial looking at the horizon, HUD visible",
		# 264 = sea level 64 + 200 m. The F4 view distance must go to 12 chunks first: at the
		# default 8 the viewer's vertical volume is only ~128 voxels, so from 200 m up the
		# streamer legitimately loads nothing (measured with tools/probe_vertical.gd).
		# 264 = sea level 64 + 200 m. Pitched down 35 deg: with a 12-chunk (192 m) horizontal
		# stream radius, a LEVEL camera at 200 m looks past the loaded disc (edge sits 46 deg
		# below the horizon), and vd>=20 stalls at ~2000 blocks on this 2-thread box
		# (measured: tools/probe_vd20.gd before removal). Pitching keeps the horizon band in
		# the top of frame and the streamed disc below it. The config's vertical ratio of 2.0
		# is what makes the surface stream at all from this altitude (probe_vratio.gd).
		"pos": Vector3(8, 264, 8), "pitch_deg": -35.0, "yaw_deg": 35.0,
		"speed_index": 2, "touch": false, "noclip": true, "gravity": false,
		"view_distance": 12,
	},
	{
		"label": "03_block_closeup_ao",
		"desc": "close-up of block faces showing the atlas and ambient occlusion",
		# Placed by code just off the surface so faces and AO corners fill the frame.
		# Framed on a real cliff face found by scanning the GENERATOR (not the streamed world,
		# so the search costs nothing and needs no blocks loaded): side faces, tile seams and
		# the mesher's ambient-occlusion corners fill the frame. Falls back to a steep
		# top-down of the spawn column if the world happens to be flat.
		"pos": Vector3.ZERO, "auto_cliff": true,
		"pitch_deg": -12.0, "yaw_deg": 42.0,
		"speed_index": 2, "touch": false, "noclip": true, "gravity": false,
		"view_distance": 8,
	},
	{
		"label": "04_far_teleport",
		"desc": "after a far teleport, HUD showing large coordinates",
		# Start at the origin and let F6 do the work, so the HUD's large coordinates are the
		# real +/-100 000 block teleport A4 asks for, not a hardcoded pose.
		"pos": Vector3(0, 96, 0), "pitch_deg": -8.0, "yaw_deg": -20.0,
		"speed_index": 2, "touch": false, "noclip": true, "gravity": false,
		"teleport": true, "view_distance": 8,
	},
]


func _initialize() -> void:
	_capture()


func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		print("REFUSING to run: --headless has no backbuffer, so every screenshot would be empty.")
		print("Run windowed instead, e.g.:")
		print("  xvfb-run -a -s '-screen 0 1280x720x24' godot --path <project> --script res://tools/capture_screenshots.gd")
		quit(1)
		return

	print("=== capture_screenshots ===")
	print("display=%s renderer=%s gpu=%s" % [
		DisplayServer.get_name(),
		ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"),
		RenderingServer.get_video_adapter_name(),
	])
	print("window size = %s" % str(DisplayServer.window_get_size()))

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var packed: PackedScene = load(WORLD_SCENE)
	if packed == null or not packed.can_instantiate():
		print("FATAL: could not instantiate %s" % WORLD_SCENE)
		quit(1)
		return
	var world: Node = packed.instantiate()
	root.add_child(world)

	await _frames(SETTLE_FRAMES)
	print("world booted; startup_errors=%s blocks=%d" % [str(world.startup_errors()), world.loaded_block_count()])

	var saved: Array[String] = []
	for shot_variant in SHOTS:
		var shot: Dictionary = shot_variant
		var path := await _take_shot(world, shot)
		if path.is_empty():
			print("  FAILED to capture %s" % shot["label"])
		else:
			saved.append(path)
			print("  captured %s -> %s" % [shot["label"], path])

	# Restore the desktop default so the app is left in the state a player would expect.
	var cam: Node = world.fly_camera()
	cam.set_touch_mode(false)

	print("")
	print("captured %d/%d screenshots into %s" % [saved.size(), SHOTS.size(), OUT_DIR])
	for p in saved:
		print("   %s" % p)
	if saved.size() != SHOTS.size():
		quit(1)
		return
	quit(0)


func _take_shot(world: Node, shot: Dictionary) -> String:
	var cam: Node = world.fly_camera()

	if shot.has("view_distance"):
		world.set_view_distance(int(shot["view_distance"]), "shot")

	cam.set_touch_mode(bool(shot.get("touch", false)))
	cam.noclip = bool(shot.get("noclip", true))
	cam.speed_index = int(shot.get("speed_index", 2))

	var pos: Vector3 = shot["pos"]
	var pitch := float(shot.get("pitch_deg", 0.0))
	var yaw := float(shot.get("yaw_deg", 0.0))
	if bool(shot.get("auto_cliff", false)):
		var cliff := _find_cliff_face(world)
		if cliff.has("pos"):
			pos = cliff["pos"]
			yaw = cliff["yaw_deg"]
			pitch = cliff["pitch_deg"]
			print("  cliff face found at %s (drop %d blocks), camera %s yaw %.0f" % [
				str(cliff["face"]), int(cliff["drop"]), str(pos), yaw])
		else:
			pos = _closeup_position(world, cam.global_position, 2.5)
			pitch = -50.0
			print("  no cliff face found; falling back to top-down close-up")
	cam.teleport_to(pos)
	_set_orientation(cam, pitch, yaw)

	# A far teleport must go through the same code path the F6 key uses, so the HUD's
	# coordinates and the streamer's reaction are genuinely the feature under test.
	if bool(shot.get("teleport", false)):
		world._on_teleport_far()
		_set_orientation(cam, pitch, yaw)

	# Wait until the streamer has actually delivered terrain, not for a fixed frame count:
	# on a 4 fps software renderer a fixed wait would capture an empty world, and on a fast
	# GPU it would waste time. Either way the shot is only taken once blocks exist.
	var waited := await _settle_until_rendered(world, MIN_BLOCKS_FOR_SHOT, MIN_PRIMITIVES_FOR_SHOT, SHOT_SETTLE_MAX_FRAMES)
	if waited < 0:
		print("  WARNING: streamer/mesher never delivered a rendered world for %s" % shot["label"])

	# Print the state that must be visible in the HUD for this shot, so the report can quote
	# real numbers next to the image instead of asserting them.
	print("  [%s] %s | pos=%s pitch=%.1f yaw=%.1f blocks=%d fps=%.1f touch=%s vd=%d" % [
		shot["label"], shot["desc"], str(cam.global_position), rad_to_deg(cam.rotation.x),
		rad_to_deg(cam.rotation.y), world.loaded_block_count(),
		Engine.get_frames_per_second(), str(bool(shot.get("touch", false))),
		world.config.view_distance_chunks])

	return await world._save_screenshot(shot["label"])


## Scan the GENERATOR for the steepest nearby cliff and return a camera pose that frames its
## face. Done against the generator rather than the streamed terrain so the search works
## before any blocks exist around the target, and so it is fully deterministic (same seed ->
## same cliff -> same framing on every run).
func _find_cliff_face(world: Node) -> Dictionary:
	var cfg: WorldConfig = world.config
	var built := AdapterRegistry.build_generator(cfg.generator_id, cfg.seed_value, cfg.to_gen_context())
	if not built["ok"]:
		return {}
	var gen: Resource = built["generator"]
	var cache := {}

	# Coarse pass: 8 m grid over +/-160 m, keep the neighbour pair with the biggest drop.
	# A 1-block step is enough: at close range its side face, tile seam and the mesher's
	# ambient-occlusion corner are exactly what screenshot #3 must show.
	var coarse := {}
	var best_drop := 0
	var best_at := Vector2i(0, 0)
	for gx in range(-20, 21):
		for gz in range(-20, 21):
			coarse[Vector2i(gx, gz)] = _col_height(gen, cache, gx * 8, gz * 8)
	for gx in range(-20, 20):
		for gz in range(-20, 20):
			var h0: int = coarse[Vector2i(gx, gz)]
			for nb in [Vector2i(gx + 1, gz), Vector2i(gx, gz + 1)]:
				var dh := absi(h0 - int(coercei(coarse, nb)))
				if dh > best_drop:
					best_drop = dh
					best_at = nb
	if best_drop < 1:
		return {}

	# Fine pass: 1 m grid around the coarse hit to locate the exact face.
	var cx := best_at.x * 8
	var cz := best_at.y * 8
	var fine := {}
	for x in range(cx - 8, cx + 9):
		for z in range(cz - 8, cz + 9):
			fine[Vector2i(x, z)] = _col_height(gen, cache, x, z)
	var face := Vector2i.ZERO
	var low := Vector2i.ZERO
	var drop := 0
	for x in range(cx - 8, cx + 8):
		for z in range(cz - 8, cz + 8):
			for nb in [Vector2i(x + 1, z), Vector2i(x, z + 1)]:
				var h0: int = fine[Vector2i(x, z)]
				var h1: int = fine[nb]
				var dh := absi(h0 - h1)
				if dh > drop:
					drop = dh
					face = Vector2i(x, z) if h0 > h1 else nb
					low = nb if h0 > h1 else Vector2i(x, z)
	if drop < 1:
		return {}

	# Stand on the low side, 4 m back from the face, 2 m above the low ground, looking at it.
	var away := Vector2(float(low.x - face.x), float(low.y - face.y))
	if away.length_squared() < 0.5:
		away = Vector2(1, 0)
	away = away.normalized()
	var h_low: int = fine[low]
	var stand_off := 3.0 + float(drop)
	var p := Vector3(float(face.x) + away.x * stand_off, float(h_low) + 1.5 + 0.5 * float(drop), float(face.y) + away.y * stand_off)
	var d := Vector3(float(face.x) - p.x, 0.0, float(face.y) - p.z).normalized()
	return {
		"pos": p,
		"yaw_deg": rad_to_deg(atan2(-d.x, -d.z)),
		"pitch_deg": -10.0,
		"face": Vector3(face.x, fine[face], face.y),
		"drop": drop,
	}


static func coercei(d: Dictionary, k: Vector2i) -> int:
	return int(d.get(k, 0))


## Surface height (top solid voxel y) of one column, read from generated blocks only.
func _col_height(gen: Resource, cache: Dictionary, x: int, z: int) -> int:
	for y in range(96, -64, -1):
		if _voxel_at(gen, cache, x, y, z) != 0:
			return y
	return -65


func _voxel_at(gen: Resource, cache: Dictionary, x: int, y: int, z: int) -> int:
	var origin := Vector3i(int(floor(float(x) / 16.0)) * 16, int(floor(float(y) / 16.0)) * 16, int(floor(float(z) / 16.0)) * 16)
	var buf: VoxelBuffer = cache.get(origin)
	if buf == null:
		buf = VoxelBuffer.new()
		buf.create(16, 16, 16)
		gen.call("generate_block", buf, origin, 0)
		buf.decompress_channel(VoxelBuffer.CHANNEL_TYPE)
		cache[origin] = buf
	return buf.get_voxel(x - origin.x, y - origin.y, z - origin.z, VoxelBuffer.CHANNEL_TYPE)


## Await until the world is both LOADED and MESHED: VoxelEngine can report hundreds of loaded
## data blocks while the mesher is still behind (at 2 fps on this box that produced a fully
## loaded but completely invisible world, with dropped_block_loads in the thousands). Loaded
## blocks alone is therefore not a valid settle condition for a screenshot.
func _settle_until_rendered(world: Node, min_blocks: int, min_prims: int, max_frames: int) -> int:
	# Two phases: (1) until enough is loaded AND rendered, (2) until nothing has changed for
	# STABLE_FRAMES in a row. Phase 2 matters: at 3 fps the primitive count clears the minimum
	# while half the chunks around a fresh teleport are still unmeshed holes, which produced
	# a screenshot of a half-built world.
	var hist_b: Array = []
	var hist_p: Array = []
	for i in max_frames:
		var blocks: int = world.loaded_block_count()
		var prims: int = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		hist_b.append(blocks)
		hist_p.append(prims)
		if hist_b.size() > STABLE_WINDOW:
			var old_b: int = hist_b[0]
			var old_p: int = hist_p[0]
			hist_b.pop_front()
			hist_p.pop_front()
			var enough: bool = blocks >= min_blocks and prims >= min_prims
			var db: int = absi(blocks - old_b)
			var dp: int = absi(prims - old_p)
			if enough and db <= STABLE_BLOCK_TOL and dp <= maxi(50, int(float(old_p) * STABLE_PRIM_TOL)):
				return i
		await process_frame
	return -1


## Position the camera ~4 blocks off the terrain surface, looking at it, so block faces and
## the mesher's ambient occlusion fill the frame (screenshot #3).
func _closeup_position(world: Node, from: Vector3, offset: float = 3.0) -> Vector3:
	var terrain: Node3D = world.terrain_node()
	# Search DOWN from a height guaranteed to be inside the stream volume, not from wherever
	# the previous shot left the camera (that produced y=247 mid-air once). Search the SPAWN
	# column, which shot 01 proves meshes completely.
	var search_top := 140.0
	var ground := search_top - 80.0
	if terrain != null and terrain.has_method("get_voxel_tool"):
		var tool: VoxelTool = terrain.call("get_voxel_tool")
		if tool != null:
			# Step down from the camera until we hit something solid.
			for i in 100:
				var p := Vector3(from.x, search_top - float(i), from.z)
				if tool.get_voxel(p) != 0:
					ground = p.y
					break
	return Vector3(8.0 + 3.0, ground + offset, 8.0 + 3.0)


func _set_orientation(cam: Node, pitch_deg: float, yaw_deg: float) -> void:
	# The camera keeps pitch in a private field and yaw on the body; drive both the way the
	# look handler does so the pose matches what a player would see.
	cam.rotation = Vector3(deg_to_rad(pitch_deg), deg_to_rad(yaw_deg), 0.0)
	cam.set("_pitch", deg_to_rad(pitch_deg))


func _frames(n: int) -> void:
	for i in n:
		await process_frame
