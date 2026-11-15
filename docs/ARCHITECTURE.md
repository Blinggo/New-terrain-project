# Architecture - VoxelTerrain M00

## 0. What M00 is

A streaming, blocky, **infinite** voxel world rendered in real 3D by Godot 4.7.2 +
Voxel Tools 1.7 (GDExtension), plus the engineering harness (determinism proofs, perf
benchmarks, screenshots, reporting) that every later milestone will be measured with.

World contract: **1 block = 1 m**, Y in `[-64, 320)` (384 blocks tall, 24 data-block rows
of 16), sea level 64, horizontal bounds +/-16 777 216 blocks (engine clamp), mesh block
size 16, TYPE channel forced to 8 bit (halves the payload; 10 block ids fit easily).

Target hardware, in priority order: **low-end Android (3-4 GB RAM, Adreno 610 class)**,
then desktop. Every rendering and memory choice below is made for the phone first.

## 1. The five layers

```
                        +-------------------------------------+
   L5 RUNTIME           | runtime/world  world.tscn world.gd  |  scene, streaming owner,
                        |              world_config.gd        |  config load/validate
                        | runtime/debug  fly_camera.gd         |  desktop+touch camera,
                        |                debug_hud.gd         |  HUD (<0.3 ms/frame)
                        +-------------------+-----------------+
                                            |  Node3D / Resource / Dictionary only
                        +-------------------v-----------------+
   L4 ADAPTERS          | adapters/voxel  terrain_adapter.gd  |  owns VoxelTerrain +
      (ONLY layer that  |                 adapter_registry.gd |  VoxelViewer node graph;
       names Voxel      |                 i_generator_adapter |  generator selection (F3)
       Tools classes)   |                 gen_noise2d_adapter |  two generators behind
                        |                 gen_graph_adapter   |  one interface
                        |                 block_library_builder| code-built library from
                        |                 chunk_hasher.gd     |  blocks.json; FNV-1a chunk
                        +-------------------+-----------------+  fingerprints (T8)
                                            |
              +-----------------------------+----------------------------+
   L3 MODULES | worldgen/  (biomes, climate, caves, ores ... in M01+)    |  EMPTY in M00
   L2 SPINE   | spine/     (cross-module contracts for M01+)             |  EMPTY in M00
   L1 CORE    | core/      hash64.gd  json_data.gd  chunk_origins.gd     |  no deps
              +----------------------------------------------------------+
```

Data flows down as calls, up as plain values. `content/` (blocks.json, world_config.json,
the atlas) is read by L4/L5 through `JsonData`/`WorldConfig`; generation code never reads
files at run time.

## 2. Built vs empty, honestly

| Path                        | M00 state | Why |
|-----------------------------|-----------|-----|
| `src/core/`                 | **built** | FNV-1a 64 hashing, JSON, the fixed 64 chunk origins |
| `src/spine/`                | **empty** | no cross-module contract exists yet; D5b guards it |
| `src/worldgen/`             | **empty** | biomes/climate/caves are M01-M07; D5b guards it |
| `src/adapters/voxel/`       | **built** | the whole Voxel Tools boundary (7 files) |
| `src/runtime/world/`        | **built** | scene + world owner + immutable config |
| `src/runtime/debug/`        | **built** | fly camera (desktop+touch), self-measuring HUD |
| `content/`                  | **built** | 10 blocks, 11-tile generated atlas, world config |
| `tests/`                    | **built** | hash vectors, extension/assets/generator/scene smoke, determinism D1-D5, gen+runtime benches |
| `tools/`                    | **built** | API dump, probes, atlas generator, test runner, screenshot capture, compile check |

## 3. Streaming path (what actually happens at run time)

1. `world.gd::_ready()` loads+validates `WorldConfig`, asks `BlockLibraryBuilder` for a
   `VoxelBlockyLibrary` (10 models, index == block id, one opaque atlas material - see the
   MATERIALS block in `block_library_builder.gd` for why exactly one) and
   `AdapterRegistry` for the configured generator.
2. `TerrainAdapter.create()` builds `VoxelTerrain` (mesher `VoxelMesherBlocky`, library,
   8-bit `VoxelFormat`, bounds, collisions on, `stream` deliberately **unset** -
   persistence is M12) and a `VoxelViewer` parented to the camera. Viewer
   `view_distance` = `view_distance_chunks * mesh_block_size` **voxels** (measured),
   `view_distance_vertical_ratio` 2.0 (measured necessary for flight, see ADR-0003 note
   and `probe_vratio` evidence in the M00 report).
3. VoxelEngine's thread pools generate + mesh 16^3 blocks; the HUD reads real stats from
   `VoxelTerrain.get_statistics()` (7 timing keys) and `VoxelEngine.get_stats()`
   (block_count, voxel payload, task queues).
4. `fly_camera.gd` moves a `CharacterBody3D` (noclip default; gravity/collision toggle N);
   `debug_hud.gd` renders FPS, avg+p95 frame time over 120 frames, draw calls, primitives,
   static/video memory, position, chunk, seed, generator, view distance and the raw
   statistics dict, and measures its own amortised cost against the 0.3 ms budget.

## 4. Determinism architecture

`ChunkHasher` fingerprints the decompressed TYPE channel of each generated block with
`Hash64`; `test_determinism.gd` runs D1 (same seed, same process), D2 (separate process vs
committed goldens), D3/D3b (order independence, incl. a non-uniform chunk), D4 (seed
sensitivity over surface-straddling chunks), D5/D5b/D5c (lint + empty-later-layers +
origin coverage) and prints a hash table. See `docs/adr/ADR-0003`.

## 5. Known engine realities recorded in M00 (do not re-litigate later)

- `VoxelMesherBlocky` has **no material property**; materials arrive via
  `VoxelBlockyLibrary.get_materials()`, and a cube model can carry only **one**
  (surface index 0). Translucent water therefore needs `VoxelBlockyModelMesh` later.
- `VoxelBlockyModel.Side` and `VoxelMesherBlocky.Side` enums differ in ordering; code uses
  the enum constants only.
- `VoxelGeneratorNoise2D` (a `VoxelGeneratorHeightmap`) hardcodes voxel id 1 above
  `height_start`; it cannot express strata/caves/ores. Kept as the cheap F3 baseline.
- `VoxelGraphFunction` node ids must be resolved by **name** (`OutputType` is id 44 and is
  absent from the `NodeTypeID` enum).
- Loaded data blocks are **not** scene children in 1.7; count them via
  `VoxelEngine.get_stats().memory_pools.block_count`.
- `Input.MOUSE_MODE_CAPTURED` does not stick under `--headless`; captured-mouse routing is
  proven windowed only (see `docs/TESTING.md`).

## 6. Deferred (explicitly NOT in M00)

Biomes/climate (M01), seasons/weather/clouds, erosion/rivers (M02+), caves (M06), strata
(M05), ores, volcanoes, trees/foliage (M09), structures (M10), save/load + streams (M12),
multiplayer, distant-terrain LOD (M13), translucent water, `VoxelBlockyTypeLibrary`
migration, GPU generation (`use_gpu_generation`), instancing (`VoxelInstancer`).
The full list with milestone mapping lives in `docs/reports/M00_REPORT.md` section 11.
