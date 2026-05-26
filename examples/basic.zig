// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Basic usage example for timeseries-storage.
//!
//! Run with `zig build example`. Demonstrates the full ingest +
//! query path: open an `Engine` over a fresh temp directory, append
//! a small batch of points, query them back, and print the result.

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

    var pool = try thread_pool.ThreadPool.init(init.gpa, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(init.gpa, .{
        .data_dir = data_dir,
        .max_memtable_points = 1024,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
        .{ .ts = 3000, .value = 300 },
    };

    const series_id: lib.types.SeriesId = 42;
    try eng.appendPoints(series_id, &pts);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var query_it = try eng.queryPoints(arena.allocator(), series_id, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (query_it.next()) |pt| {
        try out.print("  ts={d} value={d}\n", .{ pt.ts, pt.value });
        count += 1;
    }

    try out.print("\nappended {d} points, queried back {d}\n", .{ pts.len, count });
    try out.flush();
}
