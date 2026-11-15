# ADR-0001 - Engine, extension and language baseline

- Status: Accepted (M00)
- Date: 2026-11-14
- Deciders: M00 implementation

## Context

The project is a 15-milestone (M00-M14) infinite deterministic voxel terrain generator for a
voxel survival game. M00 must fix the technology baseline that every later milestone is
judged against, on a target of low-end Android first (3-4 GB RAM, Adreno 610 class) and
desktop second.

## Decision

1. **Engine: Godot 4.7.2-stable** (official build, hash `ed1daf0bf001b61586d9930840f2f1394092c079`).
2. **Terrain: Voxel Tools 1.7.0 as a GDExtension** (`GodotVoxelExtension.zip`, release build,
   git `75d3c6d996ed2331c80edcd8c3ebc947afc0f041`), vendored under `addons/zylann.voxel/`
   and never modified (hard rule #3; verified byte-for-byte by
   `tests/smoke/test_extension.gd` S2i against `docs/reports/addon_manifest.json`).
3. **Game code: GDScript only.** No C#, no C++, no compute shaders, no asset-library
   plugins, no third-party dependencies other than Voxel Tools (hard rule #4).
4. **Renderer: Forward Mobile** with the cheapest settings that still show the blocky world
   (nearest + nearest-mipmap filtering, no MSAA/glow/SSAO/volumetric fog, 2048 directional
   shadow map, soft shadow quality 0). Chosen for the Adreno 610 class, not for looks.
5. **Linux-only binaries in this checkout.** Per explicit project instruction only the two
   Linux `.so` files were extracted from the upstream archive; Android/Windows/macOS/iOS
   binaries were left in the archive. The Android arm64 library required by T11 is verified
   from the archive listing and recorded in `docs/ANDROID.md` and the manifest, not shipped
   here.

## Consequences

- Every API fact used by later code must come from `docs/reports/voxel_api_dump.json`
  (T2) or from a probe script, never from memory of older Voxel Tools versions. The dump
  records 133 classes, 21 requested classes present and `VoxelBlockyLibraryManager`
  missing in 1.7.
- GDScript-only means generator logic lives in `VoxelGeneratorGraph` node graphs built from
  code, not in `VoxelGeneratorScript` hot loops; the graph path is also the one with the
  engine's own `debug_measure_microseconds_per_voxel()` instrumentation.
- The extension is a GDExtension, so a never-imported project does not load it under
  `--headless --script`; `.godot/extension_list.cfg` must exist (run `--import` once). This
  is encoded in `tools/run_tests.sh` / `run_tests.ps1`.
- Software Vulkan (llvmpipe) is the only rasteriser on the CI box; all windowed evidence is
  therefore software-rendered and labelled as such.
