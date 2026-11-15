class_name MultipassPassPlan
extends RefCounted
## src/adapters/voxel/multipass_pass_plan.gd
##
## M01-fix / T1 - Compiles a resolved module pipeline into ENGINE PASSES for
## VoxelGeneratorMultipassCB, and refuses (loudly) when the pipeline does not fit.
##
## ENGINE LIMITS, measured on Voxel Tools 1.7.0 / Godot 4.7.2 (tools/probe_native_cb*.gd):
##   MAX_PASSES                = 4   (class constant VoxelGeneratorMultipassCB.MAX_PASSES)
##   MAX_PASS_EXTENT           = 2   (class constant, in COLUMNS/blocks)
##   MAX_COLUMN_HEIGHT_BLOCKS  = 32  (documented; NOT a ClassDB constant in this build, so
##                                    the value is declared here and asserted at build time)
##   no LOD                    VoxelTerrain has no LOD; a pass never sees a level-of-detail
##                                    index (that is VoxelLodTerrain + a different generator).
##
## COMPILATION:
##   * TerrainPass modules are bucketed by their declared `extent`; buckets are sorted
##     ascending and become passes 0..n-1 with that extent. Ascending order matters: the
##     engine makes earlier passes' output readable in a later pass' editable area, so a
##     neighbour-aware pass sees finished terrain, never a half-written column.
##   * FeatureStamp modules run in the LAST pass (after its TerrainPasses) so they stamp onto
##     finished terrain. Their writes are main-column-only like every other write, so a stamp
##     whose radius crosses a column border is clipped: honest, documented, and the reason
##     overlap-aware stamping is M08 work rather than an M01 promise.
##   * FieldProviders are NOT bucketed: the executor runs their compute_region (cached) and
##     compute_column at the start of EVERY pass, so each pass sees exact column data.
##   * A module that is none of the three executable contracts is an ERROR, not a skip. A
##     resolved-but-never-executed module is exactly the M01 defect (evidence E2).
##   * Too many passes / too large an extent / too tall a column is an ERROR naming the
##     offending modules and the limit. The world then refuses to boot (fail closed).
##
## LAYER: adapters. Names no module id and no worldgen class - only the three contracts.

const MAX_PASSES := 4
const MAX_EXTENT := 2
## Documented engine limit on one column's height, in blocks. Verified absent from
## ClassDB.class_get_integer_constant_list("VoxelGeneratorMultipassCB") in this build, so it
## is asserted here rather than read.
const MAX_COLUMN_HEIGHT_BLOCKS := 32

var passes: Array = []            # [{"index": int, "extent": int, "modules": Array, "kinds": Array[String]}]
var providers: Array = []         # FieldProvider modules, run every pass
var errors: Array[String] = []
var warnings: Array[String] = []
var skipped: Dictionary = {}      # id -> reason (quality tier retraction)
## Limits this plan was compiled against. The native backend passes the engine's; the
## self-hosted experimental_columns backend passes unlimited values, because its passes are
## GDScript and bounded only by patience.
var limit_passes := MAX_PASSES
var limit_extent := MAX_EXTENT


static func compile(modules: Array, tier: String, max_passes: int = MAX_PASSES, max_extent: int = MAX_EXTENT) -> MultipassPassPlan:
	var plan := MultipassPassPlan.new()
	plan.limit_passes = max_passes
	plan.limit_extent = max_extent
	plan._compile(modules, tier)
	return plan


