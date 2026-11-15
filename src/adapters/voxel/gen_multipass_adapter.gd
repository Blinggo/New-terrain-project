class_name GenMultipassAdapter
extends IGeneratorAdapter
## src/adapters/voxel/gen_multipass_adapter.gd
##
## M01 / Task 9 - The neighbour-aware backend: runs the resolved module pipeline as COLUMN
## PASSES with extents, over a per-column cache, on top of VoxelGeneratorScript.
##
## WHY NOT VoxelGeneratorMultipassCB (measured, tools/probe_multipass*.gd, Voxel Tools 1.7.0
## GDExtension, Godot 4.7.2):
##   * VoxelToolMultipassGenerator - the class a pass must be - CANNOT BE SUBCLASSED from
##     GDScript: ClassDB.instantiate() says "cannot be instantiated" and a GDScript extends
##     says "Can't inherit from a virtual class".
##   * VoxelGeneratorMultipassCB exposes only pass_count / column_base_y_blocks /
##     column_height_blocks / pass_%d_extent. There is NO script-visible property or method
##     to attach pass tools (no "passes" in get_property_list()), so passes can only be
##     authored in C++/editor land, which hard rule #3-ish (GDScript only) forbids us to add.
##   * VoxelGeneratorScript, however, IS scriptable (_generate_block verified live).
## So M01 self-hosts the multipass pattern: same semantics (passes over columns, extents in
## columns, cross-column reads), deterministic, and - crucially for the spike - its GDScript
## cost is exactly the number M02/M08 need before committing to neighbour-aware features.
## If a future Voxel Tools release makes MultipassCB scriptable, this file is the swap point.
##
## PASSES (M01):
##   pass A, extent 0: the resolved pipeline as-is (planet.hills_v1 tile + surface pass).
##   pass B, extent 1: a cliff rule that reads the 8 neighbour columns' pass-A output and
##     converts the grass cap to stone where a neighbour rises >= cliff_threshold blocks.
##     It exists to price cross-chunk reads; it is real terrain logic, not a no-op.
##
## LAYER: adapters. May name Voxel Tools classes (VoxelGeneratorScript, ZN_FastNoiseLite).

const COLUMN_BYTES := 16 * 16 * 384
const COLUMN_CACHE_MAX := 768

var _report := {}


func get_id() -> String:
	return "multipass"


func get_display_name() -> String:
	return "Self-hosted multipass columns (VoxelGeneratorScript, extents 0+1)"


func build(seed_value: int, config: Dictionary) -> VoxelGenerator:
	_report = {
		"adapter": get_id(),
		"seed": seed_value,
		"generator_class": "VoxelGeneratorScript (self-hosted multipass)",
		"multipass_cb_scriptable": false,
		"probe_evidence": "VoxelToolMultipassGenerator: 'Can't inherit from a virtual class'; VoxelGeneratorMultipassCB has no passes property (tools/probe_multipass2.gd)",
		"warnings": [],
	}

	var pipeline: Dictionary = config.get("pipeline", {})
	if not pipeline.get("ok", false):
		pipeline = PipelineBootstrap.build(config)
	if not pipeline.get("ok", false):
		push_error("gen_multipass_adapter: pipeline failed to resolve: %s" % str(pipeline.get("errors")))
		return null

	var gen := MultipassColumnGenerator.new()
	gen.setup(pipeline, config, seed_value, bool(config.get("multipass_pass_b", true)))
	_report["pipeline"] = pipeline["scheduler"].pipeline_dump()
	_report["column_factor"] = pipeline["scheduler"].column_factor()
	return gen


func get_last_build_report() -> Dictionary:
	return _report
