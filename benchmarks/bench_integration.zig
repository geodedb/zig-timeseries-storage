// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Integration benchmarks for timeseries-storage.
//!
//! These scenarios exercise the full Engine across multiple threads and
//! across recovery boundaries — workloads the default `bench.zig` suite
//! does not cover. Each scenario constructs a fresh `Engine` over a
//! per-iteration tmp directory so iterations are independent.
//!
//! Scenarios:
//!   - bench_concurrent_append   4 writer threads × 25k pts → 100k ops
//!   - bench_concurrent_rw       2 writers + 2 readers      → 52k ops
//!   - bench_ooo_append          10k sorted → flush → 1k OoO → flush
//!   - bench_recovery_latency    re-init engine over 4-segment dir
//!
//! Wired via `zig build bench-integration`.
//!
//! NOTE on allocation tracking: the framework's `TrackingAllocator` is
//! NOT thread-safe (see `benchmarks/framework/tracking_allocator.zig`),
//! and allocations performed inside spawned worker threads pass through
//! the engine's internal allocator path which is NOT wrapped by the
//! framework's tracker. As a result, `alloc_count`/`alloc_bytes` for the
//! concurrent scenarios reflect only the main-thread setup/teardown
//! allocations, not the per-thread workload.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");
const framework = @import("framework");

const CONCURRENT_APPEND_THREADS: usize = 4;
const CONCURRENT_APPEND_PER_THREAD: usize = 25_000;
const CONCURRENT_APPEND_TOTAL: usize = CONCURRENT_APPEND_THREADS * CONCURRENT_APPEND_PER_THREAD;

const CONCURRENT_RW_WRITER_POINTS: usize = 25_000;
const CONCURRENT_RW_READS_PER_THREAD: usize = 1_000;
const CONCURRENT_RW_TOTAL: usize = (2 * CONCURRENT_RW_WRITER_POINTS) + (2 * CONCURRENT_RW_READS_PER_THREAD);

const OOO_INORDER_POINTS: usize = 10_000;
const OOO_OOO_POINTS: usize = 1_000;
const OOO_TOTAL: usize = OOO_INORDER_POINTS + OOO_OOO_POINTS;

const RECOVERY_SEGMENTS: usize = 4;
const RECOVERY_POINTS_PER_SEGMENT: usize = 500;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{
            .name = "bench_concurrent_append",
            .ops_per_iteration = CONCURRENT_APPEND_TOTAL,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = benchConcurrentAppend,
        },
        .{
            .name = "bench_concurrent_rw",
            .ops_per_iteration = CONCURRENT_RW_TOTAL,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = benchConcurrentRw,
        },
        .{
            .name = "bench_ooo_append",
            .ops_per_iteration = OOO_TOTAL,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = benchOooAppend,
        },
        .{
            .name = "bench_recovery_latency",
            .ops_per_iteration = 1,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = benchRecoveryLatency,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-integration"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// Scenario 1: bench_concurrent_append
// 4 writer threads share one Engine, each appending 25k points to a
// disjoint series id. Total = 100k ops.
// ----------------------------------------------------------------------------

const ConcurrentAppendCtx = struct {
    eng: *lib.Engine,
    series: lib.types.SeriesId,
    points_to_write: usize,
};

fn concurrentAppendWorker(c: ConcurrentAppendCtx) void {
    var batch: [256]lib.types.Point = undefined;
    var ts: i64 = 0;
    var remaining = c.points_to_write;
    while (remaining > 0) {
        const n = @min(remaining, batch.len);
        for (0..n) |i| {
            batch[i] = .{
                .ts = ts + @as(i64, @intCast(i)),
                .value = ts + @as(i64, @intCast(i)),
            };
        }
        // Errors from a worker are swallowed for benchmark purposes; a
        // mis-configured engine would surface as wildly wrong throughput
        // in the report and a debug-build panic during smoke runs.
        c.eng.appendPoints(c.series, batch[0..n]) catch {};
        ts += @as(i64, @intCast(n));
        remaining -= n;
    }
}

fn benchConcurrentAppend(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        // Large enough to avoid an auto-flush during the run; per-flush
        // cost is measured by the dedicated `flush_cost` scenario in
        // the default suite.
        .max_memtable_points = CONCURRENT_APPEND_TOTAL + 1,
    }, &pool);
    defer eng.deinit();

    var threads: [CONCURRENT_APPEND_THREADS]std.Thread = undefined;
    inline for (0..CONCURRENT_APPEND_THREADS) |k| {
        const series: lib.types.SeriesId = @as(lib.types.SeriesId, @intCast(k + 1));
        threads[k] = try std.Thread.spawn(.{}, concurrentAppendWorker, .{ConcurrentAppendCtx{
            .eng = &eng,
            .series = series,
            .points_to_write = CONCURRENT_APPEND_PER_THREAD,
        }});
    }
    for (&threads) |t| t.join();

    std.mem.doNotOptimizeAway(eng.man.last_checkpoint_lsn);
}

// ----------------------------------------------------------------------------
// Scenario 2: bench_concurrent_rw
// 2 writers (25k pts each → series 1 + 2) + 2 readers (500 queryPoints
// each → series 1). Total = 52k ops.
// ----------------------------------------------------------------------------

const ConcurrentRwReaderCtx = struct {
    eng: *lib.Engine,
    allocator: std.mem.Allocator,
    reads: usize,
    series: lib.types.SeriesId,
};

