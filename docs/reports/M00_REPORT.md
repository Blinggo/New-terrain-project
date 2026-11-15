# M00 REPORT - Streaming blocky voxel foundation

Project: VoxelTerrain (15-milestone deterministic voxel survival terrain). Milestone: **M00 only**.
Date: 2026-11-14. Author: M00 implementation run (Arena.ai agent).
Rule compliance: GDScript only; no third-party deps beyond Voxel Tools; `addons/zylann.voxel/`
unmodified; no later-milestone systems built; every number below was measured by a script
whose output is committed or quoted verbatim.

---

## 1. Environment and versions

| Item | Value |
|---|---|
| Engine | Godot **4.7.2-stable (official)**, hash `ed1daf0bf001b61586d9930840f2f1394092c079` |
| Voxel Tools | **1.7.0**, edition **GDExtension**, release build, git `75d3c6d996ed2331c80edcd8c3ebc947afc0f041` |
| Upstream archive | `GodotVoxelExtension.zip` (v1.7x), sha256 `600737572a5e25541ba6f503e842a3717ba19afafa5474510a6ceff995a1d2d8` |
| OS | Debian GNU/Linux 13 (trixie), kernel 6.1.189+, x86_64 |
| CPU | Intel Xeon @ 2.60 GHz, **2 threads** |
| RAM | **1982.8 MiB** total (no swap), ~750-890 MiB available during runs |
| GPU | **none** - RenderingServer reports `llvmpipe (LLVM 19.1.7, 256 bits)` software Vulkan |
| Display | none natively; windowed evidence captured under `Xvfb` 1280x720x24 |
| Renderer setting | Forward Mobile, nearest + nearest-mipmap, MSAA/glow/SSAO/volumetric fog off, 2048 shadow map, soft-shadow quality 0, 60 Hz physics |

**Honesty note.** This machine is far weaker than the 3-4 GB RAM / Adreno 610-class Android
target. Benchmarks `B0` and `R1` therefore report **BLOCKED as statements about the target
device** while still providing valid *relative* comparisons and a regression baseline for
this box. No number in this report is a phone number unless labelled as such (none are).

## 2. API verification (T2) - what 1.7 actually exposes

`tools/dump_voxel_api.gd` ran FIRST, before any terrain code: `docs/reports/voxel_api_dump.json`
(309,028 bytes; 133 classes reflected) and `docs/reports/voxel_graph_nodes.json`
(16,560 bytes; 57 graph node types). Verdict:

- **PRESENT (21 requested):** VoxelEngine, VoxelTerrain, VoxelLodTerrain, VoxelViewer,
  VoxelMesherBlocky, VoxelBlockyLibrary, VoxelBlockyTypeLibrary, VoxelBlockyModel,
  VoxelBlockyModelCube, VoxelBuffer, VoxelTool, VoxelGenerator, VoxelGeneratorNoise2D,
  VoxelGeneratorGraph, VoxelGraphFunction, VoxelGeneratorScript, VoxelGeneratorMultipassCB,
  VoxelToolMultipassGenerator, VoxelInstancer, VoxelInstanceLibrary, VoxelStreamSQLite.
- **MISSING / renamed vs older docs:** `VoxelBlockyLibraryManager` (absent from ClassDB),
  VoxelToolBlocky, VoxelBufferInternal, VoxelGraphRuntime, VoxelInstanceTransformer;
  `FastNoise2` not registered; `ZN_FastNoiseLite` extends `Resource`, not `Noise`.
- **Traps found and encoded** (each re-verified by a probe, listed in
  `docs/ARCHITECTURE.md` §5): generator/mesher/format live on `VoxelNode`; viewer distance
  is in **voxels**; `VoxelMesherBlocky` has no material property; cube models carry exactly
  one material (surface index 0); mesher/model `Side` enums differ; graph node ids resolve
  by name (`OutputType` = 44, absent from `NodeTypeID`); loaded blocks are not scene
  children (`VoxelEngine.get_stats().memory_pools.block_count` is the counter);
  `VoxelGeneratorGraph` is RefCounted (never `free()`); `Input.MOUSE_MODE_CAPTURED` does
  not stick headless.

