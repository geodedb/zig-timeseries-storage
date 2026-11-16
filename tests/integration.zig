// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Integration tests for timeseries-storage.
//!
//! These tests run via `zig build test-integration` and exercise the
//! library through its public module surface (the same way a downstream
//! consumer would import it). Coverage spans:
//!
//!   - Append/query round-trip
//!   - Flush + on-disk segment query
//!   - Empty-range query semantics
//!   - Multi-series multi-batch ingest at 100 batches × 100 points
//!   - Flush -> compactAll -> segment-count reduction -> query consistency
//!   - Restart scenario (open, append, sync, close, reopen, query)
//!   - Crash-recovery scenario (close WITHOUT sync, reopen, replay)
//!
//! Closes GAP-0007, Q-DEAD-005, Q-DEAD-006.

const std = @import("std");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

test {
    // SONNY-6615: WAL key-mode mismatch / torn-tail / mid-log corruption.
    _ = @import("wal_open_safety.zig");
    // SONNY-6622: a refused post-flush WAL compaction is non-fatal.
    _ = @import("wal_compaction_refusal.zig");
    // SONNY-6623: Engine closes its WAL directory handle.
    _ = @import("engine_descriptors.zig");
}

test "integration: version is defined" {
    try std.testing.expectEqualStrings("0.2.23", lib.version);
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

test "integration: 100 batches x 100 points across 4 series — query reflects every insert" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        // Force several flushes during the run so the query path
        // exercises both the active memtable and on-disk segments.
        .max_memtable_points = 500,
    }, &pool);
    defer eng.deinit();

    const num_series: u128 = 4;
    const num_batches: i64 = 100;
    const points_per_batch: usize = 100;

    var batch: [points_per_batch]lib.types.Point = undefined;

    var s: u128 = 0;
    while (s < num_series) : (s += 1) {
        var b: i64 = 0;
        while (b < num_batches) : (b += 1) {
            const base = b * @as(i64, @intCast(points_per_batch));
            for (0..points_per_batch) |i| {
                const ts = base + @as(i64, @intCast(i));
                batch[i] = .{ .ts = ts, .value = ts };
            }
            try eng.appendPoints(s, &batch);
        }
    }

    // Drain the active memtable to make sure all data is queryable
    // from a consistent snapshot.
    try eng.flush();

    s = 0;
    while (s < num_series) : (s += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), s, 0, std.math.maxInt(i64));
        var count: usize = 0;
        var last_ts: i64 = -1;
        while (it.next()) |pt| {
            // Verify monotonic ordering — the merge iterator's
            // contract is ascending (ts, value).
            try std.testing.expect(pt.ts >= last_ts);
            last_ts = pt.ts;
            count += 1;
        }
        const expected = @as(usize, @intCast(num_batches)) * points_per_batch;
        try std.testing.expectEqual(expected, count);
    }
}

test "integration: flush + compactAll reduces segment count and preserves data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        // Small threshold so a few hundred points produce multiple L0
        // segments without slamming the auto-trigger threshold.
        .max_memtable_points = 50,
    }, &pool);
    defer eng.deinit();

    var batch: [50]lib.types.Point = undefined;
    var b: i64 = 0;
    while (b < 6) : (b += 1) {
        const base = b * 50;
        for (0..50) |i| {
            batch[i] = .{
                .ts = base + @as(i64, @intCast(i)),
                .value = base + @as(i64, @intCast(i)),
            };
        }
        try eng.appendPoints(1, &batch);
        try eng.flush();
    }

    const segments_before = eng.man.segments.items.len;
    try std.testing.expect(segments_before >= 2);

    try eng.compactAll();

    var l0_after: usize = 0;
    var l1_after: usize = 0;
    for (eng.man.segments.items) |seg| {
        if (seg.level == 0) l0_after += 1;
        if (seg.level == 1) l1_after += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), l0_after);
    try std.testing.expect(l1_after >= 1);

    // Data must still be queryable end-to-end.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), 1, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 300), count);
}

test "integration: restart preserves data after sync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: open, append, flush + sync (the durable path), close.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 100,
        }, &pool);
        defer eng.deinit();

        const pts = [_]lib.types.Point{
            .{ .ts = 10, .value = 100 },
            .{ .ts = 20, .value = 200 },
            .{ .ts = 30, .value = 300 },
        };
        try eng.appendPoints(123, &pts);
        try eng.flush();
        try eng.sync();
    }

    // Phase 2: reopen the same data_dir and prove the data survives.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 100,
        }, &pool);
        defer eng.deinit();

        // The flush in phase 1 produced one segment.
        try std.testing.expect(eng.man.segments.items.len >= 1);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 123, 0, 1000);
        var values: [3]i64 = undefined;
        var count: usize = 0;
        while (it.next()) |pt| {
            try std.testing.expect(count < values.len);
            values[count] = pt.value;
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
        try std.testing.expectEqual(@as(i64, 100), values[0]);
        try std.testing.expectEqual(@as(i64, 200), values[1]);
        try std.testing.expectEqual(@as(i64, 300), values[2]);
    }
}

