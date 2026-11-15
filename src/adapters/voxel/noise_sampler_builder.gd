class_name NoiseSamplerBuilder
extends RefCounted
## src/adapters/voxel/noise_sampler_builder.gd
##
## M01-fix / T1-T2 - Turns a module's `noise_sampler_recipe()` (plain strings and numbers,
## declared in src/worldgen/) into the ONE noise implementation every backend shares
## (ZN_FastNoiseLite - Voxel Tools' own copy, which is what the compiled graph's FastNoise2D
## node evaluates).
##
## WHY THIS FILE EXISTS: an adapter must configure the sampler without knowing any module id
## or concrete worldgen class (hard rule: no content ids in adapters/spine/runtime). So the
## plan is scanned for the FIRST non-empty recipe in resolved order, and the recipe is data.
## A GDScript backend sampling through ctx.noise_2d and the compiled graph therefore evaluate
## identical maths from identical numbers, which is what makes the two backends' goldens
## comparable at all.
##
## LAYER: adapters. May name Voxel Tools classes.

## Exact constant names, verified against docs/reports/voxel_api_dump.json
## (ZN_FastNoiseLite.enums.NoiseType / .FractalType): there is NO TYPE_SIMPLEX and the
## ping-pong fractal is FRACTAL_PING_PONG, not FRACTAL_PINGPONG. Guessing either one is a
## parse error, which is the good outcome - a wrong number would have been silent.
const TYPES := {
	"open_simplex_2": ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2,
	"open_simplex_2s": ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S,
	"perlin": ZN_FastNoiseLite.TYPE_PERLIN,
	"cellular": ZN_FastNoiseLite.TYPE_CELLULAR,
	"value": ZN_FastNoiseLite.TYPE_VALUE,
	"value_cubic": ZN_FastNoiseLite.TYPE_VALUE_CUBIC,
}
const FRACTALS := {
	"none": ZN_FastNoiseLite.FRACTAL_NONE,
	"fbm": ZN_FastNoiseLite.FRACTAL_FBM,
	"ridged": ZN_FastNoiseLite.FRACTAL_RIDGED,
	"ping_pong": ZN_FastNoiseLite.FRACTAL_PING_PONG,
}


## First non-empty recipe in resolved order. {} when no module declares one, which is legal:
## a pipeline may be purely analytic. The caller decides whether that is an error.
static func first_recipe(modules: Array) -> Dictionary:
	for m_variant in modules:
		var m := m_variant as ModuleDefinition
		if m == null:
			continue
		var recipe: Dictionary = m.noise_sampler_recipe()
		if not recipe.is_empty():
			return recipe
	return {}


## Build a configured sampler. Returns null and pushes an error for an unknown recipe key
## value: a typo must not silently become default noise (fail closed).
static func build(recipe: Dictionary, seed_value: int) -> ZN_FastNoiseLite:
	if recipe.is_empty():
		return null
	var type_name := String(recipe.get("type", ""))
	if not TYPES.has(type_name):
		push_error("noise_sampler_builder: unknown noise type '%s' (known: %s)" % [type_name, str(TYPES.keys())])
		return null
	var fractal_name := String(recipe.get("fractal", "fbm"))
	if not FRACTALS.has(fractal_name):
		push_error("noise_sampler_builder: unknown fractal type '%s' (known: %s)" % [fractal_name, str(FRACTALS.keys())])
		return null
	var frequency := float(recipe.get("frequency", 0.0035))
	if frequency <= 0.0:
		push_error("noise_sampler_builder: frequency must be > 0 (got %s)" % str(frequency))
		return null

	var noise := ZN_FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = int(TYPES[type_name])
	noise.fractal_type = int(FRACTALS[fractal_name])
	noise.fractal_octaves = clampi(int(recipe.get("octaves", 5)), 1, 16)
	noise.fractal_lacunarity = float(recipe.get("lacunarity", 2.0))
	noise.fractal_gain = float(recipe.get("gain", 0.5))
	# ZN_FastNoiseLite's knob is `period`, not `frequency` (verified in M00 with
	# tools/probe_generators.gd); the recipe speaks the more common word.
	noise.period = 1.0 / frequency
	return noise


## Canonical one-line description, used in build reports and cache-key extras so two runs can
## be compared without depending on Dictionary iteration order.
static func describe(recipe: Dictionary) -> String:
	if recipe.is_empty():
		return "(none)"
	var keys: Array = recipe.keys()
	keys.sort()
	var parts: Array[String] = []
	for k in keys:
		parts.append("%s=%s" % [String(k), str(recipe[k])])
	return ", ".join(parts)
