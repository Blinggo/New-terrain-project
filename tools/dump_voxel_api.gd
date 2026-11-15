extends SceneTree
## tools/dump_voxel_api.gd
##
## M00 / T2 - Dump the REAL Voxel Tools API surface from ClassDB before writing any
## terrain code. Hard rule #2: never guess a class, method, property or enum name.
##
## Run:
##   godot --headless --path <project> --script res://tools/dump_voxel_api.gd
##
## Writes: res://docs/reports/voxel_api_dump.json
##
## This script is deliberately defensive: it uses only ClassDB methods whose existence
## was verified on Godot 4.7.2 (class_exists, class_get_api_type, can_instantiate,
## is_class_enabled, get_parent_class, class_get_method_list, class_get_property_list,
## class_get_signal_list, class_get_enum_list, class_get_enum_constants,
## class_get_integer_constant_list, get_class_list).

const OUT_PATH := "res://docs/reports/voxel_api_dump.json"

## Classes explicitly requested by milestone M00 / task T2.
const REQUESTED_CLASSES: Array[String] = [
	"VoxelEngine",
	"VoxelTerrain",
	"VoxelLodTerrain",
	"VoxelViewer",
	"VoxelMesherBlocky",
	"VoxelBlockyLibrary",
	"VoxelBlockyLibraryManager",
	"VoxelBlockyTypeLibrary",
	"VoxelBlockyModel",
	"VoxelBlockyModelCube",
	"VoxelBuffer",
	"VoxelTool",
	"VoxelGenerator",
	"VoxelGeneratorNoise2D",
	"VoxelGeneratorGraph",
	"VoxelGraphFunction",
	"VoxelGeneratorScript",
	"VoxelGeneratorMultipassCB",
	"VoxelToolMultipassGenerator",
	"VoxelInstancer",
	"VoxelInstanceLibrary",
	"VoxelStreamSQLite",
]

## Support classes discovered while reading the dump above. M00 code depends on these
## too (VoxelMesherBlocky.library is typed VoxelBlockyLibraryBase, so the base class
## and the two sibling library classes must all be inspected before choosing one).
const EXTRA_CLASSES: Array[String] = [
	"VoxelBlockyLibraryBase",
	"VoxelBlockyType",
	"VoxelNode",
	"VoxelMesher",
	"VoxelStream",
	"VoxelToolBlocky",
	"VoxelToolBuffer",
	"VoxelBufferInternal",
	"VoxelGraphRuntime",
	"VoxelInstanceTransformer",
	"VoxelToolTerrain",
	"VoxelFormat",
	"ZN_FastNoiseLite",
	"ZN_SpotNoise",
	"VoxelGeneratorHeightmap",
	"VoxelGeneratorFlat",
	"VoxelBlockyModelEmpty",
	"VoxelBlockyModelFluid",
	"VoxelBlockyModelMesh",
]

## Prefixes used to discover every class the extension registers, so we cannot miss a
## rename (e.g. VoxelBlockyLibrary vs VoxelBlockyTypeLibrary).
const EXTENSION_PREFIXES: Array[String] = ["Voxel", "FastNoise2", "ZN_"]


func _init() -> void:
	var report := {
		"generated_by": "res://tools/dump_voxel_api.gd",
		"godot": {
			"version_info": Engine.get_version_info(),
			"version_string": String(Engine.get_version_info().get("string", "?")),
			"build": String(Engine.get_version_info().get("build", "?")),
			"hash": String(Engine.get_version_info().get("hash", "?")),
		},
		"os": {
			"name": OS.get_name(),
			"has_feature_headless": OS.has_feature("headless"),
		},
		"extension": _extension_info(),
		"all_extension_classes": _all_extension_classes(),
		"requested_classes": _dump_requested(),
		"support_classes": _dump_support(),
	}

	var json := JSON.stringify(report, "\t")
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("dump_voxel_api: cannot open %s (err %d)" % [OUT_PATH, FileAccess.get_open_error()])
		quit(1)
		return
	f.store_string(json)
	f.close()

	print("dump_voxel_api: wrote %s (%d bytes)" % [OUT_PATH, json.length()])
	_print_summary(report)
	quit(0)


