// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Scale benchmark suite for timeseries-storage.
//!
//! These scenarios run for longer than the default `bench` suite —
//! useful for ad-hoc grid sweeps or scheduled CI runs. Wired via
//! `zig build scale-bench` and gated to schedule/manual in the default
//! `.gitlab-ci.yml`.
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
            .name = "engine_append_default",
            .ops_per_iteration = 1,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = runAppendDefault,
        },
        .{
            .name = "engine_query_default",
            .ops_per_iteration = 1,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = runQueryDefault,
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

fn runAppendDefault(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
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

fn runQueryDefault(ctx: *framework.Context) anyerror!void {
    const data_dir = try scaleTmpDir(ctx.allocator, ctx);
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
