// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Segment format migration: TSSEG001 (pre-CRC32C) -> TSSEG002 (with
//! per-block CRC32C). Closes GAP-0009.
//!
//! Phase E commit 088b2f1 bumped the segment magic and added a 4-byte
//! trailing CRC32C to every block header. `SegmentReader` now rejects
//! TSSEG001 files with `error.InvalidMagic` (see segment.zig). Without
//! a migration tool an operator with a v1 data directory has no path
//! forward.
//!
//! ## On-disk diff
//!
//! v1: SEGMENT_MAGIC_V1(8) + (block_body(88) + data(data_len))*
//! v2: SEGMENT_MAGIC_V2(8) + (block_body(88) + crc32c(4) + data(data_len))*
//!
//! The block body bytes are byte-identical between v1 and v2 — the
//! only change is the addition of the trailing 4-byte CRC32C between
//! the body and the data payload. This lets us copy each body
//! verbatim, recompute the CRC32C, and stamp it before the data.
//!
//! ## Behaviour
//!
//! `migrateSegment(src, dst)` validates the source magic, then streams
//! one block at a time:
//!
//!   1. Read 88 bytes of body.
//!   2. Read `data_len` bytes of payload.
//!   3. Compute CRC32C over (body || data).
//!   4. Write body || crc32c || data to the destination.
//!
//! The destination is created with 0600 permissions to match
//! `SegmentWriter`. The destination is fsync'd before return so a
//! crash mid-migration leaves either the old or the new file on disk
//! — never a half-written segment that would corrupt the engine's
//! view on next open.

const std = @import("std");
const Allocator = std.mem.Allocator;
const segment = @import("segment.zig");
const limits = @import("limits.zig");

const Crc32C = std.hash.crc.Crc32Iscsi;
const owner_only_file_mode = 0o600;

/// v1 segment magic — pre-CRC32C format. Kept here, NOT in segment.zig,
/// because the rest of the engine MUST reject it on read.
pub const SEGMENT_MAGIC_V1: [8]u8 = .{ 'T', 'S', 'S', 'E', 'G', '0', '0', '1' };

pub const MigrationError = error{
    /// Source file is not a v1 segment (wrong magic / too short).
    NotV1Segment,
    /// A block header advertised `data_len > limits.MAX_BLOCK_DATA_LEN`.
    /// We refuse to migrate untrusted blocks past the same cap the
    /// reader enforces.
    BlockTooLarge,
    /// Read returned fewer bytes than the block header advertised —
    /// the source segment is truncated.
    UnexpectedEOF,
};

/// Migrate a single v1 segment file at `src_path` to a v2 file at
/// `dst_path`. Returns the number of blocks migrated.
///
/// Errors:
///   * `error.NotV1Segment` — magic mismatch or file too short.
///   * `error.UnexpectedEOF` — truncated block in the source.
///   * `error.BlockTooLarge` — adversarial `data_len`.
///   * Any I/O error from the underlying filesystem.
///
/// The destination is fsync'd on success.
pub fn migrateSegment(allocator: Allocator, src_path: []const u8, dst_path: []const u8) !u32 {
    const io = std.Io.Threaded.global_single_threaded.io();

    const src = try std.Io.Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);

    const src_len = try src.length(io);
    if (src_len < SEGMENT_MAGIC_V1.len) return error.NotV1Segment;

    var magic_buf: [SEGMENT_MAGIC_V1.len]u8 = undefined;
    const magic_read = try src.readPositionalAll(io, &magic_buf, 0);
    if (magic_read != SEGMENT_MAGIC_V1.len) return error.NotV1Segment;
    if (!std.mem.eql(u8, &magic_buf, &SEGMENT_MAGIC_V1)) return error.NotV1Segment;

    const dst = try std.Io.Dir.cwd().createFile(io, dst_path, .{
        .read = false,
        .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
    });
    defer dst.close(io);

    // Stamp the v2 magic up front.
    try dst.writeStreamingAll(io, &segment.SEGMENT_MAGIC);

    // Iterate blocks: each v1 block is 88 bytes of body + data_len bytes
    // of payload. Body offset = 84 carries the u32 `data_len` field.
    const body_size = segment.BlockHeader.body_size;
    var offset: u64 = SEGMENT_MAGIC_V1.len;
    var blocks: u32 = 0;
    var body_buf: [body_size]u8 = undefined;

    while (offset < src_len) : (blocks += 1) {
        if (offset + body_size > src_len) return error.UnexpectedEOF;

        const body_read = try src.readPositionalAll(io, &body_buf, offset);
        if (body_read != body_size) return error.UnexpectedEOF;

        // data_len lives at body offset 84 (see segment.zig BlockHeader
        // wire layout — series_id(16) + min_ts(8) + max_ts(8) + count(4)
        // + min_value(8) + max_value(8) + sum(16) + first_value(8) +
        // last_value(8) = 84).
        const data_len = std.mem.readInt(u32, body_buf[84..88], .little);
        if (data_len > limits.MAX_BLOCK_DATA_LEN) return error.BlockTooLarge;

        const data_offset = offset + body_size;
        if (data_offset + data_len > src_len) return error.UnexpectedEOF;

        // Read the payload. Large blocks heap-allocate; everyone else
        // is well under the stdlib's stack limits.
        const data = try allocator.alloc(u8, data_len);
        defer allocator.free(data);
        if (data_len > 0) {
            const data_read = try src.readPositionalAll(io, data, data_offset);
            if (data_read != data_len) return error.UnexpectedEOF;
        }

        // Compute CRC32C over (body || data) — the exact same hash the
        // v2 reader will recompute on every decodePoints call.
        var hasher = Crc32C.init();
        hasher.update(&body_buf);
        hasher.update(data);
        const crc = hasher.final();

        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, crc, .little);

        try dst.writeStreamingAll(io, &body_buf);
        try dst.writeStreamingAll(io, &crc_buf);
        if (data_len > 0) try dst.writeStreamingAll(io, data);

        offset = data_offset + data_len;
    }

    // Durability: fsync before returning so callers who observe a
    // successful return get an on-disk artefact, not a page-cached one.
    try dst.sync(io);
    return blocks;
}