test "integration: crash recovery replays unflushed WAL records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: open, append, sync to make the WAL durable, then close
    // WITHOUT flushing the memtable to a segment. The next open must
    // replay the WAL into the memtable from scratch.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
        }, &pool);
        defer eng.deinit();

        const pts = [_]lib.types.Point{
            .{ .ts = 1, .value = 11 },
            .{ .ts = 2, .value = 22 },
            .{ .ts = 3, .value = 33 },
        };
        try eng.appendPoints(7, &pts);
        try eng.sync();

        // Deliberately skip eng.flush() — data lives only in the WAL
        // and in the in-memory memtable. The memtable is lost when
        // deinit fires; recovery must come from the WAL.
        try std.testing.expectEqual(@as(usize, 0), eng.man.segments.items.len);
    }

    // Phase 2: reopen and prove the records were replayed into the
    // active memtable from the WAL.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
        }, &pool);
        defer eng.deinit();

        // No flush happened in phase 1, so no segments on disk; the
        // points must come from the recovered memtable.
        try std.testing.expectEqual(@as(usize, 0), eng.man.segments.items.len);
        try std.testing.expectEqual(@as(usize, 3), eng.active_mem.load(.acquire).point_count.load(.acquire));

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 7, 0, 1000);
        var count: usize = 0;
        var first_ts: i64 = -1;
        while (it.next()) |pt| {
            if (first_ts < 0) first_ts = pt.ts;
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
        try std.testing.expectEqual(@as(i64, 1), first_ts);
    }
}

/// Block until any in-flight background compaction has finished.
/// Used by the L1->L2 test below so it can observe a quiescent
/// manifest after each cycle. Parks on the engine's existing
/// `done_cv` (broadcast by workers as they clear their in-flight
/// flags), which is the same primitive `Engine.deinit` uses to
/// drain background work — so we inherit its correctness rather
/// than spin-polling on the side.
fn waitForCompactionQuiescent(eng: *lib.Engine) void {
    const io = eng.io;
    eng.mu.lockUncancelable(io);
    defer eng.mu.unlock(io);
    while (eng.compaction_running or eng.flushing_mem != null or eng.flush_workers_active > 0) {
        eng.done_cv.waitUncancelable(io, &eng.mu);
    }
}

