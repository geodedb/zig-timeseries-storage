// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! End-to-end Engine tests for timeseries-storage.
//!
//! These tests run via `zig build test-engine-e2e` and exercise the
//! Engine through its full ingestion + flush + query path with
//! large input volumes. Use this file for high-fan-in scenarios that
//! would dominate the runtime of the default unit-test suite.

const std = @import("std");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

test "End-to-End: Insert 100k points across multiple series" {
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
        .max_memtable_points = 10000,
    }, &pool);
    defer eng.deinit();

    const num_series = 10;
    const points_per_series = 10000;

    var pts = try allocator.alloc(lib.types.Point, 1000);
    defer allocator.free(pts);

    for (0..num_series) |s_id| {
        var t: i64 = 1000;
        var remaining: usize = points_per_series;
        while (remaining > 0) {
            const batch_size = @min(remaining, 1000);
            for (0..batch_size) |i| {
                pts[i] = .{ .ts = t, .value = @intCast(s_id * 100 + i) };
                t += 10;
            }
            try eng.appendPoints(@intCast(s_id), pts[0..batch_size]);
            remaining -= batch_size;
        }
    }

    try eng.flush(); // Flush remaining

    try std.testing.expect(eng.man.segments.items.len <= 10);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var merge_it = try eng.queryPoints(arena.allocator(), 1, 1000, 2000);

    var count: usize = 0;
    while (merge_it.next()) |_| {
        count += 1;
    }

    // Series 1 starts at 1000, goes up by 10. 2000 is included.
    // 1000 to 2000 (inclusive) = 101 points.
    try std.testing.expectEqual(@as(usize, 101), count);
}
