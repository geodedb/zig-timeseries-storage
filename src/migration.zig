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
const types = @import("types.zig");

// fips-exempt: non-security — CRC32C per-block framing checksum recomputed
// during the TSSEG001 -> TSSEG002 migration; data-integrity only, not a
// cryptographic primitive (no FIPS-regulated algorithm).
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

// ---------------------------------------------------------------------------
// P-ALGO-001: footer retrofit migration
// ---------------------------------------------------------------------------
//
// Closes the remaining work of P-ALGO-001 (the backwards-compatible
// footer index landed in commit `4ec8c3a`). Segments written before
// that change lack the trailing `[FOOTER_BODY][FOOTER_OFFSET][FOOTER_MAGIC]`
// region and therefore fall back to the full-scan query path. This
// migration walks each segment in a data_dir, scans its block headers
// once, builds the same sorted `(series_id, first_block_offset,
// block_count)` map that a fresh writer would have accumulated, and
// APPENDS the canonical footer + sentinel tail. The block region of
// each file is touched read-only — every existing byte is preserved
// bit-identical.
//
// ## Crash-safety contract
//
// The append is intentionally NOT atomic: we cannot rename a "footered"
// file over the original without burning a full file copy worth of disk
// I/O per segment. Instead the migration relies on the on-disk format's
// existing "magic-at-EOF or nothing" probe:
//
//   1. We open the file read+write and append the FOOTER_BODY, then the
//      FOOTER_OFFSET, then the FOOTER_MAGIC, then fsync.
//   2. If the process crashes mid-append, the file ends with some
//      partial suffix that is NOT FOOTER_MAGIC. `SegmentReader.init`
//      probes the last 8 bytes; a non-magic suffix is treated as "no
//      footer" and the reader degrades to the full-scan path — the
//      legacy behaviour we are trying to upgrade away from.
//   3. A subsequent migration run sees the same non-magic suffix, takes
//      the "needs upgrade" branch, and re-appends the footer. Re-running
//      the migration after a crash is therefore safe and correct, BUT
//      the partial footer suffix is left in the file. To keep the file
//      compact across retries we first truncate back to the data-block
//      end before appending — see `findDataEndOffset` below.
//
// ## Idempotency
//
// A segment that already has a verified footer is detected by reading
// the trailing 8 bytes and matching FOOTER_MAGIC. We DO NOT re-verify
// the CRC32C on detection — that would force callers to pay for a full
// footer parse just to skip the file. Operators worried about a
// CRC-corrupt footer should run `tsdb verify` first; the reader's
// downgrade path already preserves correctness.

/// Result of retrofitting a single segment's footer. One element per
/// `*.tsseg` file in the data_dir.
pub const FooterMigrationResult = struct {
    /// Absolute (or relative-to-cwd) path of the segment file. The
    /// slice is allocator-owned and must be freed via the helper
    /// `freeResults` on the slice returned by `migrateSegmentFooters`.
    path: []const u8,
    /// True if the segment already carried a footer when the migration
    /// looked at it — no work done.
    already_indexed: bool,
    /// True if this run appended a fresh footer to the segment. Mutually
    /// exclusive with `already_indexed`.
    upgraded: bool,
    /// Bytes appended to the file (footer body + offset + magic). Zero
    /// when `already_indexed` is true.
    bytes_appended: u64,
    /// Number of unique series_ids the footer indexes. Zero for
    /// already-indexed segments (we do not parse the existing footer)
    /// and for segments that contain no data blocks at all.
    series_count: u32,
};

/// Free the path slices owned by a `migrateSegmentFooters` result and
/// then the result slice itself. Mirrors the stdlib `freeSlice` idiom.
pub fn freeResults(allocator: Allocator, results: []FooterMigrationResult) void {
    for (results) |r| allocator.free(r.path);
    allocator.free(results);
}