test "integration: P-COMP-002 L1->L2 tiered compaction triggers and cleans up L1 segments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        // Small threshold so each appended batch trips a flush.
        .max_memtable_points = 50,
    }, &pool);
    defer eng.deinit();

    // Build 8 L1 segments by running 8 disjoint "rounds". Each round:
    //   1. Append a batch covering a fresh, non-overlapping ts window.
    //   2. flush() to seal that batch into an L0 segment.
    //   3. compactAll() to fold the new L0 into a fresh L1 segment.
    //
    // Using disjoint ts windows is the key invariant: it guarantees
    // the round's compactAll does NOT fold in any pre-existing L1
    // segment via the overlap-aware selection path. After 8 rounds
    // the manifest holds exactly 8 L1 segments — enough to trip
    // kL1CompactionThreshold on the next flush.
    const points_per_round: usize = 50;
    const num_rounds: usize = 8;
    const series_id: lib.types.SeriesId = 7;

    var round: usize = 0;
    while (round < num_rounds) : (round += 1) {
        var batch: [points_per_round]lib.types.Point = undefined;
        const base: i64 = @intCast(round * 10_000);
        for (0..points_per_round) |i| {
            const ts: i64 = base + @as(i64, @intCast(i));
            batch[i] = .{ .ts = ts, .value = ts };
        }
        try eng.appendPoints(series_id, &batch);
        try eng.flush();
        // `flush()` returns once the segment is durable; the flush worker's
        // trailing WAL truncate and `triggerCompaction` may still be running.
        // Let it finish before `compactAll`, or on the last round it can see
        // the 8th L1 segment and start the L1->L2 pass before the sanity
        // check below (wal v0.1.23 made an emptying truncate slower).
        waitForCompactionQuiescent(&eng);
        try eng.compactAll();
        waitForCompactionQuiescent(&eng);
    }

    // Sanity: 8 L1 segments, 0 L0.
    var l0_before: usize = 0;
    var l1_before: usize = 0;
    var l2_before: usize = 0;
    for (eng.man.segments.items) |seg| {
        if (seg.level == 0) l0_before += 1;
        if (seg.level == 1) l1_before += 1;
        if (seg.level == 2) l2_before += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), l0_before);
    try std.testing.expectEqual(@as(usize, 8), l1_before);
    try std.testing.expectEqual(@as(usize, 0), l2_before);

    // Trigger one more flush. The flushed L0 segment count is 1 (well
    // below kL0CompactionThreshold=4), but the L1 count of 8 meets
    // kL1CompactionThreshold=8 — `triggerCompaction` should now
    // dispatch an L1->L2 worker.
    {
        var batch: [points_per_round]lib.types.Point = undefined;
        const base: i64 = @intCast(num_rounds * 10_000);
        for (0..points_per_round) |i| {
            const ts: i64 = base + @as(i64, @intCast(i));
            batch[i] = .{ .ts = ts, .value = ts };
        }
        try eng.appendPoints(series_id, &batch);
        try eng.flush();
    }
    waitForCompactionQuiescent(&eng);

    // After the L1->L2 pass the manifest should contain:
    //   * 0 L1 segments (all 8 folded into the new L2 — they were
    //     disjoint by construction so no L2 pre-existed to also fold
    //     in via overlap).
    //   * Exactly 1 L2 segment.
    //   * The post-flush L0 segment may have been picked up by the
    //     compactor as well, but at minimum it is NOT >= the L0
    //     threshold, so we assert "fewer than 4" rather than an exact
    //     count.
    var l0_after: usize = 0;
    var l1_after: usize = 0;
    var l2_after: usize = 0;
    for (eng.man.segments.items) |seg| {
        if (seg.level == 0) l0_after += 1;
        if (seg.level == 1) l1_after += 1;
        if (seg.level == 2) l2_after += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), l1_after);
    try std.testing.expectEqual(@as(usize, 1), l2_after);
    try std.testing.expect(l0_after < 4);

    // The new L2 segment file must be on disk. Iterate the segments
    // list to find the L2 entry and stat the file.
    var l2_id: ?u64 = null;
    for (eng.man.segments.items) |seg| {
        if (seg.level == 2) {
            l2_id = seg.id;
            break;
        }
    }
    try std.testing.expect(l2_id != null);
    const l2_path = try lib.segment.segmentPath(allocator, data_dir, l2_id.?);
    defer allocator.free(l2_path);
    {
        const f = try std.Io.Dir.cwd().openFile(io, l2_path, .{});
        defer f.close(io);
        const len = try f.length(io);
        try std.testing.expect(len > 0);
    }

    // The old L1 segment files must have been deleted by the
    // compactor's cleanup loop. We can't easily enumerate them
    // (we no longer have their ids), but the manifest's L1 count
    // dropped to 0 above, which is the source-of-truth check.

    // Data must still be queryable end-to-end across all rounds —
    // the compaction is supposed to be invisible to readers.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), series_id, 0, std.math.maxInt(i64));
    var count: usize = 0;
    var last_ts: i64 = -1;
    while (it.next()) |pt| {
        try std.testing.expect(pt.ts >= last_ts);
        last_ts = pt.ts;
        count += 1;
    }
    const expected: usize = (num_rounds + 1) * points_per_round;
    try std.testing.expectEqual(expected, count);
}

