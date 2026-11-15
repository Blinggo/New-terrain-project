extends RefCounted
## tests/smoke/test_spine.gd
##
## M01 / Task 10 - Contract tests for the spine machinery: RNG streams (X3), scheduler
## order stability (X4), cycle detection (X5), missing producer (X6), duplicate id (X7),
## cache eviction/recompute (X8), plus blackboard and field-tile behaviour that the whole
## design rests on. X9 lives in the determinism suite (D5/X9, shared LayerLint).
##
## M01-fix additions (X13..X24). Each one is a REGRESSION TEST for a specific defect the
## independent review found, and each would have failed on the M01 code:
##   X13 an added module changes the DEFAULT backend's output        (evidence E2)
##   X14 a no-op module leaves every golden hash unchanged           (E2's converse)
##   X15 a module with no executable contract is refused loudly      (E2, fail closed)
##   X16 FeatureStamp contracts are executed, not just declared      (T2)
##   X17 an unplanned phase_order/phase_name resolves and runs       (T7/C16 enum gate)
##   X18 channel declarations are enforced on publish and read       (T7)
##   X19 cache keys carry every tile-changing input                  (T5)
##   X20 the surface pass reads exact per-block heights              (evidence E3)
##   X21 the pass plan refuses what the engine cannot run            (T1 limits)
##   X22 live streaming equals the harness, on several worker threads (T1/T4)
##   X23 capability metadata + the fail-closed legacy gate           (T2/T8)
##   X24 FixedPoint boundary behaviour                               (T7)
##   X25 the in-memory harness counts the neighbour reads it cannot serve (T4, honest numbers)
##   X26 a WORLD-scope-only provider executes, and a declared-but-unpublished channel is loud
##
## Modules used by the negative tests are written to user://modules/ (the modding root) and
## deleted afterwards, so the shipped content/modules/ set never changes (B17).

const SUITE := "smoke"
const USER_MODULES := "user://modules/"

var _created_files: Array[String] = []
## Generators built for contexts must stay referenced for the whole test: a
## VoxelGeneratorScript is RefCounted, and dropping the last reference frees the Callable
## target the noise sampler points at.
var _keep_alive: Array = []


var _tree: SceneTree = null


func run(ctx: Dictionary) -> Array:
	_tree = ctx.get("tree")
	var out: Array = []
	out.append(_x0_module_root_clean())
	out.append(_x3_rng_independence())
	out.append(_blackboard_basics())
	out.append(_field_tile_sampling())
	out.append(_x8_cache_recompute())
	out.append_array(_x4_order_stability())
	out.append(_x5_cycle_detection())
	out.append(_x6_missing_producer())
	out.append(_x7_duplicate_id())
	out.append(_scheduler_column_factor())
	out.append(_x18_declarations_enforced())
	out.append(_x19_cache_fingerprint())
	out.append(_x20_exact_height())
	out.append_array(_x21_pass_plan_limits())
	out.append(_x23_capabilities_and_legacy_gate())
	out.append(_x24_fixed_point_boundaries())
	out.append_array(await _x25_harness_neighbour_reads_counted())
	out.append_array(_x26_world_scope_providers_run())
	out.append_array(await _x13_to_x17_module_execution())
	out.append_array(await _x22_live_streaming_matches_harness())
	_cleanup()
	return out


# --- X3 -----------------------------------------------------------------------------------

func _x3_rng_independence() -> Dictionary:
	# 1000 domains at the same coords: pairwise distinct first draws...
	var firsts := {}
	var collisions: Array[String] = []
	for i in 1000:
		var rng := RngStreams.stream_at(20260814, StringName("domain.%d" % i), Vector3i(7, 0, -9))
		var v: int = rng.randi()
		if firsts.has(v):
			collisions.append("domain.%d and %s share first draw %d" % [i, str(firsts[v]), v])
		firsts[v] = "domain.%d" % i

	# ...and adding a brand-new domain never perturbs an existing stream.
	var before: Array = []
	var probe := RngStreams.stream_at(20260814, &"flora.oak", Vector3i(3, 0, 4))
	for i in 100:
		before.append(probe.randi())
	var _new_domain := RngStreams.stream_at(20260814, &"flora.totally_new_domain", Vector3i(3, 0, 4))
	var after: Array = []
	var probe2 := RngStreams.stream_at(20260814, &"flora.oak", Vector3i(3, 0, 4))
	for i in 100:
		after.append(probe2.randi())
	var stable := before == after

	# chance() must be stateless and monotone in probability.
	var c0 := RngStreams.chance(&"t.x", 1, 2, 0.0)
	var c1 := RngStreams.chance(&"t.x", 1, 2, 1.0)
	var repeat := RngStreams.chance(&"t.x", 1, 2, 0.5) == RngStreams.chance(&"t.x", 1, 2, 0.5)

	var ok := collisions.is_empty() and stable and not c0 and c1 and repeat
	return TestHarness.result(SUITE, "X3", "PASS" if ok else "FAIL",
		"1000 domains pairwise independent; new domains do not perturb existing streams",
		"distinct first draws: %d/1000, collisions=%s, existing stream stable after adding a domain=%s, chance(0)=%s chance(1)=%s stateless=%s" % [
			firsts.size(), str(collisions.slice(0, 3)), str(stable), str(c0), str(c1), str(repeat)])


# --- blackboard ---------------------------------------------------------------------------

func _blackboard_basics() -> Dictionary:
	var bb := GenBlackboard.new()
	bb.loud = false   # this test triggers the failure modes on purpose
	bb.publish(&"field.height", 42.5, &"planet.hills_v1", GenBlackboard.Scope.WORLD)
	bb.begin_column(Vector3i(16, 0, 16))
	bb.publish(&"surface.roughness", 3, &"surface.grass_stone_v1")

	var problems: Array[String] = []
	if not bb.has(&"field.height"):
		problems.append("world-scoped publish not readable")
	if int(bb.try_read(&"surface.roughness", -1)) != 3:
		problems.append("column value round-trip failed")
	if bb.try_read(&"field.nobody_home", 7) != 7:
		problems.append("try_read default not honoured")

	# Unknown channels are legal to publish (the X2 property), type flips are not.
	bb.publish(&"field.ice_thickness", 1.5, &"climate.imaginary")
	if not bb.has(&"field.ice_thickness"):
		problems.append("unknown channel publish rejected (must be legal)")
	bb.errors.clear()
	bb.publish(&"field.ice_thickness", 4, &"climate.imaginary2")
	if bb.errors.is_empty():
		problems.append("type-mismatched publish did not error")
	elif bb.errors[0].find("FLOAT") < 0 or bb.errors[0].find("INT") < 0:
		problems.append("type-mismatch error does not name both types: %s" % bb.errors[0])

	# Reading a channel nobody published must be loud, not a silent zero.
	bb.errors.clear()
	var v: Variant = bb.read(&"field.never_published")
	if v != null or bb.errors.is_empty():
		problems.append("read of unpublished channel was silent")

	var dump := bb.debug_dump()
	var has_dims := true
	for row in dump:
		if String(row["scope"]) == "" or String(row["producer"]) == "":
			has_dims = false
	return TestHarness.result(SUITE, "S6a", "PASS" if problems.is_empty() and has_dims else "FAIL",
		"blackboard: scopes, unknown-channel legality, loud missing reads, typed mismatch errors",
		"\n".join(problems) if not problems.is_empty() else "dump rows=%d, sample=%s" % [dump.size(), str(dump[0])])


# --- field tiles --------------------------------------------------------------------------

func _field_tile_sampling() -> Dictionary:
	var tile := FieldTile.make_float(8, 4.0, Vector2(1024, 2048), 1)
	for j in tile.width:
		for i in tile.width:
			tile.set_f(i, j, float(i + j * 100))
	var problems: Array[String] = []
	# World (1028, 2048) = array (2, 1): one core sample east of the core origin.
	var exact: float = tile.sample_nearest(1028.0, 2048.0)
	if exact != 102.0:
		problems.append("nearest sample wrong: %f (expected 102)" % exact)
	# (1030, 2054) sits half-way between samples (2,2),(3,2),(2,3),(3,3) = 202,203,302,303.
	var bil: float = tile.sample_bilinear(1024.0 + 6.0, 2048.0 + 6.0)
	if absf(bil - 252.5) > 0.001:
		problems.append("bilinear midpoint wrong: %f (expected 252.5)" % bil)
	if tile.core_width() != 8 or tile.width != 10:
		problems.append("halo geometry wrong: core=%d width=%d" % [tile.core_width(), tile.width])
	return TestHarness.result(SUITE, "S6b", "PASS" if problems.is_empty() else "FAIL",
		"field tile halo geometry, nearest and bilinear sampling",
		"\n".join(problems) if not problems.is_empty() else "core=8 halo=1 width=10 spacing=4 verified")


