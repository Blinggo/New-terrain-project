class_name ModuleFixtures
extends RefCounted
## tests/fixtures/module_fixtures.gd
##
## M01-fix - THROWAWAY modules, written into user://modules/ by the tests and benchmarks and
## deleted again afterwards. They exist because several M01-fix acceptance criteria can only
## be proven by ADDING a module and watching what happens:
##
##   marker_pass    a TerrainPass (extent 0) that writes one distinctive id per column.
##                  Proves "adding an active module changes the DEFAULT backend's output with
##                  zero edits to any existing file" - the property the reviewer found missing
##                  (evidence E2: a module resolved and then wrote nothing).
##   no_op_pass     a TerrainPass that writes nothing. Proves the converse: goldens unchanged.
##   cliff_pass     a TerrainPass with extent 1 that reads NEIGHBOUR columns through the
##                  writer and converts a grass cap to stone where a neighbour rises by
##                  `threshold`. It derives its ids from the voxels it reads, so it names no
##                  content module - and it is what prices neighbour passes in B3.
##   stamp_probe    a FeatureStamp: proves the stamp contract is EXECUTED (candidates ->
##                  evaluate -> materialize), not just declared.
##   bare_module    a plain ModuleDefinition with no executable contract: the plan compiler
##                  must refuse it loudly instead of resolving it and doing nothing (E2).
##
## Nothing here is shipped content: content/modules/ keeps exactly the two M01 modules
## (D5b/B17 whitelist), and `clear()` removes every fixture file this helper wrote.
##
## LAYER: tests. May name adapters (it builds generators to check output).

const DIR := "user://modules"

const MARKER_ID := 200
const MARKER_ROW := 96

## kind -> {"script": String file name, "tres": String file name, "id": String}
const KINDS := {
	"marker_pass": {"script": "fixture_marker_pass.gd", "tres": "fixture_marker_pass.tres", "id": "tests.marker_pass"},
	"no_op_pass": {"script": "fixture_no_op_pass.gd", "tres": "fixture_no_op_pass.tres", "id": "tests.no_op_pass"},
	"cliff_pass": {"script": "fixture_cliff_pass.gd", "tres": "fixture_cliff_pass.tres", "id": "tests.cliff_pass"},
	"stamp_probe": {"script": "fixture_stamp_probe.gd", "tres": "fixture_stamp_probe.tres", "id": "tests.stamp_probe"},
	"bare_module": {"script": "fixture_bare_module.gd", "tres": "fixture_bare_module.tres", "id": "tests.bare_module"},
	"alien_phase_pass": {"script": "fixture_alien_phase_pass.gd", "tres": "fixture_alien_phase_pass.tres", "id": "tests.alien_phase_pass"},
	"silent_provider": {"script": "fixture_silent_provider.gd", "tres": "fixture_silent_provider.tres", "id": "tests.silent_provider"},
	"world_provider": {"script": "fixture_world_provider.gd", "tres": "fixture_world_provider.tres", "id": "tests.world_provider"},
}


static func install(kind: String) -> Dictionary:
	if not KINDS.has(kind):
		push_error("ModuleFixtures: unknown fixture kind '%s'" % kind)
		return {"ok": false}
	var meta: Dictionary = KINDS[kind]
	_ensure_dir()
	var script_path := "%s/%s" % [DIR, String(meta["script"])]
	var tres_path := "%s/%s" % [DIR, String(meta["tres"])]
	var body := _script_body(kind)
	var tres := _tres_body(kind, script_path)
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "cannot write %s" % script_path}
	f.store_string(body)
	f.close()
	var g := FileAccess.open(tres_path, FileAccess.WRITE)
	if g == null:
		return {"ok": false, "error": "cannot write %s" % tres_path}
	g.store_string(tres)
	g.close()
	return {"ok": true, "script": script_path, "tres": tres_path, "id": String(meta["id"])}


static func uninstall(kind: String) -> void:
	if not KINDS.has(kind):
		return
	var meta: Dictionary = KINDS[kind]
	for key in ["script", "tres"]:
		var p := "%s/%s" % [DIR, String(meta[key])]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		var uid := p + ".uid"
		if FileAccess.file_exists(uid):
			DirAccess.remove_absolute(uid)


static func clear() -> void:
	for kind in KINDS:
		uninstall(String(kind))


static func installed() -> Array:
	var out: Array = []
	for kind in KINDS:
		var meta: Dictionary = KINDS[String(kind)]
		if FileAccess.file_exists("%s/%s" % [DIR, String(meta["tres"])]):
			out.append(String(kind))
	return out


static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)


# --- the fixture module sources ------------------------------------------------------------

