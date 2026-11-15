extends RefCounted
## tests/smoke/test_extensibility.gd
##
## M01 / Task 10, rewritten in the M01 fix - The two tests that define whether the spine
## actually delivers on its promise:
##
##   X1 ADDITIVE STABILITY: drop a brand-new module into the modding root that publishes a
##      channel nobody consumes and writes no voxels, re-resolve, re-generate - and every
##      COMMITTED golden hash of the DEFAULT backend must still reproduce. This is the single
##      most important test in M01: it proves "adding a module" cannot perturb existing terrain.
##      M01-fix: it now runs on the DEFAULT backend (the one that executes modules). Running it
##      on the compiled graph proved nothing, because the graph ignores the module set entirely
##      - that is reviewer evidence E2, and X13 in test_spine.gd is its converse.
##   X2 UNACCOUNTED CHANNEL: module A publishes `field.not_in_any_spec`, a channel that appears
##      in NO spec, enum or list anywhere; module B requires and consumes it. Works with zero
##      edits to any pre-existing file (both modules are new files under the user:// modding
##      root), and the value round-trips through the blackboard while the shipped surface module
##      still writes real terrain in the same run.
##
## Both write throwaway files into user://modules/ and delete them afterwards, and both assert
## the root is empty when they finish: a leftover .tres there makes the NEXT suite fail to boot
## (that isolation defect was real - see X0/X7 in test_spine.gd).
##
## Contract notes for anyone extending these fixtures:
##   * `phase` no longer exists. A module sets `phase_order` (plain int) and `phase_name`
##     (plain StringName), or calls use_known_phase() for one of the shipped stages. An
##     UNPLANNED stage needs no edit to src/spine/ - X17 in test_spine.gd proves that.
##   * every entry of `requires`/`provides` needs a `channel_declarations` entry
##     {type, scope, version}; the scheduler rejects an undeclared one (X18).

const SUITE := "smoke"
const USER_MODULES := "user://modules/"
const GOLDEN_MODULAR := "res://tests/determinism/golden_hashes_modular.json"
const GOLDEN_M00 := "res://tests/determinism/golden_hashes.json"

var _created: Array[String] = []


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	_purge_root()
	out.append(_x1_additive_stability())
	_cleanup()
	out.append(_x2_unaccounted_channel())
	_cleanup()
	out.append(_x2b_root_left_clean())
	return out


# --- X1 -----------------------------------------------------------------------------------

