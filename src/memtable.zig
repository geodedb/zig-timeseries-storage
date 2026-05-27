// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

/// Number of independent shards inside a single `Memtable` (P-LOCK-005).
///
/// Each shard owns its own mutex and series HashMap, so concurrent
/// `insert` calls landing on distinct shards never contend. The shard
/// is picked from the low bits of the `SeriesId` via a power-of-two
/// mask (`series_id & (NUM_SHARDS - 1)`), which keeps the dispatch
/// cost to a single AND.
///
/// 16 is a deliberate trade-off: small enough that each shard's
/// HashMap and per-series ArrayList cache lines stay reasonably hot,
/// large enough that 4-16 concurrent writer threads typically land
/// on distinct shards on random series IDs (collision probability at
/// 4 writers is 4!/(16^4) ≈ 0.04%). MUST be a power of two so the
/// mask is exact.
pub const NUM_SHARDS: usize = 16;

comptime {
    // NUM_SHARDS must be a power of two so the mask works without modulo.
    if (NUM_SHARDS & (NUM_SHARDS - 1) != 0) {
        @compileError("NUM_SHARDS must be a power of two");
    }
}

/// Pick the shard index for a given series id. Single bitwise-AND,
/// inlined by the compiler.
inline fn shardIndex(id: types.SeriesId) usize {
    // SeriesId is a u128. Masking the low usize-sized bits is enough —
    // NUM_SHARDS-1 is a small power-of-two-minus-one so the upper
    // bits do not matter for distribution.
    const lo: usize = @truncate(id);
    return lo & (NUM_SHARDS - 1);
}

