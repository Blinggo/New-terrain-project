class_name GenNoise2DAdapter
extends IGeneratorAdapter
## src/adapters/voxel/gen_noise2d_adapter.gd
##
## M00 / T5 - Adapter #1: wraps the built-in VoxelGeneratorNoise2D. This is the
## "guaranteed to work" reference generator.
##
## LAYER: adapters (may name Voxel Tools classes).
##
## SEMANTICS, VERIFIED EMPIRICALLY on Voxel Tools 1.7.0 / Godot 4.7.2 with
## tools/probe_generators.gd (P1) - not assumed from documentation:
##
##   * VoxelGeneratorNoise2D extends VoxelGeneratorHeightmap, whose exposed knobs are
##     `channel`, `height_start`, `height_range`, `curve`, `iso_scale`, `offset`, plus
##     `noise` (typed Godot `Noise`) and `curve`.
##   * It fills EVERY voxel from the bottom of the block up to the surface height, so the
##     terrain is a solid column - no floating slabs. Surface height lands inside
##     [height_start, height_start + height_range].
##   * It writes a SINGLE hardcoded voxel value: 1. There is no "top block / filler /
##     stone" layering and no property to change it. In our blocks.json id 1 == grass, so
##     this generator renders as an all-grass world. That is a real limitation and the main
##     reason the graph adapter is recommended as the M01 starting point.
##   * `noise` must be a Godot `Noise` (e.g. built-in FastNoiseLite). Voxel Tools' own
##     ZN_FastNoiseLite extends Resource, NOT Noise, so it is NOT assignable here - it is
##     used by the graph's FastNoise2D node instead.
##
## DETERMINISM: the only inputs are seed_value and config. FastNoiseLite.seed is set
## explicitly; nothing calls randf()/randi(), reads Time.*, or depends on frame order.

var _report := {}


func get_id() -> String:
	return "noise2d"


func get_display_name() -> String:
	return "Noise2D heightmap (built-in VoxelGeneratorNoise2D)"


func build(seed_value: int, config: Dictionary) -> VoxelGenerator:
	_report = {
		"adapter": get_id(),
		"seed": seed_value,
		"generator_class": "VoxelGeneratorNoise2D",
		"noise_class": "FastNoiseLite",
		"warnings": [],
	}

	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = param(config, "noise_frequency", 0.0035)
	noise.fractal_octaves = clampi(int(param(config, "noise_octaves", 5)), 1, 16)
	noise.fractal_lacunarity = param(config, "noise_lacunarity", 2.0)
	noise.fractal_gain = param(config, "noise_gain", 0.5)

	var height_base := param(config, "height_base", 64.0)
	var height_amplitude := maxf(param(config, "height_amplitude", 42.0), 1.0)

	var gen := VoxelGeneratorNoise2D.new()
	gen.noise = noise
	# CHANNEL TYPE, as required by T5, so the blocky mesher can read it.
	gen.channel = VoxelBuffer.CHANNEL_TYPE
	# Centre the surface band on height_base (sea level by default) and span the amplitude.
	gen.height_start = height_base - height_amplitude * 0.5
	gen.height_range = height_amplitude

	_report["noise_frequency"] = noise.frequency
	_report["noise_octaves"] = noise.fractal_octaves
	_report["height_start"] = gen.height_start
	_report["height_range"] = gen.height_range
	_report["channel"] = gen.channel
	_report["writes_only_voxel_id"] = 1
	_report["notes"] = "surface height in [%.1f, %.1f]; fills solid to the bottom of every block; voxel id is hardcoded to 1 by VoxelGeneratorHeightmap" % [
		gen.height_start, gen.height_start + gen.height_range
	]
	return gen


func get_last_build_report() -> Dictionary:
	return _report
