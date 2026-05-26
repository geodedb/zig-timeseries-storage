// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const segment = @import("segment.zig");
const iterator = @import("iterator.zig");
const thread_pool = @import("thread_pool");

const BlockInfo = struct {
    file_index: usize,
    block: segment.Block,
};

pub const Compactor = struct {
    allocator: Allocator,
    pool: *thread_pool.ThreadPool,

    pub fn init(allocator: Allocator, pool: *thread_pool.ThreadPool) Compactor {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    /// Compacts multiple segments into a single segment.
    /// Blocks are grouped by SeriesId, decoded, merged, and written sequentially.
    pub fn compactSegments(self: *Compactor, input_paths: []const []const u8, output_path: []const u8) !void {
        var readers = std.ArrayList(segment.SegmentReader).empty;
        defer {
            for (readers.items) |*r| r.deinit();
            readers.deinit(self.allocator);
        }

        for (input_paths) |path| {
            const reader = try segment.SegmentReader.init(self.allocator, path);
            try readers.append(self.allocator, reader);
        }

        // Map SeriesId to a list of BlockInfo
        var series_blocks = std.AutoHashMap(types.SeriesId, std.ArrayList(BlockInfo)).init(self.allocator);
        defer {
            var it = series_blocks.valueIterator();
            while (it.next()) |list| {
                list.deinit(self.allocator);
            }
            series_blocks.deinit();
        }

        for (readers.items, 0..) |*r, i| {
            var block_it = r.iterator();
            while (try block_it.next()) |blk| {
                const gop = try series_blocks.getOrPut(blk.header.series_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(BlockInfo).empty;
                }
                try gop.value_ptr.append(self.allocator, .{ .file_index = i, .block = blk });
            }
        }

        var writer = try segment.SegmentWriter.init(self.allocator, output_path);
        defer writer.deinit();

        var it = series_blocks.iterator();
        while (it.next()) |entry| {
            const series_id = entry.key_ptr.*;
            const blocks = entry.value_ptr.items;

            var merger = iterator.MergeIterator.init(self.allocator);
            defer merger.deinit();

            var slices = std.ArrayList([]types.Point).empty;
            defer {
                for (slices.items) |s| self.allocator.free(s);
                slices.deinit(self.allocator);
            }
            var slice_iters = std.ArrayList(iterator.SliceIterator).empty;
            defer slice_iters.deinit(self.allocator);

            for (blocks) |binfo| {
                const pts = try binfo.block.decodePoints(self.allocator);
                try slices.append(self.allocator, pts);
            }

            for (slices.items) |pts| {
                const slice_it = iterator.SliceIterator{ .slice = pts };
                try slice_iters.append(self.allocator, slice_it);
            }

            for (slice_iters.items) |*sit| {
                try merger.addIterator(sit.iterator());
            }

            var merged_points = std.ArrayList(types.Point).empty;
            defer merged_points.deinit(self.allocator);

            while (merger.next()) |pt| {
                // Deduplicate points with the same timestamp by taking the later one (which comes last if stable).
                // Our simple MergeIterator might not be perfectly stable, but it guarantees sorted order.
                if (merged_points.items.len > 0 and merged_points.items[merged_points.items.len - 1].ts == pt.ts) {
                    merged_points.items[merged_points.items.len - 1] = pt; // overwrite
                } else {
                    try merged_points.append(self.allocator, pt);
                }
            }

            try writer.writeBlock(series_id, merged_points.items);
        }
    }
};

test "Compactor basic merge" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(path);

    const seg1_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{path});
    defer allocator.free(seg1_path);
    const seg2_path = try std.fmt.allocPrint(allocator, "{s}/2.tsseg", .{path});
    defer allocator.free(seg2_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out.tsseg", .{path});
    defer allocator.free(out_path);

    {
        var w1 = try segment.SegmentWriter.init(allocator, seg1_path);
        defer w1.deinit();
        try w1.writeBlock(10, &.{ .{ .ts = 1, .value = 10 }, .{ .ts = 5, .value = 50 } });
        try w1.writeBlock(20, &.{.{ .ts = 2, .value = 20 }});
    }

    {
        var w2 = try segment.SegmentWriter.init(allocator, seg2_path);
        defer w2.deinit();
        try w2.writeBlock(10, &.{.{ .ts = 3, .value = 30 }});
        try w2.writeBlock(30, &.{.{ .ts = 4, .value = 40 }});
    }

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var compactor = Compactor.init(allocator, &pool);
    try compactor.compactSegments(&.{ seg1_path, seg2_path }, out_path);

    var r = try segment.SegmentReader.init(allocator, out_path);
    defer r.deinit();

    var block_count: usize = 0;
    var it = r.iterator();
    while (try it.next()) |blk| {
        block_count += 1;
        const pts = try blk.decodePoints(allocator);
        defer allocator.free(pts);
        if (blk.header.series_id == 10) {
            try std.testing.expectEqual(@as(usize, 3), pts.len);
            try std.testing.expectEqual(@as(i64, 1), pts[0].ts);
            try std.testing.expectEqual(@as(i64, 3), pts[1].ts);
            try std.testing.expectEqual(@as(i64, 5), pts[2].ts);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), block_count);
}
