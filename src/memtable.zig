// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

/// In-memory write buffer for points awaiting a segment flush.
///
/// Holds an `AutoHashMap<SeriesId, SeriesEntry>` keyed by series, where
/// each entry tracks both the point list and a `sorted` flag indicating
/// whether the list is currently in non-decreasing `(ts, value)` order.
///
/// ## Lazy sort (P-ALGO-003)
///
/// Previously `insert` re-sorted the entire per-series list whenever an
/// out-of-order point arrived. With 100k points already buffered and a
/// single late arrival, that triggered a 100k-element `pdq` sort under
/// the engine's writer lock for every late point.
///
/// The current design defers that work:
///
///   * If the incoming batch is sorted AND its head is `>=` the
///     existing tail, the list stays `sorted = true` and we just
///     `appendSlice`. This is the steady-state ingest path.
///   * Otherwise we still `appendSlice` (cheap) and flip the entry's
///     `sorted` flag to `false`. NO sort happens on the write path.
///   * When a reader (`getPoints`, `getSortedPoints`, `forEachSorted`)
///     needs sorted iteration, it calls `ensureSorted` which sorts
///     once and flips the flag back to `true`.
///
/// The flush and query paths therefore pay the sort exactly once per
/// (series, OoO arrival window) rather than once per OoO point.
///
/// `point_count` tracks the total live points across all series and
/// is consulted by `shouldFlush()` against `max_points` to decide
/// when the engine should rotate the memtable. The memtable does not
/// itself trigger a flush — the engine owns that policy decision.
///
/// Threading: not internally synchronised. The engine serialises all
/// access via its own lock. Because `getSortedPoints` / `ensureSorted`
/// can mutate (sort + flip the flag), they take a `*Memtable` rather
/// than `*const Memtable`; the engine must hold the writer lock (not
/// just the reader lock) when calling them.
pub const Memtable = struct {
    allocator: Allocator,
    series: std.AutoHashMap(types.SeriesId, SeriesEntry),
    point_count: usize,
    max_points: usize,
    /// Per-series ArrayList capacity hint. When non-zero, the first
    /// time a series is touched in `insert` the entry's `points` list
    /// is pre-grown to this many slots so the initial `appendSlice`
    /// avoids the first growth allocation. Zero (the `init` default)
    /// preserves the historical lazy-grow behaviour bit-for-bit.
    /// ENT-002 / ENT-005.
    points_per_series_hint: usize = 0,

    pub const SeriesEntry = struct {
        points: std.ArrayListUnmanaged(types.Point) = .empty,
        sorted: bool = true,
    };

    pub fn init(allocator: Allocator, max_points: usize) Memtable {
        return .{
            .allocator = allocator,
            .series = std.AutoHashMap(types.SeriesId, SeriesEntry).init(allocator),
            .point_count = 0,
            .max_points = max_points,
        };
    }

    /// Construct a Memtable pre-sized for the expected steady-state
    /// cardinality. `expected_series` is a hint for the AutoHashMap
    /// backing store; `expected_points_per_series` is a hint for each
    /// per-series ArrayList. Both are best-effort: if the workload
    /// exceeds the hint the structures still grow correctly, just with
    /// the regular doubling cost.
    ///
    /// ENT-002 / ENT-005. The engine calls this from `Engine.init`
    /// and from `maybeTriggerFlushLocked` / `sync` (rotation paths) so
    /// the active memtable starts with enough capacity to avoid the
    /// first-touch realloc on the steady-state ingest path. The
    /// per-series ArrayList pre-sizing happens lazily on the first
    /// `insert` for a given SeriesId — at construction time the set
    /// of SeriesIds is not yet known.
    pub fn initCapacity(
        allocator: Allocator,
        max_points: usize,
        expected_series: usize,
        expected_points_per_series: usize,
    ) !Memtable {
        var series = std.AutoHashMap(types.SeriesId, SeriesEntry).init(allocator);
        errdefer series.deinit();
        if (expected_series > 0) {
            try series.ensureTotalCapacity(@intCast(expected_series));
        }
        return .{
            .allocator = allocator,
            .series = series,
            .point_count = 0,
            .max_points = max_points,
            .points_per_series_hint = expected_points_per_series,
        };
    }

    pub fn deinit(self: *Memtable) void {
        var it = self.series.valueIterator();
        while (it.next()) |entry| {
            entry.points.deinit(self.allocator);
        }
        self.series.deinit();
    }

    fn lessThan(_: void, a: types.Point, b: types.Point) bool {
        return if (a.ts == b.ts) a.value < b.value else a.ts < b.ts;
    }

    /// Append `points` to the per-series list. If the incoming batch
    /// is in-order AND lands after the existing tail, the entry stays
    /// `sorted = true`. Otherwise the entry is flagged `sorted = false`
    /// without sorting — readers will sort lazily when they need it.
    pub fn insert(self: *Memtable, id: types.SeriesId, points: []const types.Point) !void {
        if (points.len == 0) return;

        const gop = try self.series.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            // ENT-002 / ENT-005: when the engine constructed this
            // memtable via `initCapacity` with a per-series hint,
            // pre-grow the freshly-minted ArrayList so the
            // `appendSlice` below stays a memcpy with no growth
            // allocation. Hint == 0 (the `init` default) preserves
            // the historical lazy-grow behaviour.
            if (self.points_per_series_hint > 0) {
                try gop.value_ptr.points.ensureTotalCapacity(self.allocator, self.points_per_series_hint);
            }
        }

        const entry = gop.value_ptr;
        const existing_len = entry.points.items.len;

        var batch_sorted = true;
        for (1..points.len) |i| {
            if (lessThan({}, points[i], points[i - 1])) {
                batch_sorted = false;
                break;
            }
        }

        const can_append_in_order = batch_sorted and (existing_len == 0 or
            !lessThan({}, points[0], entry.points.items[existing_len - 1]));

        try entry.points.appendSlice(self.allocator, points);
        self.point_count += points.len;

        if (!can_append_in_order) {
            // Defer the sort — flip the flag and let the next reader
            // (or flush) pay the cost once, regardless of how many
            // more OoO batches arrive in the meantime.
            entry.sorted = false;
        }
        // If can_append_in_order is true and the entry was previously
        // unsorted, it STAYS unsorted: appending sorted-after-tail to
        // an unsorted list does not make the whole list sorted. We
        // only set sorted = true after an actual ensureSorted call.
        if (!entry.sorted) return;
    }

    /// Read-only access to the raw per-series buffer. May be unsorted
    /// — callers that need sorted iteration must use
    /// `getSortedPoints` instead.
    pub fn getPoints(self: *const Memtable, id: types.SeriesId) []const types.Point {
        if (self.series.getPtr(id)) |entry| {
            return entry.points.items;
        }
        return &.{};
    }

    /// Lazy-sort the per-series buffer (if needed) and return a
    /// guaranteed-sorted slice. The sort runs at most once per OoO
    /// arrival window — subsequent calls are O(1).
    pub fn getSortedPoints(self: *Memtable, id: types.SeriesId) []const types.Point {
        if (self.series.getPtr(id)) |entry| {
            if (!entry.sorted) {
                std.sort.pdq(types.Point, entry.points.items, {}, lessThan);
                entry.sorted = true;
            }
            return entry.points.items;
        }
        return &.{};
    }

    /// Force-sort every series. Used by the flush path so a single
    /// pass costs O(n log n) per series rather than paying the sort
    /// inside the per-series flush loop.
    pub fn ensureAllSorted(self: *Memtable) void {
        var it = self.series.valueIterator();
        while (it.next()) |entry| {
            if (!entry.sorted) {
                std.sort.pdq(types.Point, entry.points.items, {}, lessThan);
                entry.sorted = true;
            }
        }
    }

    pub fn shouldFlush(self: *const Memtable) bool {
        return self.point_count >= self.max_points;
    }

    pub fn clear(self: *Memtable) void {
        var it = self.series.valueIterator();
        while (it.next()) |entry| {
            entry.points.clearRetainingCapacity();
            entry.sorted = true;
        }
        self.point_count = 0;
    }
};

