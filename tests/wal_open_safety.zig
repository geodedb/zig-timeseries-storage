// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! WAL open-safety regression tests (SONNY-6615).
//!
//! `Engine.init` used to truncate `ts.wal` to zero bytes whenever the
//! wal library could not decode its first record. Opening a plaintext
//! WAL with an encryption key, an encrypted WAL without one, or an
//! encrypted WAL with the wrong key therefore destroyed every point
//! that had not yet been flushed to a segment.
//!
//! These tests drive the real `Engine` against real files:
//!
//!   - a key-mode mismatch (either direction) or a wrong key fails with
//!     a distinct error and leaves `ts.wal` byte-for-byte intact, and a
//!     reopen in the right mode recovers every point;
//!   - a torn tail is truncated from the first bad record onward only;
//!   - a corrupt record in the middle of the WAL (valid records follow
//!     it) fails closed under the default policy and leaves the file
//!     intact; `.salvage` opts in to point-in-time recovery up to it.
//!
//! The seed engines never call `sync()` or `flush()`, so no manifest
//! is written and the WAL is the only copy of the data. That is the
//! crash-before-first-checkpoint state in which the manifest layer
//! cannot reject a mismatched key first.
//!
//! Pulled into `zig build test-integration` from `integration.zig`.

const std = @import("std");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

const SERIES: lib.types.SeriesId = 7;
const KEY_A: [32]u8 = [_]u8{0xA5} ** 32;
const KEY_B: [32]u8 = [_]u8{0x5A} ** 32;

/// Encrypted wal-library framing: [blob_len u32][magic 8][nonce 12][tag 16][ct].
const ENC_BLOB_LEN_SIZE: usize = 4;
const ENC_MAGIC_OFFSET: usize = 4;
const ENC_CIPHERTEXT_OFFSET: usize = 40;
/// Plaintext wal-library framing: [lsn u64][payload_len u32][payload][crc32 u32].
const PT_HEADER_SIZE: usize = 12;
const PT_CRC_SIZE: usize = 4;

const io_single = std.Io.Threaded.global_single_threaded;

fn io() std.Io {
    return io_single.io();
}

/// Open an engine in `key` mode, append `batches` single-point batches
/// (one WAL record each) and close WITHOUT `sync()` / `flush()`.
fn seed(allocator: std.mem.Allocator, data_dir: []const u8, key: ?[32]u8, batches: usize) !void {
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = key,
    }, &pool);
    defer eng.deinit();

    for (0..batches) |i| {
        const ts: i64 = @intCast(100 + i);
        try eng.appendPoints(SERIES, &.{.{ .ts = ts, .value = @intCast(i * 10) }});
    }
}

fn openEngine(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    key: ?[32]u8,
    policy: lib.engine.WalRecoveryPolicy,
    pool: *thread_pool.ThreadPool,
) !lib.Engine {
    return lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = key,
        .wal_recovery = policy,
    }, pool);
}

/// Open the engine in `key` mode and return how many points of SERIES
/// it serves. Fails the test if the open fails.
fn recoveredPointCount(allocator: std.mem.Allocator, data_dir: []const u8, key: ?[32]u8, policy: lib.engine.WalRecoveryPolicy) !usize {
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try openEngine(allocator, data_dir, key, policy, &pool);
    defer eng.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), SERIES, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    return count;
}

/// Assert `Engine.init` in `key` mode fails with `expected`.
fn expectOpenError(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    key: ?[32]u8,
    policy: lib.engine.WalRecoveryPolicy,
    expected: anyerror,
) !void {
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    if (openEngine(allocator, data_dir, key, policy, &pool)) |opened| {
        var eng = opened;
        eng.deinit();
        std.debug.print("Engine.init unexpectedly succeeded; expected error.{s}\n", .{@errorName(expected)});
        return error.TestUnexpectedSuccess;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

fn walPath(buf: []u8, data_dir: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/ts.wal", .{data_dir});
}

fn readWal(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path = try walPath(&path_buf, data_dir);
    const f = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer f.close(io());
    const len: usize = @intCast(try f.length(io()));
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    const n = try f.readPositionalAll(io(), bytes, 0);
    try std.testing.expectEqual(len, n);
    return bytes;
}

fn writeWal(data_dir: []const u8, bytes: []const u8) !void {
    var path_buf: [1024]u8 = undefined;
    const path = try walPath(&path_buf, data_dir);
    const f = try std.Io.Dir.cwd().openFile(io(), path, .{ .mode = .read_write });
    defer f.close(io());
    try f.setLength(io(), 0);
    try f.writePositionalAll(io(), bytes, 0);
    try f.sync(io());
}

/// Drop the wal library's checkpoint sidecar so the next open performs a
/// full scan of the hand-edited WAL instead of trusting a stale boundary.
fn dropWalCheckpoint(data_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "ts.wal") and !std.mem.eql(u8, entry.name, "ts.wal")) {
            try dir.deleteFile(io(), entry.name);
        }
    }
}

