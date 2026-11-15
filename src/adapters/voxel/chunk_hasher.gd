class_name ChunkHasher
extends RefCounted
## src/adapters/voxel/chunk_hasher.gd
##
## M00 / T8 - Turns generated voxel data into a stable 64-bit fingerprint.
##
## LAYER: adapters. It touches VoxelBuffer, so it lives here and not in tests/ or src/core.
##
## The fingerprint is deliberately canonical, so it cannot drift between machines, engine
## versions or call orders:
##   1. the TYPE channel is decompressed first (a uniform block otherwise hashes to a single
##      byte, which would hide real differences),
##   2. the raw channel bytes are hashed with FNV-1a/64 (src/core/hash64.gd),
##   3. the block size, channel depth, uniformity flag and the chunk origin are folded in,
##      so a hash can never collide across a differently-shaped buffer or a moved chunk.
##
## Godot's built-in hash() is NOT used anywhere: it is not guaranteed stable across engine
## versions, and golden values must outlive an engine upgrade.

## Hash one chunk. Returns:
##   {"hash": int, "hex": String, "dec": String, "bytes": int, "uniform": bool,
##    "depth": int, "origin": Vector3i, "non_air": int, "value_histogram": Dictionary}
static func hash_chunk(generator: Resource, origin: Vector3i, block_size: int = 16, type_depth_bits: int = 8) -> Dictionary:
	var format := VoxelFormat.new()
	format.type_depth = VoxelBuffer.DEPTH_8_BIT if type_depth_bits <= 8 else VoxelBuffer.DEPTH_16_BIT

	var buffer: VoxelBuffer = format.create_buffer(Vector3i(block_size, block_size, block_size))
	# The generator is the only source of data. No time, no randomness, no position of any
	# player, no frame count.
	generator.call("generate_block", buffer, origin, 0)

	var uniform := buffer.is_uniform(VoxelBuffer.CHANNEL_TYPE)
	# Canonicalise: expand a uniform channel to its full size before hashing.
	if uniform:
		buffer.decompress_channel(VoxelBuffer.CHANNEL_TYPE)
	var bytes := buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE)
	var depth: int = buffer.get_channel_depth(VoxelBuffer.CHANNEL_TYPE)

	var h := Hash64.hash_int(0x564F5845)  # "VOXE" - domain separator, so these hashes can
	# never be confused with hashes of anything else in the project.
	h = Hash64.hash_combine(h, Hash64.hash_int(block_size))
	h = Hash64.hash_combine(h, Hash64.hash_int(depth))
	h = Hash64.hash_combine(h, Hash64.hash_int(bytes.size()))
	h = Hash64.hash_combine(h, Hash64.hash_int(1 if uniform else 0))
	h = Hash64.hash_vec3i(h, origin)
	h = Hash64.hash_combine(h, Hash64.hash_bytes(bytes))

	# Cheap structural facts, recorded so a FAIL can be diagnosed instead of just reported.
	var histogram := {}
	var non_air := 0
	var total := buffer.get_size().x * buffer.get_size().y * buffer.get_size().z
	if uniform:
		# A uniform block is one value repeated; sample the first voxel only.
		var v := buffer.get_voxel(0, 0, 0, VoxelBuffer.CHANNEL_TYPE)
		histogram[v] = total
		non_air = 0 if v == 0 else total
	else:
		for y in buffer.get_size().y:
			for x in buffer.get_size().x:
				for z in buffer.get_size().z:
					var v := buffer.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
					histogram[v] = int(histogram.get(v, 0)) + 1
					if v != 0:
						non_air += 1

	return {
		"hash": h,
		"hex": Hash64.to_hex(h),
		"dec": Hash64.to_dec(h),
		"bytes": bytes.size(),
		"uniform": uniform,
		"depth": depth,
		"origin": origin,
		"non_air": non_air,
		"total": total,
		"value_histogram": histogram,
	}


## Hash every origin in `origins`. Returns {"<x,y,z>": hash-decimal-string}.
static func hash_all(generator: Resource, origins: Array, block_size: int = 16, type_depth_bits: int = 8) -> Dictionary:
	var out := {}
	for o in origins:
		var r := hash_chunk(generator, o, block_size, type_depth_bits)
		out[ChunkOrigins.origin_to_key(o)] = r["dec"]
	return out


## Detailed per-origin records, used for the report's hash table and for diagnosing D1-D4.
static func hash_all_detailed(generator: Resource, origins: Array, block_size: int = 16, type_depth_bits: int = 8) -> Array:
	var out := []
	for o in origins:
		var r := hash_chunk(generator, o, block_size, type_depth_bits)
		r["key"] = ChunkOrigins.origin_to_key(o)
		out.append(r)
	return out
