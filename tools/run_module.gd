extends SceneTree
## tools/run_module.gd
##
## Run ONE test module headless. Handy while iterating and used by docs/TESTING.md to show
## how a single suite is executed.
##
##   godot --headless --path <project> --script res://tools/run_module.gd -- \
##       res://tests/smoke/test_scene.gd
##
## With a live world scene (windowed modules such as bench_runtime.gd):
##   godot --path <project> --script res://tools/run_module.gd -- \
##       res://tests/perf/bench_runtime.gd res://src/runtime/world/world.tscn

func _initialize() -> void:
	_run()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: --script res://tools/run_module.gd -- <module path>")
		quit(2)
		return
	var module := String(args[0])
	# Optional second arg: a scene to load as ctx["world"] (needed by bench_runtime.gd, which
	# measures the real streaming pipeline and therefore needs a live, windowed world).
	var scene_path := String(args[1]) if args.size() > 1 else ""
	print("running module: %s%s" % [module, "" if scene_path.is_empty() else ("  world=" + scene_path)])
	var ctx := {
		"phase": "single",
		"tree": self,
		"root": root,
		"results_dir": "res://docs/reports/",
		"project_root": ProjectSettings.globalize_path("res://"),
	}
	var results: Array = []
	if not scene_path.is_empty():
		var world := TestHarness.load_world(ctx, scene_path, results)
		if world == null:
			print(TestHarness.format_table(results))
			quit(1)
			return
		# Let the streamer settle before the module starts measuring.
		for i in 10:
			await process_frame
	results.append_array(await TestHarness.run_module_async(module, ctx))
	if not scene_path.is_empty():
		TestHarness.unload_world(ctx)
	for r in results:
		print("")
		print("[%s] %s / %s - %s" % [r["status"], r["suite"], r["id"], r["message"]])
		if String(r.get("evidence", "")) != "":
			for line in String(r["evidence"]).split("\n"):
				print("        %s" % line)
	print(TestHarness.format_table(results))
	# Zero results means the module never ran; that is a failure, not a pass.
	quit(1 if results.is_empty() else TestHarness.exit_code(results))
