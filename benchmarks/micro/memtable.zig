// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Micro-benchmarks for the in-memory write buffer (`Memtable`).
//!
//! Two scenarios isolate the two branches of `Memtable.insert`
//! (`src/memtable.zig:81-117`):
//!
//!   * `memtable_insert_sorted` — a 256-point batch whose timestamps
//!     are strictly ascending AND land after the existing tail. This
//!     drives `can_append_in_order = true` so the entry stays
//!     `sorted = true` and the insert path is a single `appendSlice`
//!     over the per-series `ArrayListUnmanaged`. This is the
//!     steady-state ingest path documented at `src/memtable.zig:24-26`.
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
//! ## Fixture model (ENT-002 / ENT-005)
//!
//! Both scenarios share a `Fixture` constructed once in `main`. The
//! fixture owns a pre-sized `Memtable` (via `Memtable.initCapacity`,
//! the API introduced by ENT-002 / ENT-005) and a deterministic
//! 256-point batch buffer.
//!
//! Each measured iteration only calls `mt.clear()` followed by
//! `mt.insert(...)`. `clear()` retains the AutoHashMap capacity and
//! the per-series `ArrayListUnmanaged` capacity, so the steady-state
//! insert allocates ZERO bytes — exactly what `Engine.appendPoints`
//! sees on its hot path once the active memtable has touched a
//! given series at least once.
//!
//! This is a deliberate change from the original bench shape (commit
//! 890d9f8), which built a fresh `Memtable` per iteration via
//! `Memtable.init`. Under that shape the tracking allocator measured
//! 2 allocs/iter — one for the hashmap's first `getOrPut`, one for
//! the array list's first `appendSlice`. Those are exactly the
//! allocations ENT-002 / ENT-005 hoist out of the steady-state path
//! and into one-time construction; the only way to see the
//! optimization in the bench numbers is to put construction in the
//! place the engine puts it (init / rotation), not in the measured
//! window.
//!
//! `ops_per_iteration = 256`, `warmup_iterations = 2`,
//! `sample_iterations = 10` — matches the rest of the micro-bench
//! suite (codec, segment_rw, merge, wal_io, manifest_io).
//!
//! Wired via `zig build bench-micro-memtable`.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const framework = @import("framework");

/// Shared scenario fixture (ENT-002 / ENT-005). Constructed once in
/// `main` and threaded into each scenario via `Scenario.user_data`.
/// Owns the pre-sized memtable and the two pre-built point batches
/// so the measured `run` body is just `clear()` + `insert()`.
const Fixture = struct {
    mt: lib.memtable.Memtable,
    sorted_batch: [256]lib.types.Point,
    ooo_batch: [256]lib.types.Point,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // ENT-002 / ENT-005: build the fixture once, outside the measured
    // region. The hashmap and per-series array-list pre-allocations
    // happen here; the measured `run` body sees only `clear()` +
    // `insert()` and (with the optimization in place) records zero
    // allocations per iteration.
    var fixture = Fixture{
        .mt = try lib.memtable.Memtable.initCapacity(allocator, 1_000_000, 16, 1024),
        .sorted_batch = buildBatch(256, false),
        .ooo_batch = buildBatch(256, true),
    };
    defer fixture.mt.deinit();

    // Prime the memtable so the per-series ArrayList has been touched
    // and pre-grown to the hint. After this, `clear()` retains the
    // capacity and subsequent inserts on the same SeriesId are
    // alloc-free.
    try fixture.mt.insert(7, &fixture.sorted_batch);
    fixture.mt.clear();

    const scenarios = [_]framework.Scenario{
        .{
            .name = "memtable_insert_sorted",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .user_data = &fixture,
            .run = runMemtableSorted,
        },
        .{
            .name = "memtable_insert_ooo",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .user_data = &fixture,
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
/// batch into the pre-sized memtable. `clear()` retains the existing
/// capacity, so the `appendSlice` inside `insert` is a pure memcpy —
/// zero allocations on the measured path.
fn runMemtableSorted(ctx: *framework.Context) anyerror!void {
    const fixture: *Fixture = @ptrCast(@alignCast(ctx.user_data.?));
    fixture.mt.clear();
    try fixture.mt.insert(7, &fixture.sorted_batch);
    std.mem.doNotOptimizeAway(fixture.mt.point_count);
}

/// Out-of-order detection path: the same 256-point batch with the
/// final two elements swapped. The batch-sorted scan trips on the
/// last index and the entry is flagged `sorted = false` — the sort
/// itself is deferred per P-ALGO-003. Like the sorted scenario the
/// measured path is alloc-free.
fn runMemtableOoo(ctx: *framework.Context) anyerror!void {
    const fixture: *Fixture = @ptrCast(@alignCast(ctx.user_data.?));
    fixture.mt.clear();
    try fixture.mt.insert(7, &fixture.ooo_batch);
    std.mem.doNotOptimizeAway(fixture.mt.point_count);
}
