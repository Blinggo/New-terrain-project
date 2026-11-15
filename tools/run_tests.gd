extends SceneTree
## tools/run_tests.gd
##
## M00 / T10 - Headless test runner. Runs the smoke + determinism + generation-perf suites,
## prints a PASS/FAIL/BLOCKED table and exits non-zero if anything FAILED.
##
##   godot --headless --path <project> --script res://tools/run_tests.gd
##
## Optional user args (after `--`):
##   --phase2          internal: run ONLY the second-process determinism check (D2) and
##                     write its result JSON, then exit. The main run spawns this itself in
##                     a genuinely separate process, because D2 must not share a process
##                     with D1.
##   --golden-modular=<path>  override the committed golden file for the MODULAR backends
##                     (tests/determinism/golden_hashes_modular.json by default)
##   --skip-perf       skip the generation benchmark (fast iteration)
##   --with-runtime    also run the windowed runtime benchmark (needs a display; off by
##                     default because it takes minutes)
##   --json=<path>     override the results JSON path
##
## Results are written to res://docs/reports/test_results.json.
## Exit code: 1 if any check FAILED, 0 otherwise (BLOCKED does not fail the build - a human
## is expected to run those; see docs/TESTING.md).

const DEFAULT_RESULTS_PATH := "res://docs/reports/test_results.json"
const PHASE2_PATH := "res://tests/determinism/second_process_result.json"

const SMOKE_MODULES: Array[String] = [
	"res://tests/smoke/test_hash64.gd",
	"res://tests/smoke/test_extension.gd",
	"res://tests/smoke/test_assets.gd",
	"res://tests/smoke/test_generators.gd",
	"res://tests/smoke/test_scene.gd",
	"res://tests/smoke/test_spine.gd",
	"res://tests/smoke/test_extensibility.gd",
	"res://tests/smoke/test_task0_regressions.gd",
]
const DETERMINISM_MODULE := "res://tests/determinism/test_determinism.gd"
const PERF_MODULES: Array[String] = [
	"res://tests/perf/bench_generation.gd",
]
const RUNTIME_MODULE := "res://tests/perf/bench_runtime.gd"
const WORLD_SCENE := "res://src/runtime/world/world.tscn"


func _initialize() -> void:
	_run()


func _run() -> void:
	var user_args := OS.get_cmdline_user_args()
	var results: Array = []
	var started := Time.get_ticks_msec()

	if "--phase2" in user_args:
		var p2ctx := _ctx("second_process")
		var golden_override := _arg_value(user_args, "--golden=", "")
		if golden_override != "":
			p2ctx["golden_path"] = golden_override
		var modular_override := _arg_value(user_args, "--golden-modular=", "")
		if modular_override != "":
			p2ctx["golden_modular_path"] = modular_override
		# Async: the determinism module's D6 parity check awaits nothing today, but the module
		# runner must support coroutine modules or a future `await` inside run() would be
		# reported as "run() did not return an Array" - a false failure.
		results = await TestHarness.run_module_async(DETERMINISM_MODULE, p2ctx)
		# The nonce is how the parent proves this file was written by THE CHILD IT JUST
		# SPAWNED and not left over from an earlier run (Task 0.3, stale-result false PASS).
		JsonData.save_file(PHASE2_PATH, {
			"run_nonce": _arg_value(user_args, "--nonce=", ""),
			"pid": OS.get_process_id(),
			"results": results,
		})
		print(TestHarness.format_table(results))
		quit(TestHarness.exit_code(results))
		return

	print("")
	print("############################################################")
	print("# VoxelTerrain M00 headless test run")
	print("# Godot %s   Voxel Tools %s" % [Engine.get_version_info().get("string"), _voxel_version()])
	print("# OS %s   threads %d   headless %s" % [OS.get_name(), OS.get_processor_count(), str(OS.has_feature("headless"))])
	print("############################################################")

	for module in SMOKE_MODULES:
		print("\n--- %s ---" % module)
		var r: Array = await TestHarness.run_module_async(module, _ctx("main"))
		results.append_array(r)
		for x in r:
			print("   [%s] %s %s" % [x["status"], x["id"], x["message"]])

	print("\n--- %s (phase 1: D1, D3, D4, D5) ---" % DETERMINISM_MODULE)
	var det: Array = await TestHarness.run_module_async(DETERMINISM_MODULE, _ctx("main"))
	results.append_array(det)
	for x in det:
		print("   [%s] %s %s" % [x["status"], x["id"], x["message"]])

	# D2 needs a genuinely separate process. Spawn ourselves with --phase2 using the same
	# engine binary, then merge the result it wrote.
	print("\n--- second process (D2: golden hash comparison) ---")
	var d2 := await _run_second_process()
	results.append_array(d2)
	for x in d2:
		print("   [%s] %s %s" % [x["status"], x["id"], x["message"]])

	if "--skip-perf" in user_args:
		results.append(TestHarness.blocked("perf", "P-GEN", "generation benchmark skipped via --skip-perf"))
	else:
		for module in PERF_MODULES:
			print("\n--- %s ---" % module)
			var p: Array = await TestHarness.run_module_async(module, _ctx("main"))
			results.append_array(p)
			for x in p:
				print("   [%s] %s %s" % [x["status"], x["id"], x["message"]])

	if "--with-runtime" in user_args:
		print("\n--- %s (needs a window) ---" % RUNTIME_MODULE)
		var rt_ctx := _ctx("main")
		var rt_pre: Array = []
		var rt: Array = []
		var world := TestHarness.load_world(rt_ctx, WORLD_SCENE, rt_pre)
		results.append_array(rt_pre)
		if world != null:
			# Give the streamer time to fill the default view distance before sampling.
			for i in 30:
				await process_frame
			rt = await TestHarness.run_module_async(RUNTIME_MODULE, rt_ctx)
			TestHarness.unload_world(rt_ctx)
		else:
			rt = [TestHarness.fail("perf", "R0", "world scene could not be loaded for the runtime benchmark")]
		results.append_array(rt)
		for x in rt:
			print("   [%s] %s %s" % [x["status"], x["id"], x["message"]])
	else:
		results.append(TestHarness.blocked(
			"perf", "P-RUN",
			"runtime benchmark not run from the headless runner",
			"It needs a real window and takes ~3 minutes. Run it separately: see docs/TESTING.md"
		))

	var elapsed := (Time.get_ticks_msec() - started) / 1000.0
	var out_path := _arg_value(user_args, "--json=", DEFAULT_RESULTS_PATH)
	var summary := {
		"godot": Engine.get_version_info().get("string"),
		"voxel_tools": _voxel_version(),
		"os": OS.get_name(),
		"headless": OS.has_feature("headless"),
		"threads": OS.get_processor_count(),
		"elapsed_seconds": elapsed,
		"total": results.size(),
		"pass": TestHarness.count(results, "PASS"),
		"fail": TestHarness.count(results, "FAIL"),
		"blocked": TestHarness.count(results, "BLOCKED"),
		"exit_code": TestHarness.exit_code(results),
		"results": results,
	}
	JsonData.save_file(out_path, summary)

	print(TestHarness.format_table(results))
	print("")
	print("results written to %s (%.1fs)" % [out_path, elapsed])
	if summary["fail"] > 0:
		print("RESULT: FAIL (%d failed checks)" % summary["fail"])
	elif summary["blocked"] > 0:
		print("RESULT: PASS with %d BLOCKED check(s) needing a human/window/device" % summary["blocked"])
	else:
		print("RESULT: PASS")
	quit(int(summary["exit_code"]))


