# src/worldgen

World generation modules: biomes and climate (M01), surface shaping, caves (M06), strata
(M05), ores (M07), rivers/erosion (M02+), volcanoes, trees/foliage (M09), structures
(M10). Each will be a deterministic module consuming the seed and a chunk origin and
producing voxel channel writes through the adapter interface.

**Intentionally EMPTY in M00.** M00's terrain lives in the two generator adapters
(`src/adapters/voxel/gen_*_adapter.gd`) precisely so that M01 can replace them with real
modules without touching the runtime. `tests/determinism/test_determinism.gd` check D5b
FAILS the build if any file appears here before its milestone.

Rules when modules land: deterministic only (no `randf(`, `randi(`, `randomize(`,
`Time.get_` - linted by D5), no player-position or frame-count dependence, and no Voxel
Tools classes - only `src/adapters/` may reference Voxel Tools classes; modules express
themselves as graph nodes / channel writes via the adapter interface.