fn expectNoManifest(data_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{});
    defer dir.close(io());
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |name| {
        if (dir.access(io(), name, .{})) |_| {
            std.debug.print("seed wrote {s}; the WAL is not the only copy\n", .{name});
            return error.TestUnexpectedManifest;
        } else |_| {}
    }
}

/// Byte offsets at which each wal-library record starts.
fn recordStarts(allocator: std.mem.Allocator, bytes: []const u8, encrypted: bool) ![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(allocator);
    var off: usize = 0;
    while (off < bytes.len) {
        try starts.append(allocator, off);
        if (encrypted) {
            const blob_len = std.mem.readInt(u32, bytes[off..][0..4], .little);
            off += ENC_BLOB_LEN_SIZE + blob_len;
        } else {
            const payload_len = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little);
            off += PT_HEADER_SIZE + payload_len + PT_CRC_SIZE;
        }
    }
    try std.testing.expectEqual(bytes.len, off);
    return starts.toOwnedSlice(allocator);
}

fn tmpDataDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(io(), ".", allocator);
}

// ---------------------------------------------------------------------------
// Key-mode mismatch and wrong key: fail with a distinct error, touch nothing.
// ---------------------------------------------------------------------------

test "wal open safety: plaintext WAL opened with a key fails WalEncryptionMismatch and is left intact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    try seed(allocator, data_dir, null, 5);
    try expectNoManifest(data_dir);
    const before = try readWal(allocator, data_dir);
    defer allocator.free(before);
    try std.testing.expect(before.len > 0);

    try expectOpenError(allocator, data_dir, KEY_A, .fail_closed, error.WalEncryptionMismatch);
    // `.salvage` must not turn a configuration error into data loss.
    try expectOpenError(allocator, data_dir, KEY_A, .salvage, error.WalEncryptionMismatch);

    const after = try readWal(allocator, data_dir);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    try std.testing.expectEqual(@as(usize, 5), try recoveredPointCount(allocator, data_dir, null, .fail_closed));
}

test "wal open safety: encrypted WAL opened without a key fails WalEncryptionMismatch and is left intact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    try seed(allocator, data_dir, KEY_A, 5);
    try expectNoManifest(data_dir);
    const before = try readWal(allocator, data_dir);
    defer allocator.free(before);
    try std.testing.expect(before.len > 0);

    try expectOpenError(allocator, data_dir, null, .fail_closed, error.WalEncryptionMismatch);
    try expectOpenError(allocator, data_dir, null, .salvage, error.WalEncryptionMismatch);

    const after = try readWal(allocator, data_dir);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    try std.testing.expectEqual(@as(usize, 5), try recoveredPointCount(allocator, data_dir, KEY_A, .fail_closed));
}

test "wal open safety: encrypted WAL opened with the wrong key fails WalAuthFailed and is left intact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    try seed(allocator, data_dir, KEY_A, 5);
    try expectNoManifest(data_dir);
    const before = try readWal(allocator, data_dir);
    defer allocator.free(before);

    try expectOpenError(allocator, data_dir, KEY_B, .fail_closed, error.WalAuthFailed);
    try expectOpenError(allocator, data_dir, KEY_B, .salvage, error.WalAuthFailed);

    const after = try readWal(allocator, data_dir);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    try std.testing.expectEqual(@as(usize, 5), try recoveredPointCount(allocator, data_dir, KEY_A, .fail_closed));
}

// ---------------------------------------------------------------------------
// Torn tail: truncate from the first bad record onward, never earlier.
// ---------------------------------------------------------------------------

fn tornTailCase(key: ?[32]u8) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    try seed(allocator, data_dir, key, 4);
    const full = try readWal(allocator, data_dir);
    defer allocator.free(full);
    const starts = try recordStarts(allocator, full, key != null);
    defer allocator.free(starts);
    try std.testing.expectEqual(@as(usize, 4), starts.len);

    // Crash mid-append of the 4th record: only part of it reached disk.
    const last = starts[3];
    const torn_len = last + (full.len - last) / 2;
    try writeWal(data_dir, full[0..torn_len]);
    try dropWalCheckpoint(data_dir);

    try std.testing.expectEqual(@as(usize, 3), try recoveredPointCount(allocator, data_dir, key, .fail_closed));

    // Truncated exactly at the first bad record; records 1-3 untouched.
    const after = try readWal(allocator, data_dir);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, full[0..last], after);
}

test "wal open safety: plaintext torn tail is truncated from the first bad record only" {
    try tornTailCase(null);
}

