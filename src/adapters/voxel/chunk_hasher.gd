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

## How a generator's output reaches the hasher:
##   "block"  - VoxelGenerator.generate_block(buffer, origin, lod) fills a 16^3 buffer
##              (noise2d, graph: the legacy M00 baselines).
##   "column" - the generator exposes debug_column_memory(column_origin) and produces a whole
##              16 x world_height x 16 column (the modular multipass backends). Verified in
##              M01-fix: VoxelGeneratorMultipassCB.generate_block() is "Not implemented" and
##              does NOT route to _generate_block_fallback (tools/probe_native_cb8.gd), so a
##              column generator cannot be hashed through generate_block at all.
static func source_kind(generator: Resource) -> String:
	if generator != null and generator.has_method("debug_column_memory"):
		return "column"
	return "block"


static func make_buffer(block_size: int, type_depth_bits: int) -> VoxelBuffer:
	var format := VoxelFormat.new()
	format.type_depth = VoxelBuffer.DEPTH_8_BIT if type_depth_bits <= 8 else VoxelBuffer.DEPTH_16_BIT
	return format.create_buffer(Vector3i(block_size, block_size, block_size))


## Hash one chunk, dispatching on the generator's source kind. Both paths canonicalise into
## the SAME VoxelBuffer, so a hash means the same thing whichever backend produced it.
static func hash_one(generator: Resource, origin: Vector3i, block_size: int = 16, type_depth_bits: int = 8) -> Dictionary:
	if source_kind(generator) == "column":
		var column: MemoryColumnWriter = generator.call("debug_column_memory", Vector3i(origin.x, origin.y, origin.z))
		if column == null:
			push_error("chunk_hasher: generator returned no column memory for origin %s" % str(origin))
			return {}
		return hash_column_slice(column, origin, block_size, type_depth_bits)
	return hash_chunk(generator, origin, block_size, type_depth_bits)


## Hash one chunk from generate_block(). Returns:
##   {"hash": int, "hex": String, "dec": String, "bytes": int, "uniform": bool,
##    "depth": int, "origin": Vector3i, "non_air": int, "value_histogram": Dictionary}
static func hash_chunk(generator: Resource, origin: Vector3i, block_size: int = 16, type_depth_bits: int = 8) -> Dictionary:
	var buffer := make_buffer(block_size, type_depth_bits)
	# The generator is the only source of data. No time, no randomness, no position of any
	# player, no frame count.
	generator.call("generate_block", buffer, origin, 0)
	return hash_buffer(buffer, origin, block_size)


## Hash the 16^3 slice of an in-memory column that starts at `origin`. The slice is copied
## into a real VoxelBuffer with set_voxel(value, x, y, z, channel) so the canonicalisation
## (and therefore the hash) is identical to the generate_block path.
static func hash_column_slice(column: MemoryColumnWriter, origin: Vector3i, block_size: int = 16, type_depth_bits: int = 8) -> Dictionary:
	var buffer := make_buffer(block_size, type_depth_bits)
	var col_bounds: Array = column.bounds_main()
	var col_min: Vector3i = col_bounds[0]
	var col_max: Vector3i = col_bounds[1]
	if origin.x < col_min.x or origin.z < col_min.z or origin.y < col_min.y \
			or origin.x + block_size > col_max.x or origin.z + block_size > col_max.z or origin.y + block_size > col_max.y:
		push_error("chunk_hasher: block origin %s is outside the generated column %s..%s" % [str(origin), str(col_min), str(col_max)])
	for y in block_size:
		for z in block_size:
			for x in block_size:
				var v := column.get_type_world(origin + Vector3i(x, y, z))
				buffer.set_voxel(v, x, y, z, VoxelBuffer.CHANNEL_TYPE)
	return hash_buffer(buffer, origin, block_size)


## The canonical fingerprint of a filled buffer. Split out so both source kinds share ONE
## construction and a hash can never mean two different things.
static func hash_buffer(buffer: VoxelBuffer, origin: Vector3i, block_size: int) -> Dictionary:
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
		var r := hash_one(generator, o, block_size, type_depth_bits)
		out[ChunkOrigins.origin_to_key(o)] = r["dec"]
	return out


## Detailed per-origin records, used for the report's hash table and for diagnosing D1-D4.
static func hash_all_detailed(generator: Resource, origins: Array, block_size: int = 16, type_depth_bits: int = 8) -> Array:
	var out := []
	for o in origins:
		var r := hash_one(generator, o, block_size, type_depth_bits)
		r["key"] = ChunkOrigins.origin_to_key(o)
		out.append(r)
	return out