test "P-ALGO-001 migration: retrofit footers onto pre-existing segments via engine round-trip" {
    // End-to-end: drive a real engine to write three segments, strip
    // the footer from two of them to simulate pre-`4ec8c3a` on-disk
    // artefacts, then run the migration through the public library
    // surface and verify the engine reopens, queries succeed, and the
    // retrofitted footers are observed by `SegmentReader`.
    //
    // We use 3 segments (below the L0 compaction threshold of 4) so
    // the test does not race with a background compaction worker
    // consolidating our distinct segments into one.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    const series_id: u128 = 31415;
    const num_segments: usize = 3;
    const points_per_seg: usize = 8;

    var seg_paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (seg_paths.items) |p| allocator.free(p);
        seg_paths.deinit(allocator);
    }
    var data_end_offsets: std.ArrayListUnmanaged(u64) = .empty;
    defer data_end_offsets.deinit(allocator);

    // Phase 1: write three distinct segments via the engine. Below the
    // L0 compaction threshold, so each `flush()` call produces a fresh
    // segment without consolidation.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = points_per_seg,
        }, &pool);
        defer eng.deinit();

        var next_ts: i64 = 1;
        for (0..num_segments) |_| {
            var batch: [points_per_seg]lib.types.Point = undefined;
            for (0..points_per_seg) |i| {
                batch[i] = .{ .ts = next_ts, .value = next_ts };
                next_ts += 1;
            }
            try eng.appendPoints(series_id, &batch);
            try eng.flush();
        }

        try std.testing.expectEqual(num_segments, eng.man.segments.items.len);

        // Capture every segment path + data_end_offset.
        for (eng.man.segments.items) |seg| {
            const p = try lib.segment.segmentPath(allocator, data_dir, seg.id);
            try seg_paths.append(allocator, p);

            var r = try lib.segment.SegmentReader.init(allocator, p);
            defer r.deinit();
            try std.testing.expect(r.footer != null);
            try data_end_offsets.append(allocator, r.data_end_offset);
        }
    }

    // Phase 2: hand-truncate the first two segments back to their
    // data_end_offset. This synthesises pre-`4ec8c3a` segments on
    // disk WITHOUT changing any of the data-region bytes.
    const num_stripped: usize = 2;
    for (seg_paths.items[0..num_stripped], 0..) |p, idx| {
        const f = try std.Io.Dir.cwd().openFile(io, p, .{ .mode = .read_write });
        defer f.close(io);
        try f.setLength(io, data_end_offsets.items[idx]);
        try f.sync(io);
    }

    // Sanity: the truncated segments now lack a footer; the remaining
    // one still carries one.
    for (seg_paths.items[0..num_stripped]) |p| {
        var r = try lib.segment.SegmentReader.init(allocator, p);
        defer r.deinit();
        try std.testing.expect(r.footer == null);
    }
    for (seg_paths.items[num_stripped..]) |p| {
        var r = try lib.segment.SegmentReader.init(allocator, p);
        defer r.deinit();
        try std.testing.expect(r.footer != null);
    }

    // Phase 3: run the migration through the public library surface.
    const results = try lib.migration.migrateSegmentFooters(allocator, io, data_dir);
    defer lib.migration.freeResults(allocator, results);
    try std.testing.expectEqual(num_segments, results.len);

    var upgraded: usize = 0;
    var already_indexed: usize = 0;
    for (results) |r| {
        if (r.upgraded) upgraded += 1;
        if (r.already_indexed) already_indexed += 1;
    }
    try std.testing.expectEqual(num_stripped, upgraded);
    try std.testing.expectEqual(num_segments - num_stripped, already_indexed);

    // Every segment must now carry a footer.
    for (seg_paths.items) |p| {
        var r = try lib.segment.SegmentReader.init(allocator, p);
        defer r.deinit();
        try std.testing.expect(r.footer != null);
        try std.testing.expect(r.findSeries(series_id) != null);
    }

    // Phase 4: reopen the engine; queries must still return every
    // point we wrote. This is the load-bearing assertion — if the
    // migration corrupted any block region the decode would fail.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = points_per_seg,
        }, &pool);
        defer eng.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), series_id, 0, std.math.maxInt(i64));
        var count: usize = 0;
        var last_ts: i64 = 0;
        while (it.next()) |pt| {
            count += 1;
            try std.testing.expect(pt.ts >= last_ts);
            last_ts = pt.ts;
        }
        try std.testing.expectEqual(num_segments * points_per_seg, count);
    }

    // Phase 5: a second migration must be a no-op.
    const results2 = try lib.migration.migrateSegmentFooters(allocator, io, data_dir);
    defer lib.migration.freeResults(allocator, results2);
    try std.testing.expectEqual(num_segments, results2.len);
    for (results2) |r| {
        try std.testing.expect(r.already_indexed);
        try std.testing.expect(!r.upgraded);
    }
}

test "integration: flush records exact per-segment point_count in the manifest" {
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
        .max_memtable_points = 1_000_000,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{
        .{ .ts = 1, .value = 11 },
        .{ .ts = 2, .value = 22 },
        .{ .ts = 3, .value = 33 },
    };
    try eng.appendPoints(7, &pts);
    try eng.appendPoints(9, &.{.{ .ts = 5, .value = 55 }});
    try eng.flush();

    try std.testing.expectEqual(@as(usize, 1), eng.man.segments.items.len);
    try std.testing.expectEqual(@as(u64, 4), eng.man.segments.items[0].point_count);
}

test "integration: batched appends survive a clean close with no explicit sync (final WAL fsync on deinit)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: batch mode (the default), append, close with NO
    // explicit sync() and no flush. deinit's final WAL fsync is the
    // only durability barrier for these records.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .durability_mode = .batch,
        }, &pool);
        defer eng.deinit();
        try eng.appendPoints(9, &.{
            .{ .ts = 10, .value = 1 },
            .{ .ts = 20, .value = 2 },
        });
    }

    // Phase 2: reopen and prove the records replay from the WAL.
    // (Pinning: a same-session reopen cannot distinguish page-cache
    // from fsync durability — this guards the replay contract and
    // the sync-before-teardown ordering, not the power-fail case.)
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .durability_mode = .batch,
        }, &pool);
        defer eng.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 9, 0, 1000);
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 2), count);
    }
}
