extends RefCounted
## tests/smoke/test_extensibility.gd
##
## M01 / Task 10 - The two tests that define whether the spine actually delivers on its
## promise:
##
##   X1 ADDITIVE STABILITY: register a brand-new no-op module that publishes a channel
##      nobody consumes, reload, re-resolve - and every existing M00 golden hash must still
##      reproduce. This is the single most important test in M01: it proves "adding a module"
##      cannot perturb existing terrain.
##   X2 UNACCOUNTED CHANNEL: module A publishes `field.not_in_any_spec`, a channel that
##      appears in NO spec, enum or list anywhere; module B requires and consumes it. Works
##      with zero edits to any pre-existing file (both modules are new files under the
##      user:// modding root), and the value round-trips through the blackboard.
##
## Both write throwaway files into user://modules/ and delete them afterwards.

const SUITE := "smoke"
const USER_MODULES := "user://modules/"

var _created: Array[String] = []


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	out.append(_x1_additive_stability())
	_cleanup()
	out.append(_x2_unaccounted_channel())
	_cleanup()
	return out


# --- X1 -----------------------------------------------------------------------------------

func _x1_additive_stability() -> Dictionary:
	var cfg := WorldConfig.load_config()
	var golden: Dictionary = JsonData.load_file("res://tests/determinism/golden_hashes.json")
	if golden.is_empty():
		return TestHarness.fail(SUITE, "X1", "M00 golden file unreadable")
	var origins := ChunkOrigins.get_origins(cfg.sea_level)

	# Baseline: resolved pipeline WITHOUT the extra module.
	var base := PipelineBootstrap.build(cfg.to_gen_context())
	if not base["ok"]:
		return TestHarness.fail(SUITE, "X1", "baseline pipeline failed", str(base["errors"]))
	var base_ids: Array = base["scheduler"].pipeline_dump().map(func(m): return m["id"])

	# Register the no-op module on disk, exactly as a modder or a future milestone would.
	_write_script("noop_module.gd",
		"extends FieldProvider\n\n"
		+ "func _init() -> void:\n"
		+ "\tid = &\"tests.noop_v1\"\n"
		+ "\tversion = 1\n"
		+ "\tphase = Phase.DECORATE\n"
		+ "\tpriority = 900\n"
		+ "\tprovides = [&\"field.test_dummy\"]\n\n"
		+ "func compute_region(ctx: GenContext) -> void:\n"
		+ "\tctx.publish(&\"field.test_dummy\", 1.0, id, GenBlackboard.Scope.WORLD)\n")
	_write_tres("noop_module.tres", "noop_module.gd", "")

	var extended := PipelineBootstrap.build(cfg.to_gen_context())
	if not extended["ok"]:
		return TestHarness.fail(SUITE, "X1", "pipeline with the new module failed", str(extended["errors"]))
	var ext_ids: Array = extended["scheduler"].pipeline_dump().map(func(m): return m["id"])
	var registered := ext_ids.has("tests.noop_v1") and ext_ids.size() == base_ids.size() + 1

	# Re-hash every M00 origin with the graph backend driven by the EXTENDED pipeline.
	var gen_ctx := cfg.to_gen_context()
	gen_ctx["pipeline"] = extended
	var built := AdapterRegistry.build_generator("graph", cfg.seed_value, gen_ctx)
	if not built["ok"]:
		return TestHarness.fail(SUITE, "X1", "graph generator failed with extended pipeline", str(built["report"]))
	var fresh: Dictionary = ChunkHasher.hash_all(built["generator"], origins, ChunkOrigins.BLOCK, cfg.type_depth_bits)
	var gold: Dictionary = golden["by_generator"]["graph"]
	var diffs := []
	for k in gold:
		if String(gold[k]) != String(fresh.get(k, "<missing>")):
			diffs.append(k)

	var ok := registered and diffs.is_empty()
	return TestHarness.result(SUITE, "X1", "PASS" if ok else "FAIL",
		"adding a no-op module changes NOTHING: all %d M00 graph goldens reproduce" % gold.size(),
		"registered=%s (pipeline %d -> %d modules), mismatched origins=%s" % [
			str(registered), base_ids.size(), ext_ids.size(), str(diffs.slice(0, 5))])


# --- X2 -----------------------------------------------------------------------------------

