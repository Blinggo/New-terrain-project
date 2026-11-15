# M01 REPORT - The extensibility spine

Project: VoxelTerrain (15-milestone deterministic voxel survival terrain). Milestone: **M01 only**.
Date: 2026-11-15. M00 was independently reviewed and PASSED before this milestone started.
Rule compliance: GDScript only; no third-party deps beyond Voxel Tools; `addons/zylann.voxel/`
unmodified and still Linux-only; no later-milestone content built (B17 enforced by D5b/B17);
every number below was measured by a script whose output is committed or quoted verbatim.

**Headline:** adding a module now changes nothing else - proven, not asserted. X1 registers a
no-op module at runtime and all 64 M00 graph goldens still reproduce; X2 round-trips a
channel that appears in no spec anywhere; the M00 terrain output is bit-identical after the
hills were re-expressed as modules (D2/X10: 192/192 hashes across three backends).

---

## 1. Environment and versions

| Item | Value |
|---|---|
| Engine | Godot **4.7.2-stable (official)**, hash `ed1daf0bf001b61586d9930840f2f1394092c079` |
| Voxel Tools | **1.7.0**, edition **GDExtension**, release, git `75d3c6d996ed2331c80edcd8c3ebc947afc0f041` |
| OS / CPU / RAM | Debian 13 (trixie), Intel Xeon @ 2.60 GHz **2 threads**, **1982.8 MiB** (no swap) |
| GPU | **none** - `llvmpipe (LLVM 19.1.7)` software Vulkan; windowed evidence under Xvfb 1280x720x24 |
| Suite | `tools/run_tests.sh`: **111 checks, 108 PASS, 0 FAIL, 3 BLOCKED, exit 0** in 223 s |
| Compile gate | `tools/check_scripts.sh`: **68 scripts, 0 failed, 0 warnings** |
| Windowed scene suite | **31/31 PASS** incl. captured-mouse routing (S5m3c) and HUD phone modes (S5p) |

Honesty note (unchanged from M00): this box is far weaker than the 3-4 GB / Adreno 610
target. `B0` and `R1` report **BLOCKED as statements about the device** while still giving
valid relative comparisons and a regression baseline. No number here is a phone number.

## 2. API verification (new findings this milestone)

- **`VoxelGeneratorMultipassCB` is NOT scriptable in the 1.7 GDExtension.**
  `ClassDB.instantiate("VoxelToolMultipassGenerator")` -> "cannot be instantiated"; a
  GDScript `extends VoxelToolMultipassGenerator` -> "Can't inherit from a virtual class";
  the CB instance exposes only `pass_count`, `column_base_y_blocks`, `column_height_blocks`,
  `pass_%d_extent` - **no passes property or setter** (`tools/probe_multipass.gd`,
  `tools/probe_multipass2.gd`). Consequence: the multipass backend self-hosts the pattern
  on `VoxelGeneratorScript` (whose `_generate_block(buffer, origin, lod)` IS overridable -
  `tools/probe_multipass3.gd`), and the cost spike measures honest GDScript pricing.
- **`VoxelBuffer.set_voxel` argument order is `(value, x, y, z, channel)`** - caught by test
  failure, now encoded in `MultipassColumnGenerator` (a wrong-order call produced
  solid-to-sky columns and seed-insensitive hashes; the tests caught it before any golden
  was written).
- `DirAccess.dir_exists_absolute()` is the static existence check (`DirAccess.exists()`
  does not exist; `dir_exists()` is instance-only).
- M00's verified list still stands (viewer distance in voxels, one material per cube model,
  `OutputType`=44 by name, loaded blocks via `VoxelEngine.get_stats()`, capture needs a
  window) - see `docs/ARCHITECTURE.md` section 6.

## 3. How to run

```bash
GODOT=/path/to/godot4 ./tools/run_tests.sh                 # 111 checks, ~3.7 min, exit 0/1/2
GODOT=/path/to/godot4 ./tools/run_tests.sh --skip-perf     # fast iteration
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/run_module.gd -- \
    res://tests/perf/bench_runtime.gd res://src/runtime/world/world.tscn   # windowed flights
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/capture_screenshots.gd            # 6 screenshots incl. pipeline page
$GODOT --path .                                             # Play: module-driven terrain
```

Full command matrix, module table and evidence-regeneration procedure: `docs/TESTING.md`.

## 4. What was built, per task

