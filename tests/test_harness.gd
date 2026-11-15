class_name TestHarness
extends RefCounted
## tests/test_harness.gd
##
## Minimal shared harness for the M00 test suites (smoke / determinism / perf).
## No third-party test framework (milestone hard rule #4: no third-party dependencies).
##
## CONTRACT for a test module
## --------------------------
## A test module is any GDScript that `extends RefCounted` and provides:
##
##     func run(ctx: Dictionary) -> Array    # Array of result Dictionaries
##
## Each result Dictionary:
##     {
##       "suite":   String,   # e.g. "determinism"
##       "id":      String,   # e.g. "D1", "S2", "P1"
##       "status":  String,   # exactly one of PASS / FAIL / BLOCKED
##       "message": String,   # one-line human summary
##       "evidence": String,  # actual output, error text, numbers. Never fabricated.
##     }
##
## `ctx` may carry: {"phase": String, "project_root": String, "results_dir": String}
##
## Statuses
## --------
## PASS    - the check ran and the assertion held.
## FAIL    - the check ran and the assertion did not hold (or it errored).
## BLOCKED - the check could not run in this environment (needs a window, a device, an
##           Android SDK...). BLOCKED is never PASS. tools/run_tests.gd exits non-zero on
##           FAIL only; BLOCKED is reported loudly but does not fail the build, because a
##           human is expected to run those checks.

const STATUSES: Array[String] = ["PASS", "FAIL", "BLOCKED"]


static func result(suite: String, id: String, status: String, message: String, evidence: String = "") -> Dictionary:
	assert(status in STATUSES, "illegal status %s" % status)
	return {
		"suite": suite,
		"id": id,
		"status": status,
		"message": message,
		"evidence": evidence,
	}


static func ok(suite: String, id: String, message: String, evidence: String = "") -> Dictionary:
	return result(suite, id, "PASS", message, evidence)


static func fail(suite: String, id: String, message: String, evidence: String = "") -> Dictionary:
	return result(suite, id, "FAIL", message, evidence)


static func blocked(suite: String, id: String, message: String, evidence: String = "") -> Dictionary:
	return result(suite, id, "BLOCKED", message, evidence)


## Load and run one module. Errors inside a module become a FAIL result rather than
## taking down the whole run - a crashing test must still be reported honestly.
static func run_module(script_path: String, ctx: Dictionary) -> Array:
	var out: Array = []
	if not ResourceLoader.exists(script_path):
		out.append(fail("harness", script_path, "test module file does not exist", script_path))
		return out

	var script: GDScript = load(script_path)
	if script == null:
		out.append(fail("harness", script_path, "could not load test module", script_path))
		return out

	var instance := _instantiate(script_path, script, out)
	if instance == null:
		return out
	if not instance.has_method("run"):
		out.append(fail("harness", script_path, "module has no run(ctx) method", script_path))
		return out

	var res: Variant = instance.call("run", ctx)
	return _collect(out, script_path, res)


## Load a scene into the tree and put it in ctx["world"], so a module can benchmark or
## inspect a real running world instead of building its own. Returns null (with a recorded
## failure) if the scene cannot be instantiated. Used by bench_runtime.gd.
static func load_world(ctx: Dictionary, scene_path: String, out: Array) -> Node:
	if ctx.has("world") and ctx["world"] != null:
		return ctx["world"]
	var root: Node = ctx.get("root")
	if root == null:
		out.append(fail("harness", scene_path, "no root node in the test context"))
		return null
	if not ResourceLoader.exists(scene_path):
		out.append(fail("harness", scene_path, "world scene does not exist", scene_path))
		return null
	var packed: PackedScene = load(scene_path)
	if packed == null or not packed.can_instantiate():
		out.append(fail("harness", scene_path, "world scene could not be instantiated"))
		return null
	var world: Node = packed.instantiate()
	root.add_child(world)
	ctx["world"] = world
	return world