func _x2_unaccounted_channel() -> Dictionary:
	var cfg := WorldConfig.load_config()

	_write_script("provider_unknown.gd",
		"extends FieldProvider\n\n"
		+ "func _init() -> void:\n"
		+ "\tid = &\"tests.unknown_provider\"\n"
		+ "\tversion = 1\n"
		+ "\tphase = Phase.PLANET\n"
		+ "\tpriority = 5\n"
		+ "\tprovides = [&\"field.not_in_any_spec\"]\n\n"
		+ "func compute_region(ctx: GenContext) -> void:\n"
		+ "\tctx.publish(&\"field.not_in_any_spec\", 42.0, id, GenBlackboard.Scope.WORLD)\n")
	_write_tres("provider_unknown.tres", "provider_unknown.gd", "")

	_write_script("consumer_unknown.gd",
		"extends TerrainPass\n\n"
		+ "func _init() -> void:\n"
		+ "\tid = &\"tests.unknown_consumer\"\n"
		+ "\tversion = 1\n"
		+ "\tphase = Phase.SURFACE\n"
		+ "\tpriority = 5\n"
		+ "\textent = 0\n"
		+ "\trequires = [&\"field.not_in_any_spec\"]\n\n"
		+ "func apply(ctx: GenContext) -> void:\n"
		+ "\tvar v: Variant = ctx.read(&\"field.not_in_any_spec\")\n"
		+ "\tctx.publish(&\"tests.observed\", v, id)\n")
	_write_tres("consumer_unknown.tres", "consumer_unknown.gd", "")

	var pipeline := PipelineBootstrap.build(cfg.to_gen_context())
	if not pipeline["ok"]:
		return TestHarness.fail(SUITE, "X2", "pipeline with the unaccounted channel failed to resolve",
			str(pipeline["errors"]))
	var ids: Array = pipeline["scheduler"].pipeline_dump().map(func(m): return m["id"])
	if not (ids.has("tests.unknown_provider") and ids.has("tests.unknown_consumer")):
		return TestHarness.fail(SUITE, "X2", "modules not in resolved pipeline", str(ids))

	var ctx := GenContext.new()
	ctx.blackboard = GenBlackboard.new()
	ctx.cache = FieldCache.new()
	ctx.cache.configure_budget(cfg.tier_field_cache_bytes())
	ctx.config = cfg.to_gen_context()
	ctx.world_seed = cfg.seed_value
	ctx.writer = MemWriter.new()
	var runner := PipelineRunner.new()
	runner.ctx = ctx
	runner.scheduler = pipeline["scheduler"]
	runner.run_column(Vector3i(0, -64, 0), ctx.writer)

	var observed: Variant = ctx.blackboard.try_read(&"tests.observed", "<none>")
	var ok := observed is float and is_equal_approx(float(observed), 42.0)
	return TestHarness.result(SUITE, "X2", "PASS" if ok else "FAIL",
		"a channel no spec knows about round-trips producer -> blackboard -> consumer",
		"observed=%s (expected 42.0); zero pre-existing files edited: both modules are new files under %s" % [
			str(observed), USER_MODULES])


# --- helpers ------------------------------------------------------------------------------

class MemWriter extends IColumnWriter:
	var data := {}
	var origin := Vector3i.ZERO

	func set_type(lx: int, wy: int, lz: int, id: int) -> void:
		data[Vector3i(lx, wy, lz)] = id

	func get_type(lx: int, wy: int, lz: int) -> int:
		return int(data.get(Vector3i(lx, wy, lz), 0))

	func column_origin() -> Vector3i:
		return origin


func _write_script(file_name: String, body: String) -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(USER_MODULES)):
		DirAccess.make_dir_recursive_absolute(USER_MODULES)
	var path := USER_MODULES + file_name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()
	_created.append(path)


func _write_tres(file_name: String, script_file: String, _extra: String) -> void:
	var path := USER_MODULES + file_name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(
		"[gd_resource type=\"Resource\" load_steps=2 format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"%s\" id=\"1\"]\n\n" % (USER_MODULES + script_file)
		+ "[resource]\nscript = ExtResource(\"1\")\n")
	f.close()
	_created.append(path)


func _cleanup() -> void:
	for p in _created:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	_created.clear()
