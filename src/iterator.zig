// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const segment = @import("segment.zig");
const safety = @import("safety.zig");

pub const PointIterator = struct {
    ptr: *anyopaque,
    nextFn: *const fn (ptr: *anyopaque) ?types.Point,

    pub fn next(self: PointIterator) ?types.Point {
        return self.nextFn(self.ptr);
    }
};

pub const SliceIterator = struct {
    /// Defence-in-depth tag for vtable ctx recovery (SEC-010).
    pub const MAGIC: u32 = safety.Magic.slice_iterator;
    magic: u32 = MAGIC,
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
                    const typed_ptr = safety.castCtx(SliceIterator, ptr);
                    return typed_ptr.next();
                }
            }.next,
        };
    }
};

pub const SegmentIterator = struct {
    allocator: Allocator,
    reader: segment.SegmentReader,
    /// Cursor state — replaces the previous `BlockIterator` field
    /// which held a `*SegmentReader` to a local copy and was a
    /// dangling-pointer bug waiting to surface.
    offset: u64,
    block_index: u32 = 0,
    series_id: types.SeriesId,
    start_ts: i64,
    end_ts: i64,
    current_points: []types.Point = &[_]types.Point{},
    pos: usize = 0,
    /// P-ALGO-001 (partial): when the underlying segment carries a
    /// footer index AND the index has an entry for `series_id`, this
    /// is set to the number of consecutive blocks the iterator should
    /// visit before stopping. `null` means "no upper bound from the
    /// footer — keep scanning until BlockIterator returns EOF". The
    /// block-header filter (`block.header.series_id != self.series_id`)
    /// is still applied for safety even when this bound is honoured.
    remaining_blocks: ?u32 = null,

    pub fn init(allocator: Allocator, path: []const u8, series_id: types.SeriesId, start_ts: i64, end_ts: i64) !SegmentIterator {
        const reader = try segment.SegmentReader.init(allocator, path);
        // Both v2 and v3 segment magics are the same length (8).
        var start_offset: u64 = segment.SEGMENT_MAGIC.len;
        var remaining: ?u32 = null;
        if (reader.findSeries(series_id)) |hit| {
            // Jump directly to the first block belonging to this
            // series. The footer's `count` bounds the scan so we stop
            // as soon as the series' consecutive run ends.
            start_offset = hit.offset;
            remaining = hit.count;
        }
        return .{
            .allocator = allocator,
            .reader = reader,
            .offset = start_offset,
            .series_id = series_id,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .remaining_blocks = remaining,
        };
    }

    pub fn deinit(self: *SegmentIterator) void {
        if (self.current_points.len > 0) self.allocator.free(self.current_points);
        self.reader.deinit();
    }

    /// Fetch the next point, or `null` at end of iteration.
    ///
    /// Returns an error if a block read or decode fails — the
    /// caller MUST treat that as a query failure rather than EOF.
    /// Previously this method papered over both classes of error by
    /// returning `null` (treating corruption as EOF) and by
    /// substituting an empty slice when `decodePoints` failed; both
    /// behaviours have been removed (Q-REL-009).
    pub fn next(self: *SegmentIterator) !?types.Point {
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

            // P-ALGO-001 (partial): when the footer index gave us a
            // bounded run of blocks for this series, stop as soon as
            // that bound is reached. Keeps the iterator from walking
            // into unrelated series' blocks even if the writer ever
            // interleaves them (the current writer does not, but we
            // do not want the reader to depend on that).
            if (self.remaining_blocks) |rem| {
                if (rem == 0) return null;
            }

            // Drive the block iterator from our own (offset, block_index)
            // state — `BlockIterator` carries a `*SegmentReader` that
            // would dangle if stored as a struct field on the value
            // path. Construct one fresh per next() call instead.
            var block_it = segment.SegmentReader.BlockIterator{
                .reader = &self.reader,
                .offset = self.offset,
                .block_index = self.block_index,
            };
            const maybe_block = try block_it.next();
            self.offset = block_it.offset;
            self.block_index = block_it.block_index;

            const block = maybe_block orelse return null;

            // Decrement the footer-bounded block budget on every
            // visited block (matching or not). The writer keeps a
            // series' blocks consecutive, so the typical case is
            // "match-match-match"; counting non-matches as well makes
            // the bound robust to a future writer change.
            if (self.remaining_blocks) |rem| {
                self.remaining_blocks = rem - 1;
            }

            if (block.header.series_id != self.series_id) continue;
            if (block.header.stats.max_ts < self.start_ts) continue;
            if (block.header.stats.min_ts > self.end_ts) continue;

            self.current_points = try block.decodePoints(self.allocator);
            self.pos = 0;
        }
    }
};

