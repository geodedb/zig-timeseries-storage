// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Default benchmark suite for timeseries-storage.
//!
//! This is the file invoked by `zig build bench`. Replace the
//! placeholder scenarios below with workloads that actually exercise
//! your library's public surface. The framework handles iteration
//! count, warmup, statistics, allocation tracking, and JSON output.
//!
//! CLI:
//!   zig build bench                        # run default suite
//!   zig build bench -- --output bench.json # write JSON
//!   zig build bench -- --filter init       # subset
//!   zig build bench -- --list              # list scenarios

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
            .name = "init_default_config",
            .ops_per_iteration = 10_000,
            .run = benchInitDefault,
        },
        .{
            .name = "init_custom_config",
            .ops_per_iteration = 10_000,
            .run = benchInitCustom,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// Scenario bodies — replace these with calls into the public library.
// ----------------------------------------------------------------------------

fn benchInitDefault(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        try lib.init(.{});
    }
}

fn benchInitCustom(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        try lib.init(.{
            .debug = (i & 1) == 0,
            .max_retries = @intCast(1 + (i % 16)),
            .timeout_ms = 1 + (i % 1024),
        });
    }
}
