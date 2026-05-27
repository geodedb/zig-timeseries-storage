// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const types = @import("types.zig");
const limits = @import("limits.zig");
const gorilla = @import("encoding/gorilla.zig");

const Allocator = std.mem.Allocator;
const owner_only_file_mode = 0o600;
const Crc32C = std.hash.crc.Crc32Iscsi;

/// Segment file format magic.
///
/// `TSSEG002` (this revision) introduces per-block CRC32C integrity
/// (SEC-004): each block header carries a `crc32c` field covering the
/// header (excluding the CRC field itself) plus the compressed data
/// payload. Reads verify the CRC before decoding, surfacing
/// `error.BlockCorrupted` on mismatch.
///
/// `TSSEG001` (previous) had no per-block checksum. This is a
/// BREAKING change for any existing on-disk segments — `SegmentReader`
/// rejects `TSSEG001` files with `error.InvalidMagic`. A future
/// migration that auto-upgrades v1 segments to v2 on open is tracked
/// under GAP-0009.
pub const SEGMENT_MAGIC: [8]u8 = .{ 'T', 'S', 'S', 'E', 'G', '0', '0', '2' };

/// Errors specific to segment file integrity. Functions that touch
/// the segment files may ALSO return allocator or file-system errors
/// (`error.OutOfMemory`, `error.FileNotFound`, etc.); those keep an
/// inferred error set rather than being named here because the
/// resulting union would be unwieldy and would not add discrimination
/// value over the standard library types.
pub const SegmentError = error{
    /// File is shorter than the magic header.
    InvalidFile,
    /// First 8 bytes of the segment do not match `SEGMENT_MAGIC`.
    InvalidMagic,
    /// `Block.decodePoints` rejected `data_len` for exceeding
    /// `limits.MAX_BLOCK_DATA_LEN`.
    BlockTooLarge,
    /// `GorillaEncoder.encodePoint` refused to grow the bitset past
    /// `limits.MAX_POINTS_PER_BLOCK_ABSOLUTE`.
    BlockPointLimitExceeded,
    /// Read returned fewer bytes than requested.
    UnexpectedEOF,
    /// `crc32c` field on the block header did not match the CRC32C
    /// computed over header(excluding crc) + payload. Indicates
    /// on-disk corruption or out-of-band tampering. Closes SEC-004.
    BlockCorrupted,
};

/// Build the on-disk path for a segment file, e.g. `<data_dir>/<id>.tsseg`.
/// Caller owns the returned slice and must free it with `allocator.free`.
pub fn segmentPath(allocator: Allocator, data_dir: []const u8, id: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}.tsseg", .{ data_dir, id });
}

