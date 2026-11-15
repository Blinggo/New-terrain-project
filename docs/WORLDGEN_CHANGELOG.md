# WORLDGEN CHANGELOG

Every change to world-generation code or data, with whether the OUTPUT changed. A milestone
that changes terrain maths must say so here and regenerate goldens deliberately (see
`docs/TESTING.md` section 4); a milestone that only restructures must prove output did not
change (golden hashes identical).

| Date | Milestone | Change | Output changed? | Evidence |
|---|---|---|---|---|
| 2026-11-14 | M00 | Initial hills: `VoxelGeneratorNoise2D` (`noise2d`) and code-built `VoxelGeneratorGraph` (`graph`); 10-block library; 384-tall world, sea 64 | n/a (first goldens) | `tests/determinism/golden_hashes.json` committed |
| 2026-11-15 | M01 | Hills re-expressed as spine modules `planet.hills_v1` (FieldProvider, PLANET) + `surface.grass_stone_v1` (TerrainPass, SURFACE, extent 0). Graph backend now reads its parameters from the resolved module plan instead of `content/world_config.json gen_params`. Same noise maths, same constants | **NO** - all 128 M00 hashes (noise2d+graph) reproduce bit-for-bit | D2 `192/192` incl. multipass; X1 additive stability PASS |
| 2026-11-15 | M01 | New backend `multipass`: self-hosted column passes (extent 0 surface + extent 1 cliff demo) over `VoxelGeneratorScript`, because `VoxelGeneratorMultipassCB` is not scriptable in the 1.7 GDExtension | NEW output (own goldens); 55/64 columns match the graph, deltas are exactly the cliff-rule columns | `tests/determinism/golden_hashes_multipass.json`; X11 via D2 second process |
| 2026-11-15 | M01 | `quality_tier` now owns budgets (view 6/8/12 chunks, field cache 24/48/96 MB); `view_distance_chunks` became an override of the tier default (shipped config keeps 8 as an explicit override, so default world is unchanged) | NO (override preserves M00 view distance) | S5j 499 blocks at vd8; B14 unit checks in `test_spine`/config validation |
| 2026-11-15 | M01 | Field tiles sample height at spacing 16 (one sample per column, exact) instead of per-voxel; halo 2 for future stencils | NO for graph (tiles unused by it); multipass uses tiles | S6b sampling tests; X8 bit-identical recompute |
