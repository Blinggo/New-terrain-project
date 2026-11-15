extends RefCounted
## tests/perf/bench_runtime.gd
##
## M00 / T9.2 - Runtime streaming benchmark: a scripted 60 s flight through the real, fully
## streamed world, measuring what the player would actually feel.
##
## REQUIRES A WINDOW. Unlike bench_generation.gd this drives the actual VoxelEngine pipeline
## (generation + meshing + block streaming + rendering), so it must run windowed. Under
## --headless it reports BLOCKED with the reason rather than printing meaningless zeros.
##
## WHAT IT DOES
##   For each view distance in VIEW_DISTANCES:
##     * rebuild the world at that distance with the project seed,
##     * fly the camera forward at FLIGHT_SPEED m/s along a deterministic path for
##       FLIGHT_SECONDS (no input, no randomness, no frame-count dependence: the path is a
##       pure function of elapsed wall time),
##     * sample every frame: frame time, FPS, loaded data blocks, draw calls, primitives,
##       static memory, and the viewer's world position,
##   then report min/mean FPS, p95 frame time, worst frame, max loaded blocks and max draw
##   calls, plus a BLOCKED note if the machine cannot represent the target device.
##
## HARDWARE HONESTY
##   If there is no GPU, or fewer than 3 CPU threads, or less than 3 GiB RAM, every absolute
##   number is reported but the check is BLOCKED as a claim about the Android target. This
##   sandbox has 2 threads, 1.9 GiB RAM and Lavapipe software rasterisation, so a real device
##   number can never be produced here. That is stated in the evidence, not hidden.

const SUITE := "perf"

const FLIGHT_SECONDS := 60.0
const FLIGHT_SPEED := 32.0
const VIEW_DISTANCES := [8, 6, 12]
const WARMUP_SECONDS := 3.0
const ROLLING_FRAMES := 120

## Deterministic flight path: a gentle S so the run crosses chunk borders at an angle instead
## of flying down one row of chunks forever. Pure function of t - no randf, no Time-of-day.
const PATH_AMPLITUDE := 90.0
const PATH_PERIOD := 45.0


func run(ctx: Dictionary) -> Array:
	var out: Array = []

	if DisplayServer.get_name() == "headless":
		out.append(TestHarness.blocked(SUITE, "R0",
			"runtime benchmark needs a window: running --headless",
			"Re-run windowed, e.g.:\n"
			+ "  xvfb-run -a -s '-screen 0 1280x720x24' godot --path . --script res://tools/run_module.gd -- res://tests/perf/bench_runtime.gd\n"
			+ "On a real device or desktop GPU, run it normally.\n"
			+ "Under --headless RenderingServer reports 0 draw calls, 0 primitives and 0 video memory, so every\n"
			+ "runtime number would be fabricated rather than measured."))
		return out

	var world: Node = ctx.get("world")
	if world == null:
		out.append(TestHarness.fail(SUITE, "R0", "no world node in the benchmark context",
			"bench_runtime must be run through tools/run_module.gd --world res://src/runtime/world/world.tscn"))
		return out

	out.append(_hardware_note())

	for vd in VIEW_DISTANCES:
		out.append(await _bench_one(world, int(vd)))

	return out


func _hardware_note() -> Dictionary:
	var mem: Dictionary = OS.get_memory_info()
	var threads := OS.get_processor_count()
	var gpu := RenderingServer.get_video_adapter_name()
	var weak: Array[String] = []
	if gpu.is_empty():
		weak.append("no GPU reported by RenderingServer (software rasterisation)")
	if threads <= 2:
		weak.append("only %d CPU threads" % threads)
	if int(mem.get("physical", 0)) < 3 * 1024 * 1024 * 1024:
		weak.append("%s MiB RAM" % _mib(int(mem.get("physical", 0))))
	var driver := String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))
	var notes: Array[String] = [
		"os=%s (%s)" % [OS.get_name(), OS.get_distribution_name()],
		"cpu=%s x%d" % [OS.get_processor_name(), threads],
		"ram=%s MiB total, %s MiB available" % [_mib(int(mem.get("physical", 0))), _mib(int(mem.get("available", 0)))],
		"gpu=%s vendor=%s renderer=%s" % [gpu if not gpu.is_empty() else "<none>",
			RenderingServer.get_video_adapter_vendor() if RenderingServer.get_video_adapter_vendor() != "" else "<none>", driver],
		"flight=%.0f s at %.0f m/s, warmup %.0f s, view distances %s" % [
			FLIGHT_SECONDS, FLIGHT_SPEED, WARMUP_SECONDS, str(VIEW_DISTANCES)],
	]
	if weak.is_empty():
		return TestHarness.ok(SUITE, "R1", "hardware recorded", "\n".join(notes))
	notes.append("")
	notes.append("BLOCKED as a statement about the target device: " + ", ".join(weak) + ".")
	notes.append("The Android target is a 3-4 GB RAM phone with an Adreno 610-class GPU. Numbers below")
	notes.append("describe THIS machine only and must not be quoted as device performance.")
	return TestHarness.result(SUITE, "R1", "BLOCKED",
		"hardware recorded - machine cannot represent the Android target", "\n".join(notes))