## 3. How to run

```bash
GODOT=/path/to/godot4 ./tools/run_tests.sh            # headless suite, exit 0/1/2
GODOT=/path/to/godot4 ./tools/run_tests.sh --with-runtime   # + windowed runtime bench
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/capture_screenshots.gd       # the 5 acceptance screenshots
$GODOT --path .                                        # Play: stream + fly
```

Windows: `tools\run_tests.ps1`. Full command list, module table and evidence-regeneration
procedure: `docs/TESTING.md`. Compile gate: `GODOT=... ./tools/check_scripts.sh` ->
**38 scripts, 0 failed, 0 warnings** (warnings are errors in this project).

## 4. What was built, per task

- **T1** `project.godot` (mobile renderer, cheap settings, main scene, touch emulation) +
  ADR-0001 (engine/extension/language) + ADR-0002 (layering/swap point).
- **T2** install + API dump (section 2). Linux-only binaries extracted per instruction;
  Android/Windows/macOS left in the archive and accounted for in the manifest.
- **T3** deterministic generated 64x64 atlas, 4x4 grid, 11 tiles, water alpha 0.604,
  nearest+6 mipmaps+lossless (sha256 pinned: `087f907b...fab7`); block library built in
  code from `content/blocks/blocks.json` (10 blocks, index == id, air = `VoxelBlockyModelEmpty`,
  per-face tiles, per-block collision, **one** opaque atlas material - the measured maximum
  for cube models).
- **T4** `world.tscn`/`world.gd`: VoxelTerrain + VoxelMesherBlocky + generated library +
  collisions + VoxelViewer on the camera, DirectionalLight3D with shadows, WorldEnvironment
  with procedural sky + exponential distance fog, `stream` deliberately unset. Boots
  headless and windowed with 0 startup errors. `world_config.gd/json`: immutable typed
  config with validation; y [-64,320), sea 64, 8-bit TYPE, mesh 16.
- **T5** `i_generator_adapter.gd` + `gen_noise2d_adapter.gd` + `gen_graph_adapter.gd` +
  `adapter_registry.gd` (F3 cycles). Both render visibly blocky 3D terrain (screenshots,
  S4a-S4l). Cost measured identically for both; **recommendation: `graph` for M01**
  (section 6) despite costing ~1.3-1.5x more, because the heightmap adapter can only ever
  write one non-air id.
- **T6** `fly_camera.gd`: WASD, Space/QE/Ctrl vertical, Shift boost, wheel 2/8/32/128/512
  m/s, mouse-look with capture + Esc, left-half virtual stick / right-half look drag /
  UP+DOWN buttons on touch, noclip default with N gravity+collision toggle, F1 HUD, F2
  screenshot, F3 generator, F4 view distance 6/8/12, F5 seed, F6 +-100 000 teleport, F7
  wireframe. Keyboard, gravity, collision, touch logic and (windowed) captured mouse all
  proven by tests; touch auto-enable only on real mobile features or `--touch`.
- **T7** `debug_hud.gd`: FPS, avg+p95+worst frame time over 120 rolling frames, draw calls,
  primitives, objects, static+video memory, position, chunk, voxel, seed, tier, generator
  name, view distance + vertical ratio, world y-range, loaded blocks, voxel payload, the
  raw `VoxelTerrain.get_statistics()` dict, startup errors - and it measures its own
  amortised cost against the 0.3 ms budget and prints OVER when exceeded.
- **T8** `tests/determinism/test_determinism.gd` + `src/core/hash64.gd` (FNV-1a 64,
  published vectors) + `chunk_hasher.gd` + committed `golden_hashes.json`; results in §5.
- **T9** `bench_generation.gd` (headless, 24 576 chunks/adapter, mean/p50/p95/max/chunks-s/
  peak memory delta + engine's own us/voxel) and `bench_runtime.gd` (windowed 3x60 s
  scripted flights at vd 8/6/12); results in §6.
