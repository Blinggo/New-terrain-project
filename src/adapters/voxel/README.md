# src/adapters/voxel

**The ONLY layer allowed to reference Voxel Tools classes** (project rule, ADR-0002).
Everything above sees plain `Node3D` / `Resource` / `Vector3i` / `Dictionary`.

- `i_generator_adapter.gd` - the interface: `build(seed, gen_context) -> VoxelGenerator`,
  `display_name()`, `get_last_build_report()`.
- `gen_noise2d_adapter.gd` - adapter `noise2d`: built-in `VoxelGeneratorNoise2D`
  (a heightmap generator; hardcodes voxel id 1 above `height_start` - recorded limitation,
  proven by `tests/smoke/test_generators.gd` S4g).
- `gen_graph_adapter.gd` - adapter `graph`: `VoxelGeneratorGraph` assembled in code with
  NAMED nodes (`terrain_noise`, `height_remap`, `grass_or_stone_select`, ...), grass/stone
  ids, `OutputType` resolved by name (id 44; absent from the `NodeTypeID` enum).
- `adapter_registry.gd` - id list, F3 cycling, `build_generator()`; `try_create()` for
  error-free probing, `create()` loud on unknown ids.
- `block_library_builder.gd` - builds the `VoxelBlockyLibrary` from
  `content/blocks/blocks.json` in code (no `.tres`, ever). Contains the measured MATERIALS
  findings: `VoxelMesherBlocky` has no material property; a cube model carries exactly one
  material (surface index 0); translucent water therefore deferred to a
  `VoxelBlockyModelMesh` design.
- `terrain_adapter.gd` - owns `VoxelTerrain` + `VoxelMesherBlocky` + `VoxelViewer`;
  applies view distance in VOXELS (`chunks * mesh_block_size`, measured), vertical ratio,
  bounds, collisions; exposes statistics, engine stats, loaded block count, release().
- `chunk_hasher.gd` - `ChunkHasher`: canonical FNV-1a/64 fingerprint of a generated block's
  decompressed TYPE channel (+ header), used by the determinism harness and goldens.

Known-1.7 traps encoded here (see `docs/ARCHITECTURE.md` section 5): mesher/model `Side`
enum orderings differ; graph node ids resolve by name; loaded blocks are not scene
children; `VoxelGeneratorGraph` is RefCounted (never `free()`).