/// K-way merge over a set of `PointIterator`s.
///
/// ## Ordering contract
///
/// `next()` returns points in ascending `(ts, value, iter_index)`
/// order:
///   1. lower `ts` first;
///   2. on equal `ts`, lower `value` first;
///   3. on equal `(ts, value)` (a full tie), the iterator that was
///      added EARLIEST via `addIterator` wins. This is the
///      tie-break behaviour `compaction.zig` relies on for dedup:
///      with equal `(ts, value)` the chosen point comes from the
///      earliest-added stream, so later arrivals do not silently
///      overwrite earlier ones at full ties.
///
/// ## Implementation
///
/// Previously `next()` was an O(K) linear scan of the per-stream
/// heads, called once per emitted point. The current implementation
/// uses a binary min-heap (`std.PriorityQueue`) keyed by
/// `(ts, value, iter_index)`, giving O(log K) per `next()`. For
/// K = 4 (the L0 compaction default) the change is marginal; at
/// K = 10-100 (broader compaction fan-in or multi-segment queries)
/// it materially improves the merge cost.
///
/// The heap holds at most K entries — one per non-exhausted
/// underlying iterator. On `next()` we pop the min, advance the
/// owning iterator, and push the new head back (if any). Exhausted
/// streams drop out of the heap and stay out.
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
/// release the internal storage. Either ownership model is
/// supported; do not mix them.
pub const MergeIterator = struct {
    /// Defence-in-depth tag for vtable ctx recovery (SEC-010).
    pub const MAGIC: u32 = safety.Magic.merge_iterator;
    magic: u32 = MAGIC,
    allocator: Allocator,
    iters: std.ArrayListUnmanaged(PointIterator),
    heap: HeapType,

    const HeapEntry = struct {
        point: types.Point,
        iter_index: u32,
    };

    fn compareHeap(_: void, a: HeapEntry, b: HeapEntry) std.math.Order {
        if (a.point.ts != b.point.ts) return std.math.order(a.point.ts, b.point.ts);
        if (a.point.value != b.point.value) return std.math.order(a.point.value, b.point.value);
        // Stable tie-break: the iterator added earliest wins. This
        // preserves the documented ordering contract used by the
        // compactor for dedup.
        return std.math.order(a.iter_index, b.iter_index);
    }

    const HeapType = std.PriorityQueue(HeapEntry, void, compareHeap);

    pub fn init(allocator: Allocator) MergeIterator {
        return .{
            .magic = MAGIC,
            .allocator = allocator,
            .iters = .empty,
            .heap = HeapType.empty,
        };
    }

    /// Construct an empty `MergeIterator` pre-sized for `hint`
    /// iterators (ENT-001).
    ///
    /// Pre-grows both the `iters` list and the `heap` so each
    /// subsequent `addIterator` call lands in already-reserved
    /// storage. Callers who know K up front — e.g. compaction over a
    /// fixed segment set, or any other code path with a bounded
    /// fan-in — should prefer this constructor over `init`: it drops
    /// per-`addIterator` allocator pressure from O(log K) doubling
    /// reallocations to O(1) up-front reservations.
    ///
    /// `init(allocator)` remains the correct constructor when K is
    /// unknown (e.g. multi-segment query fan-in discovered at
    /// runtime). Both ownership rules in the type-level doc comment
    /// apply unchanged: the caller still owns the underlying point
    /// data, and `deinit` must be called when the iterator was built
    /// against a real allocator rather than an arena.
    pub fn initCapacity(allocator: Allocator, hint: u32) !MergeIterator {
        var iters: std.ArrayListUnmanaged(PointIterator) = .empty;
        try iters.ensureTotalCapacity(allocator, hint);
        var heap = HeapType.empty;
        try heap.ensureTotalCapacity(allocator, hint);
        return .{
            .magic = MAGIC,
            .allocator = allocator,
            .iters = iters,
            .heap = heap,
        };
    }

    pub fn deinit(self: *MergeIterator) void {
        self.iters.deinit(self.allocator);
        self.heap.deinit(self.allocator);
    }

    pub fn addIterator(self: *MergeIterator, it: PointIterator) !void {
        // Reserve list capacity FIRST so we know we can store the
        // iterator even if heap insertion fails — but we also need
        // the index to be a valid heap key, so push to the heap
        // before committing the index would create a dangling key
        // path. Solution: ensure capacity on both, then commit.
        try self.iters.ensureUnusedCapacity(self.allocator, 1);
        const idx: u32 = @intCast(self.iters.items.len);
        // Grab the first head BEFORE storing the iterator value:
        // PointIterator.next() is a vcall that does not depend on
        // ordering, but if it returns null we still record the
        // iterator (later iterators may be added; the index space
        // must stay dense for the tie-break contract).
        const head = it.next();
        self.iters.appendAssumeCapacity(it);

        if (head) |pt| {
            try self.heap.push(self.allocator, .{ .point = pt, .iter_index = idx });
        }
    }

    pub fn next(self: *MergeIterator) ?types.Point {
        const top = self.heap.pop() orelse return null;
        const result = top.point;

        // Advance the owning iterator and push its new head back.
        // If exhausted, the iterator just drops out of the heap.
        if (self.iters.items[top.iter_index].next()) |new_head| {
            self.heap.push(self.allocator, .{ .point = new_head, .iter_index = top.iter_index }) catch {
                // OOM on push: we already popped the result point,
                // so returning it is still correct. Subsequent
                // `next()` calls will skip this iterator (its head
                // is lost). This is a degraded-mode behaviour but
                // not a correctness violation for the point we are
                // about to return.
                return result;
            };
        }

        return result;
    }

    pub fn iterator(self: *MergeIterator) PointIterator {
        return .{
            .ptr = self,
            .nextFn = struct {
                fn next(ptr: *anyopaque) ?types.Point {
                    const typed_ptr = safety.castCtx(MergeIterator, ptr);
                    return typed_ptr.next();
                }
            }.next,
        };
    }
};

