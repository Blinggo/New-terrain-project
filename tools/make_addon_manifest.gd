extends SceneTree
## tools/make_addon_manifest.gd
##
## M00 / A13 - Record the sha256 of every file under addons/zylann.voxel/ so that
## tests/smoke/test_extension.gd can prove the vendored extension was never modified.
##
## Run this ONCE, immediately after extracting the official archive, and commit the result.
## Re-running it later would silently bless a modification, so it prints a warning and
## refuses to run unless --force is passed when a manifest already exists.
##
##   godot --headless --path <project> --script res://tools/make_addon_manifest.gd

const OUT := "res://docs/reports/addon_manifest.json"
const ADDON_DIR := "res://addons/zylann.voxel"
const SOURCE_URL := "https://github.com/Zylann/godot_voxel/releases/download/v1.7x/GodotVoxelExtension.zip"
const ARCHIVE_SHA256 := "600737572a5e25541ba6f503e842a3717ba19afafa5474510a6ceff995a1d2d8"


func _init() -> void:
	if FileAccess.file_exists(OUT) and not ("--force" in OS.get_cmdline_user_args()):
		print("manifest already exists: %s" % OUT)
		print("Re-running would bless any modification made since. Pass -- --force if you really")
		print("mean to re-baseline (and say so in the M00 report).")
		quit(0)
		return

	var files := {}
	var total_bytes := 0
	for rel_v in _list(ADDON_DIR):
		var rel := String(rel_v)
		var full := ADDON_DIR + "/" + rel
		files[rel] = FileAccess.get_sha256(full)
		total_bytes += FileAccess.get_file_as_bytes(full).size()

	var manifest := {
		"_comment": [
			"sha256 baseline for the vendored Voxel Tools extension (hard rule #3: never modify",
			"anything under addons/zylann.voxel/). tests/smoke/test_extension.gd S2i verifies it.",
			"Only the Linux binaries are installed in this checkout, per project instruction;",
			"the archive listing below records which platform binaries the release contains so",
			"the Android arm64 .so can still be accounted for without shipping 100 MB of them.",
		],
		"source_url": SOURCE_URL,
		"archive_sha256": ARCHIVE_SHA256,
		"recorded_at_godot": Engine.get_version_info().get("string"),
		"file_count": files.size(),
		"total_bytes": total_bytes,
		"installed_platforms": ["linux.editor.x86_64", "linux.template_release.x86_64"],
		"archive_contains": [
			"libvoxel.android.editor.arm64.so (9031288 bytes)",
			"libvoxel.android.editor.x86_64.so (9177136 bytes)",
			"libvoxel.android.template_release.arm64.so (7301800 bytes)",
			"libvoxel.android.template_release.x86_64.so (7523376 bytes)",
			"libvoxel.ios.editor.arm64.dylib (6074760 bytes)",
			"libvoxel.ios.template_release.arm64.dylib (5207400 bytes)",
			"libvoxel.linux.editor.arm64.so (12179248 bytes)",
			"libvoxel.linux.editor.x86_64.so (11788856 bytes)",
			"libvoxel.linux.template_release.arm64.so (10101416 bytes)",
			"libvoxel.linux.template_release.x86_64.so (10366328 bytes)",
			"libvoxel.macos.editor.universal.framework/libvoxel.macos.editor.universal (12899248 bytes)",
			"libvoxel.macos.template_release.universal.framework/libvoxel.macos.template_release.universal (11142104 bytes)",
			"libvoxel.windows.editor.x86_64.dll (11337216 bytes)",
			"libvoxel.windows.template_release.x86_64.dll (10173952 bytes)",
		],
		"files": files,
	}
	JsonData.save_file(OUT, manifest)
	print("wrote %s: %d files, %d bytes" % [OUT, files.size(), total_bytes])
	for rel in files:
		print("   %-58s %s" % [rel, files[rel]])
	quit(0)


func _list(dir_path: String, prefix: String = "") -> Array:
	var out := []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		var rel := (prefix + n) if prefix.is_empty() else (prefix + "/" + n)
		if dir.current_is_dir():
			out.append_array(_list(dir_path + "/" + n, rel))
		else:
			out.append(rel)
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out
