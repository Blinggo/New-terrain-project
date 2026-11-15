# ADR-0003 - Determinism contract and its enforcement

- Status: Accepted (M00)
- Date: 2026-11-14
- Deciders: M00 implementation

## Context

Hard rule #5: terrain must be a pure function of (seed, chunk origin, generator
configuration). A single `randf()`, a `Time.get_ticks` in generation code, or a dependency
on node order would corrupt save games, multiplayer and replays in later milestones - and
such bugs are invisible until then. M00 must therefore make determinism *measured*, not
asserted.

## Decision

1. **All randomness flows from one explicit integer seed** (`content/world_config.json`,
   default `20260814`). Noise objects are seeded from it; nothing else introduces entropy.
   The F5 "new seed" debug key derives its value from wall-clock in the *runtime/debug*
   layer only, and is lint-excluded because it never feeds generation without being stored
   back into the config as an explicit integer.
2. **Hashing for golden files uses `Hash64` (FNV-1a 64)**, implemented in `src/core/hash64.gd`
   and validated against published vectors (`tests/smoke/test_hash64.gd`). Godot's
   built-in `hash()` is forbidden for goldens because its algorithm is not part of any
   stability guarantee.
3. **The unit of determinism is the 16x16x16 data block**, hashed as: canonical header
   (origin, block size, channel depth) + the decompressed TYPE channel bytes. `ChunkHasher`
   also reports uniformity and a value histogram so a degenerate (all-air) chunk can never
   masquerade as evidence.
4. **The 64 chunk origins are fixed and auditable** (`src/core/chunk_origins.gd`): 8
   hand-written extremes, 24 inside the terrain surface band, 32 spread over +/-8 million
   blocks and every block row. The surface band exists because in a 384-block-tall world a
   purely spread origin set is dominated by all-air/all-solid chunks that hash identically
   for *any* seed - which made the first D4 run change only 3/64 hashes and nearly produced
   a worthless PASS.
5. **D2 compares against a committed golden file** (`tests/determinism/golden_hashes.json`)
   produced by a genuinely separate process (`tools/run_tests.gd --phase2`), so a change in
   generator behaviour fails the build even when both in-process runs agree.
6. **Environment drift is reported, not failed**: if the second process runs a different
   Godot build or block size, D2 records it as information, because a golden mismatch under
   a changed engine is expected, not a determinism bug.

## Consequences

- Regenerating goldens is a deliberate act (`tools/make_golden_hashes.gd`) that must be
  justified in the milestone report.
- Weak evidence is treated as a failure mode of the test itself: D3b re-runs order
  independence on a non-uniform chunk, and D4 requires >=90% of *surface-straddling* chunks
  to change when the seed changes. Both were added after the naive versions passed while
  proving almost nothing.
- The lint (D5) is a build gate, not a code review habit.
