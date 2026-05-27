// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Micro-benchmark for the WAL append hot path.
//!
//! One scenario isolates the durable-log seam that `Engine.appendPoints`
//! traverses on every write:
//!
//!   * `wal_append_record` — open a fresh `WalManager` over a per-iteration
//!     tmp directory, append one fixed-size `WalRecord` carrying a 256-byte
//!     payload (the same size class an engine-level batch of ~15 points
//!     produces), then close. The scenario deliberately does NOT call
//!     `sync()` — the engine batches multiple appends and amortises the
//!     fsync at commit time (see the durability-semantics block in
//!     `src/wal_manager.zig`). Measuring only the in-memory append path
//!     keeps this micro tightly focused on the framing + CRC32C cost; an
//!     `wal_sync` scenario is intentionally future work.
//!
//! The record is constructed with `record_type = .append_points` and a
//! deterministic 256-byte payload, matching the layout
//! `Engine.encodeAppendPointsPayloadLocked` emits — `series_id (u128 LE)`
//! followed by `(i64 ts, i64 value)` pairs — so the measured `serializeInto`
//! and CRC32C cost reflects the production write path. `appendRecord`
//! mutates `record.lsn`; we just take whatever the manager assigns.
//!
//! `ops_per_iteration = 1` — one append per iteration. The scenario uses
//! 2 warmup iterations and 10 sample iterations to match the rest of the
//! micro-bench suite.
//!
//! Wired via `zig build bench-micro-wal` (added by a later task in the
//! bench plan).

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
            .name = "wal_append_record",
            .ops_per_iteration = 1,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runWalAppend,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-wal"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

/// Per-iteration tmp directory. Each iteration gets its own directory so
/// a previous iteration's `ts.wal` cannot influence the current one.
/// Lifted from `benchmarks/bench.zig:112-121`.
fn benchTmpDir(allocator: std.mem.Allocator, ctx: *framework.Context) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fmt.allocPrint(allocator, "/tmp/ts-bench-{s}-{d}", .{
        ctx.scenario.name,
        ctx.iteration_index,
    });
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

/// Open `WalManager`, append ONE 256-byte `append_points` record, close.
///
/// Mirrors the WAL portion of `Engine.appendPoints` at `src/engine.zig`:
/// the engine opens the WAL with `WalManager.init` over its data dir,
/// then `appendToWalLocked` builds a `WalRecord{ .record_type =
/// .append_points, .payload = <encoded bytes> }` and hands it to
/// `appendRecord`. We construct the same record shape with a fixed
/// 256-byte payload so the measured cost reflects framing + CRC32C
/// over a realistic payload size.
///
/// `sync()` is intentionally skipped — the production engine batches
/// many appends behind a single fsync at commit time, so the steady-
/// state per-record cost is the in-memory append path measured here.
fn runWalAppend(ctx: *framework.Context) anyerror!void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    // Open the tmp dir as a `std.Io.Dir` handle — `WalManager.init`
    // takes a directory handle, not a path, mirroring the engine's
    // own call site at `src/engine.zig:805`.
    var wal_dir = try std.Io.Dir.cwd().openDir(io, tmp, .{});
    defer wal_dir.close(io);

    // Deterministic identity UUID — any 16-byte value works; the
    // manager just persists it to `ts.uuid` and compares on reopen.
    const ts_uuid = [_]u8{0xCB} ** 16;

    var wm = try lib.wal_manager.WalManager.init(
        ctx.allocator,
        wal_dir,
        ts_uuid,
        0, // start_lsn — fresh WAL, start from 0
        .{},
    );
    defer wm.deinit();

    // Fixed 256-byte payload matching the size class of a small engine
    // append batch. Layout-wise this is just opaque bytes to the WAL;
    // CRC32C is computed over the whole record by `serializeInto`.
    var payload: [256]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @as(u8, @truncate(i));

    var rec = lib.wal_record.WalRecord{
        .lsn = 0, // overwritten by `appendRecord` with the assigned LSN
        .record_type = .append_points,
        .payload = &payload,
        .checksum = 0,
    };

    const assigned_lsn = try wm.appendRecord(&rec);

    // Force the optimiser to keep the append result alive — without
    // this the whole call is dead-code-eliminated under -OReleaseFast.
    std.mem.doNotOptimizeAway(assigned_lsn);
    std.mem.doNotOptimizeAway(wm.current_lsn);
}
