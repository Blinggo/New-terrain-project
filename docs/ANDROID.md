# Android - VoxelTerrain M00 (T11)

Target: low-end Android, 3-4 GB RAM, Adreno 610 class. This document states exactly what
was verified in M00, what was NOT, and why.

## 1. Export presets

`export_presets.cfg` (project root) defines three presets:

| Preset | Platform | Architectures | Texture formats |
|---|---|---|---|
| `Android` | Android | **arm64-v8a only** | ETC2 + ASTC (mobile class) |
| `Windows Desktop` | Windows | x86_64 | S3TC/BPTC |
| `Linux/X11` | Linux | x86_64 | S3TC/BPTC |

The Android preset is arm64-only on purpose: armeabi-v7a devices cannot meet the 3-4 GB
RAM target, and shipping one architecture halves the APK's native payload.

## 2. The Android extension binary: verified from the upstream archive, NOT installed

Project instruction: **only the Linux binaries were extracted** into
`addons/zylann.voxel/` (editor + template_release `.so`, 2 files). The Android libraries
were deliberately left inside the untouched upstream archive
(`/home/user/.local/dl/GodotVoxelExtension.zip`, sha256
`600737572a5e25541ba6f503e842a3717ba19afafa5474510a6ceff995a1d2d8`).

Verification was therefore done against the archive's file listing (recorded in
`docs/reports/addon_manifest.json` -> `archive_contains`), not against an extracted tree:

```
libvoxel.android.template_release.arm64.so    7,301,800 bytes   <- required by T11
libvoxel.android.editor.arm64.so              9,031,288 bytes
libvoxel.android.template_release.x86_64.so   7,523,376 bytes
libvoxel.android.editor.x86_64.so             9,177,136 bytes
```

So: **the Android arm64 GDExtension binary exists upstream at the exact version this
project vendors (v1.7x / 1.7.0)**, and `voxel.gdextension`'s `[libraries]` section maps
`android.arm64` to it. What is NOT verified in M00 is that the binary loads on a device -
that needs an APK and a phone (below).

To install the Android binaries later (when an APK build is actually wanted):

```bash
unzip -j GodotVoxelExtension.zip \
  'addons/zylann.voxel/bin/libvoxel.android.*.so' -d addons/zylann.voxel/bin/
# then re-run tools/make_addon_manifest.gd -- --force and record it in the report
```

## 3. APK build and on-device check: BLOCKED

Status: **BLOCKED**, honestly. This sandbox has no Android SDK/NDK, no `adb`, no JDK
toolchain configured for Gradle, no keystore and no device/emulator. Attempting
`--export-release Android` here would fail at the toolchain, not at our code, and a
fabricated "it exports" claim would violate the reporting rules.

What M00 did instead, so the BLOCKED is narrow and actionable:

1. Presets exist and are syntactically the Godot 4.7 format (arm64 + ETC2/ASTC).
2. The arm64 extension binary's presence and size are verified from the archive listing.
3. The whole runtime is exercised headless and windowed on Linux, including the memory
   numbers that decide phone viability: at the default 8-chunk view distance the streamed
   payload is **1.6 MB of voxel data / 410 data blocks** (HUD, screenshot 01), and
   `bench_generation` shows the graph generator at **0.07-0.09 ms per 16^3 chunk**
   single-threaded on a 2-thread CI CPU - i.e. generation is not the phone's bottleneck;
   fill-rate and meshing are, and those are what M01+ must budget.
4. Touch input is implemented and unit-tested (`fly_camera.gd` touch seams, S5m4-S5m6) and
   visible in screenshot 05; on-device feel is deferred to the first real device run.

To unblock, on a machine with the Android SDK:

```bash
# install the android binaries (section 2), then
godot --headless --path . --export-release "Android" build/android/voxel-terrain-m00.apk
adb install -r build/android/voxel-terrain-m00.apk
adb logcat -s godot VoxelTools
```

and record: boot-to-terrain time, `VoxelEngine.get_stats()` block_count at vd 8, and FPS
over a 60 s walk. Those three numbers are the M01 entrance criteria for the phone target.
