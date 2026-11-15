class_name Hash64
extends RefCounted
## src/core/hash64.gd
##
## FNV-1a 64-bit, implemented by hand.
##
## WHY NOT Godot's `hash()`: it is not contractually stable across engine versions or
## platforms, so it cannot be used for committed golden values (milestone rule T8).
## FNV-1a is a published, fixed algorithm: same input bytes -> same output forever.
##
## LAYER: core. Engine-agnostic, headless-safe, no Voxel Tools references, no randomness,
## no time, no I/O. Integer arithmetic only.
##
## GDScript `int` is a signed 64-bit value and wraps on overflow (two's complement), which
## is exactly the modular 2^64 arithmetic FNV-1a specifies. We therefore need no masking.

## 0xcbf29ce484222325 written as a signed int64 (the unsigned literal does not fit).
const FNV64_OFFSET_BASIS: int = -3750763034362895579
## 0x00000100000001B3
const FNV64_PRIME: int = 1099511628211


## Hash an arbitrary byte buffer. This is the primitive everything else funnels through.
static func hash_bytes(data: PackedByteArray) -> int:
	var h: int = FNV64_OFFSET_BASIS
	for i in data.size():
		h = h ^ int(data[i])
		h = h * FNV64_PRIME
	return h


## Hash a 64-bit integer, little-endian, so the result never depends on host endianness.
static func hash_int(value: int) -> int:
	var b := PackedByteArray()
	b.resize(8)
	var v := value
	for i in 8:
		b[i] = v & 0xFF
		v = v >> 8
	return hash_bytes(b)


static func hash_string(value: String) -> int:
	return hash_bytes(value.to_utf8_buffer())


## Order-sensitive combination of two hashes. Not commutative on purpose:
## combine(a, b) != combine(b, a), so field order is part of the hash.
static func hash_combine(seed_hash: int, value_hash: int) -> int:
	var h: int = seed_hash
	for i in 8:
		h = h ^ ((value_hash >> (i * 8)) & 0xFF)
		h = h * FNV64_PRIME
	return h


## Fold a Vector3i chunk origin into a running hash. Written out manually (not via
## var_to_str) so it cannot be affected by any formatting change in the engine.
static func hash_vec3i(h: int, v: Vector3i) -> int:
	h = hash_combine(h, hash_int(v.x))
	h = hash_combine(h, hash_int(v.y))
	h = hash_combine(h, hash_int(v.z))
	return h


## Deterministic 32-bit-range integer from up to 4 inputs. Used for the placeholder
## texture atlas (per-pixel variation) so the atlas is byte-identical on every machine.
## Returns a value in [0, 2^31) - always non-negative, never uses randi().
static func hash_range(i0: int, i1: int = 0, i2: int = 0, i3: int = 0) -> int:
	var h := hash_int(i0)
	h = hash_combine(h, hash_int(i1))
	h = hash_combine(h, hash_int(i2))
	h = hash_combine(h, hash_int(i3))
	return (h >> 32) & 0x7FFFFFFF


## Fixed-width lowercase hex of the 64-bit two's-complement value (16 digits).
## `>>` in GDScript is an arithmetic shift, so negative hashes correctly render their
## high bits as f...f. Verified against known FNV-1a test vectors in
## tests/smoke/test_hash64.gd.
static func to_hex(value: int) -> String:
	const DIGITS := "0123456789abcdef"
	var out := ""
	var v := value
	for i in 16:
		out = DIGITS[v & 0xF] + out
		v = v >> 4
	return out


## Decimal string form. This is what we commit in golden_hashes.json: unambiguous,
## no dependence on formatting flags, diff-friendly.
static func to_dec(value: int) -> String:
	return str(value)