func _ctx(phase: String) -> Dictionary:
	return {
		"phase": phase,
		"tree": self,
		"root": root,
		"results_dir": "res://docs/reports/",
		"project_root": ProjectSettings.globalize_path("res://"),
	}


func _run_second_process() -> Array:
	var exe := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")

	# Task 0.3: remove any committed/leftover result file BEFORE spawning, so nothing stale
	# can ever be read. The file is a generated artifact and is gitignored.
	if FileAccess.file_exists(PHASE2_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PHASE2_PATH))

	var nonce := "n%d-%d" % [Time.get_ticks_usec(), OS.get_process_id()]
	var args := ["--headless", "--path", project, "--script", "res://tools/run_tests.gd", "--", "--phase2", "--nonce=" + nonce]
	var output: Array = []

	# In Godot 4 OS.execute() returns the CHILD'S EXIT CODE, and any non-zero value looks
	# exactly like a spawn failure (Task 0.1). A golden-hash mismatch makes the child exit 1,
	# so the exit code alone must never be reported as "could not spawn". The child's result
	# file, validated by nonce, is the source of truth; the exit code is evidence.
	var exit_code := OS.execute(exe, args, output, true)

	var read := GoldenCompare.read_child_result(PHASE2_PATH, nonce)
	if read["ok"]:
		var res: Array = read["results"]
		# Record the child's exit code on every result so a mismatch (exit 1) is visible in
		# the parent's evidence even though the results themselves carry the real verdict.
		for r in res:
			if r is Dictionary:
				r["evidence"] = String(r.get("evidence", "")) + "\nchild process exit code: %d" % exit_code
		if exit_code != 0:
			print("run_tests: second process exited %d; its own results above are authoritative" % exit_code)
		return res

	# No fresh result: NOW it is a spawn/infrastructure failure, and we say precisely which.
	var reason := "could not obtain fresh results from the second process"
	if exit_code != 0:
		reason += " (OS.execute returned %d, which may be the child's exit code or a spawn error)" % exit_code
	else:
		reason += " (child exited 0 but wrote no fresh result file)"
	return [TestHarness.fail("determinism", "D2", reason,
		"validation: %s\nexe=%s\nargs=%s\noutput tail: %s" % [read["error"], exe, str(args), _tail(output)])]


func _tail(output: Array) -> String:
	var s: Array[String] = []
	var start := maxi(0, output.size() - 12)
	for i in range(start, output.size()):
		s.append(str(output[i]))
	return "\n".join(s)


func _arg_value(args: Array, prefix: String, fallback: String) -> String:
	for a in args:
		var s := String(a)
		if s.begins_with(prefix):
			return s.substr(prefix.length())
	return fallback


func _voxel_version() -> String:
	if not ClassDB.class_exists("VoxelEngine"):
		return "NOT LOADED"
	var ve: Object = ClassDB.instantiate("VoxelEngine")
	if ve == null:
		return "UNAVAILABLE"
	var v := "%s.%s.%s %s (%s)" % [
		ve.call("get_version_major"), ve.call("get_version_minor"), ve.call("get_version_patch"),
		ve.call("get_version_edition"), ve.call("get_version_status"),
	]
	ve.free()
	return v