func _x1_additive_stability() -> Dictionary:
	var cfg := WorldConfig.load_config()
	var modular: Dictionary = JsonData.load_file(GOLDEN_MODULAR)
	if modular.is_empty():
		return TestHarness.fail(SUITE, "X1", "modular golden file unreadable: " + GOLDEN_MODULAR,
			"run: godot --headless --path . --script res://tools/make_golden_hashes.gd")
	var origins := ChunkOrigins.get_origins(cfg.sea_level)
	var backend := AdapterRegistry.DEFAULT_ID

	# Baseline: resolved pipeline WITHOUT the extra module.
	var base := PipelineBootstrap.build(cfg.to_gen_context())
	if not base["ok"]:
		return TestHarness.fail(SUITE, "X1", "baseline pipeline failed", str(base["errors"]))
	var base_ids: Array = base["scheduler"].pipeline_dump().map(func(m): return m["id"])

	# Register the no-op module on disk, exactly as a modder or a future milestone would: one
	# .gd + one .tres under the modding root. No existing file is touched.
	_write_script("noop_module.gd",
		"extends FieldProvider\n"
		+ "## THROWAWAY fixture: publishes a channel nobody consumes and writes no voxels.\n\n"
		+ "func _init() -> void:\n"
		+ "\tid = &\"tests.noop_v1\"\n"
		+ "\tversion = 1\n"
		+ "\tphase_order = 9\n"
		+ "\tphase_name = &\"DECORATE\"\n"
		+ "\tpriority = 900\n"
		+ "\tprovides = [&\"field.test_dummy\"]\n"
		+ "\tchannel_declarations = {&\"field.test_dummy\": {\"type\": \"FLOAT\", \"scope\": \"world\", \"version\": 1}}\n\n"
		+ "func compute_region(ctx: GenContext) -> void:\n"
		+ "\tctx.publish(&\"field.test_dummy\", 1.0, id, GenBlackboard.Scope.WORLD)\n")
	_write_tres("noop_module.tres", "noop_module.gd")

	var extended := PipelineBootstrap.build(cfg.to_gen_context())
	if not extended["ok"]:
		return TestHarness.fail(SUITE, "X1", "pipeline with the new module failed", str(extended["errors"]))
	var ext_ids: Array = extended["scheduler"].pipeline_dump().map(func(m): return m["id"])
	var registered := ext_ids.has("tests.noop_v1") and ext_ids.size() == base_ids.size() + 1

	# Re-hash every committed origin with the DEFAULT backend driven by the EXTENDED pipeline.
	var gen_ctx := cfg.to_gen_context()
	gen_ctx["pipeline"] = extended
	var built := AdapterRegistry.build_generator(backend, cfg.seed_value, gen_ctx)
	if not built["ok"]:
		return TestHarness.fail(SUITE, "X1", "%s generator failed with the extended pipeline" % backend,
			str(built["report"]))
	var fresh: Dictionary = ChunkHasher.hash_all(built["generator"], origins, ChunkOrigins.BLOCK, cfg.type_depth_bits)
	var gold: Dictionary = modular["by_generator"][backend]
	var diffs: Array[String] = []
	for k in gold:
		if String(gold[k]) != String(fresh.get(k, "<missing>")):
			diffs.append(String(k))

	# Did the added module actually EXECUTE? "Nothing changed" is only a stability result if the
	# module ran; a module silently dropped would also change nothing (evidence E2).
	var st: Dictionary = built["generator"].call("stats") if built["generator"].has_method("stats") else {}
	var executed: Dictionary = st.get("executed_counts", {})
	var ran := int(executed.get("tests.noop_v1", 0))

	# And the M00 legacy graph goldens are the same bytes, which is why one table can serve both.
	var m00: Dictionary = JsonData.load_file(GOLDEN_M00)
	var graph_gold: Dictionary = m00.get("by_generator", {}).get("graph", {})
	var same_as_m00 := 0
	for k in graph_gold:
		if String(fresh.get(k, "?")) == String(graph_gold[k]):
			same_as_m00 += 1

	var ok := registered and diffs.is_empty() and ran > 0
	return TestHarness.result(SUITE, "X1", "PASS" if ok else "FAIL",
		"adding a no-op module changes NOTHING: all %d committed %s goldens reproduce, and the module ran %d times" % [
			gold.size(), backend, ran],
		"registered=%s (pipeline %d -> %d modules: %s)\n" % [str(registered), base_ids.size(), ext_ids.size(), str(ext_ids)]
		+ "mismatched origins vs %s = %s\n" % [GOLDEN_MODULAR, str(diffs.slice(0, 5))]
		+ "identical to the M00 legacy graph goldens = %d/%d (the modular goldens ARE the graph's bytes)\n" % [
			same_as_m00, graph_gold.size()]
		+ "executed_counts = %s\n" % str(executed)
		+ "zero pre-existing files edited: the module is one new .gd + one new .tres under %s" % USER_MODULES)


# --- X2 -----------------------------------------------------------------------------------