- **Task 0 (reviewer fixes).** 0.1: `OS.execute`'s return is the CHILD'S exit code in Godot 4;
  the parent now reads the nonce-validated child file first and only reports a spawn failure
  when no fresh result exists, appending the child exit code to every result's evidence
  (X12c proves a mismatching child exits 1 and its real verdict reaches the parent).
  0.2: D2 messages compose from counts ("second process reproduced 192/192 committed golden
  hashes (0 mismatches)"; a FAIL reads e.g. "127/128 ... (1 mismatch)").
  0.3: the child result file is deleted before spawn, carries `run_nonce` + pid, is
  gitignored, and a wrong nonce is rejected (X12b). 0.4: HUD rebuilt - COMPACT 4-line
  default (fps+hud cost, frame p95, pos, blocks), FULL, PIPELINE, OFF; F1 and touch-tap
  cycle; font/panel scale with viewport (clamped 0.55-2.0); self-cost readout kept in every
  text mode (S5p). 0.5: X12a/b/c regression tests, all passing.
- **Task 1 (core).** `rng_streams.gd` (domain-hashed `RandomNumberGenerator` streams,
  `stream_at`, stateless `chance`), `fixed_point.gd` (`quantize`/`qcompare`/`qsnap`/`qkey`),
  `channel_id.gd` (`domain.name` parsing, FLOAT/INT/VEC2/VEC4/BYTES/TILE_* types, versions,
  actionable errors).
- **Task 2 (blackboard).** `gen_blackboard.gd`: WORLD/REGION/COLUMN scopes, publish/read/
  has/try_read/read_typed, unknown channels legal, loud missing reads, type-flip errors
  naming both types, `debug_dump()` with tile dimensions, `loud` flag so tests can exercise
  failure modes without spraying ERROR lines.
- **Task 3 (contracts).** `ModuleDefinition` (id/version/enabled/phase/priority/requires/
  provides/params/quality_scaling), `FieldProvider`, `TerrainPass` (extent), `FeatureStamp`
  (cell_size, candidates_near, evaluate), `GenContext` (blackboard, cache, config dict,
  tier, writer, injected noise sampler + profiler), `IColumnWriter`. No Voxel identifiers
  anywhere in spine (X9).
- **Task 4 (registry).** Disk scan of `res://content/modules/**` + `user://modules/**`
  (hook implemented, empty in repo); duplicate-id errors name both paths (X7); unknown
  script types error, not crash; disabled modules listed but skipped; `reload()` re-resolves.
- **Task 5 (scheduler).** Requires/provides graph, topological order within fixed phases,
  tiebreak priority-then-id, **identical output under 50 input shuffles** (X4), cycle errors
  printing the real path (`tests.cyc_a -> tests.cyc_c -> tests.cyc_b -> tests.cyc_a`, X5),
  missing-producer errors naming consumer+channel+pipeline (X6), `pipeline_dump()`,
  per-pass extent factors and the total column multiplication factor (S6c).
- **Task 6 (fields).** `field_tile.gd` (packed arrays, width/spacing/origin/halo,
  bilinear+nearest, S6b) and `field_cache.gd` (LRU keyed channel+region+producer_version,
  byte budget from the quality tier, eviction invisible: X8 recomputes bit-identical).
- **Task 7 (config v2).** `worldgen_version`, `modules` override block (enable/params,
  applied to typed exports when they exist), tier budgets **low 6 chunks/24 MB/0.4/2 tasks,
  medium 8/48/0.7/4, high 12/96/1.0/8**, `view_distance_chunks` now an OVERRIDE of the tier
  default with `view_distance_source` shown on the HUD (shipped config keeps 8 as an
  explicit override so the M00 world is unchanged - B14).
- **Task 8 (hills as modules).** `planet.hills_v1` (FieldProvider, PLANET, publishes
  `field.height` at column resolution with the M00 noise maths) and
  `surface.grass_stone_v1` (TerrainPass, SURFACE, extent 0, air/grass/stone by depth), as
  `.tres` + script under `content/modules/` and `src/worldgen/`. The graph adapter now reads
  its parameters from the RESOLVED PLAN and pushes them into the named nodes - and still
  reproduces M00 goldens bit-for-bit (X10). HUD gained the PIPELINE page (screenshot 06).
- **Task 9 (multipass spike).** `gen_multipass_adapter.gd` + `multipass_column_generator.gd`:
  self-hosted column passes (A extent 0 = module pipeline, B extent 1 = neighbour cliff rule)
  over `VoxelGeneratorScript`, LRU column cache, own committed goldens
  (`golden_hashes_multipass.json`, verified cross-process by D2/X11). Benchmark + verdict in
  section 6; backend selectable in config (`generator: "multipass"`), graph remains default.
- **Task 10 (tests).** X1-X12 all implemented and passing (sections 5 and 7); D5 extended to
  scan `src/spine` and to lint Voxel/ZN identifiers outside adapters via the shared
  `src/core/layer_lint.gd` (B10).
- **Task 11 (docs).** This report, `docs/EXTENDING.md` (five zero-edit recipes),
  `docs/WORLDGEN_CHANGELOG.md`, `docs/PORTING_LEDGER.md` (empty table), `THIRD_PARTY_NOTICES.md`
  (+ ReTerraForged, TerraForged declared ahead of M02 ports), `docs/ARCHITECTURE.md` rewritten
  for the spine, ADR-0004, `docs/TESTING.md` refreshed.

## 5. Determinism (D-suite + goldens)

- **D1** 64/64 identical hashes across two in-process runs for **all three** backends.
- **D2 / X10 / X11** second process reproduced **192/192** committed hashes
  (noise2d 64/64, graph 64/64, multipass 64/64), nonce-validated child file, child exit 0.
- **D3/D3b** order independence incl. a non-uniform surface chunk; **D4** seed+1 changes
  >=90% of surface-straddling chunks for every backend; **D5c** origin coverage unchanged.
- **D5/X9** lint: zero banned calls (`randf(`, `randi(`, `randomize(`, `Time.get_`
  unqualified) and zero `Voxel`/`ZN_` identifiers in core/spine/worldgen over 31 scripts.
- **D5b/B17** `content/modules/` holds exactly `planet_hills_v1.tres` +
  `surface_grass_stone_v1.tres`; no later-milestone vocabulary in spine/worldgen code.
- Goldens: `tests/determinism/golden_hashes.json` **unchanged since M00** (graph
  `0,0,0 -> -9126349238453639341`); new `golden_hashes_multipass.json`
  (`0,0,0 -> -9126349238453639341`-family values; 55/64 columns match the graph, the deltas
  being exactly the cliff-rule columns). Regeneration is a deliberate act recorded in
  `docs/WORLDGEN_CHANGELOG.md`.

## 6. Extensibility evidence (X1 / X2 verbatim) and performance

Verbatim from `tools/run_module.gd` runs (also in `docs/reports/test_results.json`):

```
[PASS] smoke / X1 - adding a no-op module changes NOTHING: all 64 M00 graph goldens reproduce
        registered=true (pipeline 2 -> 3 modules), mismatched origins=[]

[PASS] smoke / X2 - a channel no spec knows about round-trips producer -> blackboard -> consumer
        observed=42.0 (expected 42.0); zero pre-existing files edited: both modules are new files under user://modules/
```

**Generation (headless, single-threaded, 24 576 chunks per backend, B1):**

| backend | mean ms/chunk | p50 | p95 | chunks/s |
|---|---|---|---|---|
| noise2d | 0.0047 | 0.001 | 0.027 | ~214 000 |
| graph (default) | 0.0409 | 0.001 | 0.245 | ~24 400 |
| multipass | 1.4058 | 0.206 | 0.394 | ~711 |

**Column cost spike (B3, 1024 columns of 16x384x16, same footprint as M00):**

| configuration | mean ms/column | p50 | p95 | max |
|---|---|---|---|---|
| graph (compiled) | 1.014 | - | - | - |
| multipass extent 0 | 30.080 | 29.481 | 32.902 | 48.478 |
| multipass extent 0+1 | 33.771 | 4.840 | 132.861 | 243.061 |

**Verdict (B13):** keep the compiled graph as default; multipass (29.7x graph at extent 0,
33.3x with one extent-1 pass) is reserved for genuine cross-chunk features (M08 trunks,
M10 structures). It cannot move engine-side because MultipassCB is not scriptable in this
extension build, and it lacks LOD (M13). Full reasoning in B3/rec evidence and ADR-0004.

**Runtime (windowed llvmpipe, 60 s scripted flights at 32 m/s; R1 BLOCKED as device claim):**
vd8 8.7 fps mean / p95 153 ms / max 794 blocks; vd6 14.8 / 124 / 526; vd12 5.5 / 220 / 1464.
Flight distance 1920-1927 m each. These are software-rasteriser numbers on 2 threads.

## 7. Acceptance checklist B1-B19

| # | Verdict | Evidence |
|---|---|---|
| B1 imports/runs, terrain streams | PASS | windowed boot + S5j 499 blocks/260 frames; 6 screenshots |
| B2 Task 0 five fixes + X12 | PASS | X12a/b/c PASS; D2 message/count format visible in suite output |
| B3 registry from disk, no hardcoded list | PASS | `module_registry.gd` scans roots; X1/X2 register at runtime via user:// |
| B4 scheduler deps; X4 | PASS | X4 50 shuffles identical dump |
| B5 cycle/missing/dup actionable | PASS | X5 path string, X6 names, X7 both paths |
| B6 unknown channels; X2 | PASS | X2 verbatim above |
| B7 X1 additive stability | PASS | X1 verbatim above |
| B8 X3 RNG independence | PASS | 1000 domains pairwise distinct; new domain perturbs nothing |
| B9 X8 cache bit-identical | PASS | evict+recompute equals original tile |
| B10 X9 lint in automated suite | PASS | D5+X9 in every headless run via `layer_lint.gd` |
| B11 X10 M00 graph goldens exact | PASS | D2 192/192; X1 re-checks after module addition |
| B12 multipass + own goldens (X11) | PASS | `golden_hashes_multipass.json`, second-process verified |
| B13 multipass vs graph benchmark + rec | PASS | B3 table + verdict above |
| B14 tier changes view+cache measurably | PASS | `TIER_BUDGETS` + `effective_view_distance_chunks()`; S5p/HUD source line; config validation tests |
| B15 HUD compact/full/pipeline + scale | PASS | S5p + screenshots 05 (compact+touch) and 06 (pipeline) |
| B16 EXTENDING recipes zero-edit | PASS | five recipes; only the enum-exception recipe names an existing file, and says so |
| B17 only two hills modules | PASS | D5b/B17 whitelist check |
| B18 addon untouched, Linux-only, no deps | PASS | S2i 35/35 sha256; manifest unchanged; no new imports |
| B19 report + docs | PASS | this file + EXTENDING/CHANGELOG/LEDGER/notices/ARCHITECTURE/ADR-0004 |

## 8. Visual evidence

`docs/reports/screenshots/` (windowed, llvmpipe, module-driven graph backend):
`..._01_ground_level_hills_..._graph.png` (FULL HUD), `..._05_touch_controls_...` (COMPACT
HUD + stick/UP/DOWN/look hint), `..._02_aerial_200m_horizon_...`, `..._03_block_closeup_ao_...`
(grass tops, dirt sides, AO corners), `..._04_far_teleport_...` (|x|=|z|=292 636),
`..._06_pipeline_page_...` (resolved order, versions, phases, provides, column factor).

## 9. Known issues, limitations, BLOCKED

1. **MultipassCB not scriptable** (section 2) - the spike backend is self-hosted; if a future
   Voxel Tools release scripts it, `gen_multipass_adapter.gd` is the swap point.
2. **Multipass is slow** (~30x graph): GDScript per-voxel writes. Acceptable for a spike and
   for rare cross-chunk features; not a default backend (ADR-0004).
3. **BLOCKED:** on-device Android (no SDK/keystore/device; `docs/ANDROID.md`), runtime bench
   as a device claim (no GPU), headless captured-mouse (windowed run proves it: S5m3c PASS).
4. Field tiles sample height once per column (spacing 16): exact for column decisions, but
   sub-column height detail (future micro-erosion) will need a finer spacing or analytic
   reads; recorded in WORLDGEN_CHANGELOG.
5. llvmpipe artifacts (2-9 fps windowed, HUD OVER banner at those frame rates) unchanged
   from M00; the HUD's own amortised cost at playable frame rates stays <=0.3 ms (S5p).

## 10. Decisions and deviations

- Graph adapter parameters moved from `content/world_config.json gen_params` to module
  exports; `gen_params` remains for the `noise2d` baseline. Structure changed, maths did not
  (X10). WORLDGEN_CHANGELOG records it as "output unchanged".
- `IVoxelWriter` renamed `IColumnWriter` mid-milestone because the X9 lint (correctly)
  rejects the substring `Voxel` outside adapters - the lint caught our own naming, which is
  exactly what a load-bearing layering rule should do.
- `GenBlackboard.loud` flag added so negative tests record errors without polluting the
  "zero errors from our code" evidence; production defaults stay loud.
- Shot 05 now uses COMPACT (phone default) and shot 06 documents the pipeline page; shots
  01-04 keep FULL for continuity with M00.
- The D5 lint skips `layer_lint.gd` itself (it contains the banned tokens as data) - the one
  deliberate self-exclusion, documented in the file.

## 11. Deferred (not built in M01)

Biomes/climate fields, erosion/rivers, caves/strata/ores/volcanoes, trees/foliage,
structures, weather/clouds/seasons, save/load + streams, multiplayer, distant LOD,
translucent water, VoxelBlockyTypeLibrary migration, GPU generation, disk field cache,
on-device Android validation, FeatureStamp implementations (contract only). Milestone
mapping unchanged from M00 report section 11; ports from ReTerraForged/TerraForged start at
M02 with PORTING_LEDGER entries.

## 12. Handoff to M02

- Default backend stays `graph`; new climate modules publish REGION tiles and consume them
  via the blackboard - recipes in `docs/EXTENDING.md`.
- Budget: keep hot maths in graph nodes/analytic stamps; price any neighbour-aware pass
  against B3 (30+ ms/column in GDScript on this box) before committing to it.
- Field cache budget is tier-owned (24 MB low); a disk cache (M02) must keep X8's
  bit-identical-recompute property.
- The determinism gate is now three golden sets; any maths change regenerates them
  deliberately and lands a WORLDGEN_CHANGELOG row in the same commit.
- `user://modules/` is live: mods and milestone prototypes can ship as pure additions -
  X1/X2 are the regression net that keeps that promise honest.
