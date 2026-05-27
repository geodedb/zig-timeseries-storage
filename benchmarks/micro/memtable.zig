// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Micro-benchmarks for the in-memory write buffer (`Memtable`).
//!
//! Two scenarios isolate the two branches of `Memtable.insert`
//! (`src/memtable.zig:81-117`):
//!
//!   * `memtable_insert_sorted` — a 256-point batch whose timestamps
//!     are strictly ascending AND land after the (empty) existing tail.
//!     This drives `can_append_in_order = true` so the entry stays
//!     `sorted = true` and the insert path is a single
//!     `appendSlice` over the per-series `ArrayListUnmanaged`. This
//!     is the steady-state ingest path documented at
//!     `src/memtable.zig:24-26`.
//!
//!   * `memtable_insert_ooo` — the same 256-point batch with the last
//!     two elements swapped, which forces the batch-sorted check at
//!     `src/memtable.zig:92-98` to find a `lessThan` violation at
//!     `i = points.len - 1`. The path then flags `sorted = false`
//!     without sorting (the lazy-sort contract from P-ALGO-003). This
//!     scenario measures the cost of the OoO detection branch itself,
//!     NOT a follow-up sort — the sort is deferred until a reader
//!     calls `getSortedPoints` or `ensureAllSorted`.
//!
//! Both scenarios build a fresh `Memtable` per iteration. That keeps
//! the `AutoHashMap.init` + first-insert `getOrPut` allocation inside
//! the measured region so a regression in the hashmap-warmup path
//! (e.g. a future change to the initial bucket count) shows up. The
//! tracking allocator's per-iteration alloc count therefore includes
//! the hashmap-bucket and the per-series `ArrayListUnmanaged` growth
//! — by design, not a leak.
//!
//! `Memtable.init` is called with `max_points = 1_000_000` so a single
//! 256-point insert per iteration never approaches `shouldFlush()`;
//! the engine's flush policy is intentionally out-of-scope for this
//! micro.
//!
//! `ops_per_iteration = 256`, `warmup_iterations = 2`,
//! `sample_iterations = 10` — matches the rest of the micro-bench
//! suite (codec, segment_rw, merge, wal_io, manifest_io).
//!
//! Wired via `zig build bench-micro-memtable` (added by a later task
//! in the bench plan).

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
            .name = "memtable_insert_sorted",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runMemtableSorted,
        },
        .{
            .name = "memtable_insert_ooo",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runMemtableOoo,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-memtable"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

/// Build a deterministic `N`-point batch. When `ooo` is true the last
/// two elements are swapped so the resulting slice is no longer
/// monotonically non-decreasing in `(ts, value)`.
///
/// The seed pattern `ts = i * 1000`, `value = i * 7 + 13` matches the
/// rest of the micro-bench suite (codec, segment_rw, merge) so the
/// memtable bench can be reasoned about in the same units as those.
fn buildBatch(comptime N: usize, comptime ooo: bool) [N]lib.types.Point {
    var batch: [N]lib.types.Point = undefined;
    for (&batch, 0..) |*p, i| {
        const ts: i64 = @as(i64, @intCast(i)) * 1000;
        const value: i64 = @as(i64, @intCast(i)) * 7 + 13;
        p.* = .{ .ts = ts, .value = value };
    }
    if (ooo) {
        // Swap the last two so the batch is no longer monotonic. This
        // forces Memtable.insert into the unsorted-flag-flip branch
        // (memtable.zig:92-110).
        const last = batch[N - 1];
        batch[N - 1] = batch[N - 2];
        batch[N - 2] = last;
    }
    return batch;
}

/// Steady-state ingest path: insert a strictly ascending 256-point
/// batch into a fresh memtable. The entry stays `sorted = true` and
/// the insert is one `appendSlice` plus the cheap batch-monotonicity
/// scan at `src/memtable.zig:92-98`.
fn runMemtableSorted(ctx: *framework.Context) anyerror!void {
    var mt = lib.memtable.Memtable.init(ctx.allocator, 1_000_000);
    defer mt.deinit();
    const batch = buildBatch(256, false);
    try mt.insert(7, &batch);
    std.mem.doNotOptimizeAway(mt.point_count);
}

/// Out-of-order detection path: the same 256-point batch with the
/// final two elements swapped. The batch-sorted scan trips on the
/// last index and the entry is flagged `sorted = false` — the sort
/// itself is deferred per P-ALGO-003.
fn runMemtableOoo(ctx: *framework.Context) anyerror!void {
    var mt = lib.memtable.Memtable.init(ctx.allocator, 1_000_000);
    defer mt.deinit();
    const batch = buildBatch(256, true);
    try mt.insert(7, &batch);
    std.mem.doNotOptimizeAway(mt.point_count);
}