fn concurrentRwReader(c: ConcurrentRwReaderCtx) void {
    var arena = std.heap.ArenaAllocator.init(c.allocator);
    defer arena.deinit();
    var remaining = c.reads;
    while (remaining > 0) : (remaining -= 1) {
        var it = c.eng.queryPoints(arena.allocator(), c.series, 0, std.math.maxInt(i64)) catch continue;
        var counted: usize = 0;
        while (it.next()) |_| counted += 1;
        std.mem.doNotOptimizeAway(counted);
        _ = arena.reset(.retain_capacity);
    }
}

fn benchConcurrentRw(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 100_000,
    }, &pool);
    defer eng.deinit();

    // Preload series 1 with a small sealed segment so readers have
    // something to scan from the very first iteration.
    try preloadSeries(&eng, 1, 1000);
    try eng.flush();

    var threads: [4]std.Thread = undefined;

    // Writers → series 1 and 2.
    threads[0] = try std.Thread.spawn(.{}, concurrentAppendWorker, .{ConcurrentAppendCtx{
        .eng = &eng,
        .series = 1,
        .points_to_write = CONCURRENT_RW_WRITER_POINTS,
    }});
    threads[1] = try std.Thread.spawn(.{}, concurrentAppendWorker, .{ConcurrentAppendCtx{
        .eng = &eng,
        .series = 2,
        .points_to_write = CONCURRENT_RW_WRITER_POINTS,
    }});

    // Readers → 500 reads each on series 1.
    threads[2] = try std.Thread.spawn(.{}, concurrentRwReader, .{ConcurrentRwReaderCtx{
        .eng = &eng,
        .allocator = ctx.allocator,
        .reads = CONCURRENT_RW_READS_PER_THREAD,
        .series = 1,
    }});
    threads[3] = try std.Thread.spawn(.{}, concurrentRwReader, .{ConcurrentRwReaderCtx{
        .eng = &eng,
        .allocator = ctx.allocator,
        .reads = CONCURRENT_RW_READS_PER_THREAD,
        .series = 1,
    }});

    for (&threads) |t| t.join();
    std.mem.doNotOptimizeAway(eng.man.segments.items.len);
}

// ----------------------------------------------------------------------------
// Scenario 3: bench_ooo_append
// Single-threaded. Append 10k sorted points → flush → append 1k OoO
// points (timestamps below sealed segment's max_ts) → flush. Requires
// `allow_cross_segment_ooo = true` (confirmed at src/engine.zig:538).
// ----------------------------------------------------------------------------

fn benchOooAppend(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        // Memtable larger than the OoO burst so the explicit flushes
        // are the only flush events in the timed region.
        .max_memtable_points = 20_000,
        .allow_cross_segment_ooo = true,
    }, &pool);
    defer eng.deinit();

    // Phase 1: 10k strictly-sorted points → sealed segment with
    // max_ts = 9999.
    var batch: [256]lib.types.Point = undefined;
    var i: usize = 0;
    while (i < OOO_INORDER_POINTS) : (i += 256) {
        const n = @min(@as(usize, 256), OOO_INORDER_POINTS - i);
        for (0..n) |j| {
            const ts: i64 = @intCast(i + j);
            batch[j] = .{ .ts = ts, .value = ts };
        }
        try eng.appendPoints(1, batch[0..n]);
    }
    try eng.flush();

    // Phase 2: 1k OoO points with timestamps 0..1000 — all strictly
    // below the sealed segment's max_ts (9999). Each batch is itself
    // sorted; the OoO-ness is relative to the existing segment.
    i = 0;
    while (i < OOO_OOO_POINTS) : (i += 256) {
        const n = @min(@as(usize, 256), OOO_OOO_POINTS - i);
        for (0..n) |j| {
            const ts: i64 = @intCast((i + j) % OOO_OOO_POINTS);
            batch[j] = .{ .ts = ts, .value = ts };
        }
        try eng.appendPoints(1, batch[0..n]);
    }
    try eng.flush();

    std.mem.doNotOptimizeAway(eng.man.segments.items.len);
}

// ----------------------------------------------------------------------------
// Scenario 4: bench_recovery_latency
// Build a 4-segment data dir in a setup block, then time a fresh
// Engine.init over that dir. ops_per_iteration = 1.
//
// The framework times the WHOLE `run` callback, so this scenario
// measures setup + measured-op together. The setup is constant across
// iterations (4 flushes of 500 sorted points each, no compaction),
// so the variance the bench reveals is dominated by the re-init cost.
// ----------------------------------------------------------------------------

fn benchRecoveryLatency(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    // Setup phase: produce a 4-segment data dir, then drop the engine
    // so the next init goes through the real recovery path.
    {
        var eng = try lib.Engine.init(ctx.allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000,
        }, &pool);
        defer eng.deinit();
        var base_ts: i64 = 0;
        for (0..RECOVERY_SEGMENTS) |_| {
            try preloadSeriesFrom(&eng, 1, RECOVERY_POINTS_PER_SEGMENT, base_ts);
            try eng.flush();
            base_ts += @as(i64, @intCast(RECOVERY_POINTS_PER_SEGMENT));
        }
    }

    // Measured op: re-init the engine over the populated dir.
    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000,
    }, &pool);
    defer eng.deinit();

    std.mem.doNotOptimizeAway(eng.man.segments.items.len);
}

// ----------------------------------------------------------------------------
// Shared helpers (copied verbatim from benchmarks/bench.zig).
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
