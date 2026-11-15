extends RefCounted
## tests/smoke/test_extension.gd
##
## S2 - The Voxel Tools extension really loaded, and the API is what our dump says it is.
## Hard rule #9: if the extension fails to load we STOP and report. These checks are what
## makes that observable instead of mysterious.

const SUITE := "smoke"

## The 22 classes T2 asks about. 21 exist in 1.7; VoxelBlockyLibraryManager does not.
const EXPECTED_PRESENT: Array[String] = [
	"VoxelEngine", "VoxelTerrain", "VoxelLodTerrain", "VoxelViewer", "VoxelMesherBlocky",
	"VoxelBlockyLibrary", "VoxelBlockyTypeLibrary", "VoxelBlockyModel", "VoxelBlockyModelCube",
	"VoxelBuffer", "VoxelTool", "VoxelGenerator", "VoxelGeneratorNoise2D", "VoxelGeneratorGraph",
	"VoxelGraphFunction", "VoxelGeneratorScript", "VoxelGeneratorMultipassCB",
	"VoxelToolMultipassGenerator", "VoxelInstancer", "VoxelInstanceLibrary", "VoxelStreamSQLite",
]
const EXPECTED_ABSENT: Array[String] = ["VoxelBlockyLibraryManager"]

const DUMP_PATH := "res://docs/reports/voxel_api_dump.json"
const GRAPH_DUMP_PATH := "res://docs/reports/voxel_graph_nodes.json"
const MANIFEST_PATH := "res://docs/reports/addon_manifest.json"


func run(_ctx: Dictionary) -> Array:
	var out: Array = []

	# S2a - the extension is registered at all.
	var loaded := ClassDB.class_exists("VoxelEngine") and ClassDB.class_exists("VoxelTerrain")
	out.append(TestHarness.result(SUITE, "S2a", "PASS" if loaded else "FAIL",
		"Voxel Tools GDExtension is loaded (VoxelEngine + VoxelTerrain registered)",
		"VoxelEngine=%s VoxelTerrain=%s parent=%s" % [
			str(ClassDB.class_exists("VoxelEngine")), str(ClassDB.class_exists("VoxelTerrain")),
			ClassDB.get_parent_class("VoxelTerrain") if loaded else "n/a"]))
	if not loaded:
		out.append(TestHarness.fail(SUITE, "S2b", "STOP: extension did not load - hard rule #9 applies",
			"Godot %s, addons present=%s" % [Engine.get_version_info().get("string"),
				str(FileAccess.file_exists("res://addons/zylann.voxel/voxel.gdextension"))]))
		return out

	# S2b - version, read from the real (non-static) VoxelEngine methods.
	var ve: Object = ClassDB.instantiate("VoxelEngine")
	var version := "%s.%s.%s" % [ve.call("get_version_major"), ve.call("get_version_minor"), ve.call("get_version_patch")]
	var edition := String(ve.call("get_version_edition"))
	var git_hash := String(ve.call("get_version_git_hash"))
	ve.free()
	var version_ok := version == "1.7.0" and edition == "GDExtension"
	out.append(TestHarness.result(SUITE, "S2b", "PASS" if version_ok else "FAIL",
		"Voxel Tools version is 1.7.0 GDExtension", "version=%s edition=%s git=%s" % [version, edition, git_hash]))

	# S2c - class existence matches the recorded reality.
	var missing: Array[String] = []
	for c in EXPECTED_PRESENT:
		if not ClassDB.class_exists(c):
			missing.append(c)
	var unexpected: Array[String] = []
	for c in EXPECTED_ABSENT:
		if ClassDB.class_exists(c):
			unexpected.append(c)
	out.append(TestHarness.result(SUITE, "S2c", "PASS" if missing.is_empty() and unexpected.is_empty() else "FAIL",
		"%d/%d expected classes exist; %s confirmed absent" % [
			EXPECTED_PRESENT.size() - missing.size(), EXPECTED_PRESENT.size(), str(EXPECTED_ABSENT)],
		"missing=%s unexpectedly_present=%s" % [str(missing), str(unexpected)]))

	# S2d - .gdextension compatibility against this engine.
	var gdx := ConfigFile.new()
	var err := gdx.load("res://addons/zylann.voxel/voxel.gdextension")
	var compat: Variant = gdx.get_value("configuration", "compatibility_minimum", "?") if err == OK else "?"
	var engine_hex := int(Engine.get_version_info().get("hex", 0))
	out.append(TestHarness.result(SUITE, "S2d", "PASS" if err == OK else "FAIL",
		"voxel.gdextension parses; compatibility_minimum=%s vs engine %s" % [compat, Engine.get_version_info().get("string")],
		"engine hex=%d entry_symbol=%s" % [engine_hex, gdx.get_value("configuration", "entry_symbol", "?") if err == OK else "?"]))

	# S2e - only the Linux binaries are installed (project instruction), and they are there.
	var bin_dir := DirAccess.open("res://addons/zylann.voxel/bin")
	var bins: Array[String] = []
	if bin_dir != null:
		bin_dir.list_dir_begin()
		var n := bin_dir.get_next()
		while n != "":
			if not bin_dir.current_is_dir():
				bins.append(n)
			n = bin_dir.get_next()
		bin_dir.list_dir_end()
	var linux_bins := bins.filter(func(b): return b.contains("linux"))
	var other_bins := bins.filter(func(b): return not b.contains("linux"))
	out.append(TestHarness.result(SUITE, "S2e", "PASS" if linux_bins.size() >= 2 else "FAIL",
		"Linux editor+template binaries installed (%d); non-Linux binaries intentionally not installed (%d)" % [linux_bins.size(), other_bins.size()],
		"linux=%s\nother=%s" % [str(linux_bins), str(other_bins)]))

	# S2f - API dump artifacts exist and are structurally sound.
	out.append(_dump_check("S2f", DUMP_PATH, ["godot", "extension", "all_extension_classes", "requested_classes", "support_classes"]))
	out.append(_dump_check("S2g", GRAPH_DUMP_PATH, ["node_type_count", "node_types", "outputs_available"]))

	# S2h - the OutputType node is reachable by name even though the NodeTypeID enum omits it.
	var gd := JsonData.load_file(GRAPH_DUMP_PATH)
	var outputs: Array = gd.get("outputs_available", [])
	var has_output_type := false
	for o in outputs:
		if String(o.get("name", "")) == "OutputType":
			has_output_type = true
	out.append(TestHarness.result(SUITE, "S2h", "PASS" if has_output_type else "FAIL",
		"graph OutputType node is present (id 44) despite being absent from NodeTypeID",
		"output nodes=%s" % str(outputs)))

	# S2i - addons/zylann.voxel is byte-identical to the recorded manifest (hard rule #3,
	# acceptance A13). The manifest was written straight after extraction from the official
	# v1.7x archive; see tools/make_addon_manifest.gd.
	out.append(_manifest_check())

	return out


