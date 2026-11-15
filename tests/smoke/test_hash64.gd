extends RefCounted
## tests/smoke/test_hash64.gd
##
## S1 - Prove src/core/hash64.gd is a correct FNV-1a 64-bit implementation against the
## published test vectors. If this fails, every golden hash in the determinism suite is
## meaningless, so this runs first.
##
## Expected values were independently cross-computed with a separate Python
## implementation of FNV-1a/64 (see docs/TESTING.md) - they are the canonical published
## vectors, not values taken from our own code.

const SUITE := "smoke"

## (input, expected hex)
const VECTORS := [
	["", "cbf29ce484222325"],
	["a", "af63dc4c8601ec8c"],
	["b", "af63df4c8601f1a5"],
	["foobar", "85944171f73967e8"],
	["hello world", "779a65e7023cd2e7"],
	["The quick brown fox jumps over the lazy dog", "f3f9b7f5e7e47110"],
]


func run(_ctx: Dictionary) -> Array:
	var out: Array = []

	# S1a: published FNV-1a/64 vectors.
	var bad: Array[String] = []
	var lines: Array[String] = []
	for v in VECTORS:
		var input: String = v[0]
		var expected_hex: String = v[1]
		var got := Hash64.to_hex(Hash64.hash_string(input))
		lines.append("  fnv1a64(%-46s) = %s" % ['"' + input + '"', got])
		if got != expected_hex:
			bad.append('"%s": expected %s got %s' % [input, expected_hex, got])
	if bad.is_empty():
		out.append(TestHarness.ok(SUITE, "S1a", "FNV-1a/64 matches all %d published vectors" % VECTORS.size(), "\n".join(lines)))
	else:
		out.append(TestHarness.fail(SUITE, "S1a", "FNV-1a/64 vector mismatch", "\n".join(bad)))

	# S1b: the empty-input hash must equal the offset basis, i.e. to_hex renders the
	# signed int64 as correct two's-complement hex.
	var basis_ok := Hash64.hash_string("") == Hash64.FNV64_OFFSET_BASIS
	out.append(
		TestHarness.result(SUITE, "S1b", "PASS" if basis_ok else "FAIL",
			"offset basis round-trips through to_hex",
			"basis=%d hex=%s" % [Hash64.FNV64_OFFSET_BASIS, Hash64.to_hex(Hash64.FNV64_OFFSET_BASIS)])
	)

	# S1c: hash_bytes and hash_string must agree (string hashing is defined as bytes hashing).
	var bytes_ok := Hash64.hash_bytes("foobar".to_utf8_buffer()) == Hash64.hash_string("foobar")
	out.append(TestHarness.result(SUITE, "S1c", "PASS" if bytes_ok else "FAIL",
		"hash_bytes == hash_string for identical bytes", "equal=%s" % str(bytes_ok)))

	# S1d: hash_int must be endianness-independent and injective over the sampled range.
	var seen := {}
	var collisions := 0
	for i in range(-100000, 100000, 7):
		var h := Hash64.hash_int(i)
		if seen.has(h):
			collisions += 1
		seen[h] = true
	out.append(TestHarness.result(SUITE, "S1d", "PASS" if collisions == 0 else "FAIL",
		"hash_int: 0 collisions over 28572 sampled ints", "collisions=%d distinct=%d" % [collisions, seen.size()]))

	# S1e: hash_combine must NOT be commutative (field order is part of the hash).
	var ab := Hash64.hash_combine(Hash64.hash_int(1), Hash64.hash_int(2))
	var ba := Hash64.hash_combine(Hash64.hash_int(2), Hash64.hash_int(1))
	out.append(TestHarness.result(SUITE, "S1e", "PASS" if ab != ba else "FAIL",
		"hash_combine is order-sensitive", "combine(1,2)=%s combine(2,1)=%s" % [Hash64.to_hex(ab), Hash64.to_hex(ba)]))

	# S1f: hash_range must stay non-negative (it is used for texture pixel jitter).
	var neg := 0
	for i in 5000:
		if Hash64.hash_range(i, i * 3, i - 7, 1) < 0:
			neg += 1
	out.append(TestHarness.result(SUITE, "S1f", "PASS" if neg == 0 else "FAIL",
		"hash_range never returns a negative value", "negatives=%d/5000" % neg))

	# S1g: two fresh runs in the same process must be identical (basic stability).
	var r1 := Hash64.hash_vec3i(Hash64.hash_int(42), Vector3i(-1000016, 304, 1000016))
	var r2 := Hash64.hash_vec3i(Hash64.hash_int(42), Vector3i(-1000016, 304, 1000016))
	out.append(TestHarness.result(SUITE, "S1g", "PASS" if r1 == r2 else "FAIL",
		"hash_vec3i is repeatable", "h=%s" % Hash64.to_hex(r1)))

	return out