- **T10** `tools/run_tests.gd` (spawns a genuine second process for D2), `run_tests.sh`,
  `run_tests.ps1`, PASS/FAIL/BLOCKED table, non-zero exit on FAIL, JSON results;
  `docs/TESTING.md`.
- **T11** `export_presets.cfg` (Android arm64 ETC2+ASTC, Windows, Linux), arm64 `.so`
  verified from the archive listing (7,301,800 bytes), `docs/ANDROID.md`; APK/on-device
  **BLOCKED** (no SDK/keystore/device in sandbox) with the exact unblock commands.
- **T12** this report + `docs/CONVENTIONS.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`,
  `docs/ANDROID.md`, `THIRD_PARTY_NOTICES.md`, ADR-0001/0002/0003, four folder READMEs.

## 5. Determinism (T8) - all green, with strengthened evidence

Headless run of the module: D1, D3, D3b, D4, D5, D5b, D5c, D-table PASS. Full-suite D2
PASS in a **separate process**.

- **D1** same seed, same process: 64/64 chunk hashes identical, both adapters.
- **D2** second process vs committed goldens: **128/128 hashes reproduced**
  (`0,0,0` -> noise2d `-3171562080020924751`, graph `-9126349238453639341`).
- **D3** origin #40 `(-6547600,240,-2781472)` identical alone vs after #1..#39 (both adapters).
- **D3b** (added) same on a NON-UNIFORM surface chunk `(37568,64,51696)`:
  noise2d `add7b16fc21ddda3` non_air 1104/4096; graph `5ec659db44119a4f` non_air 1533/4096.
- **D4** seed+1: of the surface-straddling chunks, **7/7 changed for both adapters**
  (>=90% required). The original "any 64 origins" version changed only 3-10/64 because a
  384-tall world makes most origins all-air/all-solid; that weakness is now measured, not
  hidden (ADR-0003 §4).
- **D5** lint of `src/worldgen|adapters|core` (10 scripts): zero `randf(`, `randi(`,
  `Time.get_`, `randomize(`. **D5b** spine+worldgen empty. **D5c** 64 origins = 8 special +
  24 surface band + 32 wide-range; 53 with a negative coord, 33 beyond +-1e6.
- First 8 hashes (noise2d): `0,0,0 d3fc59178540f6b1`, `16,0,0 70bc177f4709b3d5`,
  `-16,0,0 90a0de9450f9c076`, `0,-64,0 69f385c4a37f0f44`, `0,304,0 a3c8e77660d91540`,
  `1000000,64,-1000000 f419a68319c5717c`, `-1000016,-64,1000016 fdcababb159fee70`,
  `32752,112,-49168 6c4616baaad045ab`.

## 6. Performance (T9) - measured, hardware-labelled

**Generation (headless, single-threaded, 24 576 chunks/adapter):**

| adapter | mean ms/chunk | p50 | p95 | max | chunks/s | notes |
|---|---|---|---|---|---|---|
| noise2d | 0.0071-0.0091 | 0.001 | 0.041-0.042 | 0.12-0.15 | 110k-141k | no engine instrumentation |
| graph | 0.071-0.091 | 0.002-0.003 | 0.435-0.631 | 1.18-1.20 | 11.0k-14.1k | engine `debug_measure_microseconds_per_voxel` = 0.313-0.387 us/voxel |

Peak static-memory delta across each run: 0.0 MiB (pools are reused). `B0` BLOCKED as a
device claim (2 threads, 1.9 GiB, no GPU). **B2 recommendation for M01: `graph`** -
1.33-1.48x costlier here, but it writes 3 distinct ids (0/1/3) with named nodes and engine
instrumentation, while `noise2d` provably writes only id 1 above `height_start` (S4g);
strata/caves/ores are impossible on a heightmap at any cost. Keep `noise2d` as the F3
cheap baseline.

**Runtime (windowed under Xvfb/llvmpipe, 60 s scripted flight at 32 m/s each; `R1` BLOCKED
as device claim):**

