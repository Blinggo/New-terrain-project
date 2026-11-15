# Testing - VoxelTerrain (M01 state)

Everything runs from a clean checkout. Prerequisite: a Godot 4.7.x binary with the vendored
Voxel Tools extension (already in `addons/zylann.voxel/`).

## 1. Quick start

```bash
# Linux / macOS / WSL - GODOT overrides the binary lookup
GODOT=/home/user/.local/godot/godot4 ./tools/run_tests.sh

# Windows PowerShell
$env:GODOT = "C:\bin\Godot_v4.7.2-stable_win64.exe"
.\tools\run_tests.ps1
```

First run imports the project (`--import`) if `.godot/extension_list.cfg` is missing; the
extension only loads after an import.

Exit codes: **0** = all checks PASS (BLOCKED allowed), **1** = at least one FAIL,
**2** = no Godot binary found. Runner flags: `--skip-perf`, `--with-runtime`,
`--json=<path>`.

Full headless suite at M01: **111 checks** (~3.5 min on the 2-thread CI box, dominated by
the multipass benchmark and the second-process determinism child).

## 2. What the headless runner executes

| Module | Checks | Needs |
|---|---|---|
| `tests/smoke/test_hash64.gd` | S1 FNV-1a/64 published vectors | nothing |
| `tests/smoke/test_extension.gd` | S2 extension load/version/class set, addon sha256 manifest | nothing |
| `tests/smoke/test_assets.gd` | S3 atlas/blocks/library/materials | nothing |
| `tests/smoke/test_generators.gd` | S4 all THREE adapters: shape, ids, registry cycle, seed sensitivity, per-adapter cost | nothing |
| `tests/smoke/test_scene.gd` | S5 project settings, scene graph, streaming, HUD (S5k FULL fields, **S5p phone modes/scaling/pipeline page**), input, gravity landing | headless ok; captured mouse = BLOCKED headless, PASS windowed |
| `tests/smoke/test_spine.gd` | **X3** RNG independence, **X4** order stability (50 shuffles), **X5** cycle path, **X6** missing producer, **X7** duplicate id paths, **X8** cache evict/recompute bit-identical, blackboard + tile contracts, scheduler column factor | nothing |
| `tests/smoke/test_extensibility.gd` | **X1** additive stability vs M00 goldens, **X2** unaccounted channel round-trip (both via throwaway modules in `user://modules/`) | nothing |
| `tests/smoke/test_task0_regressions.gd` | **X12a/b/c** corrupted-golden message, stale-nonce rejection, end-to-end child-exit-1 misdiagnosis fix | spawns a child process |
| `tests/determinism/test_determinism.gd` | D1 (3 backends), D3/D3b, D4, **D5 + X9 lint**, **D5b/B17** module whitelist, D5c, D-table; phase 2 = **D2/X10/X11** vs both golden files | second process |
| `tests/perf/bench_generation.gd` | B0 env, B1 per backend, B2 comparison, **B3 multipass column cost extent 0/1 + recommendation** | nothing |
| `tests/perf/bench_runtime.gd` | R1 hardware, R2 three 60 s flights | **window** |

Results JSON: `docs/reports/test_results.json`. The D2 child writes
`tests/determinism/second_process_result.json` with a `run_nonce` + pid; the file is
**gitignored**, deleted before every spawn, and rejected if the nonce does not match
(Task 0.3, regression-tested by X12b/c).

## 3. Single module, and the windowed paths

```bash
# one module, headless
$GODOT --headless --path . --script res://tools/run_module.gd -- res://tests/smoke/test_spine.gd

# compile-check everything we own (never addons/), warnings are errors
GODOT=$GODOT ./tools/check_scripts.sh

# runtime benchmark (needs a window; ~4 min for 3x60 s flights)
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/run_module.gd -- \
    res://tests/perf/bench_runtime.gd res://src/runtime/world/world.tscn

# the acceptance screenshots (refuses headless; 6 shots incl. HUD pipeline page)
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/capture_screenshots.gd

# captured-mouse routing (S5m3c) on a real window
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/run_module.gd -- res://tests/smoke/test_scene.gd
```

## 4. Regenerating committed evidence (deliberate acts)

```bash
# golden chunk hashes (M00 backends AND multipass) - ONLY when the terrain contract
# changes on purpose; record it in docs/WORLDGEN_CHANGELOG.md.
$GODOT --headless --path . --script res://tools/make_golden_hashes.gd

# addon sha256 baseline - ONLY right after extracting a new official archive
$GODOT --headless --path . --script res://tools/make_addon_manifest.gd -- --force

# API dumps after an engine/extension upgrade
$GODOT --headless --path . --script res://tools/dump_voxel_api.gd
$GODOT --headless --path . --script res://tools/dump_graph_nodes.gd
```

## 5. Reading results honestly

- `BLOCKED` is a first-class status: "needs a window / a GPU / a phone / a human". It never
  fails the run, and every BLOCKED line says how to unblock it.
- A module yielding zero results is a FAIL; a script that fails to parse exits 1 with the
  parse error printed. Silent-green is treated as a harness defect (the reason
  `TestHarness` and `run_module.gd` guard against it).
- Perf evidence always includes the machine (CPU threads, RAM, GPU/renderer, display
  server). On the M01 CI box (2 threads, 1.9 GiB, llvmpipe) absolute numbers are
  BUILD-MACHINE numbers; `B0`/`R1` say so in-band.
- The lint (D5/X9) scans comments-stripped code only, so prose can discuss `randf()`;
  `rng.randf()` on an injected stream is legal, bare `randf()` is not. `layer_lint.gd`
  excludes itself (it contains the banned tokens as data).
