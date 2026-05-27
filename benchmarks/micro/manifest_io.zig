// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Micro-benchmark for the manifest persist/load hot path.
//!
//! One scenario isolates the durable-metadata seam that
//! `Engine.flushInternal` traverses on every flush (one `Manifest.save`
//! per sealed segment) and that `Engine.init` traverses on every open
//! (one `Manifest.initWithEncryption` per restart):
//!
//!   * `manifest_write_read` — build a 16-segment in-memory manifest,
//!     call `save()` to persist it via the ping-pong dual-file layout
//!     (`manifest.a` / `manifest.b`, atomic rename, CRC32C trailer),
//!     then call `init()` over the same data dir to load it back. The
//!     load picks the higher-counter slot, CRC-verifies both, and
//!     deserializes the winner — the exact round-trip the engine
//!     performs on a normal save-then-reopen cycle.
//!
//! `ops_per_iteration = 2` because the scenario performs one write
//! and one read per iteration. Throughput therefore reports
//! manifest-round-trips-per-second times two.
//!
//! 16 segments is the "moderate compaction state" the L0-only path
//! lands on after a steady flush cycle without an L1 compaction having
//! yet taken effect — large enough to exercise the per-segment
//! serialisation loop (`writeU64 * 3 + byte` per segment), small
//! enough to keep the measured wall-clock dominated by the framing
//! and fsync rather than the segment loop itself.
//!
//! Segment fields are deterministic and span a contiguous timestamp
//! range so the on-disk byte layout is stable run-to-run; the bench
//! is order-insensitive but a stable layout helps when diffing two
//! `compare-bench` outputs.
//!
//! Wired via `zig build bench-micro-manifest` (added by a later task
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
            .name = "manifest_write_read",
            .ops_per_iteration = 2,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runManifestWriteRead,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-manifest"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

/// Per-iteration tmp directory. Each iteration gets its own directory
/// so a previous iteration's `manifest.a` / `manifest.b` slots cannot
/// influence the current one. Lifted from `benchmarks/bench.zig:112-121`.
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

/// Build a 16-segment manifest, persist it, then reload it from disk.
///
/// `Manifest.init` opens an empty manifest when no slots exist on disk,
/// stashing the supplied `data_dir`. We register 16 `SegmentMeta`
/// entries via `addSegment` (the same call site `Engine.flushInternal`
/// uses), call `save()` to write the ping-pong slot, then call
/// `Manifest.init` a second time over the same `data_dir` — this
/// triggers the load path (`readFromFileWithKey` → `deserialize`) the
/// engine takes on reopen.
///
/// Both manifest instances must be `deinit`'d to release the
/// `ArrayListUnmanaged(SegmentMeta)` backing storage they own.
fn runManifestWriteRead(ctx: *framework.Context) anyerror!void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    // First open: empty in-memory manifest (no slots on disk yet).
    var man = try lib.manifest.Manifest.init(ctx.allocator, tmp);
    defer man.deinit();

    // Populate with 16 deterministic segments. Field shape comes from
    // `pub const SegmentMeta` in `src/manifest.zig:88`: `id`, `min_ts`,
    // `max_ts`, `level`. Timestamps span a contiguous range so the
    // serialised byte layout is stable run-to-run.
    var i: u64 = 0;
    while (i < 16) : (i += 1) {
        const id = man.getNextSegmentId();
        try man.addSegment(.{
            .id = id,
            .min_ts = @as(i64, @intCast(i)) * 1000,
            .max_ts = @as(i64, @intCast(i)) * 1000 + 999,
            .level = 0,
        });
    }

    // Measured op 1: persist.
    //
    // `save()` increments `counter`, picks the slot by parity, writes
    // the body through `manifest.<a|b>.tmp` + fsync + rename(2), and
    // emits a CRC32C trailer over the whole body.
    try man.save();

    // Measured op 2: load fresh.
    //
    // `init` over a dir with at least one valid slot CRC-verifies both
    // `manifest.a` and `manifest.b`, picks the higher-counter winner,
    // and deserialises it. This is the engine's reopen path.
    var loaded = try lib.manifest.Manifest.init(ctx.allocator, tmp);
    defer loaded.deinit();

    // Force the optimiser to keep the load result alive — without
    // these doNotOptimizeAway barriers the entire round-trip is
    // dead-code-eliminated under -OReleaseFast.
    std.mem.doNotOptimizeAway(loaded.segments.items.len);
    std.mem.doNotOptimizeAway(loaded.counter);
}