func _extension_info() -> Dictionary:
	## Voxel Tools version. Do NOT assume `VoxelEngine.get_version()` exists - check.
	var info := {
		"voxel_engine_class_exists": ClassDB.class_exists("VoxelEngine"),
		"version_methods_found": [],
		"version_result": null,
		"gdextension_file": "res://addons/zylann.voxel/voxel.gdextension",
		"gdextension_present": FileAccess.file_exists("res://addons/zylann.voxel/voxel.gdextension"),
		"binaries_present": _list_binaries(),
	}
	if not info["voxel_engine_class_exists"]:
		return info

	var candidates := []
	for m in ClassDB.class_get_method_list("VoxelEngine", true):
		var n := String(m["name"])
		if "version" in n.to_lower():
			candidates.append(n)
	info["version_methods_found"] = candidates

	# These version methods are NOT static in 1.7 (class_call_static fails with
	# "Method is not static"), so read them from a temporary instance instead.
	var result := {}
	var ve: Object = ClassDB.instantiate("VoxelEngine")
	if ve == null:
		info["version_result"] = null
		info["version_note"] = "VoxelEngine could not be instantiated"
		info["get_stats_keys"] = []
		return info

	for name in candidates:
		result[name] = _jsonable(ve.call(name))
	info["version_result"] = result
	info["version_note"] = "non-static methods, read from a temporary VoxelEngine instance"

	# Engine-wide voxel stats (used by the HUD; keys are recorded in the report).
	var stats = ve.call("get_stats")
	info["get_stats_keys"] = _stats_keys(stats)
	info["get_stats_sample"] = _jsonable(stats)

	# Single instance, freed once - no use-after-free.
	ve.free()
	return info


func _stats_keys(stats) -> Array:
	var out := []
	if stats is Dictionary:
		for k in stats:
			out.append(String(k))
	out.sort()
	return out


func _list_binaries() -> Array:
	var out := []
	var dir := DirAccess.open("res://addons/zylann.voxel/bin")
	if dir == null:
		return out
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir():
			out.append({"name": fn, "bytes": FileAccess.get_file_as_bytes("res://addons/zylann.voxel/bin/" + fn).size()})
		fn = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	return out


func _all_extension_classes() -> Array:
	var out := []
	for cls in ClassDB.get_class_list():
		var s := String(cls)
		for p in EXTENSION_PREFIXES:
			if s.begins_with(p):
				out.append({
					"name": s,
					"parent": ClassDB.get_parent_class(s),
					"api_type": ClassDB.class_get_api_type(s),
				})
				break
	out.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	return out


func _dump_requested() -> Dictionary:
	var out := {}
	for cls in REQUESTED_CLASSES:
		out[cls] = _dump_class(cls)
	return out


func _dump_support() -> Dictionary:
	var out := {}
	for cls in EXTRA_CLASSES:
		out[cls] = _dump_class(cls)
	return out


