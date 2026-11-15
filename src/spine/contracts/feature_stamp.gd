class_name FeatureStamp
extends ModuleDefinition
## src/spine/contracts/feature_stamp.gd
##
## M01 / Task 3 - Contract for point features (trees M08, structures M10, boulders...).
## Declared now so those milestones add content without touching the spine: placement is a
## deterministic 3x3 CELL lookup (a feature near a chunk boundary is found from either
## side), and density is an ANALYTIC function of position, so the graph backend can compile
## extent-0 stamps and the multipass backend can run them identically.
##
## No implementations exist in M01 (hard rule #4: no trees/structures yet). The contract is
## exercised only by the extensibility tests.

## Cell edge in blocks. Candidates are looked up in the 3x3 cells around a query point.
@export var cell_size: int = 64


## Deterministic candidate sites in the 3x3 cells around ctx.column_origin.
## Must depend only on (seed, cell coords, params) - typically RngStreams.chance per cell.
func candidates_near(_ctx: GenContext) -> Array:
	push_error("FeatureStamp '%s' does not override candidates_near()" % String(id))
	return []


## Analytic density contribution at a world position (0 = none). Pure maths, no state.
func evaluate(_ctx: GenContext, _pos: Vector3) -> float:
	push_error("FeatureStamp '%s' does not override evaluate()" % String(id))
	return 0.0
