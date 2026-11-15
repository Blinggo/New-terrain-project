class_name GoldenCompare
extends RefCounted
## tests/determinism/golden_compare.gd
##
## M01 / Task 0 - The single implementation of "compare freshly generated chunk hashes
## against a golden table", shared by:
##   * the second-process child (D2 / X11),
##   * the parent runner (to validate the child's result file and its freshness nonce),
##   * the X12 regression test (which corrupts a golden IN MEMORY and asserts the failure
##     message is a mismatch report, never a spawn misdiagnosis).
##
## Keeping it here means the message format cannot drift between child and test, which is
## exactly the defect Task 0.2 called out: the child used to hardcode the success string
## even when status was FAIL.

const SUITE := "determinism"


## Compare `golden` (parsed golden_hashes*.json) against freshly generated hashes.
## Returns:
##   { "checked": int, "matched": int, "mismatches": Array[String],
##     "per_gen": Array[String], "env_ok": bool, "ok": bool }
## `adapter_ids` lets a caller compare only one backend (multipass child vs both).
static func compare(golden: Dictionary, origins: Array, cfg: WorldConfig, adapter_ids: Array) -> Dictionary:
	var by_gen: Dictionary = golden.get("by_generator", {})
	var mismatches: Array = []
	var per_gen: Array[String] = []
	var checked := 0

	for id_variant in adapter_ids:
		var id := String(id_variant)
		if not by_gen.has(id):
			mismatches.append("%s: no golden section" % id)
			continue
		var built := AdapterRegistry.build_generator(id, int(golden.get("seed", cfg.seed_value)), cfg.to_gen_context())
		if not built["ok"]:
			mismatches.append("%s: generator failed to build: %s" % [id, built["report"].get("error", "?")])
			continue
		var fresh: Dictionary = ChunkHasher.hash_all(built["generator"], origins, ChunkOrigins.BLOCK, int(golden.get("type_depth_bits", 8)))
		var gold: Dictionary = by_gen[id]
		var diffs := _diff(gold, fresh)
		checked += gold.size()
		mismatches.append_array(diffs)
		per_gen.append("%s: %d/%d match" % [id, gold.size() - diffs.size(), gold.size()])

	return {
		"checked": checked,
		"matched": checked - mismatches.size(),
		"mismatches": mismatches,
		"per_gen": per_gen,
		"env_ok": _environment_matches(golden),
		"ok": mismatches.is_empty() and checked > 0,
	}


## Compose the human message FROM THE COUNTS. Never a hardcoded success string: a FAIL must
## read as a FAIL (Task 0.2).
static func compose_message(res: Dictionary, label: String = "second process") -> String:
	var n_mis: int = res["mismatches"].size()
	if n_mis == 0:
		return "%s reproduced %d/%d committed golden hashes (0 mismatches)" % [label, res["matched"], res["checked"]]
	return "%s reproduced %d/%d golden hashes (%d mismatch%s)" % [
		label, res["matched"], res["checked"], n_mis, "" if n_mis == 1 else "es"]


static func compose_evidence(res: Dictionary, golden_path: String, extra: String = "") -> String:
	var lines: Array[String] = []
	lines.append("process pid=%d" % OS.get_process_id())
	lines.append_array(res["per_gen"])
	lines.append("golden: %s" % golden_path)
	lines.append("env match: %s" % str(res["env_ok"]))
	if extra != "":
		lines.append(extra)
	if not res["mismatches"].is_empty():
		lines.append("mismatches (%d): %s" % [res["mismatches"].size(), str(res["mismatches"].slice(0, 5))])
	return "\n".join(lines)


## Read and validate the child's result file (Task 0.3).
## Returns {"ok": bool, "error": String, "results": Array, "nonce": String, "pid": int}.
## A file whose run_nonce differs from what the parent passed to the child is STALE and is
## rejected even though it parses - that is the false-PASS the reviewer flagged.
static func read_child_result(path: String, expected_nonce: String) -> Dictionary:
	var out := {"ok": false, "error": "", "results": [], "nonce": "", "pid": -1}
	if not FileAccess.file_exists(path):
		out["error"] = "child result file does not exist: %s" % path
		return out
	var data: Dictionary = JsonData.load_file(path)
	if data.is_empty():
		out["error"] = "child result file is empty or unparsable: %s" % path
		return out
	var nonce := String(data.get("run_nonce", ""))
	out["nonce"] = nonce
	out["pid"] = int(data.get("pid", -1))
	if nonce != expected_nonce:
		out["error"] = (
			"STALE child result file: nonce '%s' != nonce passed to child '%s' (pid in file %d). "
			% [nonce, expected_nonce, out["pid"]]
			+ "Refusing to trust it; the child either never ran or never wrote.")
		return out
	var res: Array = data.get("results", [])
	if res.is_empty():
		out["error"] = "child result file has a matching nonce but zero results"
		return out
	out["results"] = res
	out["ok"] = true
	return out


static func _diff(a: Dictionary, b: Dictionary) -> Array:
	var diffs := []
	for k in a:
		if not b.has(k):
			diffs.append("origin %s missing from fresh hashes" % k)
		elif String(a[k]) != String(b[k]):
			diffs.append("origin %s: golden %s != fresh %s" % [k, a[k], b[k]])
	for k in b:
		if not a.has(k):
			diffs.append("origin %s present in fresh hashes but not in golden" % k)
	return diffs


## Environment drift is INFORMATION, not pass/fail: a golden mismatch after an engine upgrade
## is expected, and saying so here stops us misreading it as a determinism bug.
static func _environment_matches(golden: Dictionary) -> bool:
	var godot_now: String = String(Engine.get_version_info().get("string"))
	var block_now := ChunkOrigins.BLOCK
	return String(golden.get("godot", godot_now)) == String(godot_now) \
		and int(golden.get("block_size", block_now)) == int(block_now)
