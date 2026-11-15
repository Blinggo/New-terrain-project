class_name GenExperimentalColumnsAdapter
extends IGeneratorAdapter
## src/adapters/voxel/gen_experimental_columns_adapter.gd
##
## M01-fix / T1 - RENAMED from gen_multipass_adapter.gd, together with the backend it builds
## (`experimental_columns`, was `multipass`). The old name was wrong in a way that mattered:
## it implied the extension's VoxelGeneratorMultipassCB, which this is not. The first M01
## pass concluded that class was unscriptable (evidence E1 says otherwise: it IS scriptable,
## M01 probed VoxelToolMultipassGenerator, a virtual class GDScript cannot inherit) and then
## named its self-hosted substitute after the thing it claimed could not be used.
##
## Current split, so the names carry the truth:
##   native_cb              the engine's own multipass callback (default, fast, limited to
##                          MAX_PASSES=4 / MAX_PASS_EXTENT=2 / 32-block columns / no LOD)
##   experimental_columns   THIS: self-hosted columns on VoxelGeneratorScript, no engine pass
##                          or extent limits, GDScript speed. A pricing spike and a fallback,
##                          not a claim about the extension.
##
## LAYER: adapters. Names no module id and no worldgen class: what runs comes from the plan.

var _report := {}

const ID := "experimental_columns"


func get_id() -> String:
	return ID


func get_display_name() -> String:
	return "Experimental self-hosted columns (VoxelGeneratorScript; module pipeline, no engine pass limits)"


func capabilities() -> Dictionary:
	var caps := super.capabilities()
	caps["label"] = "modular (self-hosted columns, experimental)"
	caps["executes_all_modules"] = true
	caps["supports_neighbor_passes"] = true
	caps["max_passes"] = 0            # 0 = no limit: passes are GDScript here
	caps["max_extent"] = 0
	caps["max_column_height_blocks"] = 0
	caps["supports_lod"] = false
	caps["legacy"] = false
	caps["experimental"] = true
	caps["notes"] = ("Compiles whole 16 x world_height x 16 columns in GDScript and caches them (LRU). "
		+ "Neighbour passes read columns compiled with earlier passes only, reproducing the engine's "
		+ "visibility rule. Cost is roughly 30x the compiled graph per column (B3), which is exactly "
		+ "what this backend exists to measure before anyone ships a neighbour-aware rule.")
	return caps


func build(seed_value: int, config: Dictionary) -> VoxelGenerator:
	_report = {
		"adapter": get_id(),
		"seed": seed_value,
		"generator_class": "ExperimentalColumnGenerator (VoxelGeneratorScript)",
		"capabilities": capabilities(),
		"warnings": [],
	}

	var pipeline: Dictionary = config.get("pipeline", {})
	if not pipeline.get("ok", false):
		pipeline = PipelineBootstrap.build(config)
	if not pipeline.get("ok", false):
		push_error("gen_experimental_columns_adapter: pipeline failed to resolve: %s" % str(pipeline.get("errors")))
		_report["error"] = "pipeline resolve failed: %s" % str(pipeline.get("errors"))
		return null

	var gen := ExperimentalColumnGenerator.new()
	if not gen.setup(pipeline, config, seed_value):
		_report["error"] = gen.broken_reason
		_report["warnings"].append("generator refused to configure: %s" % gen.broken_reason)
		return null

	_report["pipeline"] = pipeline["scheduler"].pipeline_dump()
	_report["plan"] = gen.plan.describe()
	_report["column_factor"] = pipeline["scheduler"].column_factor()
	_report["noise_recipe"] = NoiseSamplerBuilder.describe(NoiseSamplerBuilder.first_recipe(pipeline["modules"]))
	return gen


func get_last_build_report() -> Dictionary:
	return _report
