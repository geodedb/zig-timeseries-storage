// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Compare two benchmark result files emitted by `framework.runScenarios`.
//!
//! Matches rows by `scenario_name` and reports percent change for
//! `throughput_ops_per_sec` and `wall_ns_p50`. A regression is any
//! throughput drop that exceeds the noise gate, computed as
//! `max(absolute_floor_pct, 3 * stddev_pct_in_baseline)`. The default
//! floor (15%) is intentionally loose so first-time wiring does not
//! flag noise; tighten via `--floor <pct>` once the baseline is
//! stable.
//!
//! Exits non-zero on any regression.
//!
//! Usage:
//!   compare-bench --baseline <baseline.json> --current <latest.json>
//!                 [--floor 15] [--quiet]

const std = @import("std");
const Io = std.Io;
const framework = @import("framework");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);
    var baseline_path: ?[]const u8 = null;
    var current_path: ?[]const u8 = null;
    var floor_pct: f64 = 15.0;
    var quiet = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--baseline") and i + 1 < args.len) {
            baseline_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--current") and i + 1 < args.len) {
            current_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--floor") and i + 1 < args.len) {
            floor_pct = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printUsage(stderr);
            return;
        }
    }
    if (baseline_path == null or current_path == null) {
        try printUsage(stderr);
        return error.InvalidArguments;
    }

    const baseline_doc = try readDocument(allocator, init.io, baseline_path.?);
    const current_doc = try readDocument(allocator, init.io, current_path.?);

    var failures: usize = 0;
    var matched: usize = 0;
    for (current_doc.value.rows) |row| {
        const baseline = findMatch(baseline_doc.value.rows, row.scenario_name) orelse {
            if (!quiet) {
                try stderr.print("  {s}: no baseline row, skipping\n", .{row.scenario_name});
                try stderr.flush();
            }
            continue;
        };
        matched += 1;
        const tput_change = pctChange(baseline.throughput_ops_per_sec, row.throughput_ops_per_sec);
        const wall_change = pctChange(@floatFromInt(baseline.wall_ns_p50), @floatFromInt(row.wall_ns_p50));
        const stddev_pct = if (baseline.throughput_ops_per_sec != 0)
            (baseline.throughput_stddev_ops_per_sec / baseline.throughput_ops_per_sec) * 100.0
        else
            0.0;
        const noise_gate = @max(floor_pct, 3.0 * stddev_pct);

        try stderr.print(
            "{s}: throughput {s}{d:.2}%  wall_p50 {s}{d:.2}%  noise_gate={d:.2}% (stddev_pct={d:.2}%)\n",
            .{
                row.scenario_name,
                if (tput_change >= 0) "+" else "",
                tput_change,
                if (wall_change >= 0) "+" else "",
                wall_change,
                noise_gate,
                stddev_pct,
            },
        );
        if (tput_change < -noise_gate) {
            try stderr.print(
                "  FAIL: throughput regression {d:.2}% exceeds noise gate {d:.2}%\n",
                .{ -tput_change, noise_gate },
            );
            failures += 1;
        }
    }
    try stderr.flush();

    if (matched == 0) {
        try stderr.writeAll("no scenarios matched between baseline and current\n");
        try stderr.flush();
        return error.NoMatches;
    }
    if (failures != 0) return error.BenchmarkRegression;
}

fn printUsage(out: *Io.Writer) !void {
    try out.writeAll(
        \\Usage: compare-bench --baseline <file> --current <file>
        \\                     [--floor <pct>] [--quiet]
        \\
        \\Compares two benchmark result documents. Exits non-zero if any
        \\matched scenario shows a throughput regression beyond the
        \\noise gate (max of --floor and 3 * baseline stddev).
        \\
    );
    try out.flush();
}

fn readDocument(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !std.json.Parsed(framework.ResultDocument) {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    return std.json.parseFromSlice(
        framework.ResultDocument,
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    );
}

fn findMatch(rows: []const framework.ResultRow, name: []const u8) ?framework.ResultRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.scenario_name, name)) return row;
    }
    return null;
}

fn pctChange(before: f64, after: f64) f64 {
    if (before == 0) return 0;
    return ((after - before) / before) * 100.0;
}
