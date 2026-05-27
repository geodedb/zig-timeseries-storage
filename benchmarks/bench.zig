// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Default benchmark suite for timeseries-storage.
//!
//! Runs via `zig build bench`. Closes GAP-0011: the placeholder
//! "append one point" scenarios are replaced with workloads that
//! exercise the real ingest, query, flush, and compaction paths:
//!
//!   - append_single_series    100k appends into one series
//!   - append_high_cardinality 10k series × 10 points each
//!   - query_recent            full read of the last 1000 points
//!                             after 100k inserts
//!   - query_full_range        full-range scan over a populated dir
//!   - flush_cost              time to flush one memtable to a
//!                             segment with 1000 points
//!   - compaction_cost         time to compactAll over 4 L0 segments
//!
//! Each scenario constructs a fresh `Engine` over a per-iteration
//! tmp directory so iterations are independent and the framework's
//! median/p95/p99/stddev statistics are meaningful.
//!
//! CLI:
//!   zig build bench                            # run default suite
//!   zig build bench -- --output bench.json     # write JSON
//!   zig build bench -- --filter append         # subset
//!   zig build bench -- --list                  # list scenarios

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");
const framework = @import("framework");

const APPEND_SINGLE_SERIES_TOTAL: usize = 100_000;
const APPEND_HIGH_CARDINALITY_SERIES: usize = 10_000;
const APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES: usize = 10;
const QUERY_RECENT_TOTAL: usize = 100_000;
const QUERY_RECENT_WINDOW: usize = 1_000;
const FLUSH_BATCH_POINTS: usize = 1_000;
const COMPACTION_L0_COUNT: usize = 4;
const COMPACTION_POINTS_PER_L0: usize = 500;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{
            .name = "append_single_series",
            .ops_per_iteration = APPEND_SINGLE_SERIES_TOTAL,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = benchAppendSingleSeries,
        },
        .{
            .name = "append_high_cardinality",
            .ops_per_iteration = APPEND_HIGH_CARDINALITY_SERIES * APPEND_HIGH_CARDINALITY_POINTS_PER_SERIES,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = benchAppendHighCardinality,
        },
        .{
            .name = "query_recent",
            .ops_per_iteration = QUERY_RECENT_WINDOW,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = benchQueryRecent,
        },
        .{
            .name = "query_full_range",
            .ops_per_iteration = QUERY_RECENT_TOTAL,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = benchQueryFullRange,
        },
        .{
            .name = "flush_cost",
            .ops_per_iteration = FLUSH_BATCH_POINTS,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = benchFlushCost,
        },
        .{
            .name = "compaction_cost",
            .ops_per_iteration = COMPACTION_L0_COUNT,
            .warmup_iterations = 1,
            .sample_iterations = 3,
            .run = benchCompactionCost,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// Scenario bodies. Each body constructs a fresh Engine over a tmp
// directory, drives the workload, then tears down. Iteration index
// keeps the tmp paths unique across the framework's warmup + sample
// runs.
// ----------------------------------------------------------------------------

fn benchTmpDir(allocator: std.mem.Allocator, ctx: *framework.Context) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fmt.allocPrint(allocator, "/tmp/ts-bench-{s}-{d}", .{
        ctx.scenario.name,
        ctx.iteration_index,
    });
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn benchAppendSingleSeries(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        // Big memtable so the workload is dominated by ingest cost,
        // not by flush. Flush cost is exercised by a separate bench.
        .max_memtable_points = APPEND_SINGLE_SERIES_TOTAL + 1,
    }, &pool);
    defer eng.deinit();

    var batch: [256]lib.types.Point = undefined;
    var remaining = APPEND_SINGLE_SERIES_TOTAL;
    var ts: i64 = 0;
    while (remaining > 0) {
        const n = @min(remaining, batch.len);
        for (0..n) |i| {
            batch[i] = .{ .ts = ts + @as(i64, @intCast(i)), .value = ts + @as(i64, @intCast(i)) };
        }
        try eng.appendPoints(1, batch[0..n]);
        ts += @as(i64, @intCast(n));
        remaining -= n;
    }
    std.mem.doNotOptimizeAway(eng.man.last_checkpoint_lsn);
}

fn benchAppendHighCardinality(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
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

fn benchQueryRecent(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 20_000,
    }, &pool);
    defer eng.deinit();

    try preloadSeries(&eng, 1, QUERY_RECENT_TOTAL);
    try eng.flush();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const start_ts: i64 = @intCast(QUERY_RECENT_TOTAL - QUERY_RECENT_WINDOW);
    const end_ts: i64 = std.math.maxInt(i64);
    var it = try eng.queryPoints(arena.allocator(), 1, start_ts, end_ts);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    std.mem.doNotOptimizeAway(count);
}

fn benchQueryFullRange(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 20_000,
    }, &pool);
    defer eng.deinit();

    try preloadSeries(&eng, 1, QUERY_RECENT_TOTAL);
    try eng.flush();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 1, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    std.mem.doNotOptimizeAway(count);
}

fn benchFlushCost(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        // Threshold above FLUSH_BATCH_POINTS so the only flush in
        // the timed region is the explicit one below.
        .max_memtable_points = FLUSH_BATCH_POINTS * 2,
    }, &pool);
    defer eng.deinit();

    try preloadSeries(&eng, 1, FLUSH_BATCH_POINTS);
    try eng.flush();
    std.mem.doNotOptimizeAway(eng.man.segments.items.len);
}

fn benchCompactionCost(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        // Memtable threshold above COMPACTION_POINTS_PER_L0 so each
        // explicit flush below produces exactly one L0 segment.
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

    // The actual measured work: fold the L0 segments into L1.
    try eng.compactAll();
    std.mem.doNotOptimizeAway(eng.man.segments.items.len);
}

// ----------------------------------------------------------------------------
// Shared helpers.
// ----------------------------------------------------------------------------

fn preloadSeries(eng: *lib.Engine, series: lib.types.SeriesId, count: usize) !void {
    try preloadSeriesFrom(eng, series, count, 0);
}

fn preloadSeriesFrom(eng: *lib.Engine, series: lib.types.SeriesId, count: usize, base_ts: i64) !void {
    var batch: [256]lib.types.Point = undefined;
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