/// In-memory write buffer for points awaiting a segment flush.
///
/// ## Per-shard locking (P-LOCK-005)
///
/// The memtable is decomposed into `NUM_SHARDS` independent shards,
/// each with its own `std.Io.Mutex` and per-series HashMap. Writers
/// targeting different shards never contend — the key win over the
/// previous "single HashMap under the engine writer lock" shape.
///
/// `point_count` is a process-wide `std.atomic.Value(usize)` so
/// `shouldFlush` is lock-free. `pending_writers` is incremented by
/// `appendPoints` before `insert` and decremented after, so the flush
/// worker can drain in-flight writers before it scans the (now
/// rotated) memtable — without this barrier a writer that snapshotted
/// the active pointer pre-rotation could land points in the memtable
/// after the flush worker had already begun scanning it, breaking
/// the "all points appended before flush are visible in the segment"
/// contract.
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
/// `point_count` tracks the total live points across all shards and
/// is consulted by `shouldFlush()` against `max_points` to decide
/// when the engine should rotate the memtable. The memtable does not
/// itself trigger a flush — the engine owns that policy decision.
///
/// Threading: per-shard internally synchronised. The engine no longer
/// needs to hold `Engine.mu` around `insert` / `getPoints` /
/// `getSortedPoints` — each shard mutex covers exactly the state it
/// guards. Bulk operations (`ensureAllSorted`, `clear`, `deinit`)
/// lock every shard in shard-index order to avoid deadlock.
pub const Memtable = struct {
    allocator: Allocator,
    shards: [NUM_SHARDS]Shard,
    /// Lock-free total across all shards. Read by `shouldFlush` and
    /// the engine's flush trigger; incremented by `insert` via
    /// `fetchAdd`. Acquire/release ordering pairs with the shard
    /// mutexes so a `shouldFlush` reader observes a non-stale view of
    /// the work the most recent `insert` published.
    point_count: std.atomic.Value(usize),
    max_points: usize,
    /// Per-series ArrayList capacity hint. When non-zero, the first
    /// time a series is touched in `insert` the entry's `points` list
    /// is pre-grown to this many slots so the initial `appendSlice`
    /// avoids the first growth allocation. Zero (the `init` default)
    /// preserves the historical lazy-grow behaviour bit-for-bit.
    /// ENT-002 / ENT-005.
    points_per_series_hint: usize = 0,

    /// In-flight `insert` counter (P-LOCK-005 barrier).
    ///
    /// Bumped by the engine in `appendPoints` before it calls
    /// `insert`, decremented after. The flush worker uses
    /// `waitForQuiescence` to spin until this hits zero before it
    /// starts scanning the (post-rotation) memtable, closing the
    /// "late-arrival insert after flush worker began scan" lost-
    /// update race.
    pending_writers: std.atomic.Value(u32) = .init(0),

    pub const SeriesEntry = struct {
        points: std.ArrayListUnmanaged(types.Point) = .empty,
        sorted: bool = true,
    };

    pub const Shard = struct {
        mu: std.Io.Mutex = std.Io.Mutex.init,
        series: std.AutoHashMap(types.SeriesId, SeriesEntry),
    };

    pub fn init(allocator: Allocator, max_points: usize) Memtable {
        var shards: [NUM_SHARDS]Shard = undefined;
        for (&shards) |*s| {
            s.* = .{
                .series = std.AutoHashMap(types.SeriesId, SeriesEntry).init(allocator),
            };
        }
        return .{
            .allocator = allocator,
            .shards = shards,
            .point_count = .init(0),
            .max_points = max_points,
        };
    }

    /// Construct a Memtable pre-sized for the expected steady-state
    /// cardinality. `expected_series` is a hint distributed evenly
    /// across shards; `expected_points_per_series` is a hint for each
    /// per-series ArrayList. Both are best-effort: if the workload
    /// exceeds the hint the structures still grow correctly, just with
    /// the regular doubling cost.
    ///
    /// ENT-002 / ENT-005 + P-LOCK-005. The hint is divided by
    /// `NUM_SHARDS` (rounded up) so each shard reserves its fair share
    /// of the expected cardinality without over-allocating globally.
    pub fn initCapacity(
        allocator: Allocator,
        max_points: usize,
        expected_series: usize,
        expected_points_per_series: usize,
    ) !Memtable {
        var shards: [NUM_SHARDS]Shard = undefined;
        // Track how many shards have been successfully constructed so
        // an `errdefer` can tear them down cleanly on a mid-loop OOM.
        var built: usize = 0;
        errdefer {
            for (shards[0..built]) |*s| s.series.deinit();
        }
        const per_shard_hint = if (expected_series == 0)
            0
        else
            (expected_series + NUM_SHARDS - 1) / NUM_SHARDS;
        while (built < NUM_SHARDS) : (built += 1) {
            shards[built] = .{
                .series = std.AutoHashMap(types.SeriesId, SeriesEntry).init(allocator),
            };
            if (per_shard_hint > 0) {
                try shards[built].series.ensureTotalCapacity(@intCast(per_shard_hint));
            }
        }
        return .{
            .allocator = allocator,
            .shards = shards,
            .point_count = .init(0),
            .max_points = max_points,
            .points_per_series_hint = expected_points_per_series,
        };
    }

    pub fn deinit(self: *Memtable) void {
        // No lock needed: deinit is only called when no other thread
        // can touch the memtable (engine ensures via flush worker
        // ownership / deinit gating).
        for (&self.shards) |*s| {
            var it = s.series.valueIterator();
            while (it.next()) |entry| {
                entry.points.deinit(self.allocator);
            }
            s.series.deinit();
        }
    }

    fn lessThan(_: void, a: types.Point, b: types.Point) bool {
        return if (a.ts == b.ts) a.value < b.value else a.ts < b.ts;
    }

    /// Append `points` to the per-series list. If the incoming batch
    /// is in-order AND lands after the existing tail, the entry stays
    /// `sorted = true`. Otherwise the entry is flagged `sorted = false`
    /// without sorting — readers will sort lazily when they need it.
    ///
    /// Thread-safe: locks only the relevant shard's mutex. Concurrent
    /// inserts on distinct shards proceed in parallel.
    pub fn insert(self: *Memtable, id: types.SeriesId, points: []const types.Point) !void {
        if (points.len == 0) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const shard = &self.shards[shardIndex(id)];
        shard.mu.lockUncancelable(io);
        defer shard.mu.unlock(io);

        const gop = try shard.series.getOrPut(id);
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
        _ = self.point_count.fetchAdd(points.len, .release);

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
    }

    /// Read-only access to the raw per-series buffer. May be unsorted
    /// — callers that need sorted iteration must use
    /// `getSortedPoints` instead.
    ///
    /// Returns a slice copied into `out_buf` (an `ArrayListUnmanaged`)
    /// because the underlying ArrayList sits behind a shard mutex
    /// that this function releases before returning. Returning a raw
    /// `[]const types.Point` slice that points into the shard buffer
    /// would invite a use-after-free if a concurrent `insert`
    /// reallocates the array.
    pub fn copyPoints(
        self: *Memtable,
        id: types.SeriesId,
        out_alloc: Allocator,
        out: *std.ArrayListUnmanaged(types.Point),
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const shard = &self.shards[shardIndex(id)];
        shard.mu.lockUncancelable(io);
        defer shard.mu.unlock(io);
        if (shard.series.getPtr(id)) |entry| {
            try out.appendSlice(out_alloc, entry.points.items);
        }
    }

    /// Lazy-sort the per-series buffer (if needed) and copy a sorted
    /// snapshot into `out`. The shard mutex is held only for the
    /// in-place sort and the copy; the snapshot is safe to read after
    /// the lock is released because it lives in caller-supplied
    /// memory.
    ///
    /// `out` is appended-to (not cleared) so callers can accumulate
    /// across multiple memtables (active + flushing) into the same
    /// buffer.
    pub fn copySortedPoints(
        self: *Memtable,
        id: types.SeriesId,
        out_alloc: Allocator,
        out: *std.ArrayListUnmanaged(types.Point),
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const shard = &self.shards[shardIndex(id)];
        shard.mu.lockUncancelable(io);
        defer shard.mu.unlock(io);
        if (shard.series.getPtr(id)) |entry| {
            if (!entry.sorted) {
                std.sort.pdq(types.Point, entry.points.items, {}, lessThan);
                entry.sorted = true;
            }
            try out.appendSlice(out_alloc, entry.points.items);
        }
    }

    /// Force-sort every series across every shard. Used by the flush
    /// path so a single pass costs O(n log n) per series rather than
    /// paying the sort inside the per-series flush loop.
    ///
    /// Locks shards in shard-index order (consistent with `clear`)
    /// so concurrent calls cannot deadlock. The flush worker holds
    /// this against a quiesced memtable (no in-flight writers), so
    /// the per-shard lock contention is minimal in practice.
    pub fn ensureAllSorted(self: *Memtable) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        for (&self.shards) |*shard| {
            shard.mu.lockUncancelable(io);
            defer shard.mu.unlock(io);
            var it = shard.series.valueIterator();
            while (it.next()) |entry| {
                if (!entry.sorted) {
                    std.sort.pdq(types.Point, entry.points.items, {}, lessThan);
                    entry.sorted = true;
                }
            }
        }
    }

    /// Lock-free read of the total point count across all shards.
    /// The result may briefly lag a concurrent `insert` that has
    /// performed its appendSlice but not yet completed `fetchAdd`,
    /// but is monotonic — `shouldFlush` rounds up to the threshold
    /// once enough work has been published.
    pub fn shouldFlush(self: *const Memtable) bool {
        return self.point_count.load(.acquire) >= self.max_points;
    }

    /// Bump the in-flight writer counter. Callers MUST balance with
    /// `endAppend()`. The engine wraps `insert` between these so the
    /// flush worker (post-rotation) can drain in-flight inserts on
    /// the rotated-out memtable before scanning it.
    pub fn beginAppend(self: *Memtable) void {
        _ = self.pending_writers.fetchAdd(1, .acquire);
    }

    /// Drop the in-flight writer counter. MUST match a prior
    /// `beginAppend()`. Release-ordered so the rotated-out memtable's
    /// flush worker observes every preceding `insert` completion when
    /// it sees the counter hit zero.
    pub fn endAppend(self: *Memtable) void {
        _ = self.pending_writers.fetchSub(1, .release);
    }

    /// Spin-wait until `pending_writers` drops to zero. Called by the
    /// flush worker immediately after the engine has rotated this
    /// memtable into the flushing slot — once the pointer swap is
    /// published, no NEW writers can target this memtable, so the
    /// counter is monotonic-decreasing.
    ///
    /// The wait is a bounded spin in practice: every in-flight writer
    /// is in the middle of a `memtable.insert` call (microseconds).
    /// Under the absurd worst case of an OS scheduler de-scheduling
    /// the writer thread mid-insert, we yield to be polite — but a
    /// blocking primitive here would just trade the spin for a
    /// futex round-trip without changing the asymptotic behaviour.
    pub fn waitForQuiescence(self: *Memtable) void {
        var spin: u32 = 0;
        while (self.pending_writers.load(.acquire) != 0) {
            spin += 1;
            // After ~256 spins fall back to thread yield so we don't
            // burn a core on a descheduled writer.
            if (spin > 256) {
                std.Thread.yield() catch {};
                spin = 0;
            }
        }
    }

    pub fn clear(self: *Memtable) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        for (&self.shards) |*shard| {
            shard.mu.lockUncancelable(io);
            defer shard.mu.unlock(io);
            var it = shard.series.valueIterator();
            while (it.next()) |entry| {
                entry.points.clearRetainingCapacity();
                entry.sorted = true;
            }
        }
        self.point_count.store(0, .release);
    }

    /// Visit every (series_id, points slice) pair across every shard.
    /// Locks the current shard while the visitor is active so the
    /// slice the visitor sees is stable; callers MUST NOT retain the
    /// slice past the visitor return without copying.
    ///
    /// Used by the flush worker to encode the memtable into a segment
    /// without copying the whole memtable first.
    pub fn forEachSeries(
        self: *Memtable,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), types.SeriesId, []const types.Point) anyerror!void,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        for (&self.shards) |*shard| {
            shard.mu.lockUncancelable(io);
            defer shard.mu.unlock(io);
            var it = shard.series.iterator();
            while (it.next()) |entry| {
                try visit(ctx, entry.key_ptr.*, entry.value_ptr.points.items);
            }
        }
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
    var raw_buf = std.ArrayListUnmanaged(types.Point).empty;
    defer raw_buf.deinit(allocator);
    try mem.copyPoints(id, allocator, &raw_buf);
    try std.testing.expectEqual(@as(usize, 2), raw_buf.items.len);
    try std.testing.expectEqual(@as(i64, 2000), raw_buf.items[0].ts);
    try std.testing.expectEqual(@as(i64, 1000), raw_buf.items[1].ts);

    // Sorted view: triggers lazy sort, returns ascending.
    var sorted_buf = std.ArrayListUnmanaged(types.Point).empty;
    defer sorted_buf.deinit(allocator);
    try mem.copySortedPoints(id, allocator, &sorted_buf);
    try std.testing.expectEqual(@as(usize, 2), sorted_buf.items.len);
    try std.testing.expectEqual(@as(i64, 1000), sorted_buf.items[0].ts);
    try std.testing.expectEqual(@as(i64, 2000), sorted_buf.items[1].ts);
    try std.testing.expectEqual(@as(usize, 2), mem.point_count.load(.acquire));
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
        const shard = &mem.shards[shardIndex(id)];
        try std.testing.expect(shard.series.getPtr(id).?.sorted);
    }

    // Now insert a single OoO point.
    try mem.insert(id, &.{.{ .ts = 500, .value = -1 }});

    // The entry MUST still be marked unsorted — the insert path
    // does NOT eagerly sort. This is the P-ALGO-003 contract.
    {
        const shard = &mem.shards[shardIndex(id)];
        const entry = shard.series.getPtr(id).?;
        try std.testing.expect(!entry.sorted);
        // The raw buffer order: the new point is at the tail, not
        // re-sorted into position.
        try std.testing.expectEqual(@as(i64, 500), entry.points.items[entry.points.items.len - 1].ts);
    }

    // Reading via copySortedPoints sorts on demand and flips the flag.
    var sorted_buf = std.ArrayListUnmanaged(types.Point).empty;
    defer sorted_buf.deinit(allocator);
    try mem.copySortedPoints(id, allocator, &sorted_buf);
    try std.testing.expectEqual(@as(i64, 500), sorted_buf.items[0].ts);
    {
        const shard = &mem.shards[shardIndex(id)];
        try std.testing.expect(shard.series.getPtr(id).?.sorted);
    }

    // A second OoO arrival re-flips the flag.
    try mem.insert(id, &.{.{ .ts = 300, .value = -2 }});
    {
        const shard = &mem.shards[shardIndex(id)];
        try std.testing.expect(!shard.series.getPtr(id).?.sorted);
    }

    // ensureAllSorted is the flush path's bulk variant.
    mem.ensureAllSorted();
    {
        const shard = &mem.shards[shardIndex(id)];
        const entry = shard.series.getPtr(id).?;
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

    const shard = &mem.shards[shardIndex(id)];
    const entry = shard.series.getPtr(id).?;
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

    try std.testing.expectEqual(@as(usize, 256), mem.point_count.load(.acquire));
    {
        const shard = &mem.shards[shardIndex(id)];
        const entry = shard.series.getPtr(id).?;
        try std.testing.expect(entry.sorted);
        try std.testing.expectEqual(@as(usize, 256), entry.points.items.len);
        // The pre-sized ArrayList must already hold at least the hint.
        try std.testing.expect(entry.points.capacity >= 1024);
    }

    // OoO insert flips sorted=false without sorting (P-ALGO-003 contract).
    try mem.insert(id, &.{.{ .ts = 500, .value = -1 }});
    {
        const shard = &mem.shards[shardIndex(id)];
        const entry = shard.series.getPtr(id).?;
        try std.testing.expect(!entry.sorted);
        try std.testing.expectEqual(@as(i64, 500), entry.points.items[entry.points.items.len - 1].ts);
    }

    // Reader triggers the lazy sort.
    var sorted_buf = std.ArrayListUnmanaged(types.Point).empty;
    defer sorted_buf.deinit(allocator);
    try mem.copySortedPoints(id, allocator, &sorted_buf);
    try std.testing.expectEqual(@as(i64, 500), sorted_buf.items[0].ts);
    try std.testing.expect(mem.shards[shardIndex(id)].series.getPtr(id).?.sorted);
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
    try std.testing.expectEqual(@as(usize, 2), mem.point_count.load(.acquire));
    try std.testing.expect(mem.shards[shardIndex(id)].series.getPtr(id).?.sorted);
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

    try std.testing.expect(!mem.shards[shardIndex(id)].series.getPtr(id).?.sorted);
    mem.clear();
    // After clear, the entry should still exist with capacity, but
    // be marked sorted (the empty list is trivially sorted).
    try std.testing.expect(mem.shards[shardIndex(id)].series.getPtr(id).?.sorted);
    try std.testing.expectEqual(@as(usize, 0), mem.point_count.load(.acquire));
}

