const std = @import("std");
const engine = @import("engine.zig");
const types = @import("types.zig");
const thread_pool = @import("thread_pool");

test "End-to-End Stress Test: Insert 100k points across multiple series" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try engine.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 10000,
    }, &pool);
    defer eng.deinit();

    const num_series = 10;
    const points_per_series = 10000;

    var pts = try allocator.alloc(types.Point, 1000);
    defer allocator.free(pts);

    for (0..num_series) |s_id| {
        var t: i64 = 1000;
        var remaining: usize = points_per_series;
        while (remaining > 0) {
            const batch_size = @min(remaining, 1000);
            for (0..batch_size) |i| {
                pts[i] = .{ .ts = t, .value = @intCast(s_id * 100 + i) };
                t += 10;
            }
            try eng.appendPoints(@intCast(s_id), pts[0..batch_size]);
            remaining -= batch_size;
        }
    }

    try eng.flush(); // Flush remaining

    const total_points = num_series * points_per_series;
    _ = total_points;

    try std.testing.expect(eng.man.segments.items.len <= 10);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var merge_it = try eng.queryPoints(arena.allocator(), 1, 1000, 2000);

    var count: usize = 0;
    while (merge_it.next()) |_| {
        count += 1;
    }

    // Series 1 starts at 1000, goes up by 10. 2000 is included.
    // 1000 to 2000 (inclusive) = 101 points.
    try std.testing.expectEqual(@as(usize, 101), count);
}