// =============================================================================
// Tests
// =============================================================================

const types = @import("types.zig");
const gorilla = @import("encoding/gorilla.zig");

/// Test helper — hand-craft a TSSEG001 segment file containing one
/// block. We can't use `SegmentWriter` because the writer emits v2.
fn writeV1Segment(
    allocator: Allocator,
    path: []const u8,
    series_id: types.SeriesId,
    points: []const types.Point,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = false,
        .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
    });
    defer f.close(io);

    try f.writeStreamingAll(io, &SEGMENT_MAGIC_V1);

    var encoder = try gorilla.GorillaEncoder.initForPoints(allocator, points.len);
    defer encoder.deinit();
    for (points) |p| try encoder.encodePoint(p);
    const data = try encoder.getCompressedData(allocator);
    defer allocator.free(data);

    // Build the body using the same serializeBody path as v2 (the body
    // is byte-identical between formats).
    var body_buf: [segment.BlockHeader.body_size]u8 = undefined;
    const header = segment.BlockHeader{
        .series_id = series_id,
        .stats = encoder.stats,
        .data_len = @intCast(data.len),
        .crc32c = 0, // irrelevant for v1
    };
    header.serializeBody(&body_buf);

    try f.writeStreamingAll(io, &body_buf);
    try f.writeStreamingAll(io, data);
    try f.sync(io);
}

test "migration: v1 -> v2 round-trip via SegmentReader" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const v1_path = try std.fmt.allocPrint(allocator, "{s}/v1.tsseg", .{base});
    defer allocator.free(v1_path);
    const v2_path = try std.fmt.allocPrint(allocator, "{s}/v2.tsseg", .{base});
    defer allocator.free(v2_path);

    const pts = [_]types.Point{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 200, .value = 2 },
        .{ .ts = 300, .value = 3 },
        .{ .ts = 400, .value = 4 },
    };
    try writeV1Segment(allocator, v1_path, 42, &pts);

    // Migrate.
    const block_count = try migrateSegment(allocator, v1_path, v2_path);
    try std.testing.expectEqual(@as(u32, 1), block_count);

    // v2 file must open cleanly with the standard reader.
    var reader = try segment.SegmentReader.init(allocator, v2_path);
    defer reader.deinit();

    var it = reader.iterator();
    const block = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectEqual(@as(types.SeriesId, 42), block.header.series_id);
    try std.testing.expectEqual(@as(u32, 4), block.header.stats.count);

    // decodePoints verifies the per-block CRC32C — migration must have
    // recomputed it correctly.
    const out = try block.decodePoints(allocator);
    defer allocator.free(out);
    try std.testing.expectEqual(pts.len, out.len);
    for (pts, 0..) |expected, i| {
        try std.testing.expectEqual(expected.ts, out[i].ts);
        try std.testing.expectEqual(expected.value, out[i].value);
    }
    try std.testing.expect((try it.next()) == null);
}

test "migration: rejects v2 segments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const v2_path = try std.fmt.allocPrint(allocator, "{s}/already_v2.tsseg", .{base});
    defer allocator.free(v2_path);
    const dst = try std.fmt.allocPrint(allocator, "{s}/dst.tsseg", .{base});
    defer allocator.free(dst);

    {
        var w = try segment.SegmentWriter.init(allocator, v2_path);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    try std.testing.expectError(error.NotV1Segment, migrateSegment(allocator, v2_path, dst));
}

test "migration: rejects truncated v1 file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const v1_path = try std.fmt.allocPrint(allocator, "{s}/v1.tsseg", .{base});
    defer allocator.free(v1_path);
    const dst = try std.fmt.allocPrint(allocator, "{s}/dst.tsseg", .{base});
    defer allocator.free(dst);

    // Write only the magic + a partial body (50 bytes of zeros).
    const f = try std.Io.Dir.cwd().createFile(io, v1_path, .{
        .read = false,
        .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
    });
    defer f.close(io);
    try f.writeStreamingAll(io, &SEGMENT_MAGIC_V1);
    const partial: [50]u8 = @splat(0);
    try f.writeStreamingAll(io, &partial);
    try f.sync(io);

    try std.testing.expectError(error.UnexpectedEOF, migrateSegment(allocator, v1_path, dst));
}

test "migration: empty v1 (only magic) yields a magic-only v2 file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const v1_path = try std.fmt.allocPrint(allocator, "{s}/v1.tsseg", .{base});
    defer allocator.free(v1_path);
    const v2_path = try std.fmt.allocPrint(allocator, "{s}/v2.tsseg", .{base});
    defer allocator.free(v2_path);

    const f = try std.Io.Dir.cwd().createFile(io, v1_path, .{
        .read = false,
        .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
    });
    defer f.close(io);
    try f.writeStreamingAll(io, &SEGMENT_MAGIC_V1);
    try f.sync(io);

    const blocks = try migrateSegment(allocator, v1_path, v2_path);
    try std.testing.expectEqual(@as(u32, 0), blocks);

    // v2 file should be exactly 8 bytes (just the v2 magic) — the
    // reader will report it as too short to hold a block header but
    // not as an InvalidMagic.
    const out = try std.Io.Dir.cwd().openFile(io, v2_path, .{});
    defer out.close(io);
    const len = try out.length(io);
    try std.testing.expectEqual(@as(u64, segment.SEGMENT_MAGIC.len), len);
}
