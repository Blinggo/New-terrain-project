class_name ModuleDefinition
extends Resource
## src/spine/contracts/module_definition.gd
##
## M01 / Task 3 - Base contract for every worldgen module. A module is a .tres instance of a
## subclass of this script, discovered by ModuleRegistry scanning content/modules/** (and
## user://modules/** later). Nothing anywhere holds a hardcoded list of modules.
##
## Contracts name NO Voxel Tools types (hard rule #2 / X9 lint). Everything a module touches
## arrives through GenContext: the blackboard, the RNG stream factory, the plain-Dictionary
## world config, the quality tier, an abstract voxel writer, and the field cache.
##
## `requires` / `provides` are channel names ("domain.name"). The scheduler builds the whole
## pipeline from them; a missing producer is a boot error, never a silent zero.

## KNOWN phase conveniences ONLY. A module may use any integer order and any name without
## editing this file (C16): the scheduler sorts by phase_order, never by this enum.
enum Phase {
	PLANET, CLIMATE, GEOLOGY, SURFACE, CARVE, WATER, FEATURE, FLORA, STRUCTURE, DECORATE,
}
const PHASE_NAMES := [
	"PLANET", "CLIMATE", "GEOLOGY", "SURFACE", "CARVE", "WATER", "FEATURE", "FLORA", "STRUCTURE", "DECORATE",
]

@export var id: StringName = &""
@export var version: int = 1
@export var enabled: bool = true
## Execution band. Numeric: the scheduler groups and orders by this value alone.
@export var phase_order: int = 0
@export var phase_name: StringName = &"PLANET"
## Tiebreak ONLY. Dependencies decide order; priority never overrides a dependency.
@export var priority: int = 100
@export var requires: Array[StringName] = []
@export var provides: Array[StringName] = []
## Channel metadata: channel -> {"type": "TILE_FLOAT", "scope": "region", "version": 1}.
## Declarations are validated at load (ChannelId) and enforced by the blackboard on
## publish/read. Unknown channel NAMES stay legal; undeclared channels are an error for
## anything listed in requires/provides.
@export var channel_declarations: Dictionary = {}
## Free-form parameters (noise frequency, depths, ids...). The graph backend pushes these
## into named graph nodes; GDScript backends read them directly. Overridable per world via
## content/world_config.json "modules" block.
@export var params: Dictionary = {}
## Cost multipliers per quality tier, e.g. {"low": 0.5, "medium": 1.0, "high": 2.0}.
## WIRED (M01-fix / T9): the executor SKIPS a module whose factor for the active tier is
## <= 0.0 and reports the skip; any other value is advisory and reported per module.
@export var quality_scaling: Dictionary = {}
## Optional recipe for the injected `ctx.noise_2d` sampler, e.g.
## {"type": "open_simplex_2", "fractal": "fbm", "octaves": 5, "lacunarity": 2.0,
##  "gain": 0.5, "frequency": 0.0035}. Backends that host a native noise implementation
## read the FIRST non-empty recipe in resolved order - so no adapter ever needs to know a
## module id or class to configure its sampler (M01-fix / T2: no content ids in adapters).
## Keys are plain strings; values are numbers/strings. An unknown "type" is a loud error.
@export var noise_sampler: Dictionary = {}


## Convenience: set phase_order/phase_name from the known enum. Modules with an unplanned
## stage set the two exported fields directly instead.
func use_known_phase(p: int) -> void:
	phase_order = p
	phase_name = StringName(PHASE_NAMES[clampi(p, 0, PHASE_NAMES.size() - 1)])


func phase_label() -> String:
	return String(phase_name)


## Deterministic fingerprint of every exported knob + `params` + `channel_declarations`.
## Cache keys and build reports use it (T5): two runs with the same numbers collide, a
## single changed parameter does not. Exported properties are read by name so a subclass
## adding a knob needs no change here.
func params_fingerprint() -> int:
	var snapshot := {}
	for prop in get_property_list():
		var pname := String(prop["name"])
		if pname.begins_with("_") or pname in ["id", "enabled", "script", "resource_local_to_scene", "resource_name"]:
			continue
		if not (int(prop["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		snapshot[pname] = get(pname)
	return Hash64.hash_variant(snapshot)


## The recipe adapters use to configure the injected `ctx.noise_2d`. Override this to derive
## the recipe from the module's own knobs (a subclass's exports are applied AFTER _init(), so
## building the Dictionary in _init() would capture defaults, not the .tres values).
func noise_sampler_recipe() -> Dictionary:
	return noise_sampler


## True when this module should run at all in `tier` (T9: a non-positive factor retracts it).
func runs_at_tier(tier: String) -> bool:
	return quality_factor(tier) > 0.0


func param(name: String, default: Variant) -> Variant:
	return params.get(name, default)


func param_f(name: String, default: float) -> float:
	return float(params.get(name, default))


func param_i(name: String, default: int) -> int:
	return int(params.get(name, default))


## Quality multiplier for a tier, defaulting to 1.0 when the module does not declare one.
func quality_factor(tier: String) -> float:
	return float(quality_scaling.get(tier, 1.0))


func describe() -> String:
	return "%s v%d [%s/%d] prio=%d requires=%s provides=%s enabled=%s" % [
		String(id), version, String(phase_name), phase_order, priority,
		str(requires), str(provides), str(enabled)]
