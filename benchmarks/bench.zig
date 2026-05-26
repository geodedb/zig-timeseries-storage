// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Default benchmark suite for timeseries-storage.
//!
//! This is the file invoked by `zig build bench`. Scenarios construct
//! a real `Engine` over a fresh temp directory, drive a single
//! `appendPoints` and `queryPoints` call against it, then tear down.
//! The framework handles iteration count, warmup, statistics,
//! allocation tracking, and JSON output.
//!
//! CLI:
//!   zig build bench                            # run default suite
//!   zig build bench -- --output bench.json     # write JSON
//!   zig build bench -- --filter append         # subset
//!   zig build bench -- --list                  # list scenarios
//!
//! TODO(GAP-0011): wire real benchmark bodies — the current scenarios
//! exercise the public Engine surface but only with a single trivial
//! point per iteration. Phase D will land comprehensive bench bodies
//! (multi-batch ingest, segment-spanning queries, compaction-induced
//! flushes) so the measurements actually reflect production workloads.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");
const framework = @import("framework");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{
            .name = "engine_append_one_point",
            .ops_per_iteration = 1,
            .run = benchAppendOnePoint,
        },
        .{
            .name = "engine_query_one_point",
            .ops_per_iteration = 1,
            .run = benchQueryOnePoint,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// Scenario bodies.
// ----------------------------------------------------------------------------

/// Create a fresh tmp data_dir for the duration of one bench iteration.
/// Caller (the test framework) supplies the arena; we just need a unique
/// path. We use the iteration index to keep paths stable across runs.
fn benchTmpDir(allocator: std.mem.Allocator, ctx: *framework.Context) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fmt.allocPrint(allocator, "/tmp/ts-bench-{s}-{d}", .{
        ctx.scenario.name,
        ctx.iteration_index,
    });
    // Best-effort cleanup of previous run.
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn benchAppendOnePoint(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1024,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{.{ .ts = 1000, .value = 1 }};
    try eng.appendPoints(1, &pts);
}

fn benchQueryOnePoint(ctx: *framework.Context) anyerror!void {
    const data_dir = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(ctx.allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(ctx.allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1024,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{.{ .ts = 1000, .value = 1 }};
    try eng.appendPoints(1, &pts);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 1, 0, 2000);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    std.mem.doNotOptimizeAway(count);
}
