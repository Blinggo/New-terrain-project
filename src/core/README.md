# src/core

Dependency-free primitives every other layer may use.

- `hash64.gd` - `Hash64`: FNV-1a 64-bit hashing (`hash_int`, `hash_bytes`, `hash_combine`,
  `hash_vec3i`, `to_hex`, `to_dec`). The ONLY hash used for golden files and chunk
  fingerprints; Godot's `hash()` is forbidden for that (no stability guarantee).
- `json_data.gd` - `JsonData`: typed, failure-tolerant JSON load/save and dict accessors.
- `chunk_origins.gd` - `ChunkOrigins`: the fixed, auditable list of 64 chunk origins
  (8 hand-written extremes, 24 surface-band, 32 wide-range) shared by the determinism
  harness and the golden-file generator so both can never drift apart.

Rules: no Voxel Tools classes, no scene-tree dependence, no `Time.*`, no `rand*()`, no
dictionary-iteration-order dependence. Everything here is a pure function of its inputs.
Only `src/adapters/` may reference Voxel Tools classes - this folder does not and must not.
