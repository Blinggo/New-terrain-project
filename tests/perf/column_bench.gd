class_name ColumnBench
extends RefCounted
## tests/perf/column_bench.gd
##
## M01-fix - The ONE place a benchmark touches a generator, so every backend is timed through
## the same dispatch the determinism harness uses (ChunkHasher.source_kind).
##
## Why this exists: the four shipped backends no longer share an entry point.
##   * "block" generators (the legacy graph and noise2d baselines) implement generate_block().
##   * "column" generators produce a whole 16 x 384 x 16 column per call. The native
##     VoxelGeneratorMultipassCB subclass prints "Not implemented" from generate_block() and
##     does NOT route to _generate_block_fallback (measured: tools/probe_native_cb8.gd,
##     fb_calls = 0), so timing it through generate_block() would time an empty buffer and
##     report a fabricated speed.
## Timing the wrong entry point is how a benchmark becomes a lie; this file makes the choice
## explicit and shared.
##
## LAYER: tests only. It may name Voxel Tools types because nothing in src/core, src/spine or
## src/worldgen is scanned from here (LayerLint covers src/, and src/adapters/ is the only
## place in the product that names them).

const VOXELS_PER_BLOCK := 16


## One unit of work for a "block" generator: fill a mesh_block_size^3 buffer at `origin`.
static func generate_block(generator: Resource, origin: Vector3i, cfg: WorldConfig) -> void:
	var format := VoxelFormat.new()
	format.type_depth = VoxelBuffer.DEPTH_8_BIT if cfg.type_depth_bits <= 8 else VoxelBuffer.DEPTH_16_BIT
	var size := Vector3i(cfg.mesh_block_size, cfg.mesh_block_size, cfg.mesh_block_size)
	var buf: VoxelBuffer = format.create_buffer(size)
	generator.call("generate_block", buf, origin, 0)


## One unit of work for a "column" generator: build the whole world column at `origin` in
## memory. Synchronous and caller-thread, so the timing is the generator's own cost.
static func generate_column(generator: Resource, origin: Vector3i) -> MemoryColumnWriter:
	if not generator.has_method("debug_column_memory"):
		push_error("ColumnBench.generate_column: %s exposes no debug_column_memory()" % generator.get_class())
		return null
	return generator.call("debug_column_memory", origin)


## Dispatch helper for callers that have a generator but not a kind.
static func generate(generator: Resource, origin: Vector3i, cfg: WorldConfig) -> void:
	if ChunkHasher.source_kind(generator) == "column":
		generate_column(generator, origin)
	else:
		generate_block(generator, origin, cfg)


## A strided byte sample of what a backend actually wrote, for expressiveness checks (which
## distinct voxel ids appear). Columns are sampled through the in-memory writer; blocks
## through the buffer they filled.
static func sample_bytes(generator: Resource, origin: Vector3i, kind: String, cfg: WorldConfig) -> PackedByteArray:
	var out := PackedByteArray()
	if kind == "column":
		var column := generate_column(generator, origin)
		if column == null:
			return out
		var b: Array = column.bounds_main()
		var bmin: Vector3i = b[0]
		var bmax: Vector3i = b[1]
		for y in range(bmin.y, bmax.y, 4):
			for z in range(bmin.z, bmax.z, 4):
				for x in range(bmin.x, bmax.x, 4):
					out.append(column.get_type_world(Vector3i(x, y, z)))
		return out

	var format := VoxelFormat.new()
	format.type_depth = VoxelBuffer.DEPTH_8_BIT if cfg.type_depth_bits <= 8 else VoxelBuffer.DEPTH_16_BIT
	var size := Vector3i(cfg.mesh_block_size, cfg.mesh_block_size, cfg.mesh_block_size)
	var buf: VoxelBuffer = format.create_buffer(size)
	generator.call("generate_block", buf, origin, 0)
	buf.decompress_channel(VoxelBuffer.CHANNEL_TYPE)
	return buf.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE)
