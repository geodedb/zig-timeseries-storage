// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Scenario / Context / RunFn types — the contract between a bench
//! suite and the framework runner.
//!
//! Closes the "types" slice of Q-CPLX-005 (split of framework.zig).
//! Everything here is library-agnostic: it depends only on the Zig
//! stdlib so it can be lifted into any project by copying the
//! `framework/` directory wholesale.

const std = @import("std");

/// User-supplied benchmark callback. Perform `scenario.ops_per_iteration`
/// units of work; the framework times the wall clock around the call.
/// Read `ctx.allocator` for any allocations the body needs (allocations
/// are tracked when `RunOptions.track_allocations` is set).
pub const RunFn = *const fn (ctx: *Context) anyerror!void;

pub const Scenario = struct {
    /// Stable identifier; used to match across runs in `compare`.
    name: []const u8,
    /// Number of operations the body performs in a single call. The
    /// framework divides wall time by this to compute throughput.
    ops_per_iteration: u64 = 1,
    /// Iterations to discard before sampling (cold caches, JIT warmup,
    /// allocator one-time setup, etc.). Defaults to 1.
    warmup_iterations: u32 = 1,
    /// Sample iterations to median over. Defaults to 6 for a 7-run
    /// total. Larger values reduce noise but cost runtime.
    sample_iterations: u32 = 6,
    /// Optional opaque payload forwarded to `run`.
    user_data: ?*anyopaque = null,
    /// The benchmark body.
    run: RunFn,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    scenario: *const Scenario,
    iteration_index: u32,
    user_data: ?*anyopaque,
};

pub const ResultRow = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
    scenario_name: []const u8,
    ops_per_iteration: u64,
    sample_count: u32,
    wall_ns_min: u64,
    wall_ns_p50: u64,
    wall_ns_p95: u64,
    wall_ns_p99: u64,
    wall_ns_max: u64,
    wall_ns_stddev: f64,
    throughput_ops_per_sec: f64,
    throughput_stddev_ops_per_sec: f64,
    alloc_count: u64,
    alloc_bytes: u64,
    peak_live_bytes: u64,
    rss_current_bytes: u64,
    rss_peak_bytes: u64,
};

pub const ResultDocument = struct {
    generated_at_unix_s: i64,
    rows: []ResultRow,
};

pub const RunOptions = struct {
    /// If set, write a `ResultDocument` JSON to this path.
    output_path: ?[]const u8 = null,
    /// If set, only run scenarios whose name contains this substring.
    filter: ?[]const u8 = null,
    /// Override per-scenario `warmup_iterations` when non-null.
    warmup_override: ?u32 = null,
    /// Override per-scenario `sample_iterations` when non-null.
    samples_override: ?u32 = null,
    /// Wrap the user allocator with a tracking allocator that records
    /// alloc count + bytes per iteration. Adds small overhead; disable
    /// for the tightest hot loops.
    track_allocations: bool = true,
    /// Print one line per run to stderr. Useful for live iteration.
    verbose: bool = true,
};

pub const ParseResult = union(enum) {
    run: RunOptions,
    list_only,
    help_only,
};

// =============================================================================
// CLI parsing — small enough to live with the type contract instead of
// in its own file. parseArgs / printHelp / printScenarios are the
// canonical entry points for every bench `main`.
// =============================================================================

const Io = std.Io;

/// Parse `--output <path>`, `--filter <substr>`, `--warmup N`,
/// `--samples N`, `--no-track`, `--list`, `--help` from process args.
/// Returns `.run` (with options) or `.list_only` / `.help_only` so the
/// caller can short-circuit.
pub fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !ParseResult {
    const argv = try args.toSlice(allocator);
    var opts: RunOptions = .{};
    var list_only = false;
    var help_only = false;
    var idx: usize = 1;
    while (idx < argv.len) : (idx += 1) {
        const a = argv[idx];
        if (std.mem.eql(u8, a, "--output") and idx + 1 < argv.len) {
            opts.output_path = try allocator.dupe(u8, argv[idx + 1]);
            idx += 1;
        } else if (std.mem.eql(u8, a, "--filter") and idx + 1 < argv.len) {
            opts.filter = try allocator.dupe(u8, argv[idx + 1]);
            idx += 1;
        } else if (std.mem.eql(u8, a, "--warmup") and idx + 1 < argv.len) {
            opts.warmup_override = try std.fmt.parseInt(u32, argv[idx + 1], 10);
            idx += 1;
        } else if (std.mem.eql(u8, a, "--samples") and idx + 1 < argv.len) {
            opts.samples_override = try std.fmt.parseInt(u32, argv[idx + 1], 10);
            idx += 1;
        } else if (std.mem.eql(u8, a, "--no-track")) {
            opts.track_allocations = false;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            opts.verbose = false;
        } else if (std.mem.eql(u8, a, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            help_only = true;
        }
    }
    if (help_only) return .help_only;
    if (list_only) return .list_only;
    return .{ .run = opts };
}

pub fn printHelp(out: *Io.Writer, program: []const u8) !void {
    try out.print(
        \\Usage: {s} [options]
        \\
        \\  --output <path>     Write JSON results to <path>.
        \\  --filter <substr>   Only run scenarios whose name contains <substr>.
        \\  --warmup <N>        Override per-scenario warmup iterations.
        \\  --samples <N>       Override per-scenario sample iterations.
        \\  --no-track          Disable per-iteration allocation tracking.
        \\  --quiet             Suppress per-run progress output.
        \\  --list              List registered scenarios and exit.
        \\  -h, --help          Show this message.
        \\
        \\Sample count is the number of medianed runs; total runs per
        \\scenario is warmup + samples. Defaults: warmup=1, samples=6.
        \\
    , .{program});
    try out.flush();
}

pub fn printScenarios(out: *Io.Writer, scenarios: []const Scenario) !void {
    try out.writeAll("Registered scenarios:\n");
    for (scenarios) |s| {
        try out.print(
            "  {s}  (ops/iter={d}, warmup={d}, samples={d})\n",
            .{ s.name, s.ops_per_iteration, s.warmup_iterations, s.sample_iterations },
        );
    }
    try out.flush();
}
