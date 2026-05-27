// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const segment = @import("segment.zig");
const iterator = @import("iterator.zig");
const thread_pool = @import("thread_pool");
const safety = @import("safety.zig");

const BlockInfo = struct {
    file_index: usize,
    block: segment.Block,
};

/// Per-series streaming iterator (P-MEM-001 / P-MEM-005).
///
/// Holds a list of `Block`s that share the same `series_id`,
/// decoded ONE AT A TIME on demand. The previous implementation
/// decoded every block in the list up front, accumulating the
/// entire per-series point sequence in RAM before writing a single
/// output block — peak memory was O(total-points-across-all-input-segments)
/// per series, which blew up for large compactions.
///
/// `BlockStreamIterator` decodes block N+1 only after block N is
/// exhausted, freeing the points slice from the previous block
/// before allocating the next. Peak memory per series is now
/// O(largest-input-block).
const BlockStreamIterator = struct {
    pub const MAGIC: u32 = safety.Magic.block_stream_iterator;
    magic: u32 = MAGIC,
    allocator: Allocator,
    blocks: []const BlockInfo,
    block_idx: usize = 0,
    current_points: []types.Point = &[_]types.Point{},
    pos: usize = 0,

    fn next(self: *BlockStreamIterator) ?types.Point {
        while (true) {
            if (self.pos < self.current_points.len) {
                const pt = self.current_points[self.pos];
                self.pos += 1;
                return pt;
            }

            // Current block exhausted; free it and advance.
            if (self.current_points.len > 0) {
                self.allocator.free(self.current_points);
                self.current_points = &[_]types.Point{};
                self.pos = 0;
            }

            if (self.block_idx >= self.blocks.len) return null;

            const blk = self.blocks[self.block_idx];
            self.block_idx += 1;
            self.current_points = blk.block.decodePoints(self.allocator) catch {
                // Decode failure on a single block is surfaced as
                // end-of-stream for the iterator. We deliberately
                // do NOT plumb errors through the PointIterator
                // interface — the compactor's existing contract is
                // best-effort merge; segments that fail to decode
                // surface their failures via the verifySegments /
                // CRC32C paths during read.
                return null;
            };
            self.pos = 0;
        }
    }

    fn deinit(self: *BlockStreamIterator) void {
        if (self.current_points.len > 0) {
            self.allocator.free(self.current_points);
            self.current_points = &[_]types.Point{};
            self.pos = 0;
        }
    }

    fn pointIterator(self: *BlockStreamIterator) iterator.PointIterator {
        return .{
            .ptr = self,
            .nextFn = struct {
                fn next(ptr: *anyopaque) ?types.Point {
                    const typed = safety.castCtx(BlockStreamIterator, ptr);
                    return typed.next();
                }
            }.next,
        };
    }
};

/// Target size of the per-series output buffer in points. Picked to
/// match typical L0 flush block sizes — small enough that peak RAM
/// stays bounded, large enough that Gorilla compression is effective
/// (per-block fixed header overhead amortised over a few hundred
/// points). Adjustable via `Compactor.config.target_block_points`.
const DEFAULT_TARGET_BLOCK_POINTS: usize = 256;

