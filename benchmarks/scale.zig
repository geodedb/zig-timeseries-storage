// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Scale benchmark suite for timeseries-storage.
//!
//! Larger / longer runs than the default `bench` suite. Wired via
//! `zig build scale-bench`, gated to schedule/manual in CI.
//!
//! Same set of scenarios as `bench.zig` but scaled 4-10x. Closes
//! GAP-0011 alongside `bench.zig`.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");
const framework = @import("framework");

const APPEND_SINGLE_SERIES_TOTAL: usize = 1_000_000;
const APPEND_HIGH_CARDINALITY_SERIES: usize = 50_000;
const APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES: usize = 10;
const QUERY_TOTAL: usize = 500_000;
const QUERY_RECENT_WINDOW: usize = 5_000;
const FLUSH_BATCH_POINTS: usize = 10_000;
const COMPACTION_L0_COUNT: usize = 8;
const COMPACTION_POINTS_PER_L0: usize = 2_000;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{
            .name = "scale_append_single_series",
            .ops_per_iteration = APPEND_SINGLE_SERIES_TOTAL,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = runAppendSingleSeries,
        },
        .{
            .name = "scale_append_high_cardinality",
            .ops_per_iteration = APPEND_HIGH_CARDINALITY_SERIES * APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = runAppendHighCardinality,
        },
        .{
            .name = "scale_query_recent",
            .ops_per_iteration = QUERY_RECENT_WINDOW,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = runQueryRecent,
        },
        .{
            .name = "scale_query_full_range",
            .ops_per_iteration = QUERY_TOTAL,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = runQueryFullRange,
        },
        .{
            .name = "scale_flush_cost",
            .ops_per_iteration = FLUSH_BATCH_POINTS,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = runFlushCost,
        },
        .{
            .name = "scale_compaction_cost",
            .ops_per_iteration = COMPACTION_L0_COUNT,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = runCompactionCost,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "scale-bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn scaleTmpDir(allocator: std.mem.Allocator, ctx: *framework.Context) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fmt.allocPrint(allocator, "/tmp/ts-scale-{s}-{d}", .{
        ctx.scenario.name,
        ctx.iteration_index,
    });
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn runAppendSingleSeries(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        // Allow auto-flushes during the run so this benchmark
        // captures realistic end-to-end ingest cost including flush.
        .max_memtable_points = 100_000,
    }, &pool);
    defer eng.deinit();

    try preloadSeries(&eng, 1, APPEND_SINGLE_SERIES_TOTAL);
    std.mem.doNotOptimizeAway(eng.man.last_checkpoint_lsn);
}

fn runAppendHighCardinality(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = APPEND_HIGH_CARDINALITY_SERIES * APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES + 1,
    }, &pool);
    defer eng.deinit();

    var batch: [APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES]lib.types.Point = undefined;
    var s: u128 = 0;
    while (s < APPEND_HIGH_CARDINALITY_SERIES) : (s += 1) {
        const base = @as(i64, @intCast(s)) * @as(i64, @intCast(APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES));
        for (0..APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES) |i| {
            batch[i] = .{ .ts = base + @as(i64, @intCast(i)), .value = base + @as(i64, @intCast(i)) };
        }
        try eng.appendPoints(s, &batch);
    }
    std.mem.doNotOptimizeAway(eng.man.last_checkpoint_lsn);
}

fn runQueryRecent(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 50_000,
    }, &pool);
    defer eng.deinit();

    try preloadSeries(&eng, 1, QUERY_TOTAL);
    try eng.flush();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const start_ts: i64 = @intCast(QUERY_TOTAL - QUERY_RECENT_WINDOW);
    var it = try eng.queryPoints(arena.allocator(), 1, start_ts, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    std.mem.doNotOptimizeAway(count);
}

fn runQueryFullRange(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 50_000,
    }, &pool);
    defer eng.deinit();

    try preloadSeries(&eng, 1, QUERY_TOTAL);
    try eng.flush();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 1, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    std.mem.doNotOptimizeAway(count);
}

fn runFlushCost(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = FLUSH_BATCH_POINTS * 2,
    }, &pool);
    defer eng.deinit();

    try preloadSeries(&eng, 1, FLUSH_BATCH_POINTS);
    try eng.flush();
    std.mem.doNotOptimizeAway(eng.man.segments.items.len);
}

fn runCompactionCost(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = COMPACTION_POINTS_PER_L0 * 2,
    }, &pool);
    defer eng.deinit();

    var ts: i64 = 0;
    var i: usize = 0;
    while (i < COMPACTION_L0_COUNT) : (i += 1) {
        try preloadSeriesFrom(&eng, 1, COMPACTION_POINTS_PER_L0, ts);
        ts += @as(i64, @intCast(COMPACTION_POINTS_PER_L0));
        try eng.flush();
    }

    try eng.compactAll();
    std.mem.doNotOptimizeAway(eng.man.segments.items.len);
}

fn preloadSeries(eng: *lib.Engine, series: lib.types.SeriesId, count: usize) !void {
    try preloadSeriesFrom(eng, series, count, 0);
}

fn preloadSeriesFrom(eng: *lib.Engine, series: lib.types.SeriesId, count: usize, base_ts: i64) !void {
    var batch: [512]lib.types.Point = undefined;
    var remaining = count;
    var ts: i64 = base_ts;
    while (remaining > 0) {
        const n = @min(remaining, batch.len);
        for (0..n) |i| {
            batch[i] = .{ .ts = ts + @as(i64, @intCast(i)), .value = ts + @as(i64, @intCast(i)) };
        }
        try eng.appendPoints(series, batch[0..n]);
        ts += @as(i64, @intCast(n));
        remaining -= n;
    }
}