test "Memtable insert and sort" {
    const allocator = std.testing.allocator;
    var mem = Memtable.init(allocator, 1000);
    defer mem.deinit();

    const id = 123;
    try mem.insert(id, &.{
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 1000, .value = 10 },
    });

    // Raw view: insert did NOT sort (lazy). Confirm the OoO order
    // is still present on the underlying buffer.
    const raw = mem.getPoints(id);
    try std.testing.expectEqual(@as(usize, 2), raw.len);
    try std.testing.expectEqual(@as(i64, 2000), raw[0].ts);
    try std.testing.expectEqual(@as(i64, 1000), raw[1].ts);

    // Sorted view: triggers lazy sort, returns ascending.
    const pts = mem.getSortedPoints(id);
    try std.testing.expectEqual(@as(usize, 2), pts.len);
    try std.testing.expectEqual(@as(i64, 1000), pts[0].ts);
    try std.testing.expectEqual(@as(i64, 2000), pts[1].ts);
    try std.testing.expectEqual(@as(usize, 2), mem.point_count);
}

test "Memtable: OoO insert does not sort until reader asks (P-ALGO-003)" {
    const allocator = std.testing.allocator;
    var mem = Memtable.init(allocator, 1_000_000);
    defer mem.deinit();

    const id: types.SeriesId = 7;

    // Seed with 1k sorted points so the series entry exists and is
    // marked sorted.
    var seed_buf: [1024]types.Point = undefined;
    for (&seed_buf, 0..) |*p, i| p.* = .{ .ts = @intCast(i + 1000), .value = @intCast(i) };
    try mem.insert(id, &seed_buf);

    // The entry should be sorted after an in-order append.
    {
        const entry = mem.series.getPtr(id).?;
        try std.testing.expect(entry.sorted);
    }

    // Now insert a single OoO point.
    try mem.insert(id, &.{.{ .ts = 500, .value = -1 }});

    // The entry MUST still be marked unsorted — the insert path
    // does NOT eagerly sort. This is the P-ALGO-003 contract.
    {
        const entry = mem.series.getPtr(id).?;
        try std.testing.expect(!entry.sorted);
        // The raw buffer order: the new point is at the tail, not
        // re-sorted into position.
        try std.testing.expectEqual(@as(i64, 500), entry.points.items[entry.points.items.len - 1].ts);
    }

    // Reading via getSortedPoints sorts on demand and flips the flag.
    const sorted = mem.getSortedPoints(id);
    try std.testing.expectEqual(@as(i64, 500), sorted[0].ts);
    {
        const entry = mem.series.getPtr(id).?;
        try std.testing.expect(entry.sorted);
    }

    // A second OoO arrival re-flips the flag.
    try mem.insert(id, &.{.{ .ts = 300, .value = -2 }});
    {
        const entry = mem.series.getPtr(id).?;
        try std.testing.expect(!entry.sorted);
    }

    // ensureAllSorted is the flush path's bulk variant.
    mem.ensureAllSorted();
    {
        const entry = mem.series.getPtr(id).?;
        try std.testing.expect(entry.sorted);
        try std.testing.expectEqual(@as(i64, 300), entry.points.items[0].ts);
    }
}

