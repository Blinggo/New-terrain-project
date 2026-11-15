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


## M01-fix / T5 - Deterministic fingerprint of an arbitrary Variant graph (used for module
## parameter fingerprints in cache keys and build reports).
##
## Rules that make it stable across processes and machines:
##   * Dictionary keys are SORTED before hashing, so insertion order cannot matter.
##   * float and int are hashed through their canonical decimal string form, so 3 and 3.0
##     differ (they are different parameters) but 0.1 always hashes the same.
##   * Arrays hash in order; PackedArrays hash their bytes.
##   * Anything else (Object/Resource/Callable/...) hashes its type name plus, for
##     Resources, their class + resource path, never an instance address. Addresses would
##     make the fingerprint change between runs and silently invalidate every cache.
## Returns 0 only for a null value.
static func hash_variant(value: Variant) -> int:
	var h := FNV64_OFFSET_BASIS
	return _hash_variant_into(h, value, 0)


static func _hash_variant_into(h: int, value: Variant, depth: int) -> int:
	if depth > 32:
		return hash_combine(h, hash_string("<too_deep>"))
	match typeof(value):
		TYPE_NIL:
			return hash_combine(h, hash_string("nil"))
		TYPE_BOOL:
			return hash_combine(h, hash_string("b:%s" % ("1" if bool(value) else "0")))
		TYPE_INT:
			return hash_combine(h, hash_string("i:%d" % int(value)))
		TYPE_FLOAT:
			return hash_combine(h, hash_string("f:%s" % str(float(value))))
		TYPE_STRING:
			return hash_combine(h, hash_string("s:%s" % String(value)))
		TYPE_STRING_NAME:
			return hash_combine(h, hash_string("n:%s" % String(value)))
		TYPE_NODE_PATH:
			return hash_combine(h, hash_string("p:%s" % String(value)))
		TYPE_VECTOR2:
			var v2: Vector2 = value
			return hash_combine(h, hash_string("v2:%s,%s" % [str(v2.x), str(v2.y)]))
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			return hash_combine(h, hash_string("v2i:%d,%d" % [v2i.x, v2i.y]))
		TYPE_VECTOR3:
			var v3: Vector3 = value
			return hash_combine(h, hash_string("v3:%s,%s,%s" % [str(v3.x), str(v3.y), str(v3.z)]))
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			return hash_combine(h, hash_string("v3i:%d,%d,%d" % [v3i.x, v3i.y, v3i.z]))
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return hash_combine(h, hash_string("v4:%s" % str(value)))
		TYPE_RECT2, TYPE_RECT2I:
			return hash_combine(h, hash_string("r2:%s" % str(value)))
		TYPE_COLOR:
			var c: Color = value
			return hash_combine(h, hash_string("c:%s,%s,%s,%s" % [str(c.r), str(c.g), str(c.b), str(c.a)]))
		TYPE_PACKED_BYTE_ARRAY:
			var pb: PackedByteArray = value
			return hash_combine(h, hash_bytes(pb))
		TYPE_PACKED_INT32_ARRAY:
			var pi: PackedInt32Array = value
			var acc := h
			for x in pi:
				acc = hash_combine(acc, hash_int(x))
			return hash_combine(acc, hash_string("pi32"))
		TYPE_PACKED_INT64_ARRAY:
			var pi64: PackedInt64Array = value
			var acc64 := h
			for x in pi64:
				acc64 = hash_combine(acc64, hash_int(int(x)))
			return hash_combine(acc64, hash_string("pi64"))
		TYPE_PACKED_FLOAT32_ARRAY:
			var pf: PackedFloat32Array = value
			var accf := h
			for x in pf:
				accf = hash_combine(accf, hash_string(str(float(x))))
			return hash_combine(accf, hash_string("pf32"))
		TYPE_PACKED_FLOAT64_ARRAY:
			var pf64: PackedFloat64Array = value
			var accf64 := h
			for x in pf64:
				accf64 = hash_combine(accf64, hash_string(str(float(x))))
			return hash_combine(accf64, hash_string("pf64"))
		TYPE_PACKED_STRING_ARRAY:
			var ps: PackedStringArray = value
			var accs := h
			for x in ps:
				accs = hash_combine(accs, hash_string(String(x)))
			return hash_combine(accs, hash_string("ps"))
		TYPE_ARRAY:
			var arr: Array = value
			var acca := hash_combine(h, hash_string("arr:%d" % arr.size()))
			for x in arr:
				acca = _hash_variant_into(acca, x, depth + 1)
			return acca
		TYPE_DICTIONARY:
			var d: Dictionary = value
			var keys: Array = d.keys()
			keys.sort_custom(func(a, b): return str(a) < str(b))
			var accd := hash_combine(h, hash_string("dict:%d" % keys.size()))
			for k in keys:
				accd = hash_combine(accd, hash_string("k:%s" % str(k)))
				accd = _hash_variant_into(accd, d[k], depth + 1)
			return accd
		TYPE_OBJECT:
			var obj := value as Object
			if obj == null:
				return hash_combine(h, hash_string("obj:null"))
			if obj is Resource:
				var res := obj as Resource
				return hash_combine(h, hash_string("res:%s@%s" % [res.get_class(), res.resource_path]))
			return hash_combine(h, hash_string("obj:%s" % obj.get_class()))
		_:
			return hash_combine(h, hash_string("t%d:%s" % [typeof(value), str(value)]))
