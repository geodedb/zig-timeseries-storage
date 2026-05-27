// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Benchmark scheduler / runner: warmup loop, sample loop, stats
//! aggregation, tracking-allocator wiring.
//!
//! Lifted out of the original framework.zig as part of Q-CPLX-005.
//! The scenario/options/result types live in `scenario.zig`; the
//! JSON output + summary printer live in `reporter.zig`. Each is
//! under 250 lines so per-file complexity stays bounded.

const std = @import("std");
const builtin = @import("builtin");
const scenario_mod = @import("scenario.zig");
const reporter = @import("reporter.zig");
const tracking = @import("tracking_allocator.zig");

const Io = std.Io;

const Scenario = scenario_mod.Scenario;
const Context = scenario_mod.Context;
const ResultRow = scenario_mod.ResultRow;
const RunOptions = scenario_mod.RunOptions;

pub const TrackingAllocator = tracking.TrackingAllocator;

// =============================================================================
// Runner
// =============================================================================

pub fn runScenarios(
    allocator: std.mem.Allocator,
    io: Io,
    scenarios: []const Scenario,
    options: RunOptions,
) !void {
    var rows: std.ArrayList(ResultRow) = .empty;
    defer rows.deinit(allocator);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const env = try reporter.captureEnv(allocator, io);
    defer env.deinit(allocator);

    for (scenarios) |scenario| {
        if (options.filter) |needle| {
            if (std.mem.indexOf(u8, scenario.name, needle) == null) continue;
        }
        const warmup = options.warmup_override orelse scenario.warmup_iterations;
        const samples = options.samples_override orelse scenario.sample_iterations;
        if (samples == 0) return error.SamplesMustBePositive;

        if (options.verbose) {
            try stderr.print(
                "running {s}: warmup={d} samples={d} ops/iter={d}\n",
                .{ scenario.name, warmup, samples, scenario.ops_per_iteration },
            );
            try stderr.flush();
        }

        const row = try runOneScenario(allocator, io, scenario, warmup, samples, options, env, stderr);
        try rows.append(allocator, row);
    }

    if (options.verbose) {
        try reporter.printSummary(stderr, rows.items);
    }

    if (options.output_path) |path| {
        try reporter.writeJson(allocator, io, path, rows.items, reporter.unixTimestampS(io));
        if (options.verbose) {
            try stderr.print("wrote {d} rows to {s}\n", .{ rows.items.len, path });
            try stderr.flush();
        }
    }
}

