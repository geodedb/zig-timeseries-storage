// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Micro-benchmark for the Gorilla codec (encode + decode hot paths).
//!
//! Four scenarios cover both directions at two block sizes:
//!
//!   * `gorilla_encode_256`  / `gorilla_encode_4096`  — measure
//!     `GorillaEncoder.encodePoint` over a deterministic fixture
//!     stream. Allocates inside the measured region (encoder bitset +
//!     `getCompressedData` happens outside, but the encoder's own
//!     bitset growth during `encodePoint` is fair game when the
//!     `initForPoints` estimate is wrong).
//!   * `gorilla_decode_256`  / `gorilla_decode_4096`  — measure
//!     `GorillaDecoder.decodePoint`. The decoder holds NO allocator,
//!     so the decode loop itself is allocation-free by construction.
//!     The encoded fixture is built and the encoder freed BEFORE the
//!     measured decode loop, but `TrackingAllocator` wraps the entire
//!     `run` callback — encoder fixture allocations therefore still
//!     register on `alloc_count`. The decoder hot path remains
//!     zero-alloc; the assertion is structural rather than a strict
//!     `alloc_count == 0` metric.
//!
//! Input fixture is deterministic and matches the bench plan:
//!   `Point{ .ts = i * 1000, .value = i * 7 + 13 }`.
//!
//! Wired via `zig build bench-micro-codec` (added in a later task in
//! the plan).

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
            .name = "gorilla_encode_256",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runEncode256,
        },
        .{
            .name = "gorilla_encode_4096",
            .ops_per_iteration = 4096,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runEncode4096,
        },
        .{
            .name = "gorilla_decode_256",
            .ops_per_iteration = 256,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runDecode256,
        },
        .{
            .name = "gorilla_decode_4096",
            .ops_per_iteration = 4096,
            .warmup_iterations = 2,
            .sample_iterations = 10,
            .run = runDecode4096,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-codec"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

/// Encode `N` deterministic points through `GorillaEncoder`. The
/// encoder pre-sizes its bitset for `N` points so the common case
/// avoids reallocs on the hot path.
fn runEncode(ctx: *framework.Context, comptime N: usize) anyerror!void {
    var enc = try lib.gorilla.GorillaEncoder.initForPoints(ctx.allocator, N);
    defer enc.deinit();
    for (0..N) |i| {
        const ts: i64 = @as(i64, @intCast(i)) * 1000;
        const val: i64 = @as(i64, @intCast(i)) * 7 + 13;
        try enc.encodePoint(.{ .ts = ts, .value = val });
    }
    // Force the optimiser to keep the encoded state alive — without
    // this the whole loop is dead-code-eliminated under -OReleaseFast.
    std.mem.doNotOptimizeAway(enc.stats.count);
}

fn runEncode256(ctx: *framework.Context) anyerror!void {
    return runEncode(ctx, 256);
}

fn runEncode4096(ctx: *framework.Context) anyerror!void {
    return runEncode(ctx, 4096);
}

/// Decode `N` deterministic points through `GorillaDecoder`.
///
/// Setup builds the encoded byte buffer from a fresh encoder, then
/// frees the encoder so only the byte slice survives into the decode
/// loop. `GorillaDecoder.init` takes no allocator, so the measured
/// decode loop performs zero allocations. Encoder fixture allocations
/// are counted by `TrackingAllocator` (it wraps the whole `run`
/// callback); the decode loop itself is allocation-free by
/// construction.
fn runDecode(ctx: *framework.Context, comptime N: usize) anyerror!void {
    // Build the encoded payload, then drop the encoder so the decode
    // loop owns nothing but the byte buffer.
    const bytes = blk: {
        var enc = try lib.gorilla.GorillaEncoder.initForPoints(ctx.allocator, N);
        defer enc.deinit();
        for (0..N) |i| {
            const ts: i64 = @as(i64, @intCast(i)) * 1000;
            const val: i64 = @as(i64, @intCast(i)) * 7 + 13;
            try enc.encodePoint(.{ .ts = ts, .value = val });
        }
        break :blk try enc.getCompressedData(ctx.allocator);
    };
    defer ctx.allocator.free(bytes);

    // Measured region — no allocations possible: `GorillaDecoder`
    // holds no allocator and `decodePoint` writes only into its own
    // stack-resident state.
    var dec = lib.gorilla.GorillaDecoder.init(bytes, @intCast(N));
    var sink: i64 = 0;
    var count: usize = 0;
    while (count < N) : (count += 1) {
        const pt = dec.decodePoint() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        sink ^= pt.ts ^ pt.value;
    }
    std.mem.doNotOptimizeAway(sink);
    std.mem.doNotOptimizeAway(count);
}

fn runDecode256(ctx: *framework.Context) anyerror!void {
    return runDecode(ctx, 256);
}

fn runDecode4096(ctx: *framework.Context) anyerror!void {
    return runDecode(ctx, 4096);
}