## Free the world loaded by load_world(). Must be called even when a module fails, or the
## next module inherits a live terrain and its numbers are not comparable.
static func unload_world(ctx: Dictionary) -> void:
	var world: Node = ctx.get("world")
	if world != null and is_instance_valid(world):
		world.queue_free()
	ctx["world"] = null


## Same as run_module but awaits the module, so a module may await frames (scene tests need
## a running tree). `await` on a plain function is a no-op, so both kinds work.
static func run_module_async(script_path: String, ctx: Dictionary) -> Array:
	var out: Array = []
	if not ResourceLoader.exists(script_path):
		out.append(fail("harness", script_path, "test module file does not exist", script_path))
		return out

	var script: GDScript = load(script_path)
	if script == null:
		out.append(fail("harness", script_path, "could not load test module", script_path))
		return out

	var instance := _instantiate(script_path, script, out)
	if instance == null:
		return out
	if not instance.has_method("run"):
		out.append(fail("harness", script_path, "module has no run(ctx) method", script_path))
		return out

	var res: Variant = await instance.call("run", ctx)
	return _collect(out, script_path, res)


## Instantiate a module defensively. A script with a parse error loads as a GDScript that
## cannot instantiate; without this guard the run would silently report zero results and
## exit 0 - a false PASS, which is the one thing this harness must never do.
static func _instantiate(script_path: String, script: GDScript, out: Array) -> RefCounted:
	if not script.can_instantiate():
		out.append(fail("harness", script_path,
			"module script cannot be instantiated (parse or compile error)",
			"run: tools/check_scripts.sh  (or --check-only --script %s)" % script_path))
		return null
	var instance: RefCounted = script.new()
	if instance == null:
		out.append(fail("harness", script_path, "module script.new() returned null"))
	return instance


static func _collect(out: Array, script_path: String, res: Variant) -> Array:
	if res is Array:
		for r in res:
			if r is Dictionary:
				out.append(r)
			else:
				out.append(fail("harness", script_path, "module returned a non-Dictionary result", str(r)))
	else:
		out.append(fail("harness", script_path, "module run() did not return an Array", str(typeof(res))))
	if out.is_empty():
		out.append(fail("harness", script_path, "module ran but produced ZERO results",
			"a test module must always report at least one check"))
	return out


static func count(results: Array, status: String) -> int:
	var n := 0
	for r in results:
		if String(r.get("status", "")) == status:
			n += 1
	return n


static func exit_code(results: Array) -> int:
	return 1 if count(results, "FAIL") > 0 else 0


## Fixed-width ASCII table. Deliberately plain so it survives copy-paste into the report.
static func format_table(results: Array) -> String:
	var lines: Array[String] = []
	lines.append("")
	lines.append("+---------+-------------+---------+------------------------------------------------------------+")
	lines.append("| SUITE   | ID          | STATUS  | MESSAGE                                                    |")
	lines.append("+---------+-------------+---------+------------------------------------------------------------+")
	for r in results:
		lines.append("| %-7s | %-11s | %-7s | %-58s |" % [
			_clip(String(r.get("suite", "")), 7),
			_clip(String(r.get("id", "")), 11),
			_clip(String(r.get("status", "")), 7),
			_clip(String(r.get("message", "")), 58),
		])
	lines.append("+---------+-------------+---------+------------------------------------------------------------+")
	lines.append("TOTAL %d  |  PASS %d  |  FAIL %d  |  BLOCKED %d" % [
		results.size(), count(results, "PASS"), count(results, "FAIL"), count(results, "BLOCKED"),
	])
	return "\n".join(lines)


static func _clip(s: String, n: int) -> String:
	if s.length() <= n:
		return s
	return s.substr(0, n - 1) + "~"


## Percentile of a sorted-or-unsorted float array, nearest-rank method.
## Used by the perf benches so p50/p95 are computed identically everywhere.
static func percentile(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted_vals := values.duplicate()
	sorted_vals.sort()
	var rank := int(ceil((p / 100.0) * float(sorted_vals.size())))
	rank = clampi(rank, 1, sorted_vals.size())
	return float(sorted_vals[rank - 1])


static func mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for v in values:
		sum += float(v)
	return sum / float(values.size())
