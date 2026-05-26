// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Integration tests for timeseries-storage.
//!
//! These tests run via `zig build test-integration` and exercise the
//! library through its public module surface (the same way a downstream
//! consumer would import it). Each test constructs a real `Engine`
//! over a fresh tmpdir, appends a small batch, queries it back, and
//! asserts the result.

const std = @import("std");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

test "integration: version is defined" {
    try std.testing.expectEqualStrings("0.1.0", lib.version);
}

test "integration: engine append + query round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 100,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    };
    try eng.appendPoints(42, &pts);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var it = try eng.queryPoints(arena.allocator(), 42, 1000, 3000);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "integration: engine flush persists data to segment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 10,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 200, .value = 2 },
    };
    try eng.appendPoints(7, &pts);
    try eng.flush();

    try std.testing.expect(eng.man.segments.items.len >= 1);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 7, 0, 1000);
    var seen: usize = 0;
    while (it.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "integration: engine query empty range returns nothing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 100,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{
        .{ .ts = 1000, .value = 1 },
    };
    try eng.appendPoints(1, &pts);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 1, 5000, 6000);
    try std.testing.expect(it.next() == null);
}
