# Testing - VoxelTerrain M00

Everything here runs from a clean checkout. The only prerequisite is a Godot 4.7.x binary
with the vendored Voxel Tools extension (already in `addons/zylann.voxel/`).

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

## 2. What the headless runner executes

| Module | Checks | Needs |
|---|---|---|
| `tests/smoke/test_hash64.gd` | S1a-S1g published FNV-1a/64 vectors | nothing |
| `tests/smoke/test_extension.gd` | S2a-S2i extension loaded, version, class set, `.gdextension` compat, Linux-only binaries, dump artifacts, **addon unmodified (sha256 manifest)** | nothing |
| `tests/smoke/test_assets.gd` | S3a-S3k atlas geometry/mipmaps/lossless/sha256/alpha, blocks.json ids, library build, model index==id, per-face tiles, collision, single material | nothing |
| `tests/smoke/test_generators.gd` | S4a-S4l both adapters: class, channel, compile, named nodes, OutputType=44, relief, column solidity, ids, grass thickness, registry cycle, seed sensitivity, per-adapter cost | nothing |
| `tests/smoke/test_scene.gd` | S5 project settings, scene graph, streaming, HUD, injected key/mouse/touch, look math, gravity landing | headless ok; captured-mouse routing = BLOCKED headless |
| `tests/determinism/test_determinism.gd` | D1, D3, D3b, D4, D5, D5b, D5c, D-table (main phase) | nothing |
| second process (`--phase2`) | D2 vs committed `golden_hashes.json` | spawns itself |
| `tests/perf/bench_generation.gd` | B0 env (BLOCKED as device claim on weak CI), B1 per adapter, B2 comparison + M01 recommendation | nothing |
| `tests/perf/bench_runtime.gd` | R0/R1/R2 - 60 s scripted flights at vd 8/6/12 | **window**; BLOCKED headless |

Results JSON: `docs/reports/test_results.json` (and
`tests/determinism/second_process_result.json` for the D2 child).

## 3. Single module, and the windowed paths

```bash
# one module, headless
$GODOT --headless --path . --script res://tools/run_module.gd -- res://tests/smoke/test_scene.gd

# compile-check everything we own (never addons/), warnings are errors
GODOT=$GODOT ./tools/check_scripts.sh

# runtime benchmark: needs a window (real renderer). ~4 min for 3x60 s flights
$GODOT --path . --script res://tools/run_module.gd -- \
    res://tests/perf/bench_runtime.gd res://src/runtime/world/world.tscn
# ...or through the runner on a machine WITH a display:
./tools/run_tests.sh --with-runtime

# on a headless CI box, provide a display with Xvfb:
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/run_module.gd -- \
    res://tests/perf/bench_runtime.gd res://src/runtime/world/world.tscn

# the five acceptance screenshots (refuses to run headless):
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/capture_screenshots.gd

# captured-mouse routing (S5m3c) and injected touch on a real window:
xvfb-run -a -s "-screen 0 1280x720x24" $GODOT --path . \
    --script res://tools/run_module.gd -- res://tests/smoke/test_scene.gd
```

## 4. Regenerating committed evidence (deliberate acts)

```bash
# golden chunk hashes - ONLY when the terrain contract changes on purpose;
# say so in the milestone report.
$GODOT --headless --path . --script res://tools/make_golden_hashes.gd

# addon sha256 baseline - ONLY right after extracting a new official archive
$GODOT --headless --path . --script res://tools/make_addon_manifest.gd          # refuses if present
$GODOT --headless --path . --script res://tools/make_addon_manifest.gd -- --force

# API dumps after an engine/extension upgrade
$GODOT --headless --path . --script res://tools/dump_voxel_api.gd
$GODOT --headless --path . --script res://tools/dump_graph_nodes.gd
```

## 5. Reading results honestly

- `BLOCKED` is a first-class status: "needs a window / a GPU / a phone / a human". It never
  fails the run, and every BLOCKED line says how to unblock it.
- A module that yields **zero** results is reported as FAIL by the harness, and a script
  that fails to parse exits 1 with the parse error printed. Silent-green runs are treated
  as a defect of the harness itself.
- Perf evidence always includes the machine (CPU threads, RAM, GPU/renderer, display
  server). On the M00 CI box (2 threads, 1.9 GiB, llvmpipe, no GPU) absolute numbers are
  BUILD-MACHINE numbers; `B0`/`R1` say this in-band instead of letting anyone quote them as
  phone numbers.
