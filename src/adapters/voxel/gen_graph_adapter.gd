class_name GenGraphAdapter
extends IGeneratorAdapter
## src/adapters/voxel/gen_graph_adapter.gd
##
## M00 / T5 - Adapter #2: a VoxelGeneratorGraph built ENTIRELY IN CODE. No hand-edited
## .tres, no editor graph. Reproducible from data, diffable, testable headless.
##
## LAYER: adapters (may name Voxel Tools classes).
##
## API REALITY (verified with tools/dump_voxel_api.gd, tools/dump_graph_nodes.gd and
## tools/probe_generators.gd on Voxel Tools 1.7.0 / Godot 4.7.2):
##
##   * The node API is NOT on VoxelGeneratorGraph. It is on VoxelGraphFunction, reached
##     with VoxelGeneratorGraph.get_main_function(). VoxelGeneratorGraph itself only
##     exposes compile(), clear(), tuning flags and a graph_data Dictionary.
##   * VoxelGraphFunction.NodeTypeID has 57 entries but is MISSING the OutputType node.
##     The real node type list (get_node_type_count/get_node_type_info) contains
##     "OutputType" at id 44, between NODE_OUTPUT_WEIGHT (43) and
##     NODE_OUTPUT_SINGLE_TEXTURE (45). So we resolve every node type BY NAME at build
##     time instead of hard-coding enum constants. If Zylann renumbers them, we still bind
##     the right node.
##   * Select(a, b, t) with param `threshold` evaluates to b when t >= threshold, else a.
##     Verified empirically (probe P3 produced exactly {0: air, 3: stone}).
##   * Inputs left UNCONNECTED use their "default input" value as a constant, set with
##     set_node_default_input_by_name(). Connecting the same (src, port, dst, port) twice
##     raises "Cannot create the same connection twice".
##   * FastNoise2D's `noise` param is a ZN_FastNoiseLite (Voxel Tools' own copy, extends
##     Resource). Its frequency knob is called `period`, not `frequency`.
##   * compile() returns a Dictionary; {"success": true} on success.
##
## GRAPH (blocky TYPE output):
##
##   InputX --\
##             >-- FastNoise2D -- Remap(-1..1 -> height band) --\
##   InputZ --/                                                  >-- Subtract (h - y)
##   InputY ----------------------------------------------------/        |
##                                                            +-----------+-----------+
##                                                            |                       |
##                                            Select(grass|stone, t>=grass_depth)      |
##                                                            |                       |
##                                            Select(air|inner, t>=0) <---------------+
##                                                            |
##                                                       OutputType
##
## DETERMINISM: depends only on seed_value and config. ZN_FastNoiseLite.seed is explicit;
## the compiled graph is pure maths over (x, y, z).

const NODE_NAMES := {
	"noise": "terrain_noise",
	"input_x": "input_x",
	"input_y": "input_y",
	"input_z": "input_z",
	"remap": "height_remap",
	"depth": "depth_below_surface",
	"grass_or_stone": "grass_or_stone_select",
	"air_or_solid": "air_or_solid_select",
	"output": "output_type",
}

## Node type names we need, looked up by name (see the OutputType note above).
const REQUIRED_NODE_TYPES: Array[String] = [
	"FastNoise2D", "InputX", "InputY", "InputZ", "Remap", "Subtract", "Select", "OutputType",
]

var _report := {}


func get_id() -> String:
	return "graph"


func get_display_name() -> String:
	return "VoxelGeneratorGraph (built in code, OutputType -> TYPE)"


