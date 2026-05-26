// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! WAL recovery regression tests.
//!
//! Run via `zig build test-wal-recovery`. Verifies that
//! `Engine.init` honours the `wal_recovery` policy:
//!
//! - `fail_closed` (default): a corrupted WAL byte must surface as an
//!   `error.ChecksumMismatch` or `error.InvalidFormat` from
//!   `Engine.init` — the engine refuses to start on damaged data.
//! - `salvage`: the same corruption must be tolerated, with a
//!   best-effort recovery that drops the bad record.

const std = @import("std");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

/// Write a small batch of points, sync, and let everything tear down
/// cleanly so the WAL file ends up on disk in a consistent state.
fn seedEngine(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    points_per_batch: usize,
) !void {
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        // Large memtable so the seed batch never triggers a flush;
        // we want the data to live exclusively in the WAL until the
        // engine is closed, so the recovery path is the only way to
        // get it back on the next open.
        .max_memtable_points = 1_000_000,
    }, &pool);
    defer eng.deinit();

    const pts_buf = try allocator.alloc(lib.types.Point, points_per_batch);
    defer allocator.free(pts_buf);
    for (pts_buf, 0..) |*p, i| p.* = .{ .ts = @intCast(1000 + i), .value = @intCast(i) };

    try eng.appendPoints(42, pts_buf);
    try eng.sync();
}

/// CRC32-IsoHDLC (RFC 1952 / zlib) used by the underlying wal library
/// for the outer envelope CRC.
const Crc32IsoHdlc = std.hash.crc.Crc32IsoHdlc;

/// On-disk layout per wal_lib record:
///   [wal_lsn: u64 LE][wal_payload_len: u32 LE]
///   [payload: WalRecord serialized bytes]
///   [wal_crc: u32 LE]   ← CRC32-IsoHDLC over the 12-byte header + payload
///
/// The inner `payload` is a `WalRecord` serialised by our project, which
/// itself ends with a CRC32C ("Castagnoli") that covers `lsn || type ||
/// payload_len || payload`.
///
/// To simulate the silent-corruption scenario the strict path is
/// supposed to catch, we flip a byte inside the inner WalRecord's
/// checksum field — that breaks the inner CRC32C without breaking the
/// outer envelope, but we still have to recompute the outer envelope
/// CRC32-IsoHDLC after the flip so wal_lib does not short-circuit and
/// silently return EOF first.
fn corruptInnerChecksum(data_dir: []const u8) !void {
    var path_buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ts.wal", .{data_dir});

    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);

    // Slurp the whole file into memory; production WALs are bigger but
    // the test data is a few hundred bytes.
    const allocator = std.testing.allocator;
    const len = try f.length(io);
    const file_bytes = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(file_bytes);
    const read_n = try f.readPositionalAll(io, file_bytes, 0);
    if (read_n != file_bytes.len) return error.UnexpectedEndOfFile;

    // Walk wal_lib records and find one whose inner payload looks like
    // an `append_points` WalRecord (record_type byte == 1 immediately
    // after the inner 8-byte LSN). The inner checksum is the last 4
    // bytes of the inner payload.
    var off: usize = 0;
    while (off + 12 <= file_bytes.len) {
        const wal_payload_len = std.mem.readInt(u32, file_bytes[off + 8 ..][0..4], .little);
        const total = 12 + @as(usize, wal_payload_len) + 4;
        if (off + total > file_bytes.len) break;

        const payload_start = off + 12;
        const payload_end = payload_start + wal_payload_len;

        // Heuristic: payload large enough to contain a WalRecord, and
        // its record_type byte at offset 8 is 1 (`append_points`).
        if (wal_payload_len >= 17 and file_bytes[payload_start + 8] == 1) {
            // Flip a bit inside the inner WalRecord's trailing
            // checksum (last 4 bytes of the wal_lib payload).
            const inner_crc_off = payload_end - 4;
            file_bytes[inner_crc_off] ^= 0xFF;

            // Recompute the outer wal_lib CRC over [header || payload]
            // so the envelope still passes wal_lib's own integrity
            // check and the iterator delivers the record up to us.
            var h = Crc32IsoHdlc.init();
            h.update(file_bytes[off .. off + 12 + wal_payload_len]);
            const new_crc = h.final();
            std.mem.writeInt(u32, file_bytes[payload_end..][0..4], new_crc, .little);

            // Write the whole modified file back. We do not bother
            // optimising — the file is tiny.
            try f.writePositionalAll(io, file_bytes, 0);
            try f.sync(io);
            return;
        }

        off += total;
    }

    return error.NoAppendPointsRecord;
}

test "wal recovery: fail_closed rejects corrupted WAL" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    try seedEngine(allocator, data_dir, 8);

    // Corrupt the inner `WalRecord` checksum so the envelope still
    // passes wal_lib's own CRC and the iterator delivers the record
    // to our strict path. Our strict path is the one that must catch
    // the inner-CRC mismatch and refuse to open the engine.
    try corruptInnerChecksum(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    const result = lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
    }, &pool);

    if (result) |eng_val| {
        var eng_mut = eng_val;
        eng_mut.deinit();
        try std.testing.expect(false); // expected an error
    } else |err| {
        try std.testing.expect(err == error.ChecksumMismatch or err == error.InvalidFormat);
    }
}

test "wal recovery: salvage tolerates corrupted WAL" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    try seedEngine(allocator, data_dir, 8);
    try corruptInnerChecksum(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Salvage mode must not propagate the corruption error: it
    // tolerates checksum failures by falling through to the lossy
    // `readFrom` path. We do not assert how many points survived —
    // the bad record may or may not be deserialisable past the
    // checksum check; what matters is that the open succeeded.
    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .wal_recovery = .salvage,
    }, &pool);
    defer eng.deinit();
}

test "wal recovery: clean WAL replays under fail_closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    // Seed a known batch.
    try seedEngine(allocator, data_dir, 5);

    // Reopen with the default fail_closed policy and verify the
    // memtable replay sees all five points.
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
    }, &pool);
    defer eng.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 42, 0, 1_000_000);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "wal recovery: empty data_dir rejected" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    const result = lib.Engine.init(allocator, .{
        .data_dir = "",
        .max_memtable_points = 100,
    }, &pool);
    try std.testing.expectError(error.InvalidDataDir, result);
}

test "wal recovery: data_dir with traversal segment rejected" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    const result = lib.Engine.init(allocator, .{
        .data_dir = "../etc",
        .max_memtable_points = 100,
    }, &pool);
    try std.testing.expectError(error.PathTraversal, result);
}
