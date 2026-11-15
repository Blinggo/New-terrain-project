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

enum Phase {
	PLANET, CLIMATE, GEOLOGY, SURFACE, CARVE, WATER, FEATURE, FLORA, STRUCTURE, DECORATE,
}
const PHASE_NAMES := [
	"PLANET", "CLIMATE", "GEOLOGY", "SURFACE", "CARVE", "WATER", "FEATURE", "FLORA", "STRUCTURE", "DECORATE",
]

@export var id: StringName = &""
@export var version: int = 1
@export var enabled: bool = true
@export var phase: int = Phase.PLANET
## Tiebreak ONLY. Dependencies decide order; priority never overrides a dependency.
@export var priority: int = 100
@export var requires: Array[StringName] = []
@export var provides: Array[StringName] = []
## Free-form parameters (noise frequency, depths, ids...). The graph backend pushes these
## into named graph nodes; GDScript backends read them directly. Overridable per world via
## content/world_config.json "modules" block.
@export var params: Dictionary = {}
## Cost multipliers per quality tier, e.g. {"low": 0.5, "medium": 1.0, "high": 2.0}.
## Advisory in M01; the scheduler reports it so tiers can thin modules later.
@export var quality_scaling: Dictionary = {}


func phase_name() -> String:
	return PHASE_NAMES[clampi(phase, 0, PHASE_NAMES.size() - 1)]


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
	return "%s v%d [%s] prio=%d requires=%s provides=%s enabled=%s" % [
		String(id), version, phase_name(), priority, str(requires), str(provides), str(enabled)]