static func _script_body(kind: String) -> String:
	match kind:
		"marker_pass":
			return '''extends TerrainPass
## THROWAWAY test fixture (tests/fixtures/module_fixtures.gd). Writes one marker id per
## column so a test can prove the default backend executed a module that was added without
## editing any existing file.

@export var marker_id: int = %d
@export var marker_row: int = %d


func _init() -> void:
	id = &"tests.marker_pass"
	version = 1
	phase_order = 4
	phase_name = &"CARVE"
	priority = 900
	extent = 0
	requires = []
	provides = []
	channel_declarations = {}


func apply(ctx: GenContext) -> void:
	var b: Array = ctx.writer.bounds_main()
	var bmin: Vector3i = b[0]
	for lz in range(bmin.z, bmin.z + 4):
		for lx in range(bmin.x, bmin.x + 4):
			ctx.writer.set_type_world(Vector3i(lx, marker_row, lz), marker_id)
''' % [MARKER_ID, MARKER_ROW]
		"no_op_pass":
			return '''extends TerrainPass
## THROWAWAY test fixture: a resolved, enabled, executed module that deliberately writes
## nothing. Adding it must leave every golden hash unchanged.


func _init() -> void:
	id = &"tests.no_op_pass"
	version = 1
	phase_order = 4
	phase_name = &"CARVE"
	priority = 901
	extent = 0
	requires = []
	provides = []
	channel_declarations = {}


func apply(_ctx: GenContext) -> void:
	pass
'''
		"cliff_pass":
			return '''extends TerrainPass
## THROWAWAY test fixture: a neighbour-aware pass (extent 1).
##
## Detection uses the coarse REGION height field (that is what a region-scale field is FOR:
## a neighbour query without touching another column's voxels). The cap conversion then reads
## the neighbour column's own top voxel through the writer, so the pass exercises real
## cross-column reads inside the engine's editable area - and the writer counts them
## (neighbour_reads), which is the evidence that this is not a pass reading zeros.
##
## It names no content module and no block id: the ids come from the voxels already written.

@export var threshold: int = 4
@export var cap: int = 3


func _init() -> void:
	id = &"tests.cliff_pass"
	version = 1
	phase_order = 4
	phase_name = &"CARVE"
	priority = 902
	extent = 1
	requires = []
	provides = []
	channel_declarations = {}


func apply(ctx: GenContext) -> void:
	var w: IColumnWriter = ctx.writer
	var b: Array = w.bounds_main()
	var bmin: Vector3i = b[0]
	var bmax: Vector3i = b[1]
	var height: FieldTile = ctx.blackboard.try_read(&"field.height", null) as FieldTile
	for wz in range(bmin.z, bmax.z):
		for wx in range(bmin.x, bmax.x):
			var own := _surface_row(w, wx, wz, bmin.y, bmax.y)
			if own < bmin.y:
				continue
			var cliff := false
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dz == 0:
						continue
					var nx: int = wx + dx * 16
					var nz: int = wz + dz * 16
					var nh := own
					if height != null:
						nh = int(roundf(height.sample_nearest(float(nx), float(nz))))
					# One real cross-column read per neighbour: the neighbour's own surface id.
					if w.get_type_world(Vector3i(nx, nh, nz)) == 0 and height == null:
						continue
					if nh - own >= threshold:
						cliff = true
						break
				if cliff:
					break
			if not cliff:
				continue
			var surface_id := w.get_type_world(Vector3i(wx, own, wz))
			var deep_id := w.get_type_world(Vector3i(wx, maxi(own - cap, bmin.y), wz))
			if deep_id == surface_id or surface_id == 0:
				continue
			w.fill_span_world(wx, wz, maxi(own - cap + 1, bmin.y), own + 1, deep_id)


func _surface_row(w: IColumnWriter, wx: int, wz: int, y0: int, y1: int) -> int:
	# Bounded search: start from the top of the column but stop after the first solid voxel.
	for y in range(y1 - 1, y0 - 1, -1):
		if w.get_type_world(Vector3i(wx, y, wz)) != 0:
			return y
	return y0 - 1
'''
		"stamp_probe":
			return '''extends FeatureStamp
## THROWAWAY test fixture: proves the FeatureStamp contract is EXECUTED by the generic
## runner (candidates_near -> evaluate -> materialize) and writes through the writer.

@export var marker_id: int = %d
@export var row: int = %d


func _init() -> void:
	id = &"tests.stamp_probe"
	version = 1
	phase_order = 6
	phase_name = &"FEATURE"
	priority = 903
	material_id = marker_id
	density_threshold = 0.5
	radius = 1
	y_span = [0, 2]
	surface_channel = &""
	fallback_channel = &""
	requires = []
	provides = []
	channel_declarations = {}


func candidates_near(ctx: GenContext) -> Array:
	var out: Array = []
	var o := ctx.column_origin
	# One deterministic candidate per column, offset so it is inside the main area.
	out.append(Vector3i(o.x + 4, row, o.z + 4))
	return out


func evaluate(_ctx: GenContext, _pos: Vector3i) -> float:
	return 1.0


func materialize(ctx: GenContext, center: Vector3i, writer: IColumnWriter) -> void:
	writer.fill_box_world(
		Vector3i(center.x - radius, center.y, center.z - radius),
		Vector3i(center.x + radius + 1, center.y + 2, center.z + radius + 1),
		material_id)
''' % [MARKER_ID, MARKER_ROW]
		"alien_phase_pass":
			return '''extends TerrainPass
## THROWAWAY test fixture: a module in a phase NOBODY PLANNED. phase_order is a plain int and
## phase_name a plain StringName, so a modder can insert a stage between (or after) the shipped
## ones without editing src/spine/contracts/module_definition.gd - which is what M01's enum
## gate made impossible (X17).

@export var marker_id: int = 200
@export var marker_row: int = 95


func _init() -> void:
	id = &"tests.alien_phase_pass"
	version = 1
	phase_order = 77
	phase_name = &"MY_UNPLANNED_STAGE"
	priority = 905
	extent = 0
	requires = []
	provides = []
	channel_declarations = {}


func apply(ctx: GenContext) -> void:
	var b: Array = ctx.writer.bounds_main()
	var bmin: Vector3i = b[0]
	ctx.writer.set_type_world(Vector3i(bmin.x + 1, marker_row, bmin.z + 1), marker_id)
	ctx.writer.set_type_world(Vector3i(bmin.x + 2, marker_row, bmin.z + 2), marker_id)
'''
		"silent_provider":
			return '''extends FieldProvider
## THROWAWAY test fixture: declares a WORLD-scope channel and publishes NOTHING. The runner
## must execute it (a provider with no region channels still owes its world channels) and then
## say out loud that the declared channel never appeared - a module that resolves, runs and
## silently produces nothing is the defect class the M01 review measured as E2.

func _init() -> void:
	id = &"tests.silent_provider"
	version = 1
	phase_order = 0
	phase_name = &"PLANET"
	priority = 5
	provides = [&"field.silent"]
	channel_declarations = {&"field.silent": {"type": "FLOAT", "scope": "world", "version": 1}}


func compute_region(_ctx: GenContext) -> void:
	pass
'''
		"world_provider":
			return '''extends FieldProvider
## THROWAWAY test fixture: a provider whose ONLY channels are WORLD-scoped, publishing a real
## value. M01's executor skipped any FieldProvider with no region channels, so this module
## resolved, appeared in the pipeline dump and never ran (X1/X26).

func _init() -> void:
	id = &"tests.world_provider"
	version = 1
	phase_order = 0
	phase_name = &"PLANET"
	priority = 5
	provides = [&"field.world_only"]
	channel_declarations = {&"field.world_only": {"type": "FLOAT", "scope": "world", "version": 1}}


func compute_region(ctx: GenContext) -> void:
	ctx.publish(&"field.world_only", 42.0, id, GenBlackboard.Scope.WORLD)
'''
		"bare_module":
			return '''extends ModuleDefinition
## THROWAWAY test fixture: a module with NO executable contract. It resolves, it is enabled,
## and nothing can run it - the pass plan compiler must refuse the whole pipeline loudly
## instead of letting it become a module that silently does nothing (evidence E2).


func _init() -> void:
	id = &"tests.bare_module"
	version = 1
	phase_order = 9
	phase_name = &"DECORATE"
	priority = 904
	requires = []
	provides = []
	channel_declarations = {}
'''
	return ""