# --- X8 -----------------------------------------------------------------------------------

func _x8_cache_recompute() -> Dictionary:
	# Compute a region tile through the real pipeline, evict it, recompute, compare bits.
	var cfg := WorldConfig.load_config()
	var pipeline := PipelineBootstrap.build(cfg.to_gen_context())
	if not pipeline["ok"]:
		return TestHarness.fail(SUITE, "X8", "pipeline did not resolve", str(pipeline["errors"]))
	var ctx := _ctx_for(cfg, pipeline)
	var runner := PipelineRunner.new()
	runner.ctx = ctx
	runner.scheduler = pipeline["scheduler"]

	var provider := _first_region_provider(pipeline)
	if provider == null:
		return TestHarness.fail(SUITE, "X8", "no FieldProvider with a region channel in the pipeline",
			str(pipeline["scheduler"].pipeline_dump()))
	var channel: StringName = provider.region_channels()[0]

	var region := Vector2i(0, 0)
	runner.ensure_region(region)
	var first: FieldTile = ctx.cache.get_tile(channel, region, provider)
	if first == null:
		return TestHarness.fail(SUITE, "X8", "%s tile not cached after ensure_region" % String(channel),
			str(ctx.cache.stats()))
	var before := ctx.cache.stats()

	ctx.cache.erase(channel, region, provider)
	if ctx.cache.get_tile(channel, region, provider) != null:
		return TestHarness.fail(SUITE, "X8", "erase did not remove the tile")

	runner.ensure_region(region)
	var second: FieldTile = ctx.cache.get_tile(channel, region, provider)
	var identical := second != null and first.equals(second)
	var after := ctx.cache.stats()
	return TestHarness.result(SUITE, "X8", "PASS" if identical else "FAIL",
		"evicted tile recomputes bit-identical (cache misses are invisible)",
		"identical=%s, cache before=%s after=%s" % [str(identical), str(before), str(after)])


# --- X4 -----------------------------------------------------------------------------------

func _x4_order_stability() -> Array:
	var cfg := WorldConfig.load_config()
	var registry := ModuleRegistry.new()
	registry.scan()
	# Add synthetic in-memory modules so the graph has real ordering decisions to make.
	var extras := _chain_modules()
	var base := registry.active() + extras

	var reference := ""
	var dumps := []
	for attempt in 50:
		var shuffled := base.duplicate()
		_shuffle(shuffled, 1000 + attempt)
		var sched := PipelineScheduler.new()
		if not sched.resolve(shuffled):
			return [TestHarness.fail(SUITE, "X4", "resolve failed on shuffle %d" % attempt, str(sched.errors))]
		dumps.append(str(sched.pipeline_dump().map(func(m): return m["id"])))
		if reference == "":
			reference = dumps[0]
	var ok := true
	for d in dumps:
		if d != reference:
			ok = false
	return [TestHarness.result(SUITE, "X4", "PASS" if ok else "FAIL",
		"50 shuffled registry inputs resolve to an identical pipeline order",
		"order=%s" % reference)]


# --- X5 -----------------------------------------------------------------------------------

func _x5_cycle_detection() -> Dictionary:
	var a := _mod(&"tests.cyc_a", ModuleDefinition.Phase.PLANET, [&"ch.from_c"], [&"ch.from_a"])
	var b := _mod(&"tests.cyc_b", ModuleDefinition.Phase.PLANET, [&"ch.from_a"], [&"ch.from_b"])
	var c := _mod(&"tests.cyc_c", ModuleDefinition.Phase.PLANET, [&"ch.from_b"], [&"ch.from_c"])
	var sched := PipelineScheduler.new()
	var ok := sched.resolve([a, b, c])
	var joined := " ".join(sched.errors)
	var has_path := joined.find("tests.cyc_a -> tests.cyc_c -> tests.cyc_b -> tests.cyc_a") >= 0
	return TestHarness.result(SUITE, "X5", "PASS" if not ok and has_path else "FAIL",
		"a->b->c->a cycle produces a boot error containing the cycle path",
		"resolved=%s errors=%s" % [str(ok), joined])


# --- X6 -----------------------------------------------------------------------------------

func _x6_missing_producer() -> Dictionary:
	var consumer := _mod(&"tests.needy", ModuleDefinition.Phase.SURFACE, [&"field.nobody_makes"], [])
	var sched := PipelineScheduler.new()
	var ok := sched.resolve([consumer])
	var joined := " ".join(sched.errors)
	var names_module := joined.find("tests.needy") >= 0
	var names_channel := joined.find("field.nobody_makes") >= 0
	return TestHarness.result(SUITE, "X6", "PASS" if not ok and names_module and names_channel else "FAIL",
		"missing producer errors name the consumer AND the channel",
		"resolved=%s errors=%s" % [str(ok), joined])


# --- X7 -----------------------------------------------------------------------------------

func _x7_duplicate_id() -> Dictionary:
	_write_module_file("dup_a.tres", "tests.dup", 1)
	_write_module_file("dup_b.tres", "tests.dup", 2)
	var registry := ModuleRegistry.new()
	registry.scan()
	var joined := " ".join(registry.errors)
	var names_both := joined.find("dup_a.tres") >= 0 and joined.find("dup_b.tres") >= 0
	var listed := registry.debug_dump().size()
	# Remove the duplicates NOW, not at the end of the suite: every later check that resolves a
	# pipeline scans user://modules, and a leftover here makes the whole world fail to boot.
	# (That is a real test-isolation defect this suite had from M01 - it only became visible
	# once a later check depended on a clean module root.)
	_remove_written_modules()
	var left := _user_module_leftovers()
	return TestHarness.result(SUITE, "X7",
		"PASS" if not registry.errors.is_empty() and names_both and left.is_empty() else "FAIL",
		"duplicate module id errors naming BOTH file paths, and the test leaves the module root clean",
		"errors=%s, modules listed=%d, leftovers after cleanup=%s" % [joined, listed, str(left)])


# --- column factor ------------------------------------------------------------------------

func _scheduler_column_factor() -> Dictionary:
	var pass0 := TerrainPass.new()
	pass0.id = &"tests.pass0"
	pass0.use_known_phase(ModuleDefinition.Phase.SURFACE)
	pass0.extent = 0
	var pass1 := TerrainPass.new()
	pass1.id = &"tests.pass1"
	pass1.use_known_phase(ModuleDefinition.Phase.SURFACE)
	pass1.extent = 1
	pass1.requires = []
	var sched := PipelineScheduler.new()
	var ok := sched.resolve([pass0, pass1])
	# extent 0 -> 1 column-touch; extent 1 -> 3x3 = 9; total 10.
	var good := ok and sched.column_factor() == 10 and int(sched.pass_factors()["tests.pass1"]) == 9
	return TestHarness.result(SUITE, "S6c", "PASS" if good else "FAIL",
		"scheduler reports per-pass extent factors and the total column multiplication",
		"factors=%s total=%d (expected pass0=1, pass1=9, total=10)" % [str(sched.pass_factors()), sched.column_factor()])


# --- helpers ------------------------------------------------------------------------------

func _ctx_for(cfg: WorldConfig, pipeline: Dictionary) -> GenContext:
	var ctx := GenContext.new()
	ctx.blackboard = GenBlackboard.new()
	ctx.cache = FieldCache.new()
	ctx.cache.configure_budget(cfg.tier_field_cache_bytes())
	ctx.config = cfg.to_gen_context()
	ctx.quality_tier = cfg.quality_tier
	ctx.world_seed = cfg.seed_value
	# The sampler is built the way a backend builds it: from the FIRST noise_sampler_recipe() in
	# the resolved plan (NoiseSamplerBuilder), so no test ever names a content module or class.
	var recipe := NoiseSamplerBuilder.first_recipe(pipeline["modules"])
	if recipe.is_empty():
		push_error("test_spine: no module in the resolved plan declares a noise_sampler_recipe()")
		return ctx
	var noise := NoiseSamplerBuilder.build(recipe, cfg.seed_value)
	if noise == null:
		push_error("test_spine: NoiseSamplerBuilder refused the recipe %s" % NoiseSamplerBuilder.describe(recipe))
		return ctx
	_keep_alive.append(noise)
	ctx.noise_2d = noise.get_noise_2d
	return ctx