/// Header for a single block in a segment file.
///
/// ## Wire layout (TSSEG002, 92 bytes, little-endian)
///
///   off  size  field
///   ---  ----  ----------------------------------------------
///     0    16  series_id (u128)
///    16     8  stats.min_ts (i64)
///    24     8  stats.max_ts (i64)
///    32     4  stats.count (u32)
///    36     8  stats.min_value (i64)
///    44     8  stats.max_value (i64)
///    52    16  stats.sum (i128)
///    68     8  stats.first_value (i64)
///    76     8  stats.last_value (i64)
///    84     4  data_len (u32)
///    88     4  crc32c (u32) — covers bytes [0..88) of THIS header
///               plus the `data_len` payload bytes that follow it
///               on disk. Verified on read; mismatch surfaces
///               `error.BlockCorrupted`. Closes SEC-004.
///
/// The `crc32c` field is intentionally placed at the END so every
/// other field keeps the same offset it had under TSSEG001 — a
/// future migration tool can copy v1 headers and append a freshly
/// computed CRC without re-encoding the body. Computation uses
/// CRC32C (Castagnoli polynomial 0x1EDC6F41) for consistency with
/// the WAL and manifest checksums.
pub const BlockHeader = struct {
    series_id: types.SeriesId,
    stats: gorilla.BlockStats,
    data_len: u32,
    crc32c: u32 = 0,

    /// Bytes serialised PRIOR to the trailing crc32c. Used both as
    /// a serialiser offset and as the slice the CRC covers.
    pub const body_size = 16 + 8 + 8 + 4 + 8 + 8 + 16 + 8 + 8 + 4; // = 88
    pub const encoded_size = body_size + 4; // 92 bytes total

    /// Serialise the body (everything except crc32c) into the
    /// caller's buffer. Useful for `SegmentWriter.writeBlock`, which
    /// needs to compute the CRC over `(body, data)` and only then
    /// stamp the trailing crc bytes into the header buffer.
    pub fn serializeBody(self: BlockHeader, buf: []u8) void {
        std.debug.assert(buf.len >= body_size);
        var pos: usize = 0;
        std.mem.writeInt(u128, buf[pos..][0..16], self.series_id, .little);
        pos += 16;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.min_ts, .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.max_ts, .little);
        pos += 8;
        std.mem.writeInt(u32, buf[pos..][0..4], self.stats.count, .little);
        pos += 4;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.min_value, .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.max_value, .little);
        pos += 8;
        std.mem.writeInt(i128, buf[pos..][0..16], self.stats.sum, .little);
        pos += 16;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.first_value, .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.last_value, .little);
        pos += 8;
        std.mem.writeInt(u32, buf[pos..][0..4], self.data_len, .little);
        pos += 4;
        std.debug.assert(pos == body_size);
    }

    /// Serialise the full 92-byte header including the trailing
    /// crc32c. The CRC must already be set on `self`.
    pub fn serialize(self: BlockHeader, buf: []u8) void {
        std.debug.assert(buf.len >= encoded_size);
        self.serializeBody(buf);
        std.mem.writeInt(u32, buf[body_size..][0..4], self.crc32c, .little);
    }

    pub fn deserialize(buf: []const u8) BlockHeader {
        std.debug.assert(buf.len >= encoded_size);
        var h: BlockHeader = undefined;
        var pos: usize = 0;
        h.series_id = std.mem.readInt(u128, buf[pos..][0..16], .little);
        pos += 16;
        h.stats.min_ts = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.max_ts = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.count = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;
        h.stats.min_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.max_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.sum = std.mem.readInt(i128, buf[pos..][0..16], .little);
        pos += 16;
        h.stats.first_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.last_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.data_len = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;
        std.debug.assert(pos == body_size);
        h.crc32c = std.mem.readInt(u32, buf[pos..][0..4], .little);
        return h;
    }
};