| view distance | mean fps | p95 frame ms | worst ms | max loaded blocks | max draw calls | max static MiB |
|---|---|---|---|---|---|---|
| 8 chunks | 6.2-6.5 | 225 | 271 | 720 | 258 | 131.2 |
| 6 chunks | 11.0 | 158-164 | 190 | 483 | 123 | 101.1 |
| 12 chunks | 4.9 | 249 | 275 | 1292 | 349 | 218.8 |

Each flight covered 1920-1927 m (target 1920). These are **software-rasteriser numbers on a
2-thread CPU**: they prove the pipeline streams while flying and give relative vd costs
(vd6 ~1.8x the fps of vd8, vd12 ~0.75x); they say nothing about a phone. Voxel payload at
rest: 1.6 MB / 410 blocks (vd8), 3.0-3.2 MB / 666-819 (vd12) - comfortably inside a 3-4 GB
phone budget; generation cost per chunk (above) is likewise small. The phone risk is
fill-rate/meshing, which M01+ must budget.

**HUD cost:** 0.031 ms/frame headless at ~145 fps (budget 0.3). Windowed on llvmpipe at
2-5 fps it reads 0.205-1.06 ms/frame because below ~20 fps even the 2-frame-gated text
rebuild amortises over almost nothing; the HUD prints OVER itself in those screenshots
rather than letting the report claim otherwise.

## 7. Visual evidence (A15) - five screenshots, all from the running game

Captured by `tools/capture_screenshots.gd` (refuses headless; waits until loaded AND meshed
AND stable; poses are deterministic functions of the seed):

1. `20261114T141253_01_ground_level_hills_seed20260814_noise2d.png` - ground level at
   (8,68,8), hills to the horizon, full HUD (410 blocks, 1.6 MB payload, stats dict).
2. `20261114T141314_02_aerial_200m_horizon_seed20260814_noise2d.png` - 200 m above sea
   level (y=264), vd 12, pitched -35deg: streamed disc below, fog/horizon band above,
   HUD shows `vertical ratio 2.00`.
3. `20261114T141323_03_block_closeup_ao_seed20260814_noise2d.png` - cliff face found by
   scanning the generator: grass tops, dirt sides, 16 px tile texels, mesher ambient
   occlusion darkening the step corners.
4. `20261114T141333_04_far_teleport_seed20260814_noise2d.png` - after F6:
   pos (-292636, 96, -292636), chunk (-18290, 6, -18290), terrain streaming normally.
5. `20261114T141300_05_touch_controls_seed20260814_noise2d.png` - touch overlay visible
   over streamed terrain: left stick ring, UP/DOWN buttons, "drag to look" hint.

## 8. Acceptance checklist A1-A15

| # | Verdict | Evidence |
|---|---|---|
| A1 zero errors/warnings from our code | PASS | `check_scripts.sh`: 38 scripts, 0 failed, 0 warnings; runs show only engine audio/kxkb warnings and our own intentional config note |
| A2 extension loads + dump produced | PASS | S2a/S2b (1.7.0 GDExtension), dump JSONs committed |
| A3 blocky 3D terrain < 3 s | PASS | windowed boot: terrain ready + 410 blocks streamed; S5j 410 blocks in 260 frames headless |
| A4 infinite streaming + +-100 000 teleport | PASS | S5j, screenshot 4 at |x|=|z|=292 636 with 395-410 blocks loaded |
| A5 fly camera keyboard+mouse AND touch | PASS | S5m1/S5m2 keyboard; S5m3c captured mouse PASS windowed; S5m4-S5m6 touch logic + screenshot 5 |
| A6 collision in non-noclip | PASS | S5o: drop from y=130 landed y=63.0, `is_on_floor=true`, 341 frames |
| A7 touch controls on mobile path | PASS | S5m4-S5m6 + screenshot 5 (overlay drawn by the runtime, not a mock) |
| A8 HUD real stats | PASS | S5k fields; screenshots show live draw calls/primitives/memory/stats dict |
| A9 HUD < 0.3 ms/frame | PASS (with caveat) | 0.031 ms headless; windowed llvmpipe at 2-5 fps exceeds and self-reports OVER (section 6) |
| A10 D1-D5 pass | PASS | section 5, incl. second-process D2 |
| A11 generation bench both adapters | PASS | section 6 table 1 |
| A12 runtime bench or BLOCKED | PASS | section 6 table 2 (windowed, real); R1 BLOCKED as device claim |
| A13 addons unmodified | PASS | S2i: 35/35 files match `addon_manifest.json` sha256 |
| A14 runner exit codes | PASS | headless suite exit 0 (87 PASS/0 FAIL/3 BLOCKED); harness FAILs on unloadable modules and zero-result modules |
| A15 screenshots + report in docs/reports | PASS | section 7 + this file + `test_results.json` |

