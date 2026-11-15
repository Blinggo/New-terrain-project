extends RefCounted
## tests/smoke/test_spine.gd
##
## M01 / Task 10 - Contract tests for the spine machinery: RNG streams (X3), scheduler
## order stability (X4), cycle detection (X5), missing producer (X6), duplicate id (X7),
## cache eviction/recompute (X8), plus blackboard and field-tile behaviour that the whole
## design rests on. X9 lives in the determinism suite (D5/X9, shared LayerLint).
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


func run(_ctx: Dictionary) -> Array:
	var out: Array = []
	out.append(_x3_rng_independence())
	out.append(_blackboard_basics())
	out.append(_field_tile_sampling())
	out.append(_x8_cache_recompute())
	out.append_array(_x4_order_stability())
	out.append(_x5_cycle_detection())
	out.append(_x6_missing_producer())
	out.append(_x7_duplicate_id())
	out.append(_scheduler_column_factor())
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

	var region := Vector2i(0, 0)
	runner.ensure_region(region)
	var first: FieldTile = ctx.cache.get_tile(&"field.height", region, 1)
	if first == null:
		return TestHarness.fail(SUITE, "X8", "field.height tile not cached after ensure_region",
			str(ctx.cache.stats()))
	var before := ctx.cache.stats()

	ctx.cache.erase(&"field.height", region, 1)
	if ctx.cache.get_tile(&"field.height", region, 1) != null:
		return TestHarness.fail(SUITE, "X8", "erase did not remove the tile")

	runner.ensure_region(region)
	var second: FieldTile = ctx.cache.get_tile(&"field.height", region, 1)
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
	return TestHarness.result(SUITE, "X7", "PASS" if not registry.errors.is_empty() and names_both else "FAIL",
		"duplicate module id errors naming BOTH file paths",
		"errors=%s, modules listed=%d" % [joined, listed])


# --- column factor ------------------------------------------------------------------------

func _scheduler_column_factor() -> Dictionary:
	var pass0 := TerrainPass.new()
	pass0.id = &"tests.pass0"
	pass0.phase = ModuleDefinition.Phase.SURFACE
	pass0.extent = 0
	var pass1 := TerrainPass.new()
	pass1.id = &"tests.pass1"
	pass1.phase = ModuleDefinition.Phase.SURFACE
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
	var gen := AdapterRegistry.build_generator("multipass", cfg.seed_value, ctx.config)
	if gen["ok"] and gen["generator"] is MultipassColumnGenerator:
		_keep_alive.append(gen["generator"])
		ctx.noise_2d = Callable(gen["generator"], "_noise_at")
	else:
		push_error("test_spine: could not build a multipass generator for the noise sampler: %s" % str(gen["report"]))
	return ctx


func _mod(id: StringName, phase: int, req: Array, prov: Array) -> ModuleDefinition:
	var m := ModuleDefinition.new()
	m.id = id
	m.phase = phase
	var r: Array[StringName] = []
	for x in req:
		r.append(StringName(x))
	var pv: Array[StringName] = []
	for x in prov:
		pv.append(StringName(x))
	m.requires = r
	m.provides = pv
	return m


func _chain_modules() -> Array:
	# Three modules with a real dependency chain plus a tiebreak pair, so shuffling has
	# something to bite on.
	var provider := FieldProvider.new()
	provider.id = &"tests.chain_provider"
	provider.phase = ModuleDefinition.Phase.PLANET
	provider.provides = [&"field.chain"]
	provider.priority = 50
	var consumer := TerrainPass.new()
	consumer.id = &"tests.chain_consumer"
	consumer.phase = ModuleDefinition.Phase.SURFACE
	consumer.requires = [&"field.chain"]
	consumer.priority = 50
	var tie_a := ModuleDefinition.new()
	tie_a.id = &"tests.tie_a"
	tie_a.phase = ModuleDefinition.Phase.CLIMATE
	tie_a.priority = 10
	var tie_b := ModuleDefinition.new()
	tie_b.id = &"tests.tie_b"
	tie_b.phase = ModuleDefinition.Phase.CLIMATE
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


func _cleanup() -> void:
	for p in _created_files:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	_created_files.clear()
