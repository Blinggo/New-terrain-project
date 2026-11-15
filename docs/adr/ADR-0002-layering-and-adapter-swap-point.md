# ADR-0002 - Layering and the generator adapter swap point

- Status: Accepted (M00)
- Date: 2026-11-14
- Deciders: M00 implementation

## Context

Fifteen milestones will pile biome, climate, cave, ore, structure and save-game logic on top
of M00's streaming renderer. Two risks dominate: (a) Voxel Tools class names leaking into
every layer, making an engine or extension swap a project-wide rewrite; (b) worldgen code
accidentally depending on runtime state (frame count, player position, wall clock), which
would silently break determinism (hard rule #5).

## Decision

Five layers, dependency direction strictly downward:

1. **Core** (`src/core/`) - dependency-free primitives: `Hash64` (FNV-1a 64), JSON helpers,
   the fixed chunk-origin list. No Godot-scene, no time, no Voxel Tools.
2. **Spine** (`src/spine/`) - cross-module contracts for later milestones. Empty in M00 by
   design; `tests/determinism/test_determinism.gd` D5b fails the build if it is not.
3. **Modules / worldgen** (`src/worldgen/`) - future biome/climate/cave modules. Empty in
   M00, same guard.
4. **Adapters** (`src/adapters/voxel/`) - the ONLY layer allowed to name a Voxel Tools
   class. Contains the `IGeneratorAdapter` interface, two generator adapters (`noise2d`,
   `graph`), the code-built block library, the chunk hasher and `TerrainAdapter`, which
   owns the `VoxelTerrain` + `VoxelViewer` node graph and exposes it upward as plain
   `Node3D` / `Resource` / `Dictionary` values.
5. **Runtime** (`src/runtime/world/`, `src/runtime/debug/`) - scene, camera, HUD, config.
   Talks to adapters only. `world.gd` never names a Voxel class; the scene file keeps an
   empty `VoxelRoot` node that code fills.

Generator selection is data (`content/world_config.json` -> `generator`: `noise2d` |
`graph`) resolved through `AdapterRegistry`, and cyclable at runtime with F3.

## Consequences

- The layering rule is mechanically enforced: `tests/smoke/*` scans every `.gd` outside
  `src/adapters/` for Voxel Tools identifiers (see `docs/CONVENTIONS.md`), and each of the
  four source folders carries a `README.md` restating the rule.
- Swapping the terrain backend (a C++ GDExtension, a native module, another engine) is a
  rewrite of `src/adapters/voxel/` only.
- Because adapters are the only Voxel-facing code, the determinism lint (D5) can scan just
  `src/worldgen/`, `src/adapters/`, `src/core/` for banned calls (`randf(`, `randi(`,
  `Time.get_`, `randomize(`) and still cover everything that touches generation. Runtime
  debug code (HUD timing, F5 seed, screenshot names) may use `Time.*` and is never scanned.
- Cost: upward layers see `Resource`/`Node3D`/`Dictionary` instead of rich types, so some
  convenience is lost at the boundary. Accepted deliberately.