## 9. Known issues, limitations, BLOCKED

1. **Aerial horizon at 200 m needs more horizontal stream radius than this box sustains**:
   vd 20 stalls at 2095 blocks (probe, removed after measurement). Shot 2 is therefore
   pitched -35deg at vd 12; the limitation is stated, not faked.
2. **`view_distance_vertical_ratio` works on VoxelTerrain** although the 1.7 docs say
   VoxelLodTerrain-only (measured: ratio 1.0 -> 0 blocks at y=264; ratio 2.0 -> 410).
   Shipped default is 2.0 so flying players keep their terrain; validator warns above 2.0.
3. **Water is opaque in M00.** A cube model carries one material (surface 0) and that
   material must stay opaque or all terrain enters the transparent pass; translucent water
   needs a 2-surface `VoxelBlockyModelMesh` (recorded design in `block_library_builder.gd`,
   reported as `translucent_deferred: ["water"]`).
4. **BLOCKED:** on-device Android run (no SDK/keystore/device) - `docs/ANDROID.md`;
   runtime bench as a device claim (CI has no GPU); headless captured-mouse (S5m3c BLOCKED
   headless, PASS windowed).
5. llvmpipe artifacts: 2-5 fps windowed, HUD OVER banner, audio driver warnings. None
   affect determinism or streaming correctness.

## 10. Decisions and deviations

- Linux-only extension binaries in the checkout (explicit instruction); Android arm64
  verified from the archive listing instead (T11 satisfied as verification, not shipping).
- `view_distance_vertical_ratio` default raised 1.0 -> 2.0 after measurement (issue 2).
- D3b and the surface-straddling D4 added because the specified versions passed while
  proving little on a 384-tall world (ADR-0003).
- Screenshots settle on loaded+meshed+stable, not fixed frames, after two honest failures
  (empty world at 200 m; half-meshed world at 3 fps).
- F5 seed and HUD timing use `Time.*` in runtime/debug only; lint scope excludes them by
  design and the report says so (D5 evidence line).

## 11. Deferred (not built in M00, by rule)

M01 biomes/climate; M02 rivers/erosion; M03 weather/clouds/seasons; M05 strata; M06 caves;
M07 ores; M08 volcanoes; M09 trees/foliage; M10 structures; M12 save/load +
VoxelStreamSQLite wiring (`stream` stays unset); multiplayer; M13 distant-terrain LOD;
plus: translucent water via VoxelBlockyModelMesh, VoxelBlockyTypeLibrary migration,
GPU generation, VoxelInstancer, on-device Android validation.

## 12. Handoff to M01

- Start from the **graph adapter** (section 6); its named nodes
  (`terrain_noise`, `height_remap`, `grass_or_stone_select`, `air_or_solid_select`,
  `output_type`) are the insertion points for climate-driven surface ids.
- Budget phone work on fill-rate/meshing, not generation: 0.07-0.09 ms/chunk generation vs
  218.8 MiB static at vd 12 on CI says memory and rasterisation dominate.
- Keep the determinism gate: any M01 module that touches generation inherits the D5 lint
  and must reproduce `golden_hashes.json` or deliberately regenerate it with a report note.
- The adapter boundary (ADR-0002) is load-bearing: M01 modules must not name Voxel classes.