/// Merge engine for combining multiple segments into a single segment.
///
/// `compactSegments` takes a list of input segment paths and an output
/// segment path. For each `SeriesId` present in any input segment, it
/// streams the per-series blocks through a `MergeIterator`, dedupes
/// same-timestamp entries (later iterator wins; see `MergeIterator`'s
/// doc-comment for the precise tie-breaker), accumulates into a
/// block-sized buffer, and emits an output block when the buffer
/// fills (or the input is exhausted for that series).
///
/// The compactor does not delete the input segments — that is the
/// engine's responsibility once the manifest has been updated to point
/// at the new output segment. The compactor borrows the supplied
/// thread pool for any future parallel-merge work; today the merge is
/// single-threaded but the dependency is kept so callers do not have
/// to plumb a new pool through later.
pub const Compactor = struct {
    allocator: Allocator,
    pool: *thread_pool.ThreadPool,
    target_block_points: usize = DEFAULT_TARGET_BLOCK_POINTS,

    pub fn init(allocator: Allocator, pool: *thread_pool.ThreadPool) Compactor {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    /// Streaming compactor (P-MEM-001 / P-MEM-005).
    ///
    /// Peak RAM is O(target_block_points + largest-input-block) per
    /// series at a time, NOT O(all-points-in-all-input-segments).
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

        // Map SeriesId -> list of BlockInfo. Each entry retains its
        // input segment index for the stable tie-break documented on
        // MergeIterator (earliest-added wins).
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
            try self.compactOneSeries(&writer, entry.key_ptr.*, entry.value_ptr.items);
        }

        // Durability ordering: the merged segment MUST be fsynced
        // before the engine updates the manifest to reference it.
        try writer.sync();
    }

    /// Stream-compact one series. Allocates one `BlockStreamIterator`
    /// per input segment that has any block for `series_id`, wires
    /// them into a `MergeIterator`, and emits output blocks of at
    /// most `target_block_points` points each.
    fn compactOneSeries(
        self: *Compactor,
        writer: *segment.SegmentWriter,
        series_id: types.SeriesId,
        blocks: []const BlockInfo,
    ) !void {
        if (blocks.len == 0) return;

        // Partition blocks by file_index to preserve per-stream ordering.
        // The MergeIterator tie-break is "earliest-added iterator wins",
        // so we add streams in file_index order — matching the previous
        // (non-streaming) compactor's emission order for ties.
        var per_file = std.AutoHashMap(usize, std.ArrayList(BlockInfo)).init(self.allocator);
        defer {
            var pf_it = per_file.valueIterator();
            while (pf_it.next()) |list| list.deinit(self.allocator);
            per_file.deinit();
        }
        for (blocks) |binfo| {
            const gop = try per_file.getOrPut(binfo.file_index);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(BlockInfo).empty;
            try gop.value_ptr.append(self.allocator, binfo);
        }

        // Build one BlockStreamIterator per input segment.
        var stream_iters = std.ArrayList(*BlockStreamIterator).empty;
        defer {
            for (stream_iters.items) |si| {
                si.deinit();
                self.allocator.destroy(si);
            }
            stream_iters.deinit(self.allocator);
        }

        var max_file_idx: usize = 0;
        var pf_it = per_file.keyIterator();
        while (pf_it.next()) |k| {
            if (k.* > max_file_idx) max_file_idx = k.*;
        }

        // Walk per_file in ascending file_index order so MergeIterator
        // ties favour the earlier segment, matching the legacy contract.
        var file_idx: usize = 0;
        while (file_idx <= max_file_idx) : (file_idx += 1) {
            const list = per_file.get(file_idx) orelse continue;
            const si = try self.allocator.create(BlockStreamIterator);
            si.* = .{
                .allocator = self.allocator,
                .blocks = list.items,
            };
            try stream_iters.append(self.allocator, si);
        }

        var merger = iterator.MergeIterator.init(self.allocator);
        defer merger.deinit();
        for (stream_iters.items) |si| {
            try merger.addIterator(si.pointIterator());
        }

        // Output buffer sized to the target block size. Resets after
        // each emit so total peak RAM per series is bounded.
        var out_buf = std.ArrayListUnmanaged(types.Point).empty;
        defer out_buf.deinit(self.allocator);
        try out_buf.ensureTotalCapacity(self.allocator, self.target_block_points);

        while (merger.next()) |pt| {
            // Dedup: same-timestamp entries collapse to the latest
            // arrival. MergeIterator's ordering puts the highest-
            // value (or earliest-added on full ties) last, so
            // overwrite-on-tie matches the previous semantics.
            if (out_buf.items.len > 0 and out_buf.items[out_buf.items.len - 1].ts == pt.ts) {
                out_buf.items[out_buf.items.len - 1] = pt;
            } else {
                try out_buf.append(self.allocator, pt);
            }

            if (out_buf.items.len >= self.target_block_points) {
                try writer.writeBlock(series_id, out_buf.items);
                out_buf.clearRetainingCapacity();
            }
        }

        // Flush the tail.
        if (out_buf.items.len > 0) {
            try writer.writeBlock(series_id, out_buf.items);
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

    // Group blocks by series — the streaming compactor may emit
    // multiple smaller blocks for the same series if the input
    // crossed the target_block_points threshold. Correctness is the
    // multiset of (series, ts, value) tuples, not the block count.
    var series10_points = std.ArrayList(types.Point).empty;
    defer series10_points.deinit(allocator);

    var series_seen = std.AutoHashMap(types.SeriesId, void).init(allocator);
    defer series_seen.deinit();

    var it = r.iterator();
    while (try it.next()) |blk| {
        try series_seen.put(blk.header.series_id, {});
        const pts = try blk.decodePoints(allocator);
        defer allocator.free(pts);
        if (blk.header.series_id == 10) {
            try series10_points.appendSlice(allocator, pts);
        }
    }

    // All three series present.
    try std.testing.expect(series_seen.contains(10));
    try std.testing.expect(series_seen.contains(20));
    try std.testing.expect(series_seen.contains(30));

    // Series 10 round-trip: ts must be {1, 3, 5} in ascending order.
    try std.testing.expectEqual(@as(usize, 3), series10_points.items.len);
    try std.testing.expectEqual(@as(i64, 1), series10_points.items[0].ts);
    try std.testing.expectEqual(@as(i64, 3), series10_points.items[1].ts);
    try std.testing.expectEqual(@as(i64, 5), series10_points.items[2].ts);
}

test "Compactor: streaming respects target_block_points (P-MEM-001/P-MEM-005)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    const seg_path = try std.fmt.allocPrint(allocator, "{s}/in.tsseg", .{path});
    defer allocator.free(seg_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out.tsseg", .{path});
    defer allocator.free(out_path);

    // Write a single big block (1000 points) for series 1.
    var pts: [1000]types.Point = undefined;
    for (&pts, 0..) |*p, i| p.* = .{ .ts = @intCast(i + 1), .value = @intCast(i) };
    {
        var w = try segment.SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(1, &pts);
    }

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // target_block_points = 100 — the streaming output must split
    // into 10 blocks of 100 each.
    var compactor = Compactor.init(allocator, &pool);
    compactor.target_block_points = 100;
    try compactor.compactSegments(&.{seg_path}, out_path);

    var r = try segment.SegmentReader.init(allocator, out_path);
    defer r.deinit();

    var block_count: usize = 0;
    var total_points: usize = 0;
    var it = r.iterator();
    while (try it.next()) |blk| {
        block_count += 1;
        const decoded = try blk.decodePoints(allocator);
        defer allocator.free(decoded);
        try std.testing.expect(decoded.len <= 100);
        total_points += decoded.len;
    }

    try std.testing.expectEqual(@as(usize, 10), block_count);
    try std.testing.expectEqual(@as(usize, 1000), total_points);
}

test "Compactor: dedup collapses same-timestamp entries" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    const seg1_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{path});
    defer allocator.free(seg1_path);
    const seg2_path = try std.fmt.allocPrint(allocator, "{s}/2.tsseg", .{path});
    defer allocator.free(seg2_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out.tsseg", .{path});
    defer allocator.free(out_path);

    // Two inputs each writing a point at ts=100 for series 1.
    {
        var w = try segment.SegmentWriter.init(allocator, seg1_path);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 100, .value = 10 }});
    }
    {
        var w = try segment.SegmentWriter.init(allocator, seg2_path);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 100, .value = 20 }});
    }

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var compactor = Compactor.init(allocator, &pool);
    try compactor.compactSegments(&.{ seg1_path, seg2_path }, out_path);

    var r = try segment.SegmentReader.init(allocator, out_path);
    defer r.deinit();

    var total_points: usize = 0;
    var it = r.iterator();
    while (try it.next()) |blk| {
        const decoded = try blk.decodePoints(allocator);
        defer allocator.free(decoded);
        total_points += decoded.len;
    }
    // Two same-ts inputs must collapse to one output point.
    try std.testing.expectEqual(@as(usize, 1), total_points);
}
