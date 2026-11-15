class_name GenContext
extends RefCounted
## src/spine/contracts/gen_context.gd
##
## M01 / Task 3 - Everything a module is allowed to touch, in one object:
##   * blackboard   publish/read named typed channels
##   * rng          deterministic streams (RngStreams bound to the explicit world seed)
##   * config       the plain-Dictionary world config (runtime classes never cross down)
##   * quality_tier the active tier, for cost-aware modules
##   * writer       the abstract voxel sink (adapter-implemented)
##   * cache        REGION tile cache
##   * noise_2d     an injected Callable(x, z) -> float sampler. The adapter injects the ONE
##                  noise implementation the compiled backends use, so GDScript passes and
##                  graph nodes evaluate identical maths without spine naming any engine
##                  noise class (layering).
##   * profiler     an injected Callable() -> int usec. The spine never reads a clock itself
##                  (hard rule #3); timing comes from whoever owns the run.
##
## Region/column origins are set by the executor around each call.

var blackboard: GenBlackboard = null
var cache: FieldCache = null
var config: Dictionary = {}
var quality_tier: String = "low"
var world_seed: int = 0
var region_origin := Vector2i(0, 0)
var column_origin := Vector3i(0, 0, 0)
var writer: IColumnWriter = null
var noise_2d: Callable = Callable()
var profiler: Callable = Callable()
## id -> accumulated microseconds, filled by the executor; the HUD pipeline page reads it.
var timings: Dictionary = {}
## id -> times executed this context (proof every resolved module actually ran; the M01
## defect was a module that resolved but was never executed - evidence E2).
var executed_counts: Dictionary = {}
## id -> human reason it did NOT run (quality tier retraction, ...). Reported, never silent.
var skipped: Dictionary = {}
## id -> number of feature stamps materialized.
var stamp_placements: Dictionary = {}
## Runner/backend errors that are not blackboard errors (e.g. a module with no executable
## contract). Surfaced in the build report so a broken pipeline cannot boot quietly.
var errors: Array[String] = []


## Zero the per-run counters after they have been absorbed into an aggregate, so a reused
## per-worker context cannot double count.
func reset_counters() -> void:
	timings.clear()
	executed_counts.clear()
	skipped.clear()
	stamp_placements.clear()
	errors.clear()


## Merge another context's counters into this one (per-worker contexts are aggregated by the
## generator under its own lock; the spine never shares a context between threads).
func absorb(other: GenContext) -> void:
	for k in other.timings:
		timings[String(k)] = float(timings.get(String(k), 0.0)) + float(other.timings[k])
	for k in other.executed_counts:
		executed_counts[String(k)] = int(executed_counts.get(String(k), 0)) + int(other.executed_counts[k])
	for k in other.stamp_placements:
		stamp_placements[String(k)] = int(stamp_placements.get(String(k), 0)) + int(other.stamp_placements[k])
	for k in other.skipped:
		skipped[String(k)] = String(other.skipped[k])
	for e in other.errors:
		if not errors.has(e):
			errors.append(e)


func stream(domain: StringName, extra: int = 0) -> RandomNumberGenerator:
	return RngStreams.stream_at(world_seed, domain, column_origin, extra)


func chance(domain: StringName, x: int, z: int, probability: float) -> bool:
	var h := RngStreams.seed_for(world_seed, domain, Vector3i(x, 0, z))
	if probability <= 0.0:
		return false
	if probability >= 1.0:
		return true
	var u := float((h >> 32) & 0x7FFFFFFF) / 2147483648.0
	return u < probability


func publish(channel: StringName, value: Variant, producer_id: StringName, scope: int = -1) -> bool:
	return blackboard.publish(channel, value, producer_id, scope)


func read(channel: StringName) -> Variant:
	return blackboard.read(channel)


func try_read(channel: StringName, default: Variant) -> Variant:
	return blackboard.try_read(channel, default)


## Height (or any float field) sampled at an exact world column, preferring the cached tile
## and falling back to the injected analytic sampler. Modules use this instead of keeping
## their own copy of a field, which is how a consumer stays decoupled from its producer.
func field_at(channel: StringName, wx: int, wz: int) -> float:
	var tile: FieldTile = blackboard.try_read(channel, null) as FieldTile
	if tile != null:
		return tile.sample_nearest(float(wx), float(wz))
	if noise_2d.is_valid():
		return float(noise_2d.call(wx, wz))
	return 0.0


func tick_usec() -> int:
	if profiler.is_valid():
		return int(profiler.call())
	return 0


func cfg(name: String, default: Variant) -> Variant:
	return config.get(name, default)
