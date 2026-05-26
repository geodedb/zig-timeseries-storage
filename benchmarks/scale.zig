// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Scale benchmark suite for timeseries-storage.
//!
//! These scenarios run for longer than the default `bench` suite —
//! useful for ad-hoc grid sweeps or scheduled CI runs. Wired via
//! `zig build scale-bench` and gated to schedule/manual in the default
//! `.gitlab-ci.yml`.

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
            .name = "init_default_x1m",
            .ops_per_iteration = 1_000_000,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = runDefault,
        },
        .{
            .name = "init_custom_x1m",
            .ops_per_iteration = 1_000_000,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .run = runCustom,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "scale-bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn runDefault(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        try lib.init(.{});
    }
}

fn runCustom(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        try lib.init(.{
            .debug = (i & 1) == 0,
            .max_retries = @intCast(1 + (i % 16)),
            .timeout_ms = 1 + (i % 1024),
        });
    }
}
