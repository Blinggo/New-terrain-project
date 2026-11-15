class_name GenNativeCBAdapter
extends IGeneratorAdapter
## src/adapters/voxel/gen_native_cb_adapter.gd
##
## M01-fix / T1 - Adapter for the NATIVE multipass backend: builds a
## NativeColumnGenerator (a GDScript subclass of VoxelGeneratorMultipassCB) configured by the
## resolved module pipeline.
##
## This is the DEFAULT backend, and the reason is the M01 review's evidence E1/E2: the
## extension's own multipass callback IS scriptable (M01 probed the wrong class and concluded
## otherwise), and the compiled graph - which was the default - executes its own fixed M00
## maths and IGNORES which modules are enabled. A backend that cannot run the modules is not
## a worldgen pipeline; it is a picture of one.
##
## LAYER: adapters. Names no module id and no worldgen class (hard rule): everything about
## WHAT runs comes from the plan, everything about HOW from the engine.

var _report := {}

const ID := "native_cb"


func get_id() -> String:
	return ID


func get_display_name() -> String:
	return "Native multipass columns (VoxelGeneratorMultipassCB subclass running the module pipeline)"


func capabilities() -> Dictionary:
	var caps := super.capabilities()
	caps["label"] = "modular (native engine columns)"
	caps["executes_all_modules"] = true
	caps["supports_neighbor_passes"] = true
	caps["max_passes"] = MultipassPassPlan.MAX_PASSES
	caps["max_extent"] = MultipassPassPlan.MAX_EXTENT
	caps["max_column_height_blocks"] = MultipassPassPlan.MAX_COLUMN_HEIGHT_BLOCKS
	caps["supports_lod"] = false
	caps["legacy"] = false
	caps["notes"] = ("Engine-driven columns: _generate_pass(tool, index) on worker threads, main area = one "
		+ "16 x column_height x 16 column, editable area = main + pass extent. Limits MAX_PASSES=4, "
		+ "MAX_PASS_EXTENT=2, column height <= 32 blocks, no LOD; MultipassPassPlan fails closed when a "
		+ "pipeline does not fit. generate_block() is 'Not implemented' on this class, so the determinism "
		+ "harness reads columns through debug_column_memory() and a live-terrain test proves the two agree.")
	return caps


func build(seed_value: int, config: Dictionary) -> VoxelGenerator:
	_report = {
		"adapter": get_id(),
		"seed": seed_value,
		"generator_class": "NativeColumnGenerator (VoxelGeneratorMultipassCB)",
		"capabilities": capabilities(),
		"warnings": [],
	}

	var pipeline: Dictionary = config.get("pipeline", {})
	if not pipeline.get("ok", false):
		pipeline = PipelineBootstrap.build(config)
	if not pipeline.get("ok", false):
		push_error("gen_native_cb_adapter: pipeline failed to resolve: %s" % str(pipeline.get("errors")))
		_report["error"] = "pipeline resolve failed: %s" % str(pipeline.get("errors"))
		return null

	var gen := NativeColumnGenerator.new()
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