/// Streaming writer for immutable segment files.
///
/// A segment file begins with the 8-byte `SEGMENT_MAGIC` followed by
/// one or more `(BlockHeader, Gorilla-compressed payload)` pairs. The
/// writer is append-only: `writeBlock` Gorilla-encodes the supplied
/// points, computes block-level statistics (min/max ts and value,
/// count, sum, first/last value), writes the header, then writes the
/// compressed payload. Headers are fixed-size (88 bytes), making
/// random-access scans of just the headers cheap for query planning.
///
/// File permissions are owner-read/write only (0o600). The caller is
/// responsible for choosing the path; see `segmentPath` for the
/// canonical `<data_dir>/<id>.tsseg` form.
///
/// `deinit` closes the file but does NOT fsync; durability is the
/// engine's responsibility (it issues the fsync as part of the
/// manifest commit when the segment is added to the manifest).
pub const SegmentWriter = struct {
    file: std.Io.File,
    io_ctx: std.Io,
    allocator: Allocator,

    pub fn init(allocator: Allocator, path: []const u8) !SegmentWriter {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
        });

        // Write magic
        try file.writeStreamingAll(io, &SEGMENT_MAGIC);

        return SegmentWriter{
            .file = file,
            .io_ctx = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SegmentWriter) void {
        self.file.close(self.io_ctx);
    }

    /// Force every previously-written byte to durable storage by
    /// issuing fsync(2) (or the platform equivalent) against the
    /// underlying file. Callers must invoke this BEFORE the segment
    /// is referenced from the manifest — without the fsync, a crash
    /// between manifest commit and the kernel's background flush
    /// would leave the manifest pointing at a segment whose blocks
    /// have not actually hit disk yet (P-IO-003 / Q-REL-008).
    ///
    /// `deinit` deliberately does NOT call this for you: closing the
    /// file is a cleanup operation, while fsyncing is a durability
    /// operation, and the two have different semantics. The engine's
    /// flush and compaction paths call `sync` explicitly at the
    /// correct point in the commit ordering.
    pub fn sync(self: *SegmentWriter) !void {
        try self.file.sync(self.io_ctx);
    }

    /// Appends a block of points for a series.
    ///
    /// On-disk layout: 88-byte body || crc32c(4) || data_len bytes of
    /// Gorilla payload. The CRC32C covers the body and the payload —
    /// the reader recomputes and verifies before decoding. Closes
    /// SEC-004.
    pub fn writeBlock(self: *SegmentWriter, series_id: types.SeriesId, points: []const types.Point) !void {
        if (points.len == 0) return;

        // P-MEM-002: pre-size the encoder bitset for the known input
        // count, eliminating most realloc-doubling cycles during the
        // hot encode loop. The estimate clamps internally so an
        // adversarial input cannot drive an absurd up-front allocation.
        var encoder = try gorilla.GorillaEncoder.initForPoints(self.allocator, points.len);
        defer encoder.deinit();

        for (points) |p| {
            try encoder.encodePoint(p);
        }

        const data = try encoder.getCompressedData(self.allocator);
        defer self.allocator.free(data);

        var buf: [BlockHeader.encoded_size]u8 = undefined;
        var header = BlockHeader{
            .series_id = series_id,
            .stats = encoder.stats,
            .data_len = @intCast(data.len),
            .crc32c = 0,
        };
        // Stamp the body first so we can hash over it.
        header.serializeBody(buf[0..BlockHeader.body_size]);

        // CRC32C over (body || data). The CRC itself is excluded —
        // it cannot cover the bytes it occupies.
        var hasher = Crc32C.init();
        hasher.update(buf[0..BlockHeader.body_size]);
        hasher.update(data);
        header.crc32c = hasher.final();
        std.mem.writeInt(u32, buf[BlockHeader.body_size..][0..4], header.crc32c, .little);

        try self.file.writeStreamingAll(self.io_ctx, &buf);
        try self.file.writeStreamingAll(self.io_ctx, data);
    }
};

/// Random-access reader for immutable segment files.
///
/// Validates the 8-byte magic on open and tracks the file size so the
/// block iterator can detect EOF without an extra `stat`. Reads are
/// positional (no internal seek state) so multiple `BlockIterator`s
/// can share a single `SegmentReader` if desired.
///
/// Lifetime: `deinit` closes the file. The caller must not use any
/// `Block` returned from a previous iteration after calling `deinit`
/// (the `Block` retains a `*SegmentReader` pointer for late payload
/// decoding).
pub const SegmentReader = struct {
    file: std.Io.File,
    io_ctx: std.Io,
    allocator: Allocator,
    file_size: u64,

    pub fn init(allocator: Allocator, path: []const u8) !SegmentReader {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});

        const file_size = try file.length(io);
        if (file_size < SEGMENT_MAGIC.len) return error.InvalidFile;

        var magic_buf: [8]u8 = undefined;
        const read_len = try file.readPositionalAll(io, &magic_buf, 0);
        if (read_len != 8 or !std.mem.eql(u8, &magic_buf, &SEGMENT_MAGIC)) {
            return error.InvalidMagic;
        }

        return SegmentReader{
            .file = file,
            .io_ctx = io,
            .allocator = allocator,
            .file_size = file_size,
        };
    }

    pub fn deinit(self: *SegmentReader) void {
        self.file.close(self.io_ctx);
    }

    /// Block iterator for reading through a segment.
    pub const BlockIterator = struct {
        reader: *SegmentReader,
        offset: u64,

        pub fn next(self: *BlockIterator) !?Block {
            if (self.offset >= self.reader.file_size) return null;

            var hdr_buf: [BlockHeader.encoded_size]u8 = undefined;
            const read_len = try self.reader.file.readPositionalAll(self.reader.io_ctx, &hdr_buf, self.offset);
            if (read_len != BlockHeader.encoded_size) return error.UnexpectedEOF;

            const header = BlockHeader.deserialize(&hdr_buf);

            const header_offset = self.offset;
            const data_offset = self.offset + BlockHeader.encoded_size;
            self.offset = data_offset + header.data_len;

            return Block{
                .header = header,
                .header_offset = header_offset,
                .data_offset = data_offset,
                .reader = self.reader,
            };
        }
    };

    pub fn iterator(self: *SegmentReader) BlockIterator {
        return .{
            .reader = self,
            .offset = SEGMENT_MAGIC.len,
        };
    }
};