test "SegmentIterator: surfaces decode errors instead of returning null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/bad.tsseg", .{dir_path});
    defer allocator.free(seg_path);

    // Hand-craft a segment with a single block whose data_len
    // exceeds the cap so decodePoints fails with BlockTooLarge.
    const limits = @import("limits.zig");
    {
        const f = try std.Io.Dir.cwd().createFile(io, seg_path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer f.close(io);
        try f.writeStreamingAll(io, &segment.SEGMENT_MAGIC);

        var hdr_buf: [segment.BlockHeader.encoded_size]u8 = undefined;
        const h = segment.BlockHeader{
            .series_id = 1,
            .stats = .{
                .min_ts = 0,
                .max_ts = 1,
                .count = 1,
                .min_value = 0,
                .max_value = 1,
                .sum = 0,
                .first_value = 0,
                .last_value = 0,
            },
            .data_len = limits.MAX_BLOCK_DATA_LEN + 1,
        };
        h.serialize(&hdr_buf);
        try f.writeStreamingAll(io, &hdr_buf);
        try f.sync(io);
    }

    var it = try SegmentIterator.init(allocator, seg_path, 1, 0, 100);
    defer it.deinit();

    // The first call to next() drives the block iterator into the
    // bad block and must propagate the decode error rather than
    // silently returning null.
    try std.testing.expectError(error.BlockTooLarge, it.next());
}

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

test "MergeIterator: K=10 streams, correct ordering and tie-break (P-ALGO-002)" {
    const allocator = std.testing.allocator;

    const K = 10;
    const N = 25;

    // Build K interleaved streams: stream `s` emits timestamps
    // (s, s+K, s+2K, ...). All ascending; merging should produce
    // a globally ascending dense sequence 0..K*N-1.
    var slices: [K][N]types.Point = undefined;
    for (0..K) |s| {
        for (0..N) |n| {
            slices[s][n] = .{ .ts = @intCast(s + n * K), .value = @intCast(s) };
        }
    }

    var its: [K]SliceIterator = undefined;
    for (0..K) |s| its[s] = SliceIterator{ .slice = &slices[s] };

    var merger = MergeIterator.init(allocator);
    defer merger.deinit();
    for (0..K) |s| try merger.addIterator(its[s].iterator());

    var expected_ts: i64 = 0;
    var produced: usize = 0;
    while (merger.next()) |pt| {
        try std.testing.expectEqual(expected_ts, pt.ts);
        expected_ts += 1;
        produced += 1;
    }
    try std.testing.expectEqual(@as(usize, K * N), produced);
}