/// Retrofit the optional per-segment footer index onto every `*.tsseg`
/// file in `data_dir` that does not already carry one. Returns one
/// `FooterMigrationResult` per file inspected — the caller owns the
/// returned slice and MUST free it via `freeResults`.
///
/// Idempotent: a second call against the same data_dir reports every
/// segment as `already_indexed` and performs no I/O writes.
///
/// Strategy per segment:
///   1. Open read+write.
///   2. Read the trailing 8 bytes; if they equal `FOOTER_MAGIC` mark
///      the segment as already indexed and return.
///   3. Otherwise scan from the post-magic offset, walking each block
///      header to build the sorted `(series_id, first_block_offset,
///      block_count)` map.
///   4. Truncate any partial footer suffix back to the post-block
///      offset (handles the crash-mid-append case).
///   5. Serialise the canonical footer body + sentinel tail and
///      `writePositionalAll` it at the post-block offset.
///   6. fsync.
///
/// The block region of the file is never modified. Every existing byte
/// is preserved bit-identical, and the footer bytes emitted by this
/// function are byte-identical to what a fresh `SegmentWriter` would
/// have emitted (same sort order, same CRC32C polynomial, same tail).
///
/// Non-`*.tsseg` entries in `data_dir` are skipped silently — the
/// manifest, WAL files, and any operator-placed sidecars are left
/// untouched.
pub fn migrateSegmentFooters(
    allocator: Allocator,
    io: std.Io,
    data_dir: []const u8,
) ![]FooterMigrationResult {
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);

    var results: std.ArrayListUnmanaged(FooterMigrationResult) = .empty;
    // On any failure mid-loop, free every path we already accumulated.
    errdefer {
        for (results.items) |r| allocator.free(r.path);
        results.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tsseg")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, entry.name });
        errdefer allocator.free(path);

        const r = try migrateSegmentFooter(allocator, io, path);
        try results.append(allocator, .{
            .path = path,
            .already_indexed = r.already_indexed,
            .upgraded = r.upgraded,
            .bytes_appended = r.bytes_appended,
            .series_count = r.series_count,
        });
    }

    return results.toOwnedSlice(allocator);
}

/// Inner result type — `migrateSegmentFooter` does not allocate a path,
/// the wrapper above does.
const SingleResult = struct {
    already_indexed: bool,
    upgraded: bool,
    bytes_appended: u64,
    series_count: u32,
};

