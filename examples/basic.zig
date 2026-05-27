// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Basic usage example for timeseries-storage.
//!
//! Run with `zig build example`. Demonstrates the full lifecycle: open
//! an `Engine` over a fresh temp directory, append a batch of points
//! across multiple series, flush to a segment, query each series back,
//! and print the result alongside engine status.
//!
//! This file is also a self-contained reference implementation: copy
//! it to bootstrap a new caller. It uses only the published surface
//! (`lib.Engine`, `lib.EngineConfig`, `lib.types.Point`,
//! `lib.types.SeriesId`).

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("timeseries-storage Example (v{s})\n", .{lib.version});
    try out.writeAll("========================\n\n");

    const data_dir = "./ts-example-data";
    std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    var pool = try thread_pool.ThreadPool.init(init.gpa, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(init.gpa, .{
        .data_dir = data_dir,
        // Small threshold to demonstrate a real flush within this
        // example without needing thousands of points.
        .max_memtable_points = 16,
    }, &pool);
    defer eng.deinit();

    // -----------------------------------------------------------------
    // Phase 1: append a batch of points across two series.
    // -----------------------------------------------------------------
    const series_a: lib.types.SeriesId = 100;
    const series_b: lib.types.SeriesId = 200;

    try out.writeAll("Phase 1: append\n");
    var i: i64 = 0;
    while (i < 20) : (i += 1) {
        const pt = lib.types.Point{ .ts = i * 1_000, .value = i * 2 };
        try eng.appendPoints(series_a, &.{pt});
    }
    var j: i64 = 0;
    while (j < 10) : (j += 1) {
        const pt = lib.types.Point{ .ts = j * 2_000, .value = j };
        try eng.appendPoints(series_b, &.{pt});
    }
    try out.print("  appended 20 points to series_a, 10 to series_b\n", .{});

    // -----------------------------------------------------------------
    // Phase 2: explicit flush + sync to make the data durable.
    // -----------------------------------------------------------------
    try out.writeAll("\nPhase 2: flush + sync\n");
    try eng.flush();
    try eng.sync();
    try out.print("  segments: {d}\n", .{eng.man.segments.items.len});
    try out.print("  last_checkpoint_lsn: {d}\n", .{eng.man.last_checkpoint_lsn});

    // -----------------------------------------------------------------
    // Phase 3: query each series back and print results.
    // -----------------------------------------------------------------
    try out.writeAll("\nPhase 3: query\n");
    {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), series_a, 0, std.math.maxInt(i64));
        var count: usize = 0;
        while (it.next()) |pt| {
            if (count < 5) {
                try out.print("  series_a[{d}]: ts={d} value={d}\n", .{ count, pt.ts, pt.value });
            }
            count += 1;
        }
        try out.print("  series_a total: {d}\n", .{count});
    }
    {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), series_b, 0, std.math.maxInt(i64));
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try out.print("  series_b total: {d}\n", .{count});
    }

    try out.writeAll("\ndone\n");
    try out.flush();
}
