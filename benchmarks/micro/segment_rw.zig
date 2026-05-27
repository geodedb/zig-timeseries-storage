// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Micro-benchmark for the segment file write/read hot paths.
//!
//! Two scenarios isolate the durable-storage seam that
//! `Engine.flushInternal` and the query path traverse on every flush
//! and every cold-cache read respectively:
//!
//!   * `segment_write_block_256` — open a fresh `SegmentWriter` over a
//!     tmp file, encode + write one 256-point block via the public
//!     `writeBlock(series_id, points)` API, `sync()` to force the
//!     bytes to disk, then `deinit()` to close. This mirrors the
//!     single-block fast path the engine takes for small memtable
//!     flushes; it captures both the Gorilla encoder cost (already
//!     measured in isolation by `gorilla_encode_256`) AND the I/O
//!     header serialization + fsync cost, so a regression in either
//!     half surfaces here even if the codec-only bench stays flat.
//!
//!   * `segment_read_block_256` — pre-write one 256-point block in
//!     setup, then measure the open + iterate + `decodePoints` round
//!     trip via `SegmentReader.init` and `Block.decodePoints`. The
//!     warmup iterations absorb the cold-cache setup wobble so the
//!     measured median reflects the steady-state read path.
//!
//! Both scenarios use the plaintext (v2 / `TSSEG002`) segment format
//! by passing `null` encryption — the same call shape
//! `Engine.flushInternal` uses when the engine is configured without
//! a key. The encrypted (v3 / `TSSEG003`) path adds AES-GCM cost on
//! top of the codec; it is intentionally out of scope here so the
//! baseline is a clean codec + I/O measurement.
//!
//! Deterministic fixture (matches the bench plan):
//!   `Point{ .ts = i * 1000, .value = i * 7 + 13 }` for `i` in `0..256`.
//!
//! Wired via `zig build bench-micro-segment-rw` (added by a later
//! task in the bench plan).

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
            .name = "segment_write_block_256",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runWriteBlock256,
        },
        .{
            .name = "segment_read_block_256",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runReadBlock256,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-segment-rw"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

/// Per-iteration tmp directory. Each iteration gets its own directory
/// so a previous iteration's `seg.dat` cannot influence the current
/// one. Lifted from `benchmarks/bench.zig:112-121`.
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

/// Deterministic 256-point fixture matching the bench plan. Caller
/// provides the backing array so the fixture stays stack-resident.
fn fillFixture(pts: *[256]lib.types.Point) void {
    for (pts, 0..) |*p, i| {
        p.* = .{
            .ts = @as(i64, @intCast(i)) * 1000,
            .value = @as(i64, @intCast(i)) * 7 + 13,
        };
    }
}

/// Open `SegmentWriter`, write ONE 256-point block, `sync()`, close.
///
/// Mirrors the single-block path inside `Engine.flushInternal` at
/// `src/engine.zig:1615` (which calls `initWithEncryption` — we use
/// the `init` convenience wrapper that passes `null` encryption,
/// producing the plaintext v2 / `TSSEG002` format).
fn runWriteBlock256(ctx: *framework.Context) anyerror!void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    var pts: [256]lib.types.Point = undefined;
    fillFixture(&pts);

    const seg_path = try std.fmt.allocPrint(ctx.allocator, "{s}/seg.dat", .{tmp});
    defer ctx.allocator.free(seg_path);

    var writer = try lib.segment.SegmentWriter.init(ctx.allocator, seg_path);
    defer writer.deinit();
    try writer.writeBlock(1, &pts);
    try writer.sync();

    std.mem.doNotOptimizeAway(writer.block_index);
}

/// Open `SegmentReader`, iterate to the single block, `decodePoints`,
/// free the decoded slice.
///
/// Setup pre-writes the segment INSIDE the `run` callback. The
/// framework wraps the entire callback in `TrackingAllocator`, so
/// alloc counts here reflect setup + measured work combined; warmup
/// iterations absorb the cold-cache wobble and the median across
/// `sample_iterations` is the steady-state cost.
fn runReadBlock256(ctx: *framework.Context) anyerror!void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp = try benchTmpDir(ctx.allocator, ctx);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    var pts: [256]lib.types.Point = undefined;
    fillFixture(&pts);

    const seg_path = try std.fmt.allocPrint(ctx.allocator, "{s}/seg.dat", .{tmp});
    defer ctx.allocator.free(seg_path);

    // Setup: write the segment we will read back.
    {
        var writer = try lib.segment.SegmentWriter.init(ctx.allocator, seg_path);
        defer writer.deinit();
        try writer.writeBlock(1, &pts);
        try writer.sync();
    }

    // Measured op: open the reader, iterate to the single block,
    // decode it, free the decoded slice.
    var reader = try lib.segment.SegmentReader.init(ctx.allocator, seg_path);
    defer reader.deinit();

    var it = reader.iterator();
    const block = (try it.next()) orelse return error.MissingBlock;
    const decoded = try block.decodePoints(ctx.allocator);
    defer ctx.allocator.free(decoded);

    std.mem.doNotOptimizeAway(decoded.len);
}
