class_name MultipassColumnGenerator
extends VoxelGeneratorScript
## src/adapters/voxel/multipass_column_generator.gd
##
## M01 / Task 9 - Self-hosted multipass column generator (see gen_multipass_adapter.gd for
## why the extension's VoxelGeneratorMultipassCB cannot be used from GDScript).
##
## Model:
##   * A COLUMN is 16 x world_height x 16 TYPE bytes, compiled once and cached (LRU).
##   * pass A (extent 0) = the resolved module pipeline through PipelineRunner:
##     FieldProviders publish REGION tiles (cached in FieldCache), TerrainPasses write TYPE.
##   * pass B (extent 1) = cliff rule reading the 8 neighbour columns' pass-A heights:
##     where a neighbour rises >= cliff_threshold, the grass cap becomes stone. Neighbours
##     are compiled with pass B disabled, so recursion is bounded and the result is a pure
##     function of (seed, column) - determinism holds across processes (X11).
##   * generate_block() copies one 16-block row of a compiled column into the engine buffer.
##
## Determinism: no rand*, no clocks (the profiler Callable is injected by the runtime and
## may be invalid), no iteration over unordered containers in value-producing code.

const COLUMN_CACHE_MAX := 768

var world_y_min := -64
var world_height := 384
var use_pass_b := true
var cliff_threshold := 4

var _board: GenBlackboard = null
var _cache: FieldCache = null
var _ctx: GenContext = null
var _runner: PipelineRunner = null
var _noise: ZN_FastNoiseLite = null
var _surface: GrassStoneV1 = null

var _cols := {}                 # "cx,cz" -> {"data": PackedByteArray, "height": PackedInt32Array}
var _col_order: Array[String] = []
var _column_compiles := 0
var _pass_b_applications := 0


func setup(pipeline: Dictionary, config: Dictionary, seed_value: int, pass_b: bool = true) -> void:
	use_pass_b = pass_b
	world_y_min = int(config.get("world_y_min", -64))
	world_height = int(config.get("world_y_max", 320)) - world_y_min

	_board = GenBlackboard.new()
	_cache = FieldCache.new()
	_cache.configure_budget(int(config.get("field_cache_budget_bytes", 24 * 1024 * 1024)))

	_ctx = GenContext.new()
	_ctx.blackboard = _board
	_ctx.cache = _cache
	_ctx.config = config
	_ctx.quality_tier = String(config.get("quality_tier", "low"))
	_ctx.world_seed = seed_value
	_ctx.noise_2d = Callable(self, "_noise_at")

	_runner = PipelineRunner.new()
	_runner.ctx = _ctx
	_runner.scheduler = pipeline["scheduler"]

	# The ONE noise instance, configured from the resolved hills module so pass A evaluates
	# the same maths the graph backend compiles (same ZN_FastNoiseLite settings as M00).
	var hills: HillsV1 = _find(pipeline, &"planet.hills_v1")
	_surface = _find(pipeline, &"surface.grass_stone_v1")
	if hills == null:
		push_error("multipass: resolved pipeline has no planet.hills_v1 module")
		return
	_noise = ZN_FastNoiseLite.new()
	_noise.seed = seed_value
	_noise.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2
	_noise.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = clampi(hills.noise_octaves, 1, 16)
	_noise.fractal_lacunarity = hills.noise_lacunarity
	_noise.fractal_gain = hills.noise_gain
	_noise.period = 1.0 / maxf(hills.noise_frequency, 0.000001)


## The runtime injects its clock for per-module timings; the spine never reads one itself.
func set_profiler(profiler: Callable) -> void:
	_ctx.profiler = profiler


func timings() -> Dictionary:
	return _ctx.timings


func stats() -> Dictionary:
	return {
		"columns_cached": _cols.size(),
		"column_compiles": _column_compiles,
		"pass_b_applications": _pass_b_applications,
		"field_cache": _cache.stats(),
	}


func _noise_at(x: int, z: int) -> float:
	return _noise.get_noise_2d(float(x), float(z))


