# src/spine

Cross-module contracts for later milestones (biome registry, climate channels, event bus
between worldgen modules and the runtime).

**Intentionally EMPTY in M00.** Nothing in M00 needs a cross-module contract yet, and an
empty spine is what keeps M00 from smuggling in M01+ design: `tests/determinism/
test_determinism.gd` check D5b FAILS the build if any file appears here or in
`src/worldgen/` before its milestone.

When M01 adds the first contract, it goes here as a `class_name`d interface with no
implementation, and this README gains a one-line entry per contract.

Rule reminder: only `src/adapters/` may reference Voxel Tools classes. Spine contracts
must stay engine-agnostic so the adapter swap point (ADR-0002) keeps working.
