// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! A refused WAL compaction after a flush is non-fatal (SONNY-6622).
//!
//! After a flush makes its segment and manifest durable, the engine
//! compacts the WAL up to the new checkpoint. Since wal v0.1.24 that
//! compaction validates the whole log first and refuses
//! (`WalEncryptionMismatch` / `WalAuthFailed` / `WalCorrupted`), leaving
//! the file untouched, when any byte is not part of a valid record. The
//! flush has already succeeded and the records the compaction would have
//! dropped are covered by the segment, so the refusal must not surface as
//! a background failure: the WAL stays usable, later appends land after
//! the last valid record, and a reopen recovers every point.
//!
//! Pulled into `zig build test-integration` from `integration.zig`.

const std = @import("std");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

const SERIES: lib.types.SeriesId = 11;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const CallbackLog = struct {
    calls: usize = 0,
    last: ?anyerror = null,

    fn record(ctx: *anyopaque, _: lib.engine.BgPhase, err: anyerror) void {
        const self: *CallbackLog = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last = err;
    }
};

/// Write `bytes` past the end of `ts.wal` through a separate handle, as
/// stray bytes after the last valid record (e.g. a torn write the engine
/// did not see). The WAL's own cursor stays at its last valid record.
fn appendStrayBytes(data_dir: []const u8, bytes: []const u8) !void {
    var path_buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ts.wal", .{data_dir});
    const f = try std.Io.Dir.cwd().openFile(io(), path, .{ .mode = .read_write });
    defer f.close(io());
    const len = try f.length(io());
    try f.writePositionalAll(io(), bytes, len);
    try f.sync(io());
}

fn waitForFlushWorker(eng: *lib.Engine) void {
    const eio = eng.io;
    eng.mu.lockUncancelable(eio);
    defer eng.mu.unlock(eio);
    while (eng.compaction_running or eng.flushing_mem != null or eng.flush_workers_active > 0) {
        eng.done_cv.waitUncancelable(eio, &eng.mu);
    }
}

fn countPoints(allocator: std.mem.Allocator, eng: *lib.Engine) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), SERIES, 0, std.math.maxInt(i64));
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn refusedCompactionCase(key: ?[32]u8) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmp.dir.realPathFileAlloc(io(), ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var cb_log: CallbackLog = .{};
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .encryption_key = key,
            .error_callback = CallbackLog.record,
            .error_callback_ctx = &cb_log,
        }, &pool);
        defer eng.deinit();

        try eng.appendPoints(SERIES, &.{ .{ .ts = 1, .value = 10 }, .{ .ts = 2, .value = 20 } });
        try eng.appendPoints(SERIES, &.{.{ .ts = 3, .value = 30 }});
        try eng.sync();

        // Seven bytes: shorter than any record header, so not a record.
        try appendStrayBytes(data_dir, &[_]u8{0xEE} ** 7);

        // The flush itself must succeed; its WAL compaction is refused.
        // `flush()` returns once the segment is durable; wait for the
        // worker's trailing WAL compaction before inspecting its outcome.
        try eng.flush();
        waitForFlushWorker(&eng);
        try std.testing.expectEqual(@as(?anyerror, null), eng.lastBackgroundError());
        try std.testing.expectEqual(@as(usize, 0), cb_log.calls);
        try std.testing.expectEqual(@as(u64, 1), eng.stats().wal_compactions_refused);

        // The WAL stays usable: appends after the refusal are durable.
        try eng.appendPoints(SERIES, &.{ .{ .ts = 4, .value = 40 }, .{ .ts = 5, .value = 50 } });
        try eng.sync();
        try std.testing.expectEqual(@as(usize, 5), try countPoints(allocator, &eng));
    }

    // Reopen: flushed points come from the segment, later ones from the WAL.
    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = key,
    }, &pool);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 5), try countPoints(allocator, &eng));
}

test "wal compaction refusal: plaintext refused compaction after flush is non-fatal" {
    try refusedCompactionCase(null);
}

test "wal compaction refusal: encrypted refused compaction after flush is non-fatal" {
    try refusedCompactionCase([_]u8{0x6C} ** 32);
}