## The .tres property values are applied AFTER the script's _init(), so anything a fixture needs
## to keep must be written here too - a provides list set only in _init() would be reset to
## empty by the resource file and the fixture would silently test nothing.
static func _tres_body(kind: String, script_path: String) -> String:
	var meta: Dictionary = KINDS[kind]
	var module_id := String(meta["id"])
	var phase_order := 4
	var phase_name := "CARVE"
	var provides_line := "provides = Array[StringName]([])"
	var decls_line := "channel_declarations = {}"
	match kind:
		"silent_provider":
			phase_order = 0
			phase_name = "PLANET"
			provides_line = "provides = Array[StringName]([&\"field.silent\"])"
			decls_line = ("channel_declarations = {&\"field.silent\": "
				+ "{\"type\": \"FLOAT\", \"scope\": \"world\", \"version\": 1}}")
		"world_provider":
			phase_order = 0
			phase_name = "PLANET"
			provides_line = "provides = Array[StringName]([&\"field.world_only\"])"
			decls_line = ("channel_declarations = {&\"field.world_only\": "
				+ "{\"type\": \"FLOAT\", \"scope\": \"world\", \"version\": 1}}")
	match kind:
		"stamp_probe":
			phase_order = 6
			phase_name = "FEATURE"
		"bare_module":
			phase_order = 9
			phase_name = "DECORATE"
		"alien_phase_pass":
			phase_order = 77
			phase_name = "MY_UNPLANNED_STAGE"
	return '''[gd_resource type="Resource" load_steps=2 format=3]

[ext_resource type="Script" path="%s" id="1_fix"]

[resource]
script = ExtResource("1_fix")
id = &"%s"
version = 1
enabled = true
phase_order = %d
phase_name = &"%s"
priority = 900
requires = Array[StringName]([])
%s
%s
params = {}
quality_scaling = {}
noise_sampler = {}
''' % [script_path, module_id, phase_order, phase_name, provides_line, decls_line]