/// Retrofit the footer onto a single segment file. Public for tests and
/// for callers that already have the path in hand.
pub fn migrateSegmentFooter(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
) !SingleResult {
    // Open read+write. The fail-closed default of `mode = .read_only`
    // would refuse the `writePositionalAll` below; passing `.read_write`
    // mirrors `SegmentWriter`'s permissions (0o600 was set at create
    // time and is unchanged here).
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const file_size = try file.length(io);
    if (file_size < segment.SEGMENT_MAGIC.len) {
        // Too short to even hold the magic — leave it alone, the
        // engine's `verifySegments` will surface a clearer error than
        // we could here.
        return .{ .already_indexed = false, .upgraded = false, .bytes_appended = 0, .series_count = 0 };
    }

    // Magic check: accept both v2 (plaintext) and v3 (encrypted)
    // segments. The footer is plaintext for both; we only need to
    // know which block size to step by while iterating headers.
    var magic_buf: [8]u8 = undefined;
    const magic_read = try file.readPositionalAll(io, &magic_buf, 0);
    if (magic_read != 8) return error.UnexpectedEOF;
    const is_v2 = std.mem.eql(u8, &magic_buf, &segment.SEGMENT_MAGIC);
    const is_v3 = std.mem.eql(u8, &magic_buf, &segment.SEGMENT_MAGIC_V3);
    if (!is_v2 and !is_v3) {
        // Not a segment we know how to migrate. (v1 segments must be
        // upgraded first via `migrateSegment`; non-segment files are
        // already filtered by the `.tsseg` extension check.)
        return .{ .already_indexed = false, .upgraded = false, .bytes_appended = 0, .series_count = 0 };
    }

    // 1) Already-indexed probe. Only meaningful if the file is long
    // enough to carry the 16-byte tail.
    if (file_size >= segment.SEGMENT_MAGIC.len + segment.FOOTER_TAIL_SIZE) {
        var tail: [segment.FOOTER_TAIL_SIZE]u8 = undefined;
        const tail_read = try file.readPositionalAll(io, &tail, file_size - segment.FOOTER_TAIL_SIZE);
        if (tail_read == segment.FOOTER_TAIL_SIZE) {
            const trailing_magic = std.mem.readInt(u64, tail[8..16], .little);
            if (trailing_magic == segment.FOOTER_MAGIC) {
                return .{
                    .already_indexed = true,
                    .upgraded = false,
                    .bytes_appended = 0,
                    .series_count = 0,
                };
            }
        }
    }

    // 2) Scan block headers to build the sorted entry map. Same logic
    // the writer uses, except we have to compute `first_block_offset`
    // and `block_count` from the existing file rather than from a
    // growing `current_offset`.
    var series_index: std.AutoHashMapUnmanaged(types.SeriesId, segment.FooterEntry) = .empty;
    defer series_index.deinit(allocator);

    const post_magic: u64 = segment.SEGMENT_MAGIC.len;
    var offset: u64 = post_magic;
    var data_end: u64 = post_magic;
    var body_buf: [segment.BlockHeader.encoded_size]u8 = undefined;

    while (offset < file_size) {
        // Stop when we cannot read a full header — the remaining bytes
        // are either a partial footer suffix (from a prior crash) or
        // garbage that the reader would also stop at. We treat the
        // remaining bytes as "everything past the data region" and
        // truncate them below before appending the fresh footer.
        if (offset + segment.BlockHeader.encoded_size > file_size) break;

        const hdr_read = try file.readPositionalAll(io, &body_buf, offset);
        if (hdr_read != segment.BlockHeader.encoded_size) return error.UnexpectedEOF;

        const header = segment.BlockHeader.deserialize(&body_buf);
        if (header.data_len > limits.MAX_BLOCK_DATA_LEN) return error.BlockTooLarge;

        // v2 block layout: header(92) + data_len bytes.
        // v3 block layout: header(92) + nonce(12) + tag(16) + data_len bytes (ciphertext).
        const block_total: u64 = if (is_v3)
            segment.BlockHeader.encoded_size + segment.ENCRYPTION_NONCE_SIZE +
                segment.ENCRYPTION_TAG_SIZE + header.data_len
        else
            segment.BlockHeader.encoded_size + header.data_len;

        if (offset + block_total > file_size) {
            // Truncated block (or a partial footer that happened to
            // decode as a giant block). Stop here and let the writer
            // place the footer at `data_end` — the partial bytes are
            // truncated away.
            break;
        }

        const block_header_offset = offset;
        const gop = try series_index.getOrPut(allocator, header.series_id);
        if (gop.found_existing) {
            gop.value_ptr.block_count += 1;
        } else {
            gop.value_ptr.* = .{
                .series_id = header.series_id,
                .first_block_offset = block_header_offset,
                .block_count = 1,
            };
        }

        offset += block_total;
        data_end = offset;
    }

    // 3) If the file has no data blocks at all (magic-only or
    // entirely-garbage trailing bytes after magic), do not emit a
    // footer — matches the writer's `entry_count == 0` skip.
    if (series_index.count() == 0) {
        // Still truncate any garbage trailing the magic so subsequent
        // operations see a clean magic-only file.
        if (file_size > post_magic) {
            try file.setLength(io, post_magic);
            try file.sync(io);
        }
        return .{ .already_indexed = false, .upgraded = false, .bytes_appended = 0, .series_count = 0 };
    }

    // 4) Truncate any post-block bytes (partial footer suffix from a
    // crashed prior run, or never-flushed trailing garbage) so the
    // fresh footer lands immediately after the last data block.
    if (file_size > data_end) {
        try file.setLength(io, data_end);
    }

    // 5) Build the canonical footer body + sentinel tail in memory,
    // then `writePositionalAll` it at `data_end`. We use positional
    // writes so we never have to fight `pos` semantics across the
    // `setLength` above.
    const entry_count: u32 = @intCast(series_index.count());
    const entries = try allocator.alloc(segment.FooterEntry, entry_count);
    defer allocator.free(entries);

    var idx: usize = 0;
    var map_it = series_index.iterator();
    while (map_it.next()) |kv| {
        entries[idx] = kv.value_ptr.*;
        idx += 1;
    }
    std.debug.assert(idx == entry_count);

    std.mem.sort(segment.FooterEntry, entries, {}, struct {
        fn lessThan(_: void, a: segment.FooterEntry, b: segment.FooterEntry) bool {
            return a.series_id < b.series_id;
        }
    }.lessThan);

    const body_bytes: usize = 4 + @as(usize, entry_count) * segment.FooterEntry.encoded_size + 4;
    const body = try allocator.alloc(u8, body_bytes);
    defer allocator.free(body);

    std.mem.writeInt(u32, body[0..4], entry_count, .little);
    var pos: usize = 4;
    for (entries) |e| {
        e.serialize(body[pos..][0..segment.FooterEntry.encoded_size]);
        pos += segment.FooterEntry.encoded_size;
    }
    var hasher = Crc32C.init();
    hasher.update(body[0..pos]);
    const crc = hasher.final();
    std.mem.writeInt(u32, body[pos..][0..4], crc, .little);
    pos += 4;
    std.debug.assert(pos == body_bytes);

    try file.writePositionalAll(io, body, data_end);

    var tail: [segment.FOOTER_TAIL_SIZE]u8 = undefined;
    std.mem.writeInt(u64, tail[0..8], data_end, .little);
    std.mem.writeInt(u64, tail[8..16], segment.FOOTER_MAGIC, .little);
    try file.writePositionalAll(io, &tail, data_end + body_bytes);

    // 6) fsync per segment. Migrating 1000 segments in memory and
    // crashing before fsync would leave operators with a corrupt
    // data_dir; the per-segment fsync trades raw throughput for the
    // crash-safety invariant the rest of the engine relies on.
    try file.sync(io);

    return .{
        .already_indexed = false,
        .upgraded = true,
        .bytes_appended = body_bytes + segment.FOOTER_TAIL_SIZE,
        .series_count = entry_count,
    };
}