func _dump_class(cls: String) -> Dictionary:
	var d := {"requested": cls, "exists": ClassDB.class_exists(cls)}
	if not d["exists"]:
		d["note"] = "NOT REGISTERED IN THIS BUILD"
		return d

	d["parent"] = ClassDB.get_parent_class(cls)
	d["api_type"] = ClassDB.class_get_api_type(cls)
	d["can_instantiate"] = ClassDB.can_instantiate(cls)
	d["is_enabled"] = ClassDB.is_class_enabled(cls)
	d["inheritance_chain"] = _chain(cls)

	var methods := []
	for m in ClassDB.class_get_method_list(cls, true):
		methods.append({
			"name": String(m.get("name", "")),
			"return": _jsonable(m.get("return", {})),
			"args": _jsonable(m.get("args", [])),
			"default_args": _jsonable(m.get("default_args", [])),
			"flags": int(m.get("flags", 0)),
		})
	methods.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	d["methods"] = methods
	d["method_names"] = methods.map(func(m): return m["name"])

	var props := []
	for p in ClassDB.class_get_property_list(cls, true):
		props.append({
			"name": String(p.get("name", "")),
			"type": int(p.get("type", -1)),
			"class_name": String(p.get("class_name", "")),
			"hint": int(p.get("hint", 0)),
			"hint_string": String(p.get("hint_string", "")),
			"usage": int(p.get("usage", 0)),
		})
	props.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	d["properties"] = props
	d["property_names"] = props.map(func(p): return p["name"])

	var signals := []
	for s in ClassDB.class_get_signal_list(cls, true):
		signals.append({"name": String(s.get("name", "")), "args": _jsonable(s.get("args", []))})
	signals.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	d["signals"] = signals
	d["signal_names"] = signals.map(func(s): return s["name"])

	var enums := {}
	for e in ClassDB.class_get_enum_list(cls, true):
		var en := String(e)
		var consts := {}
		for c in ClassDB.class_get_enum_constants(cls, en):
			consts[String(c)] = ClassDB.class_get_integer_constant(cls, String(c))
		enums[en] = consts
	d["enums"] = enums

	var integer_constants := {}
	for c in ClassDB.class_get_integer_constant_list(cls, true):
		var cn := String(c)
		integer_constants[cn] = ClassDB.class_get_integer_constant(cls, cn)
	d["integer_constants"] = integer_constants

	return d


func _chain(cls: String) -> Array:
	var out := []
	var cur := cls
	var guard := 0
	while cur != "" and guard < 32:
		out.append(cur)
		cur = ClassDB.get_parent_class(cur)
		guard += 1
	return out


## JSON.stringify cannot serialise every Variant cleanly (e.g. typed arrays of
## dictionaries). Flatten everything to plain Array/Dictionary/String/int/bool.
func _jsonable(v) -> Variant:
	if v is Array:
		var out := []
		for e in v:
			out.append(_jsonable(e))
		return out
	if v is Dictionary:
		var outd := {}
		for k in v:
			outd[String(k)] = _jsonable(v[k])
		return outd
	if v is StringName:
		return String(v)
	if v is NodePath:
		return String(v)
	return v


func _print_summary(report: Dictionary) -> void:
	print("")
	print("=== CLASS EXISTENCE ===")
	var ext: Dictionary = report["extension"]
	print("VoxelEngine registered: ", ext["voxel_engine_class_exists"])
	print("version methods found:  ", ext["version_methods_found"])
	print("version result:         ", ext["version_result"])
	print("VoxelEngine.get_stats keys: ", ext["get_stats_keys"])
	var present := []
	var missing := []
	for cls in REQUESTED_CLASSES:
		if (report["requested_classes"] as Dictionary)[cls]["exists"]:
			present.append(cls)
		else:
			missing.append(cls)
	print("")
	print("PRESENT (%d): %s" % [present.size(), ", ".join(present)])
	print("")
	print("MISSING (%d): %s" % [missing.size(), ", ".join(missing) if not missing.is_empty() else "(none)"])
	print("")
	var sp := []
	var sm := []
	for cls in EXTRA_CLASSES:
		if (report["support_classes"] as Dictionary)[cls]["exists"]:
			sp.append(cls)
		else:
			sm.append(cls)
	print("SUPPORT PRESENT (%d): %s" % [sp.size(), ", ".join(sp)])
	print("SUPPORT MISSING (%d): %s" % [sm.size(), ", ".join(sm) if not sm.is_empty() else "(none)"])
	print("")
	print("All extension-registered classes: %d" % (report["all_extension_classes"] as Array).size())