func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE


func _generate_block(buffer: VoxelBuffer, origin: Vector3i, _lod: int) -> void:
	var cx := int(floor(float(origin.x) / 16.0))
	var cz := int(floor(float(origin.z) / 16.0))
	var col: Dictionary = _column(cx, cz, true)
	var data: PackedByteArray = col["data"]
	var row := (origin.y - world_y_min) / 16
	if row < 0 or row >= world_height / 16:
		return
	var base := row * 16
	for y in 16:
		var slice := (base + y) * 256
		for lz in 16:
			var o := slice + lz * 16
			for lx in 16:
				buffer.set_voxel(data[o + lx], lx, y, lz, VoxelBuffer.CHANNEL_TYPE)


# --- column compilation -----------------------------------------------------------------

func _column(cx: int, cz: int, allow_b: bool) -> Dictionary:
	var key := "%d,%d" % [cx, cz]
	if _cols.has(key):
		return _cols[key]

	var data := PackedByteArray()
	data.resize(16 * 16 * world_height)
	var origin := Vector3i(cx * 16, world_y_min, cz * 16)
	var writer := MultipassColumnWriter.new()
	writer.data = data
	writer.y_min = world_y_min
	writer.origin = origin

	# pass A, extent 0: the module pipeline.
	_runner.run_column(origin, writer)

	var heights := PackedInt32Array()
	heights.resize(256)
	for lz in 16:
		for lx in 16:
			heights[lz * 16 + lx] = _top_solid(data, lx, lz)

	var entry := {"data": data, "height": heights}
	_cols[key] = entry
	_col_order.append(key)
	_column_compiles += 1
	if _col_order.size() > COLUMN_CACHE_MAX:
		_cols.erase(_col_order[0])
		_col_order.pop_front()

	if allow_b and use_pass_b:
		_apply_pass_b(cx, cz, entry)
	return entry


## pass B, extent 1: cliff stone caps. Reads neighbour pass-A heights only.
func _apply_pass_b(cx: int, cz: int, entry: Dictionary) -> void:
	if _surface == null:
		return
	var data: PackedByteArray = entry["data"]
	var heights: PackedInt32Array = entry["height"]
	var grass_id := _surface.grass_id
	var stone_id := _surface.stone_id
	var cap := _surface.grass_depth
	var changed := false
	for lz in 16:
		for lx in 16:
			var h: int = heights[lz * 16 + lx]
			if h < world_y_min:
				continue
			var cliff := false
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dz == 0:
						continue
					var nh: int = _column(cx + dx, cz + dz, false)["height"][lz * 16 + lx]
					if nh - h >= cliff_threshold:
						cliff = true
						break
				if cliff:
					break
			if not cliff:
				continue
			changed = true
			for wy in range(h - cap + 1, h + 1):
				var idx := (wy - world_y_min) * 256 + lz * 16 + lx
				if data[idx] == grass_id:
					data[idx] = stone_id
	if changed:
		_pass_b_applications += 1


func _top_solid(data: PackedByteArray, lx: int, lz: int) -> int:
	for wy in range(world_height - 1, -1, -1):
		if data[wy * 256 + lz * 16 + lx] != 0:
			return world_y_min + wy
	return world_y_min - 1


func _find(pipeline: Dictionary, id: StringName):
	for m in pipeline["modules"]:
		if (m as ModuleDefinition).id == id:
			return m
	return null


## In-memory column sink implementing the spine's abstract writer.
class MultipassColumnWriter extends IColumnWriter:
	var data: PackedByteArray
	var y_min := 0
	var origin := Vector3i.ZERO

	func set_type(lx: int, wy: int, lz: int, id: int) -> void:
		data[(wy - y_min) * 256 + lz * 16 + lx] = id

	func get_type(lx: int, wy: int, lz: int) -> int:
		return data[(wy - y_min) * 256 + lz * 16 + lx]

	func column_origin() -> Vector3i:
		return origin