func _x2_unaccounted_channel() -> Dictionary:
	var cfg := WorldConfig.load_config()

	_write_script("provider_unknown.gd",
		"extends FieldProvider\n"
		+ "## THROWAWAY fixture: publishes a channel that appears in no spec, enum or list.\n\n"
		+ "func _init() -> void:\n"
		+ "\tid = &\"tests.unknown_provider\"\n"
		+ "\tversion = 1\n"
		+ "\tphase_order = 0\n"
		+ "\tphase_name = &\"PLANET\"\n"
		+ "\tpriority = 5\n"
		+ "\tprovides = [&\"field.not_in_any_spec\"]\n"
		+ "\tchannel_declarations = {&\"field.not_in_any_spec\": {\"type\": \"FLOAT\", \"scope\": \"world\", \"version\": 1}}\n\n"
		+ "func compute_region(ctx: GenContext) -> void:\n"
		+ "\tctx.publish(&\"field.not_in_any_spec\", 42.0, id, GenBlackboard.Scope.WORLD)\n")
	_write_tres("provider_unknown.tres", "provider_unknown.gd")

	_write_script("consumer_unknown.gd",
		"extends TerrainPass\n"
		+ "## THROWAWAY fixture: consumes the unaccounted channel and republishes what it saw on\n"
		+ "## an UNDECLARED channel (unknown channel names stay legal; undeclared requires/provides\n"
		+ "## entries do not).\n\n"
		+ "func _init() -> void:\n"
		+ "\tid = &\"tests.unknown_consumer\"\n"
		+ "\tversion = 1\n"
		+ "\tphase_order = 3\n"
		+ "\tphase_name = &\"SURFACE\"\n"
		+ "\tpriority = 5\n"
		+ "\textent = 0\n"
		+ "\trequires = [&\"field.not_in_any_spec\"]\n"
		+ "\tchannel_declarations = {&\"field.not_in_any_spec\": {\"type\": \"FLOAT\", \"scope\": \"world\", \"version\": 1}}\n\n"
		+ "func apply(ctx: GenContext) -> void:\n"
		+ "\tvar v: Variant = ctx.read(&\"field.not_in_any_spec\")\n"
		+ "\tctx.publish(&\"tests.observed\", v, id)\n")
	_write_tres("consumer_unknown.tres", "consumer_unknown.gd")

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
	ctx.cache.configure_world(cfg.seed_value, cfg.worldgen_version, cfg.quality_tier)
	ctx.config = cfg.to_gen_context()
	ctx.quality_tier = cfg.quality_tier
	ctx.world_seed = cfg.seed_value
	# A real sink, so the SHIPPED modules run in the same pass: the unaccounted channel must
	# round-trip without breaking the terrain that was already there.
	var writer := MemoryColumnWriter.new()
	writer.setup(Vector3i(0, cfg.world_y_min, 0), ChunkOrigins.BLOCK, cfg.world_height(), ChunkOrigins.BLOCK)
	ctx.writer = writer
	# The sampler the shipped planet module needs, built the way a backend builds it: from the
	# first noise_sampler_recipe() in the resolved plan (no content id named here).
	var recipe := NoiseSamplerBuilder.first_recipe(pipeline["modules"])
	var noise := NoiseSamplerBuilder.build(recipe, cfg.seed_value)
	if noise == null:
		return TestHarness.fail(SUITE, "X2", "no noise sampler could be built for the extended pipeline",
			NoiseSamplerBuilder.describe(recipe))
	ctx.noise_2d = noise.get_noise_2d

	var runner := PipelineRunner.new()
	runner.ctx = ctx
	runner.scheduler = pipeline["scheduler"]
	runner.run_column(Vector3i(0, cfg.world_y_min, 0), writer)

	var observed: Variant = ctx.blackboard.try_read(&"tests.observed", "<none>")
	var round_trip := observed is float and is_equal_approx(float(observed), 42.0)

	# The shipped surface module must still have written terrain in that same run. Sampled down a
	# column, not across the tops: every top block is the same id by design (grass), so counting
	# distinct TOP ids would have "proved" nothing about the surface pass.
	var solid := 0
	var sampled := 0
	var distinct := {}
	for lz in range(0, ChunkOrigins.BLOCK, 4):
		for lx in range(0, ChunkOrigins.BLOCK, 4):
			sampled += 1
			var top := writer.top_solid(lx, lz)
			if top >= cfg.world_y_min:
				solid += 1
			for wy in range(cfg.world_y_min, cfg.world_y_max, 8):
				distinct[writer.get_type_world(Vector3i(lx, wy, lz))] = true
	var terrain_written := solid == sampled and distinct.size() >= 3

	# And the two new modules must have executed, not merely resolved.
	var ran_provider := int(ctx.executed_counts.get("tests.unknown_provider", 0))
	var ran_consumer := int(ctx.executed_counts.get("tests.unknown_consumer", 0))
	var board_errors := ctx.blackboard.errors.duplicate()

	var ok := round_trip and terrain_written and ran_provider > 0 and ran_consumer > 0 and board_errors.is_empty()
	return TestHarness.result(SUITE, "X2", "PASS" if ok else "FAIL",
		"a channel no spec knows about round-trips producer -> blackboard -> consumer, and the shipped terrain still generates",
		"observed=%s (expected 42.0)\n" % str(observed)
		+ "resolved order=%s\n" % str(ids)
		+ "executed: provider=%d consumer=%d  all=%s\n" % [ran_provider, ran_consumer, str(ctx.executed_counts)]
		+ "blackboard errors=%s\n" % str(board_errors)
		+ "shipped terrain in the same run: %d/%d sampled columns solid, distinct ids down the columns=%s\n" % [
			solid, sampled, str(distinct)]
		+ "zero pre-existing files edited: both modules are new files under %s" % USER_MODULES)


# --- X2b ----------------------------------------------------------------------------------

func _x2b_root_left_clean() -> Dictionary:
	var left := _root_entries()
	return TestHarness.result(SUITE, "X2b", "PASS" if left.is_empty() else "FAIL",
		"the modding root is empty again after both extensibility checks",
		"entries=%s (a leftover module would make the next suite resolve a different pipeline)" % str(left))


# --- helpers ------------------------------------------------------------------------------

func _root_entries() -> Array:
	var out: Array = []
	var dir := DirAccess.open("user://modules")
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir():
			out.append("user://modules/" + n)
		n = dir.get_next()
	dir.list_dir_end()
	return out


## Remove anything another run left behind BEFORE measuring: X1's baseline has to be the
## shipped module set, or the check compares against a world nobody shipped.
func _purge_root() -> void:
	for p in _root_entries():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _write_script(file_name: String, body: String) -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(USER_MODULES)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_MODULES))
	var path := USER_MODULES + file_name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("test_extensibility: cannot write %s" % path)
		return
	f.store_string(body)
	f.close()
	_created.append(path)


func _write_tres(file_name: String, script_file: String) -> void:
	var path := USER_MODULES + file_name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("test_extensibility: cannot write %s" % path)
		return
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
	_purge_root()
