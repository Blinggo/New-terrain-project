# ADR-0004 - Spine blackboard as the only module coupling; multipass verdict

- Status: Accepted (M01)
- Date: 2026-11-15

## Context

M01's acceptance bar is that adding a biome, rock, landmark, climate variable or unplanned
stage requires zero edits to existing files, empirically tested (X1/X2). Two coupling
styles were possible: direct module calls with a central registry of known channels (fast,
but every new idea edits a list), or a blackboard of named typed channels with dependency
resolution from requires/provides (slightly more indirection, but additions are pure
additions). Separately, M02/M08/M10 need to know NOW whether neighbour-aware generation is
affordable, i.e. whether `VoxelGeneratorMultipassCB` is a viable backend.

## Decision

1. **Blackboard coupling.** Modules publish/read named typed channels in three scopes
   (WORLD/REGION/COLUMN). Unknown channels are legal; missing producers are boot errors;
   type flips are errors naming both types. The scheduler resolves order purely from
   requires/provides within fixed phases.
2. **Modules are data.** A module is a `.tres` instancing a contract script; the registry
   scans `res://content/modules/**` and `user://modules/**`. No hardcoded list anywhere.
3. **Graph stays default; multipass is a specialist.** Measured (B3, single-threaded, this
   2-thread box): graph 1.0 ms/column vs self-hosted multipass 30.1 ms/column at extent 0
   and 33.8 ms/column with one extent-1 pass (~30x). `VoxelGeneratorMultipassCB` is not
   scriptable in the 1.7 GDExtension (virtual class, no passes property), so there is no
   engine-accelerated multipass path, and it lacks LOD (M13 needs LOD). Multipass therefore
   remains selectable for genuine cross-chunk features only.
4. **Field tiles at column resolution.** `field.height` tiles sample once per column
   (spacing 16, halo 2): exact for column decisions, ~74 KB per region tile instead of
   ~4 MB, keeping the 24 MB low-tier cache budget meaningful.

## Consequences

- Additive stability is testable: X1 re-checks all 64 M00 graph goldens after registering a
  no-op module; it passes, so "adding a module" provably cannot perturb existing terrain.
- The graph backend reads module PARAMS (structure changed in M01, maths did not); M00
  goldens reproduce bit-for-bit (X10/D2).
- Boot can fail loudly (cycle paths, missing producers, duplicate ids) - all three are
  tested (X5/X6/X7), so mod authors get actionable errors instead of silent nothing.
- Cost: GDScript module execution is ~30x the compiled graph; milestones must keep hot
  maths in graph nodes or analytic stamps and reserve multipass for cross-chunk needs.