test "Memtable: in-order appends keep sorted flag set" {
    const allocator = std.testing.allocator;
    var mem = Memtable.init(allocator, 1000);
    defer mem.deinit();

    const id: types.SeriesId = 1;
    try mem.insert(id, &.{
        .{ .ts = 10, .value = 1 },
        .{ .ts = 20, .value = 2 },
    });
    try mem.insert(id, &.{
        .{ .ts = 30, .value = 3 },
        .{ .ts = 40, .value = 4 },
    });

    const entry = mem.series.getPtr(id).?;
    try std.testing.expect(entry.sorted);
    try std.testing.expectEqual(@as(usize, 4), entry.points.items.len);
}

test "Memtable: initCapacity preserves insert semantics (ENT-002 / ENT-005)" {
    // ENT-002 / ENT-005: this test exercises the pre-sized constructor
    // and confirms it is a drop-in replacement for `init` on the
    // semantic surface. The alloc-count drop is validated by the
    // micro-bench (`benchmarks/micro/memtable.zig`); here we only
    // verify behavioural equivalence — same insert semantics, same
    // lazy-sort contract, no leaks under the testing allocator.
    const allocator = std.testing.allocator;
    var mem = try Memtable.initCapacity(allocator, 1_000_000, 16, 1024);
    defer mem.deinit();

    const id: types.SeriesId = 42;

    // In-order insert keeps the entry sorted (steady-state ingest).
    var ascending: [256]types.Point = undefined;
    for (&ascending, 0..) |*p, i| p.* = .{ .ts = @intCast(i + 1000), .value = @intCast(i) };
    try mem.insert(id, &ascending);

    try std.testing.expectEqual(@as(usize, 256), mem.point_count);
    {
        const entry = mem.series.getPtr(id).?;
        try std.testing.expect(entry.sorted);
        try std.testing.expectEqual(@as(usize, 256), entry.points.items.len);
        // The pre-sized ArrayList must already hold at least the hint.
        try std.testing.expect(entry.points.capacity >= 1024);
    }

    // OoO insert flips sorted=false without sorting (P-ALGO-003 contract).
    try mem.insert(id, &.{.{ .ts = 500, .value = -1 }});
    {
        const entry = mem.series.getPtr(id).?;
        try std.testing.expect(!entry.sorted);
        try std.testing.expectEqual(@as(i64, 500), entry.points.items[entry.points.items.len - 1].ts);
    }

    // Reader triggers the lazy sort.
    const sorted = mem.getSortedPoints(id);
    try std.testing.expectEqual(@as(i64, 500), sorted[0].ts);
    try std.testing.expect(mem.series.getPtr(id).?.sorted);
}