test "wal open safety: encrypted torn tail is truncated from the first bad record only" {
    try tornTailCase(KEY_A);
}

fn tornLastRecordCrcCase(key: ?[32]u8) !void {
    // The last record is fully sized on disk but its bytes are damaged
    // (a torn sector inside the final append). Nothing valid follows, so
    // it is a torn tail: truncate it, keep everything before it.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    try seed(allocator, data_dir, key, 4);
    const full = try readWal(allocator, data_dir);
    defer allocator.free(full);
    const starts = try recordStarts(allocator, full, key != null);
    defer allocator.free(starts);

    const damaged = try allocator.dupe(u8, full);
    defer allocator.free(damaged);
    damaged[damaged.len - 2] ^= 0xFF;
    try writeWal(data_dir, damaged);
    try dropWalCheckpoint(data_dir);

    try std.testing.expectEqual(@as(usize, 3), try recoveredPointCount(allocator, data_dir, key, .fail_closed));
    const after = try readWal(allocator, data_dir);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, full[0..starts[3]], after);
}

test "wal open safety: plaintext damaged final record is treated as a torn tail" {
    try tornLastRecordCrcCase(null);
}

test "wal open safety: encrypted damaged final record is treated as a torn tail" {
    try tornLastRecordCrcCase(KEY_A);
}

// ---------------------------------------------------------------------------
// Corrupt record in the middle: valid records follow it, so it is not a
// torn tail. Default policy fails closed; `.salvage` keeps the prefix.
// ---------------------------------------------------------------------------

fn midLogCorruptionCase(key: ?[32]u8) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    try seed(allocator, data_dir, key, 5);
    const full = try readWal(allocator, data_dir);
    defer allocator.free(full);
    const starts = try recordStarts(allocator, full, key != null);
    defer allocator.free(starts);
    try std.testing.expectEqual(@as(usize, 5), starts.len);

    // Flip a byte inside the 2nd record's payload/ciphertext. Its length
    // field stays intact; records 3-5 remain valid.
    const damaged = try allocator.dupe(u8, full);
    defer allocator.free(damaged);
    const body_off = if (key != null) ENC_CIPHERTEXT_OFFSET else PT_HEADER_SIZE;
    damaged[starts[1] + body_off + 1] ^= 0xFF;
    try writeWal(data_dir, damaged);
    try dropWalCheckpoint(data_dir);

    try expectOpenError(allocator, data_dir, key, .fail_closed, error.WalCorrupted);
    {
        const after = try readWal(allocator, data_dir);
        defer allocator.free(after);
        try std.testing.expectEqualSlices(u8, damaged, after);
    }

    // Operator opts in to lossy point-in-time recovery: keep record 1,
    // drop from the first bad record onward.
    try std.testing.expectEqual(@as(usize, 1), try recoveredPointCount(allocator, data_dir, key, .salvage));
    const after = try readWal(allocator, data_dir);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, full[0..starts[1]], after);
}

test "wal open safety: plaintext corrupt record mid-WAL fails WalCorrupted, salvage keeps the prefix" {
    try midLogCorruptionCase(null);
}

test "wal open safety: encrypted corrupt record mid-WAL fails WalCorrupted, salvage keeps the prefix" {
    try midLogCorruptionCase(KEY_A);
}

test "wal open safety: corrupt first record with valid records after it is not truncated" {
    // The first record is damaged, the rest are valid. Before the fix the
    // whole file was truncated; it must now fail closed and keep every byte.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    try seed(allocator, data_dir, KEY_A, 3);
    const full = try readWal(allocator, data_dir);
    defer allocator.free(full);

    const damaged = try allocator.dupe(u8, full);
    defer allocator.free(damaged);
    damaged[ENC_CIPHERTEXT_OFFSET + 1] ^= 0xFF;
    try writeWal(data_dir, damaged);
    try dropWalCheckpoint(data_dir);

    try expectOpenError(allocator, data_dir, KEY_A, .fail_closed, error.WalCorrupted);
    const after = try readWal(allocator, data_dir);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, damaged, after);
}

test "wal open safety: clean reopen in the same mode still recovers every point" {
    const allocator = std.testing.allocator;
    for ([_]?[32]u8{ null, KEY_A }) |key| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data_dir = try tmpDataDir(allocator, &tmp);
        defer allocator.free(data_dir);

        try seed(allocator, data_dir, key, 6);
        const before = try readWal(allocator, data_dir);
        defer allocator.free(before);
        try std.testing.expectEqual(@as(usize, 6), try recoveredPointCount(allocator, data_dir, key, .fail_closed));
        const after = try readWal(allocator, data_dir);
        defer allocator.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
    }
}
