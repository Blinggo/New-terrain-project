class_name RngStreams
extends RefCounted
## src/core/rng_streams.gd
##
## M01 / Task 1 - The ONLY source of randomness for worldgen. Hard rule #3: no global
## randf()/randi()/randomize() anywhere in core/spine/worldgen/adapters; every random draw
## comes from a stream whose seed is a pure function of
## (world_seed, domain, coords, extra).
##
## A "domain" is a StringName naming what the randomness is FOR ("flora.oak", "ore.iron",
## "tests.dummy"). Different domains at the same coordinates yield statistically independent
## streams (X3 proves pairwise distinctness over 1000 domains), and adding a new domain can
## never perturb an existing one, because the domain name is hashed INTO the seed.
##
## LAYER: core. Uses Hash64 only. The returned object is Godot's RandomNumberGenerator,
## which is a deterministic PCG-based generator: same seed -> same sequence on every
## platform, which is exactly what save games and replays need.

## Set once at boot by the runtime/adapter from the explicit config seed. Never random,
## never time-derived. Tests set it directly.
static var default_seed: int = 0


static func set_default_seed(seed_value: int) -> void:
	default_seed = seed_value


## The fold itself, exposed so tests and debug dumps can inspect seeds without drawing.
static func seed_for(seed_value: int, domain: StringName, at: Vector3i, extra: int = 0) -> int:
	var h := Hash64.hash_int(seed_value)
	h = Hash64.hash_combine(h, Hash64.hash_string(String(domain)))
	h = Hash64.hash_vec3i(h, at)
	if extra != 0:
		h = Hash64.hash_combine(h, Hash64.hash_int(extra))
	return h


## Stream for a 2D purpose (features, flora cells) at block coords (x, z).
static func stream(domain: StringName, x: int, z: int, extra: int = 0) -> RandomNumberGenerator:
	return stream_at(default_seed, domain, Vector3i(x, 0, z), extra)


## Stream for a 3D purpose (ore blobs, cave jitter) at an explicit world seed.
static func stream_at(seed_value: int, domain: StringName, at: Vector3i, extra: int = 0) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_for(seed_value, domain, at, extra)
	return rng


## Stateless Bernoulli draw: true with exactly `probability`, from one hash, no RNG state.
## Use this for "does this column/cell have the feature at all"; use a stream when a site
## needs several correlated draws.
static func chance(domain: StringName, x: int, z: int, probability: float) -> bool:
	if probability <= 0.0:
		return false
	if probability >= 1.0:
		return true
	var h := seed_for(default_seed, domain, Vector3i(x, 0, z))
	# Top 31 bits -> uniform in [0, 1). Deterministic, platform-independent.
	var u := float((h >> 32) & 0x7FFFFFFF) / 2147483648.0
	return u < probability
