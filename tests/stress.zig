// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress tests for timeseries-storage.
//!
//! These tests run via `zig build test-stress` and are intended to
//! exercise the library under load: high iteration counts, large
//! inputs, mixed batch sizes, and compaction-triggering workloads.
//! They run in ReleaseFast by default (Debug under `-Dtsan`) so they
//! finish in CI-acceptable time. Each test constructs a real
//! `Engine` over a fresh tmpdir and drives it with thousands of
//! appendPoints calls, then validates a query at the end.

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

test "stress: 1000 iters x 4 series x mixed batch sizes, end-to-end query consistency" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        // Tuned so the 1000-iter run produces multiple flushes and at
        // least one compaction round (L0 threshold is 4 segments).
        .max_memtable_points = 2_000,
    }, &pool);
    defer eng.deinit();

    const num_series: u128 = 4;
    const num_iters: usize = 1000;

    // We pre-allocate the largest possible batch buffer and reuse it.
    // Batch sizes cycle through 1, 8, 64, 256 to drive a mix of small
    // and large appends through the WAL + memtable path.
    const batch_sizes = [_]usize{ 1, 8, 64, 256 };
    const max_batch = 256;
    var batch_buf: [max_batch]lib.types.Point = undefined;

    // Track per-series expected counts so the assertion at the end is
    // an exact-equality check, not a "more than X" check.
    var expected: [num_series]usize = [_]usize{0} ** num_series;

    var i: usize = 0;
    while (i < num_iters) : (i += 1) {
        const series: u128 = @intCast(i % num_series);
        const batch_size = batch_sizes[i % batch_sizes.len];
        const base = @as(i64, @intCast(i)) * @as(i64, @intCast(max_batch));
        for (0..batch_size) |k| {
            batch_buf[k] = .{
                .ts = base + @as(i64, @intCast(k)),
                .value = base + @as(i64, @intCast(k)),
            };
        }
        try eng.appendPoints(series, batch_buf[0..batch_size]);
        expected[@intCast(series)] += batch_size;
    }

    // Drain the active memtable and confirm any background errors
    // were surfaced via the public callback path rather than swallowed.
    try eng.flush();
    try std.testing.expect(eng.lastBackgroundError() == null);

    var s: u128 = 0;
    while (s < num_series) : (s += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), s, 0, std.math.maxInt(i64));
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try std.testing.expectEqual(expected[@intCast(s)], count);
    }
}

test "stress: append -> flush -> compactAll -> query consistency under load" {
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
        // Force many small flushes to exercise the compaction path.
        .max_memtable_points = 100,
    }, &pool);
    defer eng.deinit();

    const num_flushes: usize = 20;
    const points_per_flush: usize = 100;
    var batch: [points_per_flush]lib.types.Point = undefined;

    var f: usize = 0;
    while (f < num_flushes) : (f += 1) {
        const base = @as(i64, @intCast(f)) * @as(i64, @intCast(points_per_flush));
        for (0..points_per_flush) |i| {
            batch[i] = .{
                .ts = base + @as(i64, @intCast(i)),
                .value = base + @as(i64, @intCast(i)),
            };
        }
        try eng.appendPoints(1, &batch);
        try eng.flush();
    }

    // After all the small flushes the manifest should hold multiple
    // segments (some may have been auto-compacted into L1 already).
    try std.testing.expect(eng.man.segments.items.len >= 1);

    try eng.compactAll();

    // After forced compaction everything left must be L1.
    for (eng.man.segments.items) |seg| {
        try std.testing.expect(seg.level >= 1);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 1, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |_| count += 1;

    try std.testing.expectEqual(num_flushes * points_per_flush, count);
}