/// Drive a single scenario through warmup + sample iterations and
/// return the aggregated `ResultRow`. Factored out so `runScenarios`
/// stays a thin loop; per-scenario logic lives here.
fn runOneScenario(
    allocator: std.mem.Allocator,
    io: Io,
    scenario: Scenario,
    warmup: u32,
    samples: u32,
    options: RunOptions,
    env: reporter.Env,
    stderr: *Io.Writer,
) !ResultRow {
    const wall_samples = try allocator.alloc(u64, samples);
    defer allocator.free(wall_samples);
    var alloc_count_total: u64 = 0;
    var alloc_bytes_total: u64 = 0;
    var peak_live_total: u64 = 0;

    var iter: u32 = 0;
    while (iter < warmup + samples) : (iter += 1) {
        const is_warmup = iter < warmup;

        var tracker: ?TrackingAllocator = if (options.track_allocations)
            TrackingAllocator.init(allocator)
        else
            null;
        const iter_allocator = if (tracker) |*t| t.allocator() else allocator;

        var ctx = Context{
            .allocator = iter_allocator,
            .scenario = &scenario,
            .iteration_index = iter,
            .user_data = scenario.user_data,
        };

        const start_ns = nowNs(io);
        try scenario.run(&ctx);
        const wall_ns = nowNs(io) - start_ns;

        if (!is_warmup) {
            wall_samples[iter - warmup] = wall_ns;
            if (tracker) |t| {
                alloc_count_total += t.alloc_count;
                alloc_bytes_total += t.alloc_bytes;
                if (t.peak_live > peak_live_total) peak_live_total = t.peak_live;
            }
            if (options.verbose) {
                try stderr.print(
                    "  sample {d}/{d}: {d} ns ({d:.2} ops/s)\n",
                    .{
                        iter - warmup + 1,
                        samples,
                        wall_ns,
                        opsPerSec(scenario.ops_per_iteration, wall_ns),
                    },
                );
                try stderr.flush();
            }
        }
    }

    std.sort.heap(u64, wall_samples, {}, comptime std.sort.asc(u64));
    const stats = summarize(wall_samples);
    const throughput_samples = try allocator.alloc(f64, wall_samples.len);
    defer allocator.free(throughput_samples);
    for (wall_samples, 0..) |w, i| {
        throughput_samples[i] = opsPerSec(scenario.ops_per_iteration, w);
    }
    const tput_median = opsPerSec(scenario.ops_per_iteration, stats.p50_ns);
    const tput_stddev = stddevF64(throughput_samples, tput_median);

    const sample_count_div = @as(u64, samples);
    return ResultRow{
        .git_sha = env.git_sha,
        .run_timestamp_unix_s = reporter.unixTimestampS(io),
        .zig_version = env.zig_version,
        .os = env.os,
        .arch = env.arch,
        .cpu = env.cpu,
        .scenario_name = scenario.name,
        .ops_per_iteration = scenario.ops_per_iteration,
        .sample_count = samples,
        .wall_ns_min = stats.min_ns,
        .wall_ns_p50 = stats.p50_ns,
        .wall_ns_p95 = stats.p95_ns,
        .wall_ns_p99 = stats.p99_ns,
        .wall_ns_max = stats.max_ns,
        .wall_ns_stddev = stats.stddev_ns,
        .throughput_ops_per_sec = tput_median,
        .throughput_stddev_ops_per_sec = tput_stddev,
        .alloc_count = alloc_count_total / sample_count_div,
        .alloc_bytes = alloc_bytes_total / sample_count_div,
        .peak_live_bytes = peak_live_total,
        .rss_current_bytes = reporter.readRssCurrent(),
        .rss_peak_bytes = reporter.readRssPeak(),
    };
}

// =============================================================================
// Summary stats helpers
// =============================================================================

const Stats = struct {
    min_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    stddev_ns: f64,
};

fn summarize(sorted: []const u64) Stats {
    if (sorted.len == 0) return .{ .min_ns = 0, .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0, .stddev_ns = 0 };
    const median = percentile(sorted, 50);
    return .{
        .min_ns = sorted[0],
        .p50_ns = median,
        .p95_ns = percentile(sorted, 95),
        .p99_ns = percentile(sorted, 99),
        .max_ns = sorted[sorted.len - 1],
        .stddev_ns = stddevU64(sorted, median),
    };
}

fn percentile(sorted: []const u64, pct: u8) u64 {
    if (sorted.len == 0) return 0;
    const idx = @min((sorted.len - 1) * pct / 100, sorted.len - 1);
    return sorted[idx];
}

fn stddevU64(samples: []const u64, mean_value: u64) f64 {
    if (samples.len == 0) return 0;
    var sum_sq: f64 = 0;
    const m: f64 = @floatFromInt(mean_value);
    for (samples) |s| {
        const d: f64 = @as(f64, @floatFromInt(s)) - m;
        sum_sq += d * d;
    }
    return std.math.sqrt(sum_sq / @as(f64, @floatFromInt(samples.len)));
}

fn stddevF64(samples: []const f64, mean_value: f64) f64 {
    if (samples.len == 0) return 0;
    var sum_sq: f64 = 0;
    for (samples) |s| {
        const d = s - mean_value;
        sum_sq += d * d;
    }
    return std.math.sqrt(sum_sq / @as(f64, @floatFromInt(samples.len)));
}

fn opsPerSec(ops: u64, wall_ns: u64) f64 {
    if (wall_ns == 0) return 0;
    const ops_f: f64 = @floatFromInt(ops);
    const sec: f64 = @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    return ops_f / sec;
}

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return if (ts < 0) 0 else @intCast(ts);
}