func build(seed_value: int, config: Dictionary) -> VoxelGenerator:
	_report = {
		"adapter": get_id(),
		"seed": seed_value,
		"generator_class": "VoxelGeneratorGraph",
		"node_types_resolved": {},
		"node_ids": {},
		"compile_result": null,
		"warnings": [],
	}

	var gen := VoxelGeneratorGraph.new()
	var fn: VoxelGraphFunction = gen.get_main_function()
	if fn == null:
		_report["warnings"].append("get_main_function() returned null")
		push_error("gen_graph_adapter: get_main_function() returned null")
		return null

	fn.clear()

	var t := _resolve_node_types(fn)
	if t.is_empty():
		push_error("gen_graph_adapter: could not resolve required node types; graph not built")
		return null
	_report["node_types_resolved"] = t

	# --- M01: parameters come from the RESOLVED MODULE PLAN, not from raw config ----------
	# The spine resolves content/modules/** + config overrides; this adapter then pushes the
	# resolved numbers into the named graph nodes below. Structure changed in M01, maths did
	# not: with the shipped modules the values are byte-identical to M00's gen_params, which
	# is exactly what X10 (M00 graph goldens reproduce bit-for-bit) verifies.
	var pipeline: Dictionary = config.get("pipeline", {})
	if not pipeline.get("ok", false):
		pipeline = PipelineBootstrap.build(config)
	if not pipeline.get("ok", false):
		push_error("gen_graph_adapter: pipeline failed to resolve: %s" % str(pipeline.get("errors")))
		_report["warnings"].append("pipeline resolve failed: %s" % str(pipeline.get("errors")))
		return null
	var hills: HillsV1 = _module_of(pipeline, &"planet.hills_v1")
	var surface: GrassStoneV1 = _module_of(pipeline, &"surface.grass_stone_v1")
	if hills == null or surface == null:
		push_error("gen_graph_adapter: resolved pipeline lacks planet.hills_v1 / surface.grass_stone_v1 (got %s)" % str(pipeline["scheduler"].pipeline_dump().map(func(m): return m["id"])))
		_report["warnings"].append("hills/surface modules missing from pipeline")
		return null
	_report["pipeline"] = pipeline["scheduler"].pipeline_dump()
	_report["module_params"] = {
		"planet.hills_v1": {"noise_frequency": hills.noise_frequency, "noise_octaves": hills.noise_octaves,
			"noise_lacunarity": hills.noise_lacunarity, "noise_gain": hills.noise_gain,
			"height_base": hills.height_base, "height_amplitude": hills.height_amplitude},
		"surface.grass_stone_v1": {"grass_depth": surface.grass_depth, "air_id": surface.air_id,
			"grass_id": surface.grass_id, "stone_id": surface.stone_id},
	}

	# --- noise source ------------------------------------------------------------------
	# ZN_FastNoiseLite (NOT Godot's FastNoiseLite): the graph node's param is typed
	# ZN_FastNoiseLite, verified via get_node_type_info.
	var noise := ZN_FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2
	noise.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = clampi(hills.noise_octaves, 1, 16)
	noise.fractal_lacunarity = hills.noise_lacunarity
	noise.fractal_gain = hills.noise_gain
	var frequency := maxf(hills.noise_frequency, 0.000001)
	noise.period = 1.0 / frequency

	# --- terrain shape -----------------------------------------------------------------
	var height_base := hills.height_base
	var height_amplitude := maxf(hills.height_amplitude, 1.0)
	var height_min := height_base - height_amplitude * 0.5
	var height_max := height_base + height_amplitude * 0.5
	var grass_depth := float(surface.grass_depth)

	var air_id := float(surface.air_id)
	var grass_id := float(surface.grass_id)
	var stone_id := float(surface.stone_id)

	# --- nodes (explicit ids so the graph is reproducible and findable) -----------------
	var id_noise := fn.create_node(t["FastNoise2D"], Vector2(60, 40), 1)
	var id_x := fn.create_node(t["InputX"], Vector2(-180, -20), 2)
	var id_z := fn.create_node(t["InputZ"], Vector2(-180, 100), 3)
	var id_y := fn.create_node(t["InputY"], Vector2(-180, 260), 4)
	var id_remap := fn.create_node(t["Remap"], Vector2(300, 40), 5)
	var id_depth := fn.create_node(t["Subtract"], Vector2(540, 160), 6)
	var id_grass_or_stone := fn.create_node(t["Select"], Vector2(780, 60), 7)
	var id_air_or_solid := fn.create_node(t["Select"], Vector2(1020, 160), 8)
	var id_output := fn.create_node(t["OutputType"], Vector2(1260, 160), 9)

	_report["node_ids"] = {
		"terrain_noise": id_noise,
		"input_x": id_x,
		"input_y": id_y,
		"input_z": id_z,
		"height_remap": id_remap,
		"depth_below_surface": id_depth,
		"grass_or_stone_select": id_grass_or_stone,
		"air_or_solid_select": id_air_or_solid,
		"output_type": id_output,
	}

	# --- names (so M01+ can find_node_by_name instead of relying on ids) ----------------
	fn.set_node_name(id_noise, NODE_NAMES["noise"])
	fn.set_node_name(id_x, NODE_NAMES["input_x"])
	fn.set_node_name(id_y, NODE_NAMES["input_y"])
	fn.set_node_name(id_z, NODE_NAMES["input_z"])
	fn.set_node_name(id_remap, NODE_NAMES["remap"])
	fn.set_node_name(id_depth, NODE_NAMES["depth"])
	fn.set_node_name(id_grass_or_stone, NODE_NAMES["grass_or_stone"])
	fn.set_node_name(id_air_or_solid, NODE_NAMES["air_or_solid"])
	fn.set_node_name(id_output, NODE_NAMES["output"])

	# --- params ------------------------------------------------------------------------
	fn.set_node_param_by_name(id_noise, "noise", noise)
	fn.set_node_param_by_name(id_remap, "min0", -1.0)
	fn.set_node_param_by_name(id_remap, "max0", 1.0)
	fn.set_node_param_by_name(id_remap, "min1", height_min)
	fn.set_node_param_by_name(id_remap, "max1", height_max)
	fn.set_node_param_by_name(id_grass_or_stone, "threshold", grass_depth)
	fn.set_node_param_by_name(id_air_or_solid, "threshold", 0.0)

	# --- constant inputs (unconnected => default input value is used) -------------------
	fn.set_node_default_input_by_name(id_grass_or_stone, "a", grass_id)
	fn.set_node_default_input_by_name(id_grass_or_stone, "b", stone_id)
	fn.set_node_default_input_by_name(id_air_or_solid, "a", air_id)

	# --- connections (each (src,src_port,dst,dst_port) exactly once) ---------------------
	fn.add_connection(id_x, 0, id_noise, 0)          # noise.x <- InputX
	fn.add_connection(id_z, 0, id_noise, 1)          # noise.y <- InputZ
	fn.add_connection(id_noise, 0, id_remap, 0)      # remap.x <- noise
	fn.add_connection(id_remap, 0, id_depth, 0)      # depth.a <- height
	fn.add_connection(id_y, 0, id_depth, 1)          # depth.b <- InputY
	fn.add_connection(id_depth, 0, id_grass_or_stone, 2)  # grass_or_stone.t <- depth
	fn.add_connection(id_depth, 0, id_air_or_solid, 2)    # air_or_solid.t <- depth
	fn.add_connection(id_grass_or_stone, 0, id_air_or_solid, 1)  # air_or_solid.b <- grass_or_stone
	fn.add_connection(id_air_or_solid, 0, id_output, 0)   # OutputType.type <- air_or_solid

	var compile_result: Dictionary = gen.compile()
	_report["compile_result"] = compile_result
	_report["shape"] = {
		"height_min": height_min,
		"height_max": height_max,
		"grass_depth": grass_depth,
		"air_id": int(air_id),
		"grass_id": int(grass_id),
		"stone_id": int(stone_id),
	}
	_report["tuning"] = {
		"use_optimized_execution_map": gen.is_using_optimized_execution_map(),
		"use_subdivision": gen.is_using_subdivision(),
		"subdivision_size": gen.get_subdivision_size(),
		"use_xz_caching": gen.is_using_xz_caching(),
		"debug_block_clipping": gen.is_debug_clipped_blocks(),
	}

	if not bool(compile_result.get("success", false)):
		var msg := str(compile_result)
		_report["warnings"].append("compile() did not report success: %s" % msg)
		push_error("gen_graph_adapter: graph compile failed: %s" % msg)
		return null

	# Sanity: the names must survive the build so later milestones can find the nodes.
	for key in NODE_NAMES:
		var wanted: String = NODE_NAMES[key]
		if fn.find_node_by_name(StringName(wanted)) == 0:
			_report["warnings"].append("find_node_by_name('%s') returned 0 after build" % wanted)

	return gen


## Resolve node type ids by name. Returns {} if any required type is missing, so the caller
## fails loudly instead of silently binding the wrong node.
func _resolve_node_types(fn: VoxelGraphFunction) -> Dictionary:
	var by_name := {}
	for i in fn.get_node_type_count():
		var info: Dictionary = fn.get_node_type_info(i)
		by_name[String(info.get("name", ""))] = i

	var out := {}
	for wanted in REQUIRED_NODE_TYPES:
		if not by_name.has(wanted):
			_report["warnings"].append("node type '%s' does not exist in this build" % wanted)
			push_error("gen_graph_adapter: node type '%s' not found (available: %s)" % [wanted, str(by_name.keys())])
			return {}
		out[wanted] = int(by_name[wanted])
	return out


static func _module_of(pipeline: Dictionary, id: StringName):
	for m in pipeline["modules"]:
		if (m as ModuleDefinition).id == id:
			return m
	return null


func get_last_build_report() -> Dictionary:
	return _report