/// A block of points inside a segment file.
pub const Block = struct {
    header: BlockHeader,
    /// Offset of the body bytes (88 bytes). The on-disk layout is
    /// body || crc32c || data, so `data_offset = header_offset + 92`.
    header_offset: u64,
    data_offset: u64,
    reader: *SegmentReader,

    /// Decodes the points in this block. Verifies the per-block
    /// CRC32C BEFORE allocating the decode buffer or invoking the
    /// Gorilla decoder, so a corrupted block cannot drive an
    /// out-of-bounds decode or oversized allocation.
    ///
    /// Errors:
    ///   * `error.BlockTooLarge` — `data_len` exceeds the static
    ///     `limits.MAX_BLOCK_DATA_LEN` cap.
    ///   * `error.UnexpectedEOF` — read returned fewer bytes than
    ///     `data_len`.
    ///   * `error.BlockCorrupted` — the stored crc32c does not match
    ///     the recomputed CRC32C over (body || data).
    ///   * Gorilla decode errors propagate unchanged.
    pub fn decodePoints(self: Block, allocator: Allocator) ![]types.Point {
        // CWE-770: refuse to allocate for absurd `data_len` values
        // before they reach the allocator.
        if (self.header.data_len > limits.MAX_BLOCK_DATA_LEN) return error.BlockTooLarge;

        const data = try allocator.alloc(u8, self.header.data_len);
        defer allocator.free(data);

        const read_len = try self.reader.file.readPositionalAll(self.reader.io_ctx, data, self.data_offset);
        if (read_len != self.header.data_len) return error.UnexpectedEOF;

        // SEC-004: verify CRC32C over (body || data) before decoding.
        // Re-read the body bytes from disk so a fuzzed in-memory
        // BlockHeader cannot bypass the check.
        var body_buf: [BlockHeader.body_size]u8 = undefined;
        const body_read = try self.reader.file.readPositionalAll(self.reader.io_ctx, &body_buf, self.header_offset);
        if (body_read != BlockHeader.body_size) return error.UnexpectedEOF;

        var hasher = Crc32C.init();
        hasher.update(&body_buf);
        hasher.update(data);
        const computed = hasher.final();
        if (computed != self.header.crc32c) return error.BlockCorrupted;

        var decoder = gorilla.GorillaDecoder.init(data, self.header.stats.count);
        return decoder.decodeAll(allocator);
    }
};

test "Segment roundtrip" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/test.tsseg", .{path});
    defer allocator.free(seg_path);

    const series_id: types.SeriesId = 12345;
    const pts = [_]types.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
    };

    {
        var writer = try SegmentWriter.init(allocator, seg_path);
        defer writer.deinit();
        try writer.writeBlock(series_id, &pts);
    }

    {
        var reader = try SegmentReader.init(allocator, seg_path);
        defer reader.deinit();

        var it = reader.iterator();
        const block = (try it.next()).?;
        try std.testing.expectEqual(series_id, block.header.series_id);
        try std.testing.expectEqual(@as(u32, 2), block.header.stats.count);

        const decoded = try block.decodePoints(allocator);
        defer allocator.free(decoded);

        try std.testing.expectEqual(@as(usize, 2), decoded.len);
        try std.testing.expectEqual(pts[0].ts, decoded[0].ts);
        try std.testing.expectEqual(pts[0].value, decoded[0].value);
        try std.testing.expectEqual(pts[1].ts, decoded[1].ts);
        try std.testing.expectEqual(pts[1].value, decoded[1].value);

        try std.testing.expect((try it.next()) == null);
    }
}

