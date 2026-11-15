extends RefCounted
## tests/smoke/test_task0_regressions.gd
##
## M01 / Task 0.5 - Regression tests for the harness defects the M00 reviewer reproduced:
##
##   0.1 A golden-hash mismatch used to surface as "could not spawn the second process
##       (OS.execute error 1)", because in Godot 4 OS.execute returns the CHILD'S exit code.
##       Regression: corrupt a golden on disk, spawn the real child, and assert the surfaced
##       message is the child's mismatch report (with the count) and never the word "spawn".
##   0.2 The child's D2 message used to be the hardcoded success string even on FAIL.
##       Regression: the corrupted run's message must contain the mismatch count.
##   0.3 A stale second_process_result.json could false-PASS. Regression: a result file with
##       a wrong nonce is rejected; the live runner deletes the file before spawning and the
##       child writes nonce+pid (asserted by the end-to-end spawn below).

const SUITE := "smoke"
const GOLDEN := "res://tests/determinism/golden_hashes.json"


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	out.append(_corrupted_golden_message())
	out.append(_stale_nonce_rejected())
	out.append(_end_to_end_misdiagnosis())
	_cleanup()
	return out


# --- 0.2 / in-memory corruption -----------------------------------------------------------

func _corrupted_golden_message() -> Dictionary:
	var cfg := WorldConfig.load_config()
	var origins := ChunkOrigins.get_origins(cfg.sea_level)
	var golden: Dictionary = JsonData.load_file(GOLDEN)
	if golden.is_empty():
		return TestHarness.fail(SUITE, "X12a", "golden file unreadable")

	# Corrupt exactly one graph hash, in memory only.
	var keys: Array = golden["by_generator"]["graph"].keys()
	var victim: String = String(keys[0])
	var original: String = String(golden["by_generator"]["graph"][victim])
	golden["by_generator"]["graph"][victim] = str(int(original) ^ 0xdeadbeef)

	var res := GoldenCompare.compare(golden, origins, cfg, ["noise2d", "graph"])
	var msg := GoldenCompare.compose_message(res)
	var ok: bool = (not res["ok"]) \
		and res["mismatches"].size() == 1 \
		and msg.find("1 mismatch") >= 0 \
		and msg.find("spawn") < 0
	return TestHarness.result(SUITE, "X12a", "PASS" if ok else "FAIL",
		"a corrupted golden produces a mismatch-count message, never a spawn misdiagnosis",
		"message='%s'\nmismatches=%s" % [msg, str(res["mismatches"])])


# --- 0.3 stale nonce ----------------------------------------------------------------------

func _stale_nonce_rejected() -> Dictionary:
	var path := "user://stale_result.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"run_nonce": "nonce-from-an-earlier-run",
		"pid": 1,
		"results": [{"suite": "determinism", "id": "D2", "status": "PASS",
			"message": "second process reproduced 128 committed golden hashes", "evidence": ""}],
	}))
	f.close()
	var read := GoldenCompare.read_child_result(path, "nonce-the-parent-actually-sent")
	var rejected: bool = (not read["ok"]) and read["error"].find("STALE") >= 0
	var good_results_still_ok := true
	var read2 := GoldenCompare.read_child_result(path, "nonce-from-an-earlier-run")
	good_results_still_ok = read2["ok"]
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return TestHarness.result(SUITE, "X12b", "PASS" if rejected and good_results_still_ok else "FAIL",
		"a result file whose nonce does not match is rejected; a matching nonce is accepted",
		"wrong-nonce error='%s'; matching-nonce ok=%s" % [read["error"], str(read2["ok"])])


# --- 0.1 end-to-end: child exits 1, parent must still surface the child's verdict ---------

func _end_to_end_misdiagnosis() -> Dictionary:
	var cfg := WorldConfig.load_config()
	# Corrupted golden ON DISK (user://), passed to a real child process via --golden.
	var golden: Dictionary = JsonData.load_file(GOLDEN)
	var keys: Array = golden["by_generator"]["graph"].keys()
	var victim: String = String(keys[1 % keys.size()])
	golden["by_generator"]["graph"][victim] = str(int(String(golden["by_generator"]["graph"][victim])) + 1)
	var corrupt_path := "user://corrupted_golden.json"
	JsonData.save_file(corrupt_path, golden)

	var nonce := "x12-%d" % Time.get_ticks_usec()
	var exe := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var args := ["--headless", "--path", project, "--script", "res://tools/run_tests.gd",
		"--", "--phase2", "--nonce=" + nonce, "--golden=" + corrupt_path]
	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)

	var read := GoldenCompare.read_child_result("res://tests/determinism/second_process_result.json", nonce)
	var problems: Array[String] = []
	if exit_code == 0:
		problems.append("child exited 0 despite a corrupted golden (expected 1)")
	if not read["ok"]:
		problems.append("child result not readable/fresh: %s" % read["error"])
	else:
		var child: Dictionary = read["results"][0]
		var msg := String(child.get("message", ""))
		if String(child.get("status", "")) != "FAIL":
			problems.append("child status is %s, expected FAIL" % child.get("status", ""))
		if msg.find("mismatch") < 0:
			problems.append("child message lacks a mismatch count: '%s'" % msg)
		if msg.find("spawn") >= 0:
			problems.append("child message contains the word 'spawn': '%s'" % msg)
		if int(read.get("pid", -1)) <= 0:
			problems.append("child result file did not record the child pid")
	return TestHarness.result(SUITE, "X12c", "PASS" if problems.is_empty() else "FAIL",
		"end-to-end: a mismatching child exits 1 and its REAL verdict reaches the parent",
		"child exit code=%d (OS.execute conflates this with spawn failure - the fix reads the nonce-validated file instead)\nproblems=%s" % [
			exit_code, str(problems)])


func _cleanup() -> void:
	for p in ["user://corrupted_golden.json", "user://stale_result.json"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
