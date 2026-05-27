// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Micro-benchmark for `iterator.MergeIterator` — the K-way merge hot
//! path that compaction and multi-segment queries both drive.
//!
//! Three scenarios sweep fan-in `K` across the values that matter in
//! production: K=4 is the L0 compaction default, K=16 is broader
//! compaction fan-in, and K=64 is the upper end of multi-segment query
//! fan-in. All three exercise `MergeIterator.next` exclusively — heap
//! `push` + `pop` per emitted point — so a regression in the priority
//! queue or the comparator surfaces here even if the surrounding
//! compaction / query benches stay flat.
//!
//! Each stream contains 1000 strictly-ascending deterministic `Point`
//! values, and the K streams are interleaved 1:1:...:1 across the
//! timestamp axis (stream 0 owns ts 0, K, 2K, ...; stream 1 owns ts
//! 1, K+1, 2K+1, ...). The merge therefore produces a single fully
//! sorted, gap-free output of `K * 1000` points and the heap stays
//! at its maximum occupancy (K entries) for the whole drain — the
//! worst case for `next()` cost per emitted point.
//!
//! `ops_per_iteration = K * 1000` so throughput is reported as
//! merged-points-per-second, directly comparable across the three K
//! values.
//!
//! Closes phase D of PERF_GAP_ANALYSIS / GAP-0011 for the merge
//! iterator hot path. Wired via `zig build bench-micro-merge` (added
//! by a later task in the bench plan).
//!
//! ENT-001: this bench constructs the merger via
//! `MergeIterator.initCapacity(ctx.allocator, K)` rather than the
//! generic `init(allocator)` constructor. K is a `comptime` parameter
//! here, so the bench faithfully represents the "known-K" production
//! call site (compaction over a fixed segment set). Using
//! `initCapacity` pre-sizes both the iters list and the heap, which
//! collapses the doubling-growth alloc trail that `addIterator` would
//! otherwise leave in the `TrackingAllocator`. The drop in
//! `alloc_count` (especially at K=64) is the load-bearing signal that
//! the optimisation actually fired.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const framework = @import("framework");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{
            .name = "merge_iter_k4",
            .ops_per_iteration = 4000,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runMergeK4,
        },
        .{
            .name = "merge_iter_k16",
            .ops_per_iteration = 16000,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runMergeK16,
        },
        .{
            .name = "merge_iter_k64",
            .ops_per_iteration = 64000,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runMergeK64,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-merge"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

/// Build K interleaved sorted streams of 1000 points each, wire them
/// into a `MergeIterator`, and drain the merged sequence in full.
///
/// The point slices and the `SliceIterator` storage are both held in
/// stack-resident `[K]...` arrays — the `PointIterator` returned by
/// `SliceIterator.iterator()` carries a `*SliceIterator`, so the
/// backing iterators MUST outlive the merger. `comptime K` keeps the
/// array sizes resolved at compile time without any extra heap
/// indirection. The point payload itself is heap-allocated through
/// `ctx.allocator` so the framework's `TrackingAllocator` sees the
/// fixture cost; the measured hot path is dominated by the heap-pop /
/// heap-push pair inside `MergeIterator.next` once the fixture is
/// built.
fn runMerge(ctx: *framework.Context, comptime K: u32) anyerror!void {
    const POINTS_PER_STREAM: u32 = 1000;

    // Allocate K disjoint, interleaved sorted slices. Free order does
    // not matter — `MergeIterator` does not own the underlying point
    // data; it holds `PointIterator` interface values that borrow
    // from the slices below.
    var streams: [K][]lib.types.Point = undefined;
    var allocated: u32 = 0;
    errdefer for (streams[0..allocated]) |slice| ctx.allocator.free(slice);

    while (allocated < K) : (allocated += 1) {
        const k = allocated;
        const slice = try ctx.allocator.alloc(lib.types.Point, POINTS_PER_STREAM);
        for (slice, 0..) |*p, i| {
            const ts = @as(i64, @intCast(k)) + @as(i64, @intCast(i)) * @as(i64, @intCast(K));
            const value = @as(i64, @intCast(i)) * 7 + @as(i64, @intCast(k)) * 13 + 13;
            p.* = .{ .ts = ts, .value = value };
        }
        streams[k] = slice;
    }
    defer for (streams) |slice| ctx.allocator.free(slice);

    // Stack-resident `SliceIterator` storage — the `PointIterator`
    // captures `&its[k]`, so the array must stay live across the
    // entire merger lifetime. `comptime K` makes this a fixed-size
    // stack array even at K=64.
    var its: [K]lib.iterator.SliceIterator = undefined;
    for (0..K) |k| its[k] = .{ .slice = streams[k] };

    // ENT-001: K is known at comptime, so use the capacity-hinted
    // constructor to skip the doubling-growth allocation trail that
    // `addIterator` would otherwise produce under the default `init`.
    var merger = try lib.iterator.MergeIterator.initCapacity(ctx.allocator, K);
    defer merger.deinit();

    // Add iterators in ascending k order; the tie-break contract is
    // irrelevant here because every (ts, value) tuple is unique by
    // construction, but adding in a stable order keeps the bench
    // deterministic across runs.
    for (0..K) |k| try merger.addIterator(its[k].iterator());

    var sink: i64 = 0;
    var count: usize = 0;
    while (merger.next()) |pt| {
        sink ^= pt.ts ^ pt.value;
        count += 1;
    }
    // `doNotOptimizeAway` on both sink and count keeps the drain loop
    // alive under `-OReleaseFast`. We deliberately avoid a runtime
    // `assert(count == K * POINTS_PER_STREAM)` because asserts are
    // stripped in release builds — the doNotOptimizeAway on `count`
    // is the load-bearing barrier against dead-code elimination.
    std.mem.doNotOptimizeAway(sink);
    std.mem.doNotOptimizeAway(count);
}

fn runMergeK4(ctx: *framework.Context) anyerror!void {
    return runMerge(ctx, 4);
}

fn runMergeK16(ctx: *framework.Context) anyerror!void {
    return runMerge(ctx, 16);
}

fn runMergeK64(ctx: *framework.Context) anyerror!void {
    return runMerge(ctx, 64);
}
