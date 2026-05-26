// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const Memtable = struct {
    allocator: Allocator,
    series: std.AutoHashMap(types.SeriesId, std.ArrayListUnmanaged(types.Point)),
    point_count: usize,
    max_points: usize,

    pub fn init(allocator: Allocator, max_points: usize) Memtable {
        return .{
            .allocator = allocator,
            .series = std.AutoHashMap(types.SeriesId, std.ArrayListUnmanaged(types.Point)).init(allocator),
            .point_count = 0,
            .max_points = max_points,
        };
    }

    pub fn deinit(self: *Memtable) void {
        var it = self.series.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.series.deinit();
    }

    fn lessThan(_: void, a: types.Point, b: types.Point) bool {
        return if (a.ts == b.ts) a.value < b.value else a.ts < b.ts;
    }

    pub fn insert(self: *Memtable, id: types.SeriesId, points: []const types.Point) !void {
        if (points.len == 0) return;

        const gop = try self.series.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }

        const list = gop.value_ptr;
        const existing_len = list.items.len;

        var batch_sorted = true;
        for (1..points.len) |i| {
            if (lessThan({}, points[i], points[i - 1])) {
                batch_sorted = false;
                break;
            }
        }

        const can_append = batch_sorted and (existing_len == 0 or
            !lessThan({}, points[0], list.items[existing_len - 1]));

        try list.appendSlice(self.allocator, points);
        self.point_count += points.len;

        if (!can_append) {
            std.sort.pdq(types.Point, list.items, {}, lessThan);
        }
    }

    pub fn getPoints(self: *const Memtable, id: types.SeriesId) []const types.Point {
        if (self.series.get(id)) |list| {
            return list.items;
        }
        return &.{};
    }

    pub fn shouldFlush(self: *const Memtable) bool {
        return self.point_count >= self.max_points;
    }

    pub fn clear(self: *Memtable) void {
        var it = self.series.valueIterator();
        while (it.next()) |list| {
            list.clearRetainingCapacity();
        }
        self.point_count = 0;
    }
};

test "Memtable insert and sort" {
    const allocator = std.testing.allocator;
    var memtable = Memtable.init(allocator, 1000);
    defer memtable.deinit();

    const id = 123;
    try memtable.insert(id, &.{
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 1000, .value = 10 },
    });

    const pts = memtable.getPoints(id);
    try std.testing.expectEqual(@as(usize, 2), pts.len);
    try std.testing.expectEqual(@as(i64, 1000), pts[0].ts);
    try std.testing.expectEqual(@as(i64, 2000), pts[1].ts);
    try std.testing.expectEqual(@as(usize, 2), memtable.point_count);
}
