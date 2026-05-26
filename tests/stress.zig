// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress tests for timeseries-storage.
//!
//! These tests run via `zig build test-stress` and are intended to
//! exercise the library under load: high iteration counts, concurrent
//! callers, large inputs, etc. They run in ReleaseFast by default
//! (Debug under `-Dtsan`) so they finish in CI-acceptable time. Each
//! test constructs a real `Engine` over a fresh tmpdir and drives it
//! with thousands of appendPoints calls, then validates a query at
//! the end.

const std = @import("std");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

test "stress: 1000 batched appendPoints into a single series" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1000,
    }, &pool);
    defer eng.deinit();

    const series_id: lib.types.SeriesId = 99;
    const batch_size: usize = 10;
    var batch: [batch_size]lib.types.Point = undefined;

    var iter: i64 = 0;
    while (iter < 1000) : (iter += 1) {
        const base = iter * @as(i64, batch_size);
        for (0..batch_size) |i| {
            batch[i] = .{
                .ts = base + @as(i64, @intCast(i)),
                .value = base + @as(i64, @intCast(i)),
            };
        }
        try eng.appendPoints(series_id, &batch);
    }

    try eng.flush();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var it = try eng.queryPoints(arena.allocator(), series_id, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |_| count += 1;

    try std.testing.expectEqual(@as(usize, 1000 * batch_size), count);
}
