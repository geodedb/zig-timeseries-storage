// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const segment = @import("segment.zig");

pub const PointIterator = struct {
    ptr: *anyopaque,
    nextFn: *const fn (ptr: *anyopaque) ?types.Point,

    pub fn next(self: PointIterator) ?types.Point {
        return self.nextFn(self.ptr);
    }
};

pub const SliceIterator = struct {
    slice: []const types.Point,
    pos: usize = 0,

    pub fn next(self: *SliceIterator) ?types.Point {
        if (self.pos < self.slice.len) {
            const pt = self.slice[self.pos];
            self.pos += 1;
            return pt;
        }
        return null;
    }

    pub fn iterator(self: *SliceIterator) PointIterator {
        return .{
            .ptr = self,
            .nextFn = struct {
                fn next(ptr: *anyopaque) ?types.Point {
                    const typed_ptr: *SliceIterator = @ptrCast(@alignCast(ptr));
                    return typed_ptr.next();
                }
            }.next,
        };
    }
};

pub const SegmentIterator = struct {
    allocator: Allocator,
    reader: segment.SegmentReader,
    block_it: segment.SegmentReader.BlockIterator,
    series_id: types.SeriesId,
    start_ts: i64,
    end_ts: i64,
    current_points: []types.Point = &[_]types.Point{},
    pos: usize = 0,

    pub fn init(allocator: Allocator, path: []const u8, series_id: types.SeriesId, start_ts: i64, end_ts: i64) !SegmentIterator {
        var reader = try segment.SegmentReader.init(allocator, path);
        return .{
            .allocator = allocator,
            .reader = reader,
            .block_it = reader.iterator(),
            .series_id = series_id,
            .start_ts = start_ts,
            .end_ts = end_ts,
        };
    }

    pub fn deinit(self: *SegmentIterator) void {
        if (self.current_points.len > 0) self.allocator.free(self.current_points);
        self.reader.deinit();
    }

    pub fn next(self: *SegmentIterator) ?types.Point {
        while (true) {
            if (self.pos < self.current_points.len) {
                const pt = self.current_points[self.pos];
                self.pos += 1;
                if (pt.ts >= self.start_ts and pt.ts <= self.end_ts) {
                    return pt;
                }
                continue;
            }

            if (self.current_points.len > 0) {
                self.allocator.free(self.current_points);
                self.current_points = &[_]types.Point{};
            }

            while (self.block_it.next() catch null) |block| {
                if (block.header.series_id != self.series_id) continue;
                if (block.header.stats.max_ts < self.start_ts) continue;
                if (block.header.stats.min_ts > self.end_ts) continue;

                self.current_points = block.decodePoints(self.allocator) catch &[_]types.Point{};
                self.pos = 0;
                break;
            } else {
                return null;
            }
        }
    }

    pub fn iterator(self: *SegmentIterator) PointIterator {
        return .{
            .ptr = self,
            .nextFn = struct {
                fn next(ptr: *anyopaque) ?types.Point {
                    const typed_ptr: *SegmentIterator = @ptrCast(@alignCast(ptr));
                    return typed_ptr.next();
                }
            }.next,
        };
    }
};

/// K-way merge over a set of `PointIterator`s.
///
/// ## Ordering contract
///
/// `next()` returns points in ascending `(ts, value)` order:
///   1. lower `ts` first;
///   2. on equal `ts`, lower `value` first;
///   3. on equal `(ts, value)` (a full tie), the iterator that was
///      added EARLIEST via `addIterator` wins. (This falls out of
///      the linear `<` scan in `next` — see source — and is the
///      behaviour `compaction.zig` relies on for dedup: the later
///      arrivals overwrite, so the *last* equal-`ts` point in the
///      stream wins per timestamp; with full `(ts, value)` ties no
///      observable difference occurs.)
///
/// ## Arena ownership
///
/// `MergeIterator` does NOT own the underlying point data — it holds
/// `PointIterator` interface values, which in turn borrow from the
/// caller-supplied arena (typically created and passed in by
/// `Engine.queryPoints`). When that arena is freed, the slices
/// returned by `next()` become invalid.
///
/// Callers using the engine's `queryPoints` path MUST keep the arena
/// alive for the entire query lifetime and MUST NOT call `deinit` on
/// the returned `*MergeIterator` — freeing the arena reclaims the
/// iterator itself together with all its child state.
///
/// Direct callers (e.g. tests, the compactor) that construct a
/// `MergeIterator` with a regular allocator MUST call `deinit` to
/// release the two internal ArrayLists. Either ownership model is
/// supported; do not mix them.
pub const MergeIterator = struct {
    allocator: Allocator,
    iters: std.ArrayListUnmanaged(PointIterator),
    current_heads: std.ArrayListUnmanaged(?types.Point),

    pub fn init(allocator: Allocator) MergeIterator {
        return .{
            .allocator = allocator,
            .iters = .empty,
            .current_heads = .empty,
        };
    }

    pub fn deinit(self: *MergeIterator) void {
        self.iters.deinit(self.allocator);
        self.current_heads.deinit(self.allocator);
    }

    pub fn addIterator(self: *MergeIterator, it: PointIterator) !void {
        try self.iters.append(self.allocator, it);
        try self.current_heads.append(self.allocator, it.next());
    }

    pub fn next(self: *MergeIterator) ?types.Point {
        var min_idx: ?usize = null;
        var min_pt: types.Point = undefined;

        for (self.current_heads.items, 0..) |head_opt, i| {
            if (head_opt) |pt| {
                if (min_idx == null or pt.ts < min_pt.ts or (pt.ts == min_pt.ts and pt.value < min_pt.value)) {
                    min_idx = i;
                    min_pt = pt;
                }
            }
        }

        if (min_idx) |idx| {
            self.current_heads.items[idx] = self.iters.items[idx].next();
            return min_pt;
        }

        return null;
    }

    pub fn iterator(self: *MergeIterator) PointIterator {
        return .{
            .ptr = self,
            .nextFn = struct {
                fn next(ptr: *anyopaque) ?types.Point {
                    const typed_ptr: *MergeIterator = @ptrCast(@alignCast(ptr));
                    return typed_ptr.next();
                }
            }.next,
        };
    }
};

test "MergeIterator with SliceIterators" {
    const allocator = std.testing.allocator;

    const slice1 = [_]types.Point{
        .{ .ts = 10, .value = 1 },
        .{ .ts = 30, .value = 3 },
    };
    const slice2 = [_]types.Point{
        .{ .ts = 20, .value = 2 },
        .{ .ts = 40, .value = 4 },
    };
    const slice3 = [_]types.Point{
        .{ .ts = 15, .value = 5 },
        .{ .ts = 25, .value = 6 },
    };

    var it1 = SliceIterator{ .slice = &slice1 };
    var it2 = SliceIterator{ .slice = &slice2 };
    var it3 = SliceIterator{ .slice = &slice3 };

    var merger = MergeIterator.init(allocator);
    defer merger.deinit();

    try merger.addIterator(it1.iterator());
    try merger.addIterator(it2.iterator());
    try merger.addIterator(it3.iterator());

    const expected_ts = [_]i64{ 10, 15, 20, 25, 30, 40 };

    var i: usize = 0;
    while (merger.next()) |pt| {
        try std.testing.expectEqual(expected_ts[i], pt.ts);
        i += 1;
    }
    try std.testing.expectEqual(expected_ts.len, i);
}