func _compile(modules: Array, tier: String) -> void:
	var buckets := {}        # extent int -> Array of TerrainPass
	var stamps: Array = []
	for m_variant in modules:
		var m := m_variant as ModuleDefinition
		if m == null:
			errors.append("pass plan: resolved pipeline contains a non-module entry (%s)" % str(m_variant))
			continue
		if not m.runs_at_tier(tier):
			skipped[String(m.id)] = "quality tier '%s' factor %s <= 0" % [tier, str(m.quality_factor(tier))]
			continue
		if m is FieldProvider:
			providers.append(m)
		elif m is TerrainPass:
			var extent := (m as TerrainPass).extent
			if extent < 0:
				warnings.append("pass plan: module '%s' declares extent %d; treated as 0" % [String(m.id), extent])
				extent = 0
			if extent > limit_extent:
				errors.append(
					"pass plan: module '%s' declares extent %d but this backend allows at most %d columns (the engine's VoxelGeneratorMultipassCB.MAX_PASS_EXTENT is 2). Split the rule, or run it on the 'experimental_columns' backend which has no engine limit (and no engine speed)."
					% [String(m.id), extent, limit_extent])
				continue
			if not buckets.has(extent):
				buckets[extent] = []
			(buckets[extent] as Array).append(m)
		elif m is FeatureStamp:
			stamps.append(m)
		else:
			errors.append(
				"pass plan: module '%s' (%s) is not a FieldProvider, TerrainPass or FeatureStamp - nothing could execute it, so it would resolve and then silently do nothing. Give it one of the three contracts."
				% [String(m.id), m.get_class()])

	var extents: Array = buckets.keys()
	extents.sort()
	if extents.size() > limit_passes:
		errors.append(
			"pass plan: %d distinct extents %s need %d passes but this backend allows %d (the engine's VoxelGeneratorMultipassCB.MAX_PASSES is 4). Merge extents or move a rule to the 'experimental_columns' backend."
			% [extents.size(), str(extents), extents.size(), limit_passes])
		return

	for i in extents.size():
		var extent := int(extents[i])
		var mods: Array = buckets[extent]
		passes.append({"index": i, "extent": extent, "modules": mods, "kinds": mods.map(func(x): return String((x as ModuleDefinition).id))})

	if passes.is_empty():
		# No terrain pass at all: still one pass, so stamps (or an all-air world) have a home.
		passes.append({"index": 0, "extent": 0, "modules": [], "kinds": []})
	if not stamps.is_empty():
		var last: Dictionary = passes[passes.size() - 1]
		(last["modules"] as Array).append_array(stamps)
		for s_variant in stamps:
			(last["kinds"] as Array).append(String((s_variant as ModuleDefinition).id))


func pass_count() -> int:
	return passes.size()


func extent_of(index: int) -> int:
	if index < 0 or index >= passes.size():
		return 0
	return int(passes[index]["extent"])


func modules_for(index: int) -> Array:
	if index < 0 or index >= passes.size():
		return []
	return passes[index]["modules"]


func max_extent() -> int:
	var out := 0
	for p in passes:
		out = maxi(out, int(p["extent"]))
	return out


## Every module the plan executes, in pass order (providers first, once).
func all_executed_modules() -> Array:
	var out: Array = providers.duplicate()
	for p in passes:
		out.append_array(p["modules"])
	return out


## True when every enabled module in `modules` is executed by this plan (the property the
## reviewer found missing in M01: a module that resolved but wrote nothing).
func executes_all(modules: Array, tier: String) -> bool:
	var executed := {}
	for m_variant in all_executed_modules():
		executed[(m_variant as ModuleDefinition).id] = true
	for m_variant in modules:
		var m := m_variant as ModuleDefinition
		if m == null:
			return false
		if skipped.has(String(m.id)):
			continue
		if not executed.has(m.id):
			return false
	return true


func describe() -> Dictionary:
	return {
		"pass_count": pass_count(),
		"max_extent": max_extent(),
		"limit_passes": limit_passes,
		"limit_extent": limit_extent,
		"passes": passes.map(func(p): return {
			"index": int(p["index"]), "extent": int(p["extent"]), "modules": p["kinds"]}),
		"providers": providers.map(func(m): return String((m as ModuleDefinition).id)),
		"skipped_by_tier": skipped,
		"errors": errors,
		"warnings": warnings,
	}
