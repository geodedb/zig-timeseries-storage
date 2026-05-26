// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Example micro-benchmark for timeseries-storage.
//!
//! Micro-benchmarks isolate a single function so regressions in one
//! corner of the library don't get hidden inside a broader workload.
//! Wired via `zig build bench-micro-example` (see build.zig). Copy
//! this file as a starting point for additional micro-benchmarks.
//!
//! TODO(GAP-0011): wire real benchmark bodies — the current scenario
//! exercises only Memtable.insert with a single batch per iteration.
//! Phase D will land richer per-function micros (Gorilla encode/decode,
//! manifest write/read, etc.).

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
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
            .name = "memtable_insert_one_point",
            .ops_per_iteration = 1,
            .warmup_iterations = 2,
            .sample_iterations = 6,
            .run = run,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-example"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn run(ctx: *framework.Context) anyerror!void {
    var mt = lib.memtable.Memtable.init(ctx.allocator, 1024);
    defer mt.deinit();

    const pts = [_]lib.types.Point{.{ .ts = 1000, .value = 42 }};
    try mt.insert(7, &pts);
    std.mem.doNotOptimizeAway(mt.point_count);
}