func _bench_one(world: Node, view_distance: int) -> Dictionary:
	# Switch the world to this view distance through its own public API (the F4 path).
	var config: WorldConfig = world.config
	if config == null:
		return TestHarness.fail(SUITE, "R2/vd%d" % view_distance, "world exposes no config")
	world.call("rebuild_with_config", config.with_view_distance(view_distance))

	var camera: Node3D = world.fly_camera()
	if camera == null:
		return TestHarness.fail(SUITE, "R2/vd%d" % view_distance, "world exposes no fly_camera")

	# Fly the camera itself: noclip on, so the scripted path is not perturbed by terrain.
	# The path is written straight to global_position from a pure function of elapsed time,
	# so it does not depend on the camera's own input handling or on the frame count.
	camera.noclip = true
	camera.speed_index = 2  # 32 m/s preset, matching FLIGHT_SPEED

	var start_pos: Vector3 = _path_position(0.0, Vector3(8.0, 90.0, 8.0))
	camera.global_position = start_pos

	# Warmup: let the streamer fill the new view distance before sampling.
	var tree: SceneTree = world.get_tree()
	var warm_end := Time.get_ticks_msec() + int(WARMUP_SECONDS * 1000.0)
	while Time.get_ticks_msec() < warm_end:
		await tree.process_frame

	var frame_times: Array = []
	var fps_samples: Array = []
	var block_counts: Array = []
	var draw_calls: Array = []
	var primitives: Array = []
	var mem_samples: Array = []
	var positions: Array = []

	var t0 := Time.get_ticks_msec()
	var deadline := t0 + int(FLIGHT_SECONDS * 1000.0)
	var frames := 0
	var last := t0
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		var now := Time.get_ticks_msec()
		var dt_ms := float(now - last)
		last = now
		frames += 1

		# Deterministic flight: position is a pure function of elapsed time, never of the
		# frame count, so a slow machine covers the same ground (just with fewer samples).
		var t := float(now - t0) / 1000.0
		camera.global_position = _path_position(t, start_pos)
		camera.rotation.y = _path_yaw(t)

		frame_times.append(dt_ms)
		fps_samples.append(Engine.get_frames_per_second())
		mem_samples.append(OS.get_static_memory_usage())
		positions.append(camera.global_position)

		var stats: Dictionary = world.engine_stats()
		var pools: Dictionary = stats.get("memory_pools", {})
		block_counts.append(int(pools.get("block_count", 0)))

		var info := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		draw_calls.append(int(info))
		var prims := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		primitives.append(int(prims))

	var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
	if frames < 30:
		return TestHarness.result(SUITE, "R2/vd%d" % view_distance, "BLOCKED",
			"only %d frames in %.1f s - not enough samples to report percentiles honestly" % [frames, elapsed],
			"This machine is too slow to produce a meaningful 60 s flight sample at view distance %d." % view_distance)

	frame_times.sort()
	var sorted_fps := fps_samples.duplicate()
	sorted_fps.sort()
	var distance := start_pos.distance_to(camera.global_position)

	var lines: Array[String] = [
		"view_distance=%d chunks (%d voxels), sampled %.1f s, %d frames (%.1f fps average)" % [
			view_distance, view_distance * config.mesh_block_size, elapsed, frames, frames / elapsed],
		"fps: min=%.1f mean=%.1f p5=%.1f" % [sorted_fps[0], TestHarness.mean(fps_samples), TestHarness.percentile(sorted_fps, 5)],
		"frame_time_ms: mean=%.2f p50=%.2f p95=%.2f worst=%.2f" % [
			TestHarness.mean(frame_times), TestHarness.percentile(frame_times, 50),
			TestHarness.percentile(frame_times, 95), frame_times[frame_times.size() - 1]],
		"loaded_data_blocks: max=%d mean=%.0f" % [int(_max_of(block_counts)), TestHarness.mean(_to_float(block_counts))],
		"draw_calls: max=%d mean=%.0f" % [int(_max_of(draw_calls)), TestHarness.mean(_to_float(draw_calls))],
		"primitives: max=%d" % int(_max_of(primitives)),
		"static_memory_MiB: max=%s mean=%s" % [_mib(int(_max_of(mem_samples))), _mib(int(TestHarness.mean(_to_float(mem_samples))))],
		"distance flown=%.1f m (target %.1f m at %.0f m/s)" % [distance, FLIGHT_SECONDS * FLIGHT_SPEED, FLIGHT_SPEED],
	]
	if _max_of(draw_calls) == 0:
		lines.append("draw calls read 0: the renderer did not report them in this environment.")

	return TestHarness.ok(SUITE, "R2/vd%d" % view_distance,
		"60 s flight at view distance %d: %.1f fps mean, p95 frame %.2f ms, max %d blocks" % [
			view_distance, TestHarness.mean(fps_samples), TestHarness.percentile(frame_times, 95), int(_max_of(block_counts))],
		"\n".join(lines))


## Deterministic flight path. x advances at FLIGHT_SPEED, z sweeps a sine so the camera cuts
## across chunk boundaries instead of following one row.
func _path_position(t: float, start: Vector3) -> Vector3:
	return Vector3(
		start.x + FLIGHT_SPEED * t,
		start.y + PATH_AMPLITUDE * 0.25 * sin(TAU * t / PATH_PERIOD),
		start.z + PATH_AMPLITUDE * sin(TAU * t / PATH_PERIOD)
	)


func _path_yaw(t: float) -> float:
	# Face along the direction of travel, derived from the same deterministic path.
	var a := _path_position(t, Vector3.ZERO)
	var b := _path_position(t + 0.05, Vector3.ZERO)
	var d := b - a
	if d.length_squared() < 0.000001:
		return 0.0
	return atan2(-d.x, -d.z)


func _max_of(a: Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, float(v))
	return m if is_finite(m) else 0.0


func _to_float(a: Array) -> Array:
	var out := []
	for v in a:
		out.append(float(v))
	return out


func _mib(bytes: int) -> String:
	return "%.1f" % (float(bytes) / (1024.0 * 1024.0))