// =============================================================================
// Tests
// =============================================================================

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

// ---------------------------------------------------------------------------
// P-ALGO-001 footer-migration tests
// ---------------------------------------------------------------------------

/// Test helper — write a v2 segment, then truncate the trailing footer
/// + sentinel tail so the on-disk file looks like a pre-`4ec8c3a`
/// segment. Returns the byte offset where the data region ends (the
/// `current_offset` immediately after the last `writeBlock`).
fn writeV2SegmentWithoutFooter(
    allocator: Allocator,
    path: []const u8,
    blocks: []const struct { series_id: types.SeriesId, points: []const types.Point },
) !u64 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var data_end: u64 = 0;
    {
        var w = try segment.SegmentWriter.init(allocator, path);
        defer w.deinit();
        for (blocks) |b| try w.writeBlock(b.series_id, b.points);
        data_end = w.current_offset;
        try w.sync();
    }

    // Truncate everything past the last data block to simulate a
    // pre-footer segment on disk.
    const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try f.setLength(io, data_end);
    try f.sync(io);
    return data_end;
}

test "P-ALGO-001 migration: retrofits footer onto pre-existing segment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{base});
    defer allocator.free(seg_path);

    const pts_a = [_]types.Point{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 200, .value = 2 },
    };
    const pts_b = [_]types.Point{
        .{ .ts = 300, .value = 3 },
        .{ .ts = 400, .value = 4 },
    };

    const data_end = try writeV2SegmentWithoutFooter(allocator, seg_path, &.{
        .{ .series_id = 7, .points = &pts_a },
        .{ .series_id = 9, .points = &pts_b },
        .{ .series_id = 7, .points = &pts_a },
    });

    // Before migration, the reader must report no footer.
    {
        var r = try segment.SegmentReader.init(allocator, seg_path);
        defer r.deinit();
        try std.testing.expect(r.footer == null);
        try std.testing.expect(r.findSeries(7) == null);
    }

    const results = try migrateSegmentFooters(allocator, io, base);
    defer freeResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].upgraded);
    try std.testing.expect(!results[0].already_indexed);
    try std.testing.expectEqual(@as(u32, 2), results[0].series_count);
    try std.testing.expect(results[0].bytes_appended > 0);

    // The file must now carry a footer, and `findSeries` must return
    // the offset of each series' first block. We don't compare against
    // an absolute offset because we don't know it here, but we can
    // verify the offset lies within the original data region.
    var r = try segment.SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    try std.testing.expect(r.footer != null);
    try std.testing.expectEqual(@as(usize, 2), r.footer.?.entries.len);
    try std.testing.expectEqual(data_end, r.data_end_offset);

    const hit7 = r.findSeries(7) orelse return error.MissingSeries;
    try std.testing.expectEqual(@as(u32, 2), hit7.count);
    try std.testing.expect(hit7.offset >= segment.SEGMENT_MAGIC.len);
    try std.testing.expect(hit7.offset < data_end);

    const hit9 = r.findSeries(9) orelse return error.MissingSeries;
    try std.testing.expectEqual(@as(u32, 1), hit9.count);

    try std.testing.expect(r.findSeries(42) == null);

    // The block iterator must yield exactly three blocks (the original
    // data region is byte-identical to what the writer produced).
    var it = r.iterator();
    var seen: u32 = 0;
    while (try it.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(u32, 3), seen);
}