func _dump_check(id: String, path: String, required_keys: Array) -> Dictionary:
	if not FileAccess.file_exists(path):
		return TestHarness.fail(SUITE, id, "dump artifact missing: %s" % path,
			"regenerate with tools/dump_voxel_api.gd / tools/dump_graph_nodes.gd")
	var data := JsonData.load_file(path)
	var missing: Array[String] = []
	for k in required_keys:
		if not data.has(k):
			missing.append(String(k))
	var size := FileAccess.get_file_as_bytes(path).size()
	return TestHarness.result(SUITE, id, "PASS" if missing.is_empty() else "FAIL",
		"%s present (%d bytes) with all required sections" % [path.get_file(), size],
		"missing keys=%s" % str(missing))


func _manifest_check() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return TestHarness.blocked(SUITE, "S2i",
			"no addon manifest recorded yet", "run tools/make_addon_manifest.gd to create the A13 baseline")
	var manifest := JsonData.load_file(MANIFEST_PATH)
	var expected: Dictionary = manifest.get("files", {})
	var bad: Array[String] = []
	var checked := 0
	for rel_path in expected:
		var full := "res://addons/zylann.voxel/" + String(rel_path)
		checked += 1
		if not FileAccess.file_exists(full):
			bad.append("%s MISSING" % rel_path)
			continue
		var actual := FileAccess.get_sha256(full)
		if String(actual) != String(expected[rel_path]):
			bad.append("%s sha256 %s != %s" % [rel_path, actual, expected[rel_path]])
	return TestHarness.result(SUITE, "S2i", "PASS" if bad.is_empty() else "FAIL",
		"addons/zylann.voxel/ is unmodified: %d/%d files match the recorded sha256 manifest" % [checked - bad.size(), checked],
		"\n".join(bad) if not bad.is_empty() else "manifest source: %s\narchive sha256: %s" % [
			manifest.get("source_url", "?"), manifest.get("archive_sha256", "?")])
