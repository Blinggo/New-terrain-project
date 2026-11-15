# Architecture - VoxelTerrain (M01 state)

## 0. What the project is

An infinite, deterministic, blocky voxel world in Godot 4.7.2 + Voxel Tools 1.7 (GDExtension),
GDScript only, low-end Android first (3-4 GB RAM, Adreno 610 class). World contract:
1 block = 1 m, Y in `[-64, 320)` (384 tall, 24 data-block rows), sea level 64, horizontal
bounds +/-16 777 216 blocks, mesh block 16, TYPE channel 8 bit.

M00 built streaming + camera + HUD + the determinism/perf harness. **M01 built the
extensibility machinery** every later milestone plugs into: a module spine (registry,
scheduler, blackboard, contracts, field cache) and re-expressed the M00 hills as the first
two modules - without changing one voxel of output (X10: M00 goldens reproduce exactly).

## 1. The layers

```
                        +-------------------------------------+
   L5 RUNTIME           | runtime/world   world.tscn/.gd      |  scene, streaming owner,
                        |                 world_config.gd     |  config v2 (tiers, overrides)
                        | runtime/debug   fly_camera.gd       |  desktop+touch camera
                        |                 debug_hud.gd        |  compact/full/pipeline/off
                        +------------------+------------------+
                                            |  Node3D / Resource / Dictionary only
                        +-------------------v------------------+
   L4 ADAPTERS          | adapters/voxel  terrain_adapter.gd  |  owns VoxelTerrain+Viewer
      (ONLY layer that  |                 adapter_registry.gd |  noise2d | graph | multipass
       names Voxel      |                 gen_*_adapter.gd    |  graph driven by module plan
       Tools classes)   |                 block_library_builder| multipass column evaluator
                        |                 chunk_hasher.gd     |
                        +-------------------+------------------+
                        |  spine contracts (plain Resources/RefCounted, no Voxel ids)
                        +-------------------v------------------+
   L3 MODULES           | worldgen/  planet/hills_v1.gd       |  FieldProvider, PLANET
      (content in       |            surface/grass_stone_v1.gd|  TerrainPass, SURFACE, ext 0
       content/modules) |  (+ user://modules at runtime)      |
   L2 SPINE             | spine/registry  module_registry.gd  |  disk scan, no hardcoded list
                        | spine/scheduler pipeline_scheduler.gd| topo per phase, cycle paths
                        | spine/blackboard gen_blackboard.gd  |  WORLD/REGION/COLUMN channels
                        | spine/fields    field_tile/cache    |  halo tiles, LRU, budgeted
                        | spine/contracts module_definition.. |  ModuleDefinition & friends
                        | spine/executor  pipeline_runner.gd  |  region+column execution
                        +-------------------+------------------+
   L1 CORE              | core/  hash64  json_data  chunk_origins  layer_lint
                        |        rng_streams  fixed_point  channel_id
                        +-------------------------------------+
```

Dependency direction is strictly downward. `src/adapters/` is the only layer naming Voxel
Tools classes; X9/D5 lint enforce it on every test run (`src/core/layer_lint.gd`).

## 2. The blackboard model

Modules never call each other. They publish **named typed channels** into `GenBlackboard`
and read them back by name:

- Scopes: **WORLD** (constants per world), **REGION** (`FieldTile` grids per 1024x1024
  blocks, cached in `FieldCache` keyed by channel+region+producer version), **COLUMN**
  (per 16x16 column, cleared each column).
- **Unknown channels are legal.** `field.ice_thickness` can be published by a module no
  other file has heard of; nothing central registers channels (X2 proves the round-trip).
- Reading a `requires` channel nobody produced is a **boot error** naming consumer, channel
  and the resolved pipeline (scheduler), never a silent zero.
- Type flips on a channel are errors naming both observed types.
- `debug_dump()` lists channel, producer, type, scope and tile dimensions; the HUD
  pipeline page renders the resolved order plus per-module timings.

## 3. Resolved pipeline (M01, seed 20260814)

```
order  id                      v  phase    requires        provides          extent  factor
  1    planet.hills_v1         1  PLANET   []              [field.height]    -       -
  2    surface.grass_stone_v1  1  SURFACE  [field.height]  []                 0      1
column multiplication factor: 1   (sum over TerrainPass of (1+2*extent)^2)
```

Resolution rules: phases run in enum order; inside a phase, topological order over
same-phase requires/provides edges; tiebreak `priority` ascending then `id` lexicographic
(X4: 50 shuffled inputs resolve identically); cycles print their path (X5); cross-phase
back-edges are errors.

## 4. Backends (three, selectable in `content/world_config.json`)

| id | engine object | how modules run | extent support | cost (this box, B1/B3) |
|---|---|---|---|---|
| `noise2d` | VoxelGeneratorNoise2D | not module-driven (M00 baseline, hardcoded id 1) | 0 | 0.005 ms/chunk |
| `graph` (default) | VoxelGeneratorGraph | adapter pushes resolved module PARAMS into named nodes; compiled | 0 only | 0.041 ms/chunk, 1.0 ms/column |
| `multipass` | VoxelGeneratorScript (self-hosted evaluator) | PipelineRunner runs FieldProviders into tiles, TerrainPasses per column; pass B extent 1 reads neighbour columns | 0 and 1 | 1.4 ms/chunk, 30-34 ms/column |

`VoxelGeneratorMultipassCB` itself is **not scriptable** in the 1.7 GDExtension
(`VoxelToolMultipassGenerator`: "Can't inherit from a virtual class"; no passes property -
`tools/probe_multipass2.gd`), which is why the multipass backend self-hosts the pattern and
why B3 recommends the graph as the default with multipass reserved for true cross-chunk
features (M08/M10).

## 5. Determinism architecture (unchanged from M00, extended)

`Hash64` FNV-1a 64 goldens over the decompressed TYPE channel; 64 fixed origins; D2 compares
a second process against committed goldens - now **two** golden files (M00 backends +
multipass), nonce-validated so a stale child file can never false-PASS (Task 0.3, X12).
All randomness flows through `RngStreams` (domain-hashed seeds); decisions compare
quantised integers via `FixedPoint`; `Time.*`/`rand*()` are linted out of core/spine/
worldgen/adapters.

## 6. Known engine realities (M00 list, still true)

viewer distance in voxels; cube models carry one material; mesher/model `Side` enums differ;
graph node ids by name (`OutputType`=44); loaded blocks are not scene children;
`MOUSE_MODE_CAPTURED` needs a window; MultipassCB not scriptable (new, M01).

## 7. Deferred (not built)

Biomes/climate (M01-next), erosion/rivers (M02+), caves/strata/ores/volcanoes (M05-M08),
trees/foliage (M09), structures (M10), save/load (M12), multiplayer, distant LOD (M13),
translucent water, VoxelBlockyTypeLibrary migration, GPU generation, disk field cache (M02),
on-device Android validation. Full list with milestone mapping: M00/M01 reports section 11.