test "Segment: decodePoints refuses oversized data_len" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/bad.tsseg", .{path});
    defer allocator.free(seg_path);

    // Hand-craft a segment file: magic + a single header with a
    // data_len that exceeds MAX_BLOCK_DATA_LEN. We never write the
    // payload — the decode-time check fires first.
    {
        const f = try std.Io.Dir.cwd().createFile(io, seg_path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer f.close(io);
        try f.writeStreamingAll(io, &SEGMENT_MAGIC);

        var hdr_buf: [BlockHeader.encoded_size]u8 = undefined;
        const h = BlockHeader{
            .series_id = 1,
            .stats = .{
                .min_ts = 0,
                .max_ts = 1,
                .count = 1,
                .min_value = 0,
                .max_value = 1,
                .sum = 0,
                .first_value = 0,
                .last_value = 0,
            },
            .data_len = limits.MAX_BLOCK_DATA_LEN + 1,
        };
        h.serialize(&hdr_buf);
        try f.writeStreamingAll(io, &hdr_buf);
        try f.sync(io);
    }

    var reader = try SegmentReader.init(allocator, seg_path);
    defer reader.deinit();
    var it = reader.iterator();
    const blk = (try it.next()).?;

    try std.testing.expectError(error.BlockTooLarge, blk.decodePoints(allocator));
}

test "Segment: per-block CRC32C catches a flipped byte in the payload (SEC-004)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/corrupt.tsseg", .{path});
    defer allocator.free(seg_path);

    // Step 1: write a normal segment with a single block.
    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(42, &.{
            .{ .ts = 100, .value = 10 },
            .{ .ts = 200, .value = 20 },
            .{ .ts = 300, .value = 30 },
        });
        try w.sync();
    }

    // Step 2: flip exactly one byte in the payload area. The
    // payload begins at SEGMENT_MAGIC.len + BlockHeader.encoded_size.
    {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{ .mode = .read_write });
        defer f.close(io);
        const payload_offset: u64 = SEGMENT_MAGIC.len + BlockHeader.encoded_size;
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &byte, payload_offset);
        byte[0] ^= 0xFF;
        try f.writePositionalAll(io, &byte, payload_offset);
        try f.sync(io);
    }

    // Step 3: read and assert BlockCorrupted is surfaced.
    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;

    try std.testing.expectError(error.BlockCorrupted, blk.decodePoints(allocator));
}

test "Segment: per-block CRC32C catches a flipped byte in the header (SEC-004)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/corrupt_hdr.tsseg", .{path});
    defer allocator.free(seg_path);

    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(7, &.{
            .{ .ts = 1, .value = 1 },
            .{ .ts = 2, .value = 2 },
        });
        try w.sync();
    }

    // Flip a byte inside the stats portion of the header (between
    // series_id and data_len) — not in the crc field itself. The
    // CRC was computed over the body, so this flip MUST be caught.
    {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{ .mode = .read_write });
        defer f.close(io);
        // Offset of stats.first_value within the body = 16+8+8+4+8+8+16 = 68.
        const flip_offset: u64 = SEGMENT_MAGIC.len + 68;
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &byte, flip_offset);
        byte[0] ^= 0x01;
        try f.writePositionalAll(io, &byte, flip_offset);
        try f.sync(io);
    }

    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectError(error.BlockCorrupted, blk.decodePoints(allocator));
}

test "Segment: rejects v1 (TSSEG001) magic on open" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/v1.tsseg", .{path});
    defer allocator.free(seg_path);

    // Stamp a v1 magic + a body's worth of zero bytes so the file is
    // long enough to be considered a candidate.
    {
        const f = try std.Io.Dir.cwd().createFile(io, seg_path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer f.close(io);
        const v1_magic: [8]u8 = .{ 'T', 'S', 'S', 'E', 'G', '0', '0', '1' };
        try f.writeStreamingAll(io, &v1_magic);
        try f.sync(io);
    }

    try std.testing.expectError(error.InvalidMagic, SegmentReader.init(allocator, seg_path));
}

test "SegmentWriter.sync survives a roundtrip" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/sync.tsseg", .{path});
    defer allocator.free(seg_path);

    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(1, &.{
            .{ .ts = 100, .value = 1 },
            .{ .ts = 200, .value = 2 },
        });
        try w.sync();
    }

    // After sync + close, the reader should still see the block.
    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectEqual(@as(u32, 2), blk.header.stats.count);
}