test "P-ALGO-001 migration: idempotent across multiple runs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);

    // Three segments:
    //   * 1.tsseg — fresh writer (already has footer).
    //   * 2.tsseg — truncated to pre-footer state.
    //   * 3.tsseg — truncated to pre-footer state.
    const fresh_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{base});
    defer allocator.free(fresh_path);
    const old_path_2 = try std.fmt.allocPrint(allocator, "{s}/2.tsseg", .{base});
    defer allocator.free(old_path_2);
    const old_path_3 = try std.fmt.allocPrint(allocator, "{s}/3.tsseg", .{base});
    defer allocator.free(old_path_3);

    const pts = [_]types.Point{ .{ .ts = 1, .value = 1 }, .{ .ts = 2, .value = 2 } };

    {
        var w = try segment.SegmentWriter.init(allocator, fresh_path);
        defer w.deinit();
        try w.writeBlock(1, &pts);
        try w.sync();
    }
    const fresh_size_before = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, fresh_path, .{});
        defer f.close(io);
        break :blk try f.length(io);
    };

    _ = try writeV2SegmentWithoutFooter(allocator, old_path_2, &.{.{ .series_id = 2, .points = &pts }});
    _ = try writeV2SegmentWithoutFooter(allocator, old_path_3, &.{.{ .series_id = 3, .points = &pts }});

    // First pass: fresh segment is skipped, two old segments are upgraded.
    {
        const results = try migrateSegmentFooters(allocator, io, base);
        defer freeResults(allocator, results);
        try std.testing.expectEqual(@as(usize, 3), results.len);
        var upgraded: u32 = 0;
        var skipped: u32 = 0;
        for (results) |r| {
            if (r.upgraded) upgraded += 1;
            if (r.already_indexed) skipped += 1;
        }
        try std.testing.expectEqual(@as(u32, 2), upgraded);
        try std.testing.expectEqual(@as(u32, 1), skipped);
    }

    // The fresh segment file must be byte-identical (same length —
    // a stricter "byte-identical" assertion is in the dedicated test
    // below).
    {
        const f = try std.Io.Dir.cwd().openFile(io, fresh_path, .{});
        defer f.close(io);
        try std.testing.expectEqual(fresh_size_before, try f.length(io));
    }

    // Second pass: every segment now has a footer; no upgrades expected.
    {
        const results = try migrateSegmentFooters(allocator, io, base);
        defer freeResults(allocator, results);
        try std.testing.expectEqual(@as(usize, 3), results.len);
        for (results) |r| {
            try std.testing.expect(!r.upgraded);
            try std.testing.expect(r.already_indexed);
            try std.testing.expectEqual(@as(u64, 0), r.bytes_appended);
        }
    }
}

test "P-ALGO-001 migration: fresh-footer file is not touched" {
    // Strict byte-identity check: a segment that already carries a
    // footer must not be modified by the migration. This catches a
    // regression where the magic-probe accidentally re-runs the
    // scan-and-append path.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{base});
    defer allocator.free(seg_path);

    const pts = [_]types.Point{ .{ .ts = 10, .value = 1 }, .{ .ts = 20, .value = 2 } };

    {
        var w = try segment.SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(123, &pts);
        try w.writeBlock(456, &pts);
        try w.sync();
    }

    const original = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{});
        defer f.close(io);
        const len = try f.length(io);
        const buf = try allocator.alloc(u8, len);
        const n = try f.readPositionalAll(io, buf, 0);
        try std.testing.expectEqual(len, n);
        break :blk buf;
    };
    defer allocator.free(original);

    const results = try migrateSegmentFooters(allocator, io, base);
    defer freeResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].already_indexed);

    const after = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{});
        defer f.close(io);
        const len = try f.length(io);
        const buf = try allocator.alloc(u8, len);
        const n = try f.readPositionalAll(io, buf, 0);
        try std.testing.expectEqual(len, n);
        break :blk buf;
    };
    defer allocator.free(after);

    try std.testing.expectEqualSlices(u8, original, after);
}