test "Memtable: initCapacity with zero hints behaves like init" {
    // Edge case: callers may pass (0, 0) when they only want the
    // explicit-error API surface but not the pre-sizing. The result
    // must be functionally identical to `init`.
    const allocator = std.testing.allocator;
    var mem = try Memtable.initCapacity(allocator, 1000, 0, 0);
    defer mem.deinit();

    try std.testing.expectEqual(@as(usize, 0), mem.points_per_series_hint);

    const id: types.SeriesId = 9;
    try mem.insert(id, &.{
        .{ .ts = 10, .value = 1 },
        .{ .ts = 20, .value = 2 },
    });
    try std.testing.expectEqual(@as(usize, 2), mem.point_count);
    try std.testing.expect(mem.series.getPtr(id).?.sorted);
}

test "Memtable: clear resets sorted flag" {
    const allocator = std.testing.allocator;
    var mem = Memtable.init(allocator, 1000);
    defer mem.deinit();

    const id: types.SeriesId = 2;
    try mem.insert(id, &.{
        .{ .ts = 20, .value = 2 },
        .{ .ts = 10, .value = 1 }, // OoO -> sorted=false
    });

    try std.testing.expect(!mem.series.getPtr(id).?.sorted);
    mem.clear();
    // After clear, the entry should still exist with capacity, but
    // be marked sorted (the empty list is trivially sorted).
    try std.testing.expect(mem.series.getPtr(id).?.sorted);
    try std.testing.expectEqual(@as(usize, 0), mem.point_count);
}