## In-memory module for scheduler tests. M01-fix: every requires/provides entry gets a channel
## declaration, because the scheduler now rejects an undeclared one (X18) - a test module that
## could not pass its own contract would prove nothing.
func _mod(id: StringName, phase: int, req: Array, prov: Array) -> ModuleDefinition:
	var m := ModuleDefinition.new()
	m.id = id
	m.use_known_phase(phase)
	var r: Array[StringName] = []
	for x in req:
		r.append(StringName(x))
	var pv: Array[StringName] = []
	for x in prov:
		pv.append(StringName(x))
	m.requires = r
	m.provides = pv
	for x in req:
		m.channel_declarations[StringName(x)] = {"type": "FLOAT", "scope": "column", "version": 1}
	for x in prov:
		m.channel_declarations[StringName(x)] = {"type": "FLOAT", "scope": "column", "version": 1}
	return m


## First FieldProvider in the resolved plan that publishes a REGION channel. Found by contract,
## never by id: tests must not hardcode content ids either, or they would keep passing when the
## shipped module set changes.
func _first_region_provider(pipeline: Dictionary) -> FieldProvider:
	for m_variant in pipeline["modules"]:
		var provider := m_variant as FieldProvider
		if provider != null and not provider.region_channels().is_empty():
			return provider
	return null


func _chain_modules() -> Array:
	# Three modules with a real dependency chain plus a tiebreak pair, so shuffling has
	# something to bite on.
	var provider := FieldProvider.new()
	provider.id = &"tests.chain_provider"
	provider.use_known_phase(ModuleDefinition.Phase.PLANET)
	provider.provides = [&"field.chain"]
	provider.channel_declarations = {&"field.chain": {"type": "FLOAT", "scope": "column", "version": 1}}
	provider.priority = 50
	var consumer := TerrainPass.new()
	consumer.id = &"tests.chain_consumer"
	consumer.use_known_phase(ModuleDefinition.Phase.SURFACE)
	consumer.requires = [&"field.chain"]
	consumer.channel_declarations = {&"field.chain": {"type": "FLOAT", "scope": "column", "version": 1}}
	consumer.priority = 50
	var tie_a := ModuleDefinition.new()
	tie_a.id = &"tests.tie_a"
	tie_a.use_known_phase(ModuleDefinition.Phase.CLIMATE)
	tie_a.priority = 10
	var tie_b := ModuleDefinition.new()
	tie_b.id = &"tests.tie_b"
	tie_b.use_known_phase(ModuleDefinition.Phase.CLIMATE)
	tie_b.priority = 10
	return [provider, consumer, tie_a, tie_b]