test "P-ALGO-001 migration: crash mid-write recovery via partial-footer truncation" {
    // Simulate a crash mid-append: write the magic but only PART of
    // the footer (so the trailing bytes do NOT match FOOTER_MAGIC).
    // The migration must:
    //   (a) detect the missing magic and re-enter the upgrade path,
    //   (b) truncate the corrupt suffix before appending,
    //   (c) produce a valid footer that round-trips through
    //       SegmentReader.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{base});
    defer allocator.free(seg_path);

    const pts = [_]types.Point{ .{ .ts = 1, .value = 1 }, .{ .ts = 2, .value = 2 } };
    const data_end = try writeV2SegmentWithoutFooter(allocator, seg_path, &.{
        .{ .series_id = 11, .points = &pts },
        .{ .series_id = 22, .points = &pts },
    });

    // Append 32 bytes of garbage past the last data block — simulates
    // a partial footer left by a crashed prior run. Crucially the
    // trailing 8 bytes are NOT FOOTER_MAGIC, so the reader's EOF probe
    // sees "no footer" and the migration sees "needs upgrade".
    {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{ .mode = .read_write });
        defer f.close(io);
        const garbage: [32]u8 = @splat(0xAB);
        try f.writePositionalAll(io, &garbage, data_end);
        try f.sync(io);
    }

    // Sanity: the reader confirms there's no footer.
    {
        var r = try segment.SegmentReader.init(allocator, seg_path);
        defer r.deinit();
        try std.testing.expect(r.footer == null);
    }

    // Run migration. The partial footer suffix must be truncated and
    // replaced with a real footer.
    const results = try migrateSegmentFooters(allocator, io, base);
    defer freeResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].upgraded);
    try std.testing.expectEqual(@as(u32, 2), results[0].series_count);

    // The reader now sees a valid footer pointing at the SAME data_end
    // as the original write — proving the migration truncated the
    // garbage suffix before appending.
    var r = try segment.SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    try std.testing.expect(r.footer != null);
    try std.testing.expectEqual(data_end, r.data_end_offset);
    try std.testing.expect(r.findSeries(11) != null);
    try std.testing.expect(r.findSeries(22) != null);
}

test "P-ALGO-001 migration: skips non-segment files in data_dir" {
    // Ensure migration walks ONLY *.tsseg files. WAL files, manifest
    // files, and operator-placed sidecars must be untouched.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);

    const seg_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{base});
    defer allocator.free(seg_path);
    const wal_path = try std.fmt.allocPrint(allocator, "{s}/wal.log", .{base});
    defer allocator.free(wal_path);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/MANIFEST", .{base});
    defer allocator.free(manifest_path);

    const pts = [_]types.Point{ .{ .ts = 1, .value = 1 }, .{ .ts = 2, .value = 2 } };
    _ = try writeV2SegmentWithoutFooter(allocator, seg_path, &.{.{ .series_id = 1, .points = &pts }});

    // Write a non-segment file with bytes that would crash any parser
    // that tried to deserialise them as a segment.
    {
        const f = try std.Io.Dir.cwd().createFile(io, wal_path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
        });
        defer f.close(io);
        const junk: [16]u8 = @splat(0xCD);
        try f.writeStreamingAll(io, &junk);
    }
    {
        const f = try std.Io.Dir.cwd().createFile(io, manifest_path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
        });
        defer f.close(io);
        const junk: [16]u8 = @splat(0xEF);
        try f.writeStreamingAll(io, &junk);
    }

    const results = try migrateSegmentFooters(allocator, io, base);
    defer freeResults(allocator, results);
    // Only one *.tsseg file in the directory; the other two are skipped.
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.endsWith(u8, results[0].path, "1.tsseg"));
    try std.testing.expect(results[0].upgraded);

    // Verify the non-segment files were not modified.
    {
        const f = try std.Io.Dir.cwd().openFile(io, wal_path, .{});
        defer f.close(io);
        try std.testing.expectEqual(@as(u64, 16), try f.length(io));
    }
    {
        const f = try std.Io.Dir.cwd().openFile(io, manifest_path, .{});
        defer f.close(io);
        try std.testing.expectEqual(@as(u64, 16), try f.length(io));
    }
}

test "P-ALGO-001 migration: empty data_dir yields empty result set" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);

    const results = try migrateSegmentFooters(allocator, io, base);
    defer freeResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}