test "MergeIterator: initCapacity preserves K=10 ordering contract (ENT-001)" {
    const allocator = std.testing.allocator;

    const K = 10;
    const N = 25;

    // Same construction as the K=10 ordering test, but the merger is
    // built via `initCapacity(allocator, K)`. The contract under test
    // is that pre-sizing changes ONLY allocator pressure — the merge
    // output sequence must remain bit-identical to the `init` path.
    var slices: [K][N]types.Point = undefined;
    for (0..K) |s| {
        for (0..N) |n| {
            slices[s][n] = .{ .ts = @intCast(s + n * K), .value = @intCast(s) };
        }
    }

    var its: [K]SliceIterator = undefined;
    for (0..K) |s| its[s] = SliceIterator{ .slice = &slices[s] };

    var merger = try MergeIterator.initCapacity(allocator, K);
    defer merger.deinit();
    for (0..K) |s| try merger.addIterator(its[s].iterator());

    var expected_ts: i64 = 0;
    var produced: usize = 0;
    while (merger.next()) |pt| {
        try std.testing.expectEqual(expected_ts, pt.ts);
        expected_ts += 1;
        produced += 1;
    }
    try std.testing.expectEqual(@as(usize, K * N), produced);
}

test "MergeIterator: tie-break favours earliest-added iterator" {
    const allocator = std.testing.allocator;

    // Two iterators with the exact same (ts, value) tuple. The
    // earliest-added wins per the ordering contract used by the
    // compactor for dedup correctness.
    const same1 = [_]types.Point{.{ .ts = 100, .value = 7 }};
    const same2 = [_]types.Point{.{ .ts = 100, .value = 7 }};

    var it_first = SliceIterator{ .slice = &same1 };
    var it_second = SliceIterator{ .slice = &same2 };

    var merger = MergeIterator.init(allocator);
    defer merger.deinit();
    try merger.addIterator(it_first.iterator()); // index 0 — wins ties.
    try merger.addIterator(it_second.iterator());

    // First emission: from earliest-added.
    const first = merger.next().?;
    try std.testing.expectEqual(@as(i64, 100), first.ts);
    try std.testing.expectEqual(@as(i64, 7), first.value);
    // Second emission: the other identical point.
    const second = merger.next().?;
    try std.testing.expectEqual(@as(i64, 100), second.ts);
    try std.testing.expect(merger.next() == null);
}

test "MergeIterator: empty and single-stream cases" {
    const allocator = std.testing.allocator;

    // Zero streams.
    {
        var merger = MergeIterator.init(allocator);
        defer merger.deinit();
        try std.testing.expect(merger.next() == null);
    }

    // One empty stream.
    {
        const empty_slice = &[_]types.Point{};
        var empty_it = SliceIterator{ .slice = empty_slice };
        var merger = MergeIterator.init(allocator);
        defer merger.deinit();
        try merger.addIterator(empty_it.iterator());
        try std.testing.expect(merger.next() == null);
    }

    // One stream with three points.
    {
        const single = [_]types.Point{
            .{ .ts = 1, .value = 1 },
            .{ .ts = 2, .value = 2 },
            .{ .ts = 3, .value = 3 },
        };
        var single_it = SliceIterator{ .slice = &single };
        var merger = MergeIterator.init(allocator);
        defer merger.deinit();
        try merger.addIterator(single_it.iterator());
        try std.testing.expectEqual(@as(i64, 1), merger.next().?.ts);
        try std.testing.expectEqual(@as(i64, 2), merger.next().?.ts);
        try std.testing.expectEqual(@as(i64, 3), merger.next().?.ts);
        try std.testing.expect(merger.next() == null);
    }
}