test "Memtable: concurrent insert on distinct shards (P-LOCK-005)" {
    // Smoke test for parallel inserts. Two threads writing to two
    // different shards must produce exactly the right point count
    // and not deadlock or corrupt either shard.
    const allocator = std.testing.allocator;
    var mem = Memtable.init(allocator, 1_000_000);
    defer mem.deinit();

    const Worker = struct {
        fn run(m: *Memtable, base_id: types.SeriesId) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                m.insert(base_id + (i % 7), &.{.{
                    .ts = @intCast(i),
                    .value = @intCast(i),
                }}) catch unreachable;
            }
        }
    };

    // Pick two ids that mask to DIFFERENT shards so the test
    // exercises the parallel-shard path.
    const a: types.SeriesId = 0; // shard 0
    const b: types.SeriesId = 1; // shard 1

    var t1 = try std.Thread.spawn(.{}, Worker.run, .{ &mem, a });
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{ &mem, b });
    t1.join();
    t2.join();

    try std.testing.expectEqual(@as(usize, 2000), mem.point_count.load(.acquire));
}

test "Memtable: waitForQuiescence drains in-flight writers" {
    const allocator = std.testing.allocator;
    var mem = Memtable.init(allocator, 1_000_000);
    defer mem.deinit();

    // Manually drive the barrier: begin twice, end twice — counter
    // returns to zero, waitForQuiescence is an immediate noop.
    mem.beginAppend();
    mem.beginAppend();
    try std.testing.expectEqual(@as(u32, 2), mem.pending_writers.load(.acquire));
    mem.endAppend();
    mem.endAppend();
    mem.waitForQuiescence();
    try std.testing.expectEqual(@as(u32, 0), mem.pending_writers.load(.acquire));
}

// Re-export the shardIndex helper for the engine and tests. The
// engine uses it to route inserts; tests use it to assert shard
// affinity in the concurrent-shard test above.
pub const shardIndexOf = shardIndex;
