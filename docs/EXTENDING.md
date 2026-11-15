# EXTENDING the worldgen - zero-edit recipes

The M01 acceptance bar: adding a biome, a rock type, a landmark, a climate variable, or a
stage nobody planned must require **zero edits to existing files**. Every recipe below lists
exactly the files you CREATE and states that nothing else changes. The machinery that makes
this true is the spine: `ModuleRegistry` (disk scan, no hardcoded list), `PipelineScheduler`
(deps from `requires`/`provides`), `GenBlackboard` (unknown channels are legal) and
`RngStreams` (independent deterministic randomness per domain).

Proof this is real, not aspirational: `tests/smoke/test_extensibility.gd` X1 registers a
no-op module at runtime and re-verifies all 64 M00 golden hashes; X2 round-trips a channel
that appears in no spec anywhere. Both pass.

Common rules for every new module file:

- Script extends one of `FieldProvider`, `TerrainPass`, `FeatureStamp` (src/spine/contracts/).
- `.tres` lives in `res://content/modules/` (shipped) or `user://modules/` (mods, scanned
  second). The registry picks it up on next boot or `registry.reload()`.
- No Voxel Tools identifiers, no `randf()/randi()/Time.*` (linted by D5/X9 on every run).
- Randomness only via `ctx.stream(domain)` / `ctx.chance(domain, x, z, p)`.
- Decisions compare quantised integers (`FixedPoint.qcompare`), never raw floats.

---

## Recipe 1 - Add a biome (future M01+, shown now as machinery)

CREATE:
1. `src/worldgen/biome_tundra_v1.gd` - a `FieldProvider`, phase `CLIMATE`,
   `provides = [&"biome.tundra_weight"]`; `compute_region(ctx)` fills a FLOAT tile from
   climate channels it `requires` (e.g. `field.temperature`, once M01 lands) and publishes it.
2. `content/modules/biome_tundra_v1.tres` - instances the script, sets `id`, `version`,
   `phase`, `requires`, `provides`, `params` (thresholds).

EDIT: nothing. The scheduler slots it into CLIMATE after its producers (topological order
inside the phase, tiebreak priority then id). Consumers that `requires`
`biome.tundra_weight` start seeing it without knowing the producer exists.

## Recipe 2 - Add a rock type

CREATE:
1. `content/blocks/blocks.json` gains an entry (data, not code) - id, atlas tiles,
   collision. The library rebuilds from JSON at boot (`BlockLibraryBuilder`).
2. `src/worldgen/strata_basalt_v1.gd` - a `TerrainPass`, phase `GEOLOGY`, `extent 0`,
   `requires = [&"field.height"]` (or a future strata channel); `apply(ctx)` writes the new
   block id where its quantised rule fires.
3. `content/modules/strata_basalt_v1.tres`.

EDIT: nothing (atlas regeneration is a tool run, `tools/generate_placeholder_atlas.gd`, not
a hand edit; until M05 the pass can reuse an existing tile).

## Recipe 3 - Add a landmark (boulder field, ruin, arch)

CREATE:
1. `src/worldgen/feature_boulders_v1.gd` - a `FeatureStamp`, phase `FEATURE`,
   `cell_size = 64`; `candidates_near(ctx)` returns deterministic sites from the 3x3 cell
   lookup using `ctx.chance(&"feature.boulders", cell_x, cell_z, density)`;
   `evaluate(ctx, pos)` returns analytic falloff density.
2. `content/modules/feature_boulders_v1.tres`.

EDIT: nothing. Extent-0 stamps compile into the graph backend; if the landmark ever needs
cross-chunk volume, it becomes a multipass pass instead (see B3/rec: multipass is reserved
for exactly this).

## Recipe 4 - Add a climate variable

CREATE:
1. `src/worldgen/climate_continentality_v1.gd` - `FieldProvider`, phase `CLIMATE`,
   `provides = [&"field.continentality"]`; pure maths over position and existing channels.
2. `content/modules/climate_continentality_v1.tres`.

EDIT: nothing. Any module may immediately `requires = [&"field.continentality"]`; if a
consumer is registered without a producer the scheduler fails at boot naming both - a
silent zero is impossible.

## Recipe 5 - Add a stage nobody planned

The phase enum has ten slots (PLANET...DECORATE), but a genuinely new stage needs no enum
change either:

CREATE:
1. A `FieldProvider` or `TerrainPass` in an existing phase whose `requires`/`provides`
   express the new dependency (the graph is built from channels, not phases; phases only
   group execution).
2. Its `.tres`.

If the new stage truly needs its own phase constant, that is a one-line enum addition in
`module_definition.gd` plus this document - the only recipe that touches an existing file,
and it touches the CONTRACT, not any module.

EDIT: `src/spine/contracts/module_definition.gd` (enum only). Recorded here so the
exception is visible.

---

## What protects you

| Mistake | What happens |
|---|---|
| Two modules provide one channel | boot error naming both ids (scheduler) |
| `requires` with no producer | boot error naming consumer, channel and resolved pipeline (X6) |
| Dependency cycle | boot error printing the cycle path `a -> c -> b -> a` (X5) |
| Duplicate module id | registry error naming BOTH .tres paths (X7) |
| Type flip on a channel | blackboard error naming both type names |
| Reading a channel nobody published | loud error, never a silent zero |
| `randf()` / `Time.get_` in worldgen | D5/X9 lint FAILs the build |
| Voxel identifier outside adapters | X9 lint FAILs the build |
| New module perturbs old terrain | X1 additive-stability FAILs (64 goldens re-checked) |