func _shuffle(a: Array, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = a[i]
		a[i] = a[j]
		a[j] = tmp


## Write a throwaway module .tres (+script) into user://modules. The script is shared and
## created once; each .tres instances it with the given id, producing a duplicate on purpose.
func _write_module_file(file_name: String, module_id: String, version: int) -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		DirAccess.make_dir_recursive_absolute("user://modules")
	elif not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://modules")):
		dir.make_dir("modules")
	var script_path := USER_MODULES + "dup_module.gd"
	if not FileAccess.file_exists(script_path):
		var f := FileAccess.open(script_path, FileAccess.WRITE)
		f.store_string("class_name DupModuleX7\nextends ModuleDefinition\n")
		f.close()
		_created_files.append(script_path)
	var tres := USER_MODULES + file_name
	var f2 := FileAccess.open(tres, FileAccess.WRITE)
	f2.store_string(
		"[gd_resource type=\"Resource\" load_steps=2 format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"%s\" id=\"1\"]\n\n" % script_path
		+ "[resource]\nscript = ExtResource(\"1\")\nid = &\"%s\"\nversion = %d\n" % [module_id, version])
	f2.close()
	_created_files.append(tres)


## Files this suite wrote into the modding root. Tracked so a failed check cannot leave a
## module behind that makes the NEXT suite fail to boot.
func _remove_written_modules() -> void:
	for p in _created_files:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	_created_files.clear()


## Anything left in user://modules (a modder's own files count too - the suite must not
## assume it owns the directory, it only has to leave it as it found it).
func _user_module_leftovers() -> Array:
	var out: Array = []
	var dir := DirAccess.open(ModuleFixtures.DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir():
			out.append(ModuleFixtures.DIR + "/" + n)
		n = dir.get_next()
	dir.list_dir_end()
	return out


## X0: every check from X13 on resolves the pipeline FROM DISK, so the module root has to be
## exactly the shipped set. A leftover .tres from an earlier run (or from this suite's own
## X7 before it was fixed) makes the default backend refuse to build, and the failure lands on
## an innocent check.
func _x0_module_root_clean() -> Dictionary:
	var left := _user_module_leftovers()
	var fixtures := ModuleFixtures.installed()
	if not left.is_empty() or not fixtures.is_empty():
		ModuleFixtures.clear()
		_remove_written_modules()
		left = _user_module_leftovers()
	var clean := left.is_empty()
	return TestHarness.result(SUITE, "X0", "PASS" if clean else "FAIL",
		"the modding root user://modules is empty before the suite resolves any pipeline",
		"entries=%s fixtures=%s (a non-empty root would make X13..X22 fail for the wrong reason)" % [
			str(left), str(fixtures)])


func _cleanup() -> void:
	ModuleFixtures.clear()
	_remove_written_modules()


# ==========================================================================================
# M01-fix regressions. Every test below fails on the M01 code that the independent review
# rejected, and each one names the defect it is pinning down.
# ==========================================================================================

const MODULAR_GOLDEN_PATH := "res://tests/determinism/golden_hashes_modular.json"


## Build the DEFAULT backend with whatever is currently on disk, or fail the given check id.
func _build_default(cfg: WorldConfig, check_id: String) -> Dictionary:
	var built := AdapterRegistry.build_generator(AdapterRegistry.DEFAULT_ID, cfg.seed_value, cfg.to_gen_context())
	if not built["ok"]:
		return {"ok": false, "error": str(built["report"].get("error", "?")), "id": check_id}
	_keep_alive.append(built["generator"])
	return {"ok": true, "generator": built["generator"], "report": built["report"]}


## Count marker voxels on ONE row of one column. Scanning a whole 16x384x16 column from
## GDScript is ~100k calls per column and buys nothing: the fixtures write a known row.
func _count_marker_row(column: MemoryColumnWriter, id: int, row: int) -> int:
	var n := 0
	var b: Array = column.bounds_main()
	var bmin: Vector3i = b[0]
	for lz in range(bmin.z, bmin.z + column.depth):
		for lx in range(bmin.x, bmin.x + column.width):
			if column.get_type_world(Vector3i(lx, row, lz)) == id:
				n += 1
	return n


# --- X13 / X14 / X15 / X16 -----------------------------------------------------------------

func _x13_to_x17_module_execution() -> Array:
	var out: Array = []
	var cfg := WorldConfig.load_config()
	var origins := ChunkOrigins.get_origins(cfg.sea_level)
	ModuleFixtures.clear()

	var base := _build_default(cfg, "X13")
	if not base["ok"]:
		out.append(TestHarness.fail(SUITE, "X13", "the DEFAULT backend (%s) failed to build: %s" % [
			AdapterRegistry.DEFAULT_ID, base["error"]]))
		return out
	var base_hashes := ChunkHasher.hash_all(base["generator"], origins, ChunkOrigins.BLOCK, cfg.type_depth_bits)
	var golden: Dictionary = JsonData.load_file(MODULAR_GOLDEN_PATH)
	var golden_native: Dictionary = golden.get("by_generator", {}).get(AdapterRegistry.DEFAULT_ID, {})

	# ---- X13: adding a module changes the default backend's output, zero existing files ----
	ModuleFixtures.install("marker_pass")
	var with_marker := _build_default(cfg, "X13")
	if not with_marker["ok"]:
		out.append(TestHarness.fail(SUITE, "X13", "default backend failed to build with an added module", with_marker["error"]))
	else:
		var marker_hashes := ChunkHasher.hash_all(with_marker["generator"], origins, ChunkOrigins.BLOCK, cfg.type_depth_bits)
		var changed := 0
		var changed_keys: Array[String] = []
		for k in base_hashes:
			if String(marker_hashes.get(k, "?")) != String(base_hashes[k]):
				changed += 1
				if changed_keys.size() < 3:
					changed_keys.append(String(k))
		var column: MemoryColumnWriter = with_marker["generator"].call("debug_column_memory", Vector3i(0, cfg.world_y_min, 0))
		var markers := _count_marker_row(column, ModuleFixtures.MARKER_ID, ModuleFixtures.MARKER_ROW)
		var st: Dictionary = with_marker["generator"].call("stats")
		var executed: Dictionary = st.get("executed_counts", {})
		var ran := int(executed.get(ModuleFixtures.KINDS["marker_pass"]["id"], 0))
		var ok := changed > 0 and markers > 0 and ran > 0
		out.append(TestHarness.result(SUITE, "X13", "PASS" if ok else "FAIL",
			"adding an enabled module changes the DEFAULT backend's output (zero existing files edited)",
			("backend=%s changed_hashes=%d/%d (e.g. %s) marker voxels on row %d of column 0=%d "
			+ "module executions=%d\n"
			+ "This is the exact property M01 failed: a module resolved, was listed in the pipeline "
			+ "dump, and wrote nothing. No existing file was edited to get it: the module is a "
			+ "throwaway .gd + .tres dropped into user://modules by ModuleFixtures and removed again.") % [
				AdapterRegistry.DEFAULT_ID, changed, base_hashes.size(), str(changed_keys),
				ModuleFixtures.MARKER_ROW, markers, ran]))

	# ---- X14: a no-op module leaves every golden unchanged ---------------------------------
	ModuleFixtures.clear()
	ModuleFixtures.install("no_op_pass")
	var with_noop := _build_default(cfg, "X14")
	if not with_noop["ok"]:
		out.append(TestHarness.fail(SUITE, "X14", "default backend failed to build with a no-op module", with_noop["error"]))
	else:
		var noop_hashes := ChunkHasher.hash_all(with_noop["generator"], origins, ChunkOrigins.BLOCK, cfg.type_depth_bits)
		var identical := noop_hashes == base_hashes
		var golden_identical := 0
		for k in golden_native:
			if String(noop_hashes.get(k, "?")) == String(golden_native[k]):
				golden_identical += 1
		var st2: Dictionary = with_noop["generator"].call("stats")
		var ran2 := int((st2.get("executed_counts", {}) as Dictionary).get(ModuleFixtures.KINDS["no_op_pass"]["id"], 0))
		var ok2 := identical and golden_identical == golden_native.size() and ran2 > 0
		out.append(TestHarness.result(SUITE, "X14", "PASS" if ok2 else "FAIL",
			"a module that writes nothing leaves every golden hash unchanged (and still executes)",
			"identical to baseline=%s, identical to committed modular goldens=%d/%d, executions=%d" % [
				str(identical), golden_identical, golden_native.size(), ran2]))

	# ---- X15: a module with no executable contract is refused, loudly ----------------------
	ModuleFixtures.clear()
	ModuleFixtures.install("bare_module")
	var with_bare := AdapterRegistry.build_generator(AdapterRegistry.DEFAULT_ID, cfg.seed_value, cfg.to_gen_context())
	var bare_error := str(with_bare["report"].get("error", ""))
	var names_module := bare_error.find("tests.bare_module") >= 0
	var names_reason := bare_error.find("not a FieldProvider") >= 0
	out.append(TestHarness.result(SUITE, "X15", "PASS" if not with_bare["ok"] and names_module and names_reason else "FAIL",
		"a resolved module that nothing can execute refuses the build instead of silently doing nothing",
		"built=%s error=%s" % [str(with_bare["ok"]), bare_error]))

	# ---- X16: FeatureStamp contracts are executed -----------------------------------------
	ModuleFixtures.clear()
	ModuleFixtures.install("stamp_probe")
	var with_stamp := _build_default(cfg, "X16")
	if not with_stamp["ok"]:
		out.append(TestHarness.fail(SUITE, "X16", "default backend failed to build with a stamp module", with_stamp["error"]))
	else:
		var col2: MemoryColumnWriter = with_stamp["generator"].call("debug_column_memory", Vector3i(0, cfg.world_y_min, 0))
		# The stamp fixture fills a 3x3x2 box, so its bottom row carries 9 marker voxels.
		var stamped := _count_marker_row(col2, ModuleFixtures.MARKER_ID, ModuleFixtures.MARKER_ROW)
		var st3: Dictionary = with_stamp["generator"].call("stats")
		var placements: Dictionary = st3.get("stamp_placements", {})
		var ok3 := stamped == 9 and int(placements.get(ModuleFixtures.KINDS["stamp_probe"]["id"], 0)) > 0
		out.append(TestHarness.result(SUITE, "X16", "PASS" if ok3 else "FAIL",
			"a FeatureStamp is EXECUTED by the generic runner (candidates -> evaluate -> materialize)",
			"marker voxels on row %d=%d (the 3x3x2 box puts 9 there), placements=%s, executed=%s" % [
				ModuleFixtures.MARKER_ROW, stamped, str(placements), str(st3.get("executed_counts"))]))

	# ---- X17: an unplanned phase_order/phase_name resolves AND runs ------------------------
	ModuleFixtures.clear()
	ModuleFixtures.install("alien_phase_pass")
	var pipeline := PipelineBootstrap.build(cfg.to_gen_context())
	var with_alien := _build_default(cfg, "X17")
	var dump: Array = pipeline["scheduler"].pipeline_dump() if pipeline["ok"] else []
	var alien_row := {}
	for row_variant in dump:
		var row: Dictionary = row_variant
		if String(row["id"]) == ModuleFixtures.KINDS["alien_phase_pass"]["id"]:
			alien_row = row
	var resolved_ok := not alien_row.is_empty() and int(alien_row.get("phase_order", -1)) == 77 \
		and String(alien_row.get("phase", "")) == "MY_UNPLANNED_STAGE"
	var order_ok := _order_index(dump, "MY_UNPLANNED_STAGE") > _order_index(dump, "SURFACE")
	var wrote := false
	if with_alien["ok"]:
		var col3: MemoryColumnWriter = with_alien["generator"].call("debug_column_memory", Vector3i(0, cfg.world_y_min, 0))
		wrote = _count_marker_row(col3, ModuleFixtures.MARKER_ID, 95) == 2
	out.append(TestHarness.result(SUITE, "X17", "PASS" if pipeline["ok"] and resolved_ok and order_ok and wrote else "FAIL",
		"a module in a phase nobody planned (phase_order 77, 'MY_UNPLANNED_STAGE') resolves, orders and runs",
		("pipeline_ok=%s resolved row=%s ordered after SURFACE=%s wrote its 2 markers=%s\n"
		+ "M01 gated phases behind an enum in the contract file, so an unplanned stage needed an edit\n"
		+ "to src/spine/contracts/module_definition.gd. Now phase_order is a plain int and phase_name\n"
		+ "a plain StringName: this module was added with ZERO edits to any existing file.") % [
			str(pipeline["ok"]), str(alien_row), str(order_ok), str(wrote)]))
	ModuleFixtures.clear()
	return out


func _order_index(dump: Array, phase: String) -> int:
	for i in dump.size():
		var row: Dictionary = dump[i]
		if String(row["phase"]) == phase:
			return i
	return -1


# --- X18 -----------------------------------------------------------------------------------

func _x18_declarations_enforced() -> Dictionary:
	var problems: Array[String] = []
	var evidence: Array[String] = []

	# (a) scheduler: requires/provides without a declaration is an error.
	var undeclared := TerrainPass.new()
	undeclared.id = &"tests.undeclared"
	undeclared.use_known_phase(ModuleDefinition.Phase.SURFACE)
	undeclared.requires = [&"field.mystery"]
	var sched := PipelineScheduler.new()
	var ok_a := sched.resolve([undeclared])
	if ok_a or sched.errors.is_empty():
		problems.append("an undeclared requires entry resolved without error")
	evidence.append("undeclared requires -> %s" % "; ".join(sched.errors))

	# (b) scheduler: producer/consumer type mismatch is an error naming both sides.
	var producer := FieldProvider.new()
	producer.id = &"tests.decl_prod"
	producer.use_known_phase(ModuleDefinition.Phase.PLANET)
	producer.provides = [&"field.shared"]
	producer.channel_declarations = {&"field.shared": {"type": "TILE_FLOAT", "scope": "region", "version": 1}}
	var consumer := TerrainPass.new()
	consumer.id = &"tests.decl_cons"
	consumer.use_known_phase(ModuleDefinition.Phase.SURFACE)
	consumer.requires = [&"field.shared"]
	consumer.channel_declarations = {&"field.shared": {"type": "FLOAT", "scope": "region", "version": 1}}
	var sched2 := PipelineScheduler.new()
	var ok_b := sched2.resolve([producer, consumer])
	var joined_b := " ".join(sched2.errors)
	if ok_b or joined_b.find("type mismatch") < 0 or joined_b.find("TILE_FLOAT") < 0 or joined_b.find("FLOAT") < 0:
		problems.append("a producer/consumer type mismatch was not reported with both type names: %s" % joined_b)
	evidence.append("type mismatch -> %s" % joined_b)

	# (c) scheduler: version mismatch is an error (a producer changing semantics must be deliberate).
	var consumer_v2 := TerrainPass.new()
	consumer_v2.id = &"tests.decl_cons_v2"
	consumer_v2.use_known_phase(ModuleDefinition.Phase.SURFACE)
	consumer_v2.requires = [&"field.shared"]
	consumer_v2.channel_declarations = {&"field.shared": {"type": "TILE_FLOAT", "scope": "region", "version": 2}}
	var sched3 := PipelineScheduler.new()
	var ok_c := sched3.resolve([producer, consumer_v2])
	if ok_c or " ".join(sched3.errors).find("version mismatch") < 0:
		problems.append("a channel version mismatch was not reported: %s" % "; ".join(sched3.errors))
	evidence.append("version mismatch -> %s" % "; ".join(sched3.errors))

	# (d) blackboard: publishing a value whose observed type contradicts the declaration fails.
	var bb := GenBlackboard.new()
	bb.loud = false
	bb.apply_declarations([producer])
	var published := bb.publish(&"field.shared", 1.5, &"tests.decl_prod", GenBlackboard.Scope.REGION)
	if published or bb.errors.is_empty():
		problems.append("the blackboard accepted a FLOAT for a channel declared TILE_FLOAT")
	else:
		evidence.append("publish mismatch -> %s" % bb.errors[0])

	# (e) blackboard: right type, wrong scope also fails.
	bb.errors.clear()
	var tile := FieldTile.make_float(4, 16.0, Vector2.ZERO, 0)
	var wrong_scope := bb.publish(&"field.shared", tile, &"tests.decl_prod", GenBlackboard.Scope.COLUMN)
	if wrong_scope or bb.errors.is_empty():
		problems.append("the blackboard accepted a region-declared channel in COLUMN scope")
	else:
		evidence.append("scope mismatch -> %s" % bb.errors[0])

	# (f) and the correct publish still works (enforcement must not block honest modules).
	bb.errors.clear()
	bb.begin_region(Vector2i.ZERO)
	var right := bb.publish(&"field.shared", tile, &"tests.decl_prod", GenBlackboard.Scope.REGION)
	if not right or not bb.errors.is_empty():
		problems.append("a correct publish was rejected: %s" % "; ".join(bb.errors))

	# (g) an UNKNOWN channel with no declaration stays legal (X2's property must survive).
	var unknown_ok := bb.publish(&"field.brand_new", 3, &"tests.someone_new")
	if not unknown_ok:
		problems.append("an undeclared, unknown channel was rejected - unknown channels must stay legal")

	return TestHarness.result(SUITE, "X18", "PASS" if problems.is_empty() else "FAIL",
		"channel declarations are enforced at resolve time and at publish time"
		+ ("" if problems.is_empty() else " (%d problems)" % problems.size()),
		("problems: " + "; ".join(problems) + "\n" if not problems.is_empty() else "") + "\n".join(evidence))


# --- X19 -----------------------------------------------------------------------------------

func _x19_cache_fingerprint() -> Dictionary:
	var problems: Array[String] = []
	var provider := FieldProvider.new()
	provider.id = &"tests.fp_provider"
	provider.version = 1
	provider.tile_spacing = 16
	provider.tile_halo = 2

	var region := Vector2i(1024, -2048)
	var channel := &"field.height"
	var base := FieldCache.key_of(channel, region, provider, 111)

	# Every tile-changing input must change the key. Each line is one input the M01 key ignored.
	# Each entry: {input that must change the key, mutated provider, channel, region, world fp}.
	var mutated_id := provider.duplicate() as FieldProvider
	mutated_id.id = &"tests.fp_other"
	var mutated_version := provider.duplicate() as FieldProvider
	mutated_version.version = 2
	var mutated_param := provider.duplicate() as FieldProvider
	mutated_param.params = {"rock_id": 4}
	var mutated_spacing := provider.duplicate() as FieldProvider
	mutated_spacing.tile_spacing = 8
	var mutated_halo := provider.duplicate() as FieldProvider
	mutated_halo.tile_halo = 0
	var variants: Array = [
		{"name": "world fingerprint (seed / worldgen_version / tier)", "key": FieldCache.key_of(channel, region, provider, 222)},
		{"name": "producer id", "key": FieldCache.key_of(channel, region, mutated_id, 111)},
		{"name": "producer version", "key": FieldCache.key_of(channel, region, mutated_version, 111)},
		{"name": "params fingerprint (params = {\"rock_id\": 4})", "key": FieldCache.key_of(channel, region, mutated_param, 111)},
		{"name": "tile spacing", "key": FieldCache.key_of(channel, region, mutated_spacing, 111)},
		{"name": "tile halo", "key": FieldCache.key_of(channel, region, mutated_halo, 111)},
		{"name": "region", "key": FieldCache.key_of(channel, Vector2i(2048, -2048), provider, 111)},
		{"name": "channel", "key": FieldCache.key_of(&"field.other", region, provider, 111)},
	]
	var evidence: Array[String] = ["base key = %s" % base]
	for v_variant in variants:
		var v: Dictionary = v_variant
		var k: String = v["key"]
		var name := String(v["name"])
		evidence.append("%-46s -> %s  %s" % [name, k, "CHANGED" if k != base else "UNCHANGED"])
		if k == base:
			problems.append("changing %s did NOT change the cache key" % name)

	# The backend is part of `extra`, so two backends can never share a tile even at the same
	# seed: their FieldProviders are the same resources but their sinks and passes are not. This
	# is why `world_fingerprint` legitimately differs between native_cb and experimental_columns
	# in the B1 cache stats - it is a deliberate key input, not a drift bug.
	var fp_native := FieldCache.make_world_fingerprint(1000, 1, "low", {"backend": "native_cb"})
	var fp_experimental := FieldCache.make_world_fingerprint(1000, 1, "low", {"backend": "experimental_columns"})
	if fp_native == fp_experimental:
		problems.append("two backends produced the SAME world fingerprint - their tiles could collide")
	evidence.append("backend in `extra`: native_cb=%s experimental_columns=%s (different by design)" % [
		Hash64.to_hex(fp_native), Hash64.to_hex(fp_experimental)])

	# The regression that matters: a cache built for one world must not serve another.
	var cache := FieldCache.new()
	cache.configure_world(1000, 1, "low")
	var tile := FieldTile.make_float(4, 16.0, Vector2(region), 0)
	tile.set_f(0, 0, 42.0)
	cache.put(channel, region, provider, tile)
	if cache.get_tile(channel, region, provider) == null:
		problems.append("a tile put with the current world fingerprint was not found")
	cache.configure_world(2000, 1, "low")     # a different seed
	if cache.get_tile(channel, region, provider) != null:
		problems.append("a DIFFERENT WORLD SEED still hit the old tile (this is the M01 defect)")
	if cache.entry_count() != 0:
		problems.append("reconfiguring the world did not clear the cache (entries=%d)" % cache.entry_count())

	return TestHarness.result(SUITE, "X19", "PASS" if problems.is_empty() else "FAIL",
		"cache keys carry every tile-changing input, and a new world cannot hit an old world's tiles",
		("problems: " + "; ".join(problems) + "\n" if not problems.is_empty() else "") + "\n".join(evidence))


# --- X20 -----------------------------------------------------------------------------------

func _x20_exact_height() -> Dictionary:
	var cfg := WorldConfig.load_config()
	var pipeline := PipelineBootstrap.build(cfg.to_gen_context())
	if not pipeline["ok"]:
		return TestHarness.fail(SUITE, "X20", "pipeline did not resolve", str(pipeline["errors"]))
	var ctx := _ctx_for(cfg, pipeline)
	var runner := PipelineRunner.new()
	runner.ctx = ctx
	runner.scheduler = pipeline["scheduler"]

	var writer := MemoryColumnWriter.new()
	var origin := Vector3i(0, cfg.world_y_min, 0)
	writer.setup(origin, 16, cfg.world_height(), 16)
	runner.run_column(origin, writer)

	var problems: Array[String] = []
	var evidence_lines: Array[String] = []
	var exact_channel := _first_column_channel(pipeline)
	var exact: FieldTile = ctx.blackboard.try_read(exact_channel, null) as FieldTile
	var coarse_channel := &"field.height"
	var region_provider := _first_region_provider(pipeline)
	if region_provider != null and not region_provider.region_channels().is_empty():
		coarse_channel = StringName(region_provider.region_channels()[0])
	var coarse: FieldTile = ctx.blackboard.try_read(coarse_channel, null) as FieldTile
	evidence_lines.append("exact (COLUMN scope) channel = '%s'; coarse (REGION scope) channel = '%s'" % [
		String(exact_channel), String(coarse_channel)])
	if exact == null:
		problems.append("no exact per-column height channel was published (the surface pass would be back to nearest sampling)")
	if coarse == null:
		problems.append("no region height channel was published")

	var distinct := 0
	var min_h := INF
	var max_h := -INF
	var exact_spacing: float = exact.spacing if exact != null else -1.0
	var exact_width: int = exact.width if exact != null else 0
	if exact != null:
		if not is_equal_approx(exact_spacing, 1.0):
			problems.append("the exact tile's spacing is %s, not 1 block" % str(exact_spacing))
		if exact_width != 16:
			problems.append("the exact tile is %d samples wide, not one per block column" % exact.width)
		var seen := {}
		for j in exact_width:
			for i in exact_width:
				var v := exact.get_f(i, j)
				seen[v] = true
				min_h = minf(min_h, v)
				max_h = maxf(max_h, v)
		distinct = seen.size()
		if distinct < 2:
			problems.append("every block column in this column has the SAME height - that is the plateau defect")

	# The surface pass must be reading the exact channel, not the coarse one. Found by contract,
	# never by id: no content id may appear in tests either.
	var surface := _first_terrain_pass_requiring(exact_channel, pipeline["modules"])
	if surface == null:
		problems.append("no TerrainPass in the resolved plan requires an exact per-column height channel")
	else:
		evidence_lines.append("surface pass '%s' requires %s (extent %d)" % [
			String(surface.id), str(surface.requires), surface.extent])

	# And the terrain must actually vary WITHIN one 16x16 column (the visible symptom of E3).
	var tops := {}
	for lz in range(0, 16, 3):
		for lx in range(0, 16, 3):
			tops[writer.top_solid(lx, lz)] = true

	return TestHarness.result(SUITE, "X20", "PASS" if problems.is_empty() else "FAIL",
		"the surface pass consumes an exact per-block height channel (spacing 1), not a nearest-sampled coarse tile",
		("problems: " + "; ".join(problems) + "\n" if not problems.is_empty() else "")
		+ "\n".join(evidence_lines) + "\n"
		+ "exact tile: spacing=%s width=%d distinct heights=%d range=[%.3f, %.3f]\n" % [
			str(exact_spacing), exact_width, distinct, min_h, max_h]
		+ "coarse tile: spacing=%s width=%d (region scope, cached, spacing 16 blocks)\n" % [
			str(coarse.spacing) if coarse != null else "?", coarse.width if coarse != null else 0]
		+ "distinct surface rows inside ONE 16x16 column: %d (%s)\n" % [tops.size(), str(tops.keys())]
		+ "The M01 defect this pins: the surface pass nearest-sampled the spacing-16 region tile, so 8x8"
		+ " halves of a column shared one height (reviewer evidence E3, 9/64 origin mismatches).")


## The first TerrainPass that consumes `channel`. Lookup by contract, so the test keeps working
## when content ids change - and fails loudly if the exact channel stops being consumed.
func _first_terrain_pass_requiring(channel: StringName, modules: Array) -> TerrainPass:
	for m_variant in modules:
		var tp := m_variant as TerrainPass
		if tp != null and channel in tp.requires:
			return tp
	return null


## The exact per-column channel name any FieldProvider publishes at COLUMN scope.
func _first_column_channel(pipeline: Dictionary) -> StringName:
	for m_variant in pipeline["modules"]:
		var provider := m_variant as FieldProvider
		if provider != null:
			for ch in provider.column_channels():
				return StringName(ch)
	return &""


# --- X21 -----------------------------------------------------------------------------------

func _x21_pass_plan_limits() -> Array:
	var out: Array = []
	var lines: Array[String] = []
	var failed := false

	# (a) a legal plan: extents 0, 1 and 2 -> three engine passes in ascending extent order.
	var legal: Array = []
	for e in [0, 1, 2]:
		var tp := TerrainPass.new()
		tp.id = StringName("tests.e%d" % e)
		tp.use_known_phase(ModuleDefinition.Phase.SURFACE)
		tp.extent = e
		legal.append(tp)
	var plan_ok := MultipassPassPlan.compile(legal, "low")
	if plan_ok.pass_count() != 3 or not plan_ok.errors.is_empty():
		failed = true
	lines.append("extents [0,1,2] -> pass_count=%d errors=%s" % [plan_ok.pass_count(), str(plan_ok.errors)])
	var ascending := true
	for i in plan_ok.pass_count():
		if plan_ok.extent_of(i) != i:
			ascending = false
	var extents_seen: Array[int] = []
	for i in plan_ok.pass_count():
		extents_seen.append(plan_ok.extent_of(i))
	lines.append("pass extents in order = %s (ascending: %s)" % [str(extents_seen), str(ascending)])
	if not ascending:
		failed = true

	# (b) extent 3 exceeds the engine's MAX_PASS_EXTENT and must be refused by name.
	var too_wide := TerrainPass.new()
	too_wide.id = &"tests.too_wide"
	too_wide.use_known_phase(ModuleDefinition.Phase.SURFACE)
	too_wide.extent = 3
	var plan_wide := MultipassPassPlan.compile([too_wide], "low")
	var wide_msg := "; ".join(plan_wide.errors)
	if plan_wide.errors.is_empty() or wide_msg.find("tests.too_wide") < 0 or wide_msg.find("MAX_PASS_EXTENT") < 0:
		failed = true
	lines.append("extent 3 -> errors=%s" % wide_msg)

	# (c) more distinct extents than MAX_PASSES must be refused (limit lowered to 2 to test the
	# branch without needing 5 extents, which the extent limit already forbids).
	var plan_many := MultipassPassPlan.compile(legal, "low", 2, 2)
	var many_msg := "; ".join(plan_many.errors)
	if plan_many.errors.is_empty() or many_msg.find("MAX_PASSES") < 0:
		failed = true
	lines.append("3 extents with limit_passes=2 -> errors=%s" % many_msg)

	# (d) a module nothing can execute makes executes_all() false.
	var bare := ModuleDefinition.new()
	bare.id = &"tests.bare"
	bare.use_known_phase(ModuleDefinition.Phase.DECORATE)
	var plan_bare := MultipassPassPlan.compile([bare], "low")
	if plan_bare.errors.is_empty() or plan_bare.executes_all([bare], "low"):
		failed = true
	lines.append("bare module -> errors=%s executes_all=%s" % [
		"; ".join(plan_bare.errors), str(plan_bare.executes_all([bare], "low"))])

	# (e) the shipped pipeline fits, and the plan says so in numbers.
	var cfg := WorldConfig.load_config()
	var pipeline := PipelineBootstrap.build(cfg.to_gen_context())
	var plan_ship := MultipassPassPlan.compile(pipeline["modules"], cfg.quality_tier)
	if not plan_ship.errors.is_empty() or not plan_ship.executes_all(pipeline["modules"], cfg.quality_tier):
		failed = true
	lines.append("shipped pipeline -> %s" % str(plan_ship.describe()))
	lines.append("(the plan is what decides whether the engine can run a pipeline at all: MAX_PASSES=%d, MAX_PASS_EXTENT=%d, MAX_COLUMN_HEIGHT_BLOCKS=%d)" % [
		MultipassPassPlan.MAX_PASSES, MultipassPassPlan.MAX_EXTENT, MultipassPassPlan.MAX_COLUMN_HEIGHT_BLOCKS])

	out.append(TestHarness.result(SUITE, "X21", "PASS" if not failed else "FAIL",
		"the pass plan compiles what fits the engine and refuses, by name, what does not",
		"\n".join(lines)))
	return out


# --- X22 -----------------------------------------------------------------------------------

func _x22_live_streaming_matches_harness() -> Array:
	var out: Array = []
	if _tree == null:
		out.append(TestHarness.blocked(SUITE, "X22", "no SceneTree in ctx - cannot stream a live terrain"))
		return out
	var cfg := WorldConfig.load_config()
	ModuleFixtures.clear()
	var built := AdapterRegistry.build_generator(AdapterRegistry.DEFAULT_ID, cfg.seed_value, cfg.to_gen_context())
	if not built["ok"]:
		out.append(TestHarness.fail(SUITE, "X22", "default backend failed to build", str(built["report"].get("error"))))
		return out
	var gen: Object = built["generator"]
	_keep_alive.append(gen)

	var ta := TerrainAdapter.new()
	var res := ta.create(cfg.to_terrain_context(), gen, BlockLibraryBuilder.build())
	var terrain: Node3D = res["terrain"]
	var viewer: Node3D = res["viewer"]
	if terrain == null:
		out.append(TestHarness.fail(SUITE, "X22", "the terrain adapter produced no terrain", str(res["report"])))
		return out
	# Four engine worker threads: with one thread a data race can hide for an entire run, so
	# the concurrency claim has to be measured with real parallel generation.
	var threads := ta.apply_engine_threads(4)
	_tree.root.add_child(terrain)
	var holder := Node3D.new()
	_tree.root.add_child(holder)
	holder.add_child(viewer)
	holder.position = Vector3(8, 70, 8)
	for i in 260:
		await _tree.process_frame

	var tool: Object = terrain.call("get_voxel_tool")
	var checked := 0
	var mismatched := 0
	var examples: Array[String] = []
	var columns := {}
	for bx in range(-2, 3):
		for bz in range(-2, 3):
			var origin := Vector3i(bx * 16, cfg.world_y_min, bz * 16)
			var key := "%d,%d" % [origin.x, origin.z]
			if not columns.has(key):
				columns[key] = gen.call("debug_column_memory", origin)
			var column: MemoryColumnWriter = columns[key]
			for lx in range(0, 16, 5):
				for lz in range(0, 16, 5):
					for wy in range(40, 100, 7):
						var pos := Vector3i(origin.x + lx, wy, origin.z + lz)
						var live: int = int(tool.call("get_voxel", pos))
						var harness: int = column.get_type_world(pos)
						checked += 1
						if live != harness:
							mismatched += 1
							if examples.size() < 5:
								examples.append("%s live=%d harness=%d" % [str(pos), live, harness])

	var st: Dictionary = gen.call("stats")
	var thread_ids: Array = st.get("worker_thread_ids", [])
	var blocks: int = ta.get_loaded_block_count()
	var writer_stats: Dictionary = st.get("writer", {})
	terrain.queue_free()
	holder.queue_free()
	ta.release()

	var ok := mismatched == 0 and checked > 0 and thread_ids.size() >= 2 and blocks > 0 \
		and int(writer_stats.get("rejected_writes", 0)) == 0 and int(writer_stats.get("unbound_writes", 0)) == 0
	out.append(TestHarness.result(SUITE, "X22", "PASS" if ok else "FAIL",
		"live engine streaming produces the same voxels as the harness path, on %d worker threads" % thread_ids.size(),
		"engine threads requested=4 applied=%d; worker thread ids=%s; blocks loaded=%d\n" % [threads, str(thread_ids), blocks]
		+ "voxels compared (live terrain vs debug_column_memory)=%d mismatched=%d %s\n" % [checked, mismatched, str(examples)]
		+ "pass calls=%s writer=%s\n" % [str(st.get("pass_calls")), str(writer_stats)]
		+ "modules executed during streaming=%s" % str(st.get("executed_counts"))))
	return out


# --- X23 -----------------------------------------------------------------------------------

func _x23_capabilities_and_legacy_gate() -> Dictionary:
	var problems: Array[String] = []
	var lines: Array[String] = []
	for id in AdapterRegistry.ids():
		var caps := AdapterRegistry.capabilities(id)
		lines.append("%-20s executes_all_modules=%-5s legacy=%-5s neighbour_passes=%-5s max_passes=%s max_extent=%s lod=%s | %s" % [
			id, str(caps.get("executes_all_modules")), str(caps.get("legacy")), str(caps.get("supports_neighbor_passes")),
			str(caps.get("max_passes")), str(caps.get("max_extent")), str(caps.get("supports_lod")), String(caps.get("label"))])
		if not caps.has("executes_all_modules") or not caps.has("legacy"):
			problems.append("%s does not declare capability metadata" % id)

	# The DEFAULT backend must be one that executes the modules - that is the whole point.
	if not AdapterRegistry.executes_all_modules(AdapterRegistry.DEFAULT_ID):
		problems.append("the DEFAULT backend '%s' does not execute all modules" % AdapterRegistry.DEFAULT_ID)
	var default_cfg := WorldConfig.load_config()
	if default_cfg.generator_id != AdapterRegistry.DEFAULT_ID:
		problems.append("content/world_config.json selects '%s' but the registry default is '%s'" % [
			default_cfg.generator_id, AdapterRegistry.DEFAULT_ID])
	if not default_cfg.validation_errors.is_empty():
		problems.append("the shipped config does not validate: %s" % "; ".join(default_cfg.validation_errors))

	# The legacy gate: selecting a baseline without the flag is a config ERROR (fail closed).
	for legacy_id in AdapterRegistry.LEGACY_IDS:
		# with_generator() clones and mutates; validation runs at load_config() time, so a test
		# that mutates a config must re-validate or it is asserting on a stale error list.
		var gated := default_cfg.with_generator(legacy_id)
		gated._validate()
		var named := false
		for e in gated.validation_errors:
			if e.find(legacy_id) >= 0 and e.find("allow_legacy_baseline") >= 0:
				named = true
		if not named:
			problems.append("selecting legacy '%s' without allow_legacy_baseline did not produce a gate error (%s)" % [
				legacy_id, "; ".join(gated.validation_errors)])
		var opted := gated.clone()
		opted.allow_legacy_baseline = true
		opted.validation_errors.clear()
		opted._validate()
		var still_gated := false
		for e in opted.validation_errors:
			if e.find("allow_legacy_baseline") >= 0:
				still_gated = true
		if still_gated:
			problems.append("allow_legacy_baseline=true did not lift the gate for '%s'" % legacy_id)
		lines.append("legacy '%s': gated without the flag=%s, allowed with it=%s" % [
			legacy_id, str(named), str(not still_gated)])

	# And the flag defaults to false, in code and in the shipped config file.
	if WorldConfig.new().allow_legacy_baseline:
		problems.append("allow_legacy_baseline defaults to true in code")
	if default_cfg.allow_legacy_baseline:
		problems.append("the shipped config sets allow_legacy_baseline = true")
	if default_cfg.allow_broken_pipeline:
		problems.append("the shipped config sets allow_broken_pipeline = true")

	return TestHarness.result(SUITE, "X23", "PASS" if problems.is_empty() else "FAIL",
		"backend capabilities are declared, the default backend executes modules, and legacy baselines are gated",
		("problems: " + "; ".join(problems) + "\n" if not problems.is_empty() else "") + "\n".join(lines))


# --- X24 -----------------------------------------------------------------------------------

func _x24_fixed_point_boundaries() -> Dictionary:
	var problems: Array[String] = []
	var lines: Array[String] = []

	# Half-way values: Godot's roundf() rounds half AWAY FROM ZERO, so +0.5 -> 1 and -0.5 -> -1.
	# That asymmetry is the boundary a quantised decision lives on; it is asserted, not assumed.
	var half_pos := FixedPoint.quantize(0.5, 1)
	var half_neg := FixedPoint.quantize(-0.5, 1)
	if half_pos != 1 or half_neg != -1:
		problems.append("quantize(+0.5, 1)=%d and quantize(-0.5, 1)=%d, expected 1 and -1 (round-half-away-from-zero)" % [half_pos, half_neg])
	lines.append("quantize(+/-0.5, steps=1) = %d / %d" % [half_pos, half_neg])

	# Just below / just above a boundary at a realistic resolution.
	var steps := 1024
	var below := FixedPoint.quantize(0.33 - 0.0001, steps)
	var at := FixedPoint.quantize(0.33, steps)
	var above := FixedPoint.quantize(0.33 + 0.0001, steps)
	if not (below <= at and at <= above):
		problems.append("quantize is not monotone around 0.33 (%d, %d, %d)" % [below, at, above])
	lines.append("quantize(0.33 +/- 1e-4, 1024) = %d / %d / %d" % [below, at, above])

	# Ties compare equal, and qat_least/qgreater are consistent with qcompare.
	if FixedPoint.qcompare(0.33, 0.33, steps) != 0:
		problems.append("qcompare of equal values is not 0")
	if FixedPoint.qgreater(0.33, 0.33, steps):
		problems.append("qgreater is true for a tie")
	if not FixedPoint.qat_least(0.33, 0.33, steps):
		problems.append("qat_least is false for a tie")
	if FixedPoint.qgreater(0.3300001, 0.33, steps):
		problems.append("a difference smaller than the resolution was reported as greater (that is the platform-flip risk)")
	lines.append("ties: qcompare=0 qgreater=false qat_least=true; sub-resolution difference is NOT greater")

	# qsnap is idempotent and lands exactly on the grid; qkey agrees with quantize.
	var snapped := FixedPoint.qsnap(0.3333333, steps)
	if not is_equal_approx(FixedPoint.qsnap(snapped, steps), snapped):
		problems.append("qsnap is not idempotent")
	if FixedPoint.qkey(0.33, steps) != FixedPoint.quantize(0.33, steps):
		problems.append("qkey disagrees with quantize")
	lines.append("qsnap(0.3333333, 1024) = %.9f (idempotent, qkey == quantize)" % snapped)

	# Negative zero and large magnitudes must not produce a distinct key for the same value.
	if FixedPoint.qkey(-0.0, steps) != FixedPoint.qkey(0.0, steps):
		problems.append("-0.0 and 0.0 quantize differently")
	var big := FixedPoint.quantize(1.0e9, steps)
	if big != 1000000000 * steps:
		problems.append("large magnitude quantized to %d, expected %d" % [big, 1000000000 * steps])
	lines.append("qkey(-0.0) == qkey(0.0); quantize(1e9, 1024) = %d" % big)

	return TestHarness.result(SUITE, "X24", "PASS" if problems.is_empty() else "FAIL",
		"FixedPoint boundaries: half-way rounding, ties, sub-resolution differences, snap idempotence, large values",
		("problems: " + "; ".join(problems) + "\n" if not problems.is_empty() else "") + "\n".join(lines))


# --- X25 -----------------------------------------------------------------------------------

## The in-memory harness sink holds ONE column. An extent-1 module run through it therefore
## reads air where a neighbour column should be - which, uncounted, is indistinguishable from a
## module that does nothing (the E2 defect class). MemoryColumnWriter now counts those reads;
## this check fails on the M01 code, where get_type_world() returned 0 for an out-of-column
## position without recording anything.
func _x25_harness_neighbour_reads_counted() -> Array:
	var out: Array = []
	var cfg := WorldConfig.load_config()
	ModuleFixtures.clear()
	ModuleFixtures.install("cliff_pass")
	var lines: Array[String] = []
	var failed := false
	for id in AdapterRegistry.ids():
		if AdapterRegistry.is_legacy(id):
			lines.append("%-20s legacy baseline: runs no modules, skipped" % id)
			continue
		var built := AdapterRegistry.build_generator(id, cfg.seed_value, cfg.to_gen_context())
		if not built["ok"]:
			failed = true
			lines.append("%-20s build failed: %s" % [id, str(built["report"].get("error"))])
			continue
		var gen: Resource = built["generator"]
		if not bool(gen.call("neighbour_passes_in_plan")):
			failed = true
			lines.append("%-20s the extent-1 fixture did not reach the plan" % id)
			continue
		var writer: MemoryColumnWriter = gen.call("debug_column_memory", Vector3i(0, cfg.world_y_min, 0))
		var st: Dictionary = gen.call("stats")
		var sink: Dictionary = st.get("writer", {})
		var reads := writer.neighbour_reads
		var misses := writer.neighbour_misses
		var agg_reads := int(sink.get("neighbour_reads", 0))
		var agg_misses := int(sink.get("neighbour_misses", 0))
		# experimental_columns serves neighbours from generated columns, so its misses are 0
		# while its reads are not; native_cb's harness sink has no neighbours at all, so every
		# read is a miss. Both must be REPORTED - that is the property under test.
		var served := reads - misses
		var ok := reads > 0 and misses >= 0 and served >= 0 and agg_reads >= reads
		if not ok:
			failed = true
		lines.append("%-20s plan passes=%s extent=%s" % [id,
			str((st.get("plan", {}) as Dictionary).get("pass_count")), str((st.get("plan", {}) as Dictionary).get("max_extent"))])
		lines.append("%-20s   sink: neighbour_reads=%d neighbour_misses=%d served=%d oob_reads=%d rejected_writes=%d" % [
			"", reads, misses, served, writer.oob_reads, writer.rejected_writes])
		lines.append("%-20s   generator aggregate: %s" % ["", str(sink)])
		lines.append("%-20s   verdict: %s" % ["",
			"neighbour reads are COUNTED, so a report can say whether an extent-1 harness run read real data or air"
			if ok else "neighbour reads are NOT counted - an extent-1 harness run would look like it worked"])
	ModuleFixtures.clear()
	out.append(TestHarness.result(SUITE, "X25", "PASS" if not failed else "FAIL",
		"the in-memory harness counts every neighbour read it cannot serve (no silent air)",
		"\n".join(lines) + "\nfixtures installed now = %s" % str(ModuleFixtures.installed())))
	return out


# --- X26 -----------------------------------------------------------------------------------

## Two spine defects found while fixing E2, both of the same family ("resolved, listed, ran -
## and produced nothing"):
##   (a) a FieldProvider whose only channels are WORLD-scoped was skipped entirely, because the
##       executor asked "does it have region channels?" and moved on. The module appeared in the
##       pipeline dump, so nothing looked wrong (test_extensibility X1 caught it: ran = 0).
##   (b) a provider that DECLARES a channel and publishes nothing was invisible until a consumer
##       tried to read it. The runner now verifies, per call and per scope, that every declared
##       channel exists afterwards, and reports the module by id when it does not.
func _x26_world_scope_providers_run() -> Array:
	var out: Array = []
	var cfg := WorldConfig.load_config()
	var lines: Array[String] = []
	var failed := false

	# ---- (a) a world-scope-only provider really runs ---------------------------------------
	ModuleFixtures.clear()
	ModuleFixtures.install("world_provider")
	var built := AdapterRegistry.build_generator(AdapterRegistry.DEFAULT_ID, cfg.seed_value, cfg.to_gen_context())
	if not built["ok"]:
		failed = true
		lines.append("(a) build failed: %s" % str(built["report"].get("error")))
	else:
		var gen: Resource = built["generator"]
		var writer: MemoryColumnWriter = gen.call("debug_column_memory", Vector3i(0, cfg.world_y_min, 0))
		var st: Dictionary = gen.call("stats")
		var executed: Dictionary = st.get("executed_counts", {})
		var ran := int(executed.get(ModuleFixtures.KINDS["world_provider"]["id"], 0))
		var value: Variant = writer.get_type_world(Vector3i(0, cfg.world_y_min, 0))  # unused, keeps writer bound
		var pipe := PipelineBootstrap.build(cfg.to_gen_context())
		var listed := false
		for row_variant in pipe["scheduler"].pipeline_dump():
			var row: Dictionary = row_variant
			if String(row["id"]) == ModuleFixtures.KINDS["world_provider"]["id"]:
				listed = true
		var errors: Array = st.get("pipeline_errors", [])
		# It must run, and it must NOT be reported as a silent provider: it publishes its channel.
		if ran == 0 or not listed or not errors.is_empty():
			failed = true
		lines.append("(a) world-scope-only provider: listed in the pipeline dump=%s executions=%d pipeline_errors=%s" % [
			str(listed), ran, str(errors)])
		lines.append("(a) value read back through the writer (sanity, not part of the assertion): %s" % str(value))

	# ---- (b) a declared-but-unpublished channel is reported, naming the module -------------
	ModuleFixtures.clear()
	ModuleFixtures.install("silent_provider")
	var built2 := AdapterRegistry.build_generator(AdapterRegistry.DEFAULT_ID, cfg.seed_value, cfg.to_gen_context())
	if not built2["ok"]:
		failed = true
		lines.append("(b) build failed: %s" % str(built2["report"].get("error")))
	else:
		var gen2: Resource = built2["generator"]
		gen2.call("debug_column_memory", Vector3i(0, cfg.world_y_min, 0))
		var st2: Dictionary = gen2.call("stats")
		var errs: Array = st2.get("pipeline_errors", [])
		var joined := " ".join(errs.map(func(e): return String(e)))
		var names_module := joined.find(String(ModuleFixtures.KINDS["silent_provider"]["id"])) >= 0
		var names_channel := joined.find("field.silent") >= 0
		var names_call := joined.find("compute_region") >= 0
		var ran2 := int((st2.get("executed_counts", {}) as Dictionary).get(
			ModuleFixtures.KINDS["silent_provider"]["id"], 0))
		if not (names_module and names_channel and names_call and ran2 > 0):
			failed = true
		lines.append("(b) declared-but-unpublished provider: executions=%d (it ran; running is not the problem)" % ran2)
		lines.append("(b) names the module=%s names the channel=%s names the call=%s" % [
			str(names_module), str(names_channel), str(names_call)])
		lines.append("(b) pipeline_errors=%s" % str(errs))
	ModuleFixtures.clear()

	out.append(TestHarness.result(SUITE, "X26", "PASS" if not failed else "FAIL",
		"a world-scope-only FieldProvider executes, and a declared-but-unpublished channel is reported by module id",
		"\n".join(lines) + "\nfixtures installed now = %s" % str(ModuleFixtures.installed())))
	return out
