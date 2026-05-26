// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Library-agnostic benchmark framework.
//!
//! Define a list of `Scenario` records and call `runScenarios`. The
//! framework does the rest:
//!
//! * Runs each scenario `warmup_iterations + sample_iterations` times.
//! * Discards the warmup runs.
//! * Sorts the sampled wall times, reports median + p95 + p99 + min +
//!   max + stddev.
//! * Computes `throughput_ops_per_sec` from `ops_per_iteration`.
//! * Tracks allocations via an optional `TrackingAllocator` wrapper.
//! * Reads RSS from `/proc/self/status` on Linux (zero elsewhere).
//! * Captures git SHA, Zig version, OS, arch, and CPU model.
//! * Emits a stable JSON schema that `compare.zig` can diff.
//!
//! This file has no dependency on the project library — it only uses
//! the Zig standard library — so it can be lifted into any Zig project
//! by copying `benchmarks/framework.zig` and `benchmarks/compare.zig`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

// ============================================================================
// Public types
// ============================================================================

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

// ============================================================================
// CLI parsing
// ============================================================================

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

pub const ParseResult = union(enum) {
    run: RunOptions,
    list_only,
    help_only,
};

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

// ============================================================================
// Top-level runner
// ============================================================================

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

    const env = try captureEnv(allocator, io);
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
        const row = ResultRow{
            .git_sha = env.git_sha,
            .run_timestamp_unix_s = unixTimestampS(io),
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
            .rss_current_bytes = readRssCurrent(),
            .rss_peak_bytes = readRssPeak(),
        };
        try rows.append(allocator, row);
    }

    if (options.verbose) {
        try printSummary(stderr, rows.items);
    }

    if (options.output_path) |path| {
        try writeJson(allocator, io, path, rows.items, unixTimestampS(io));
        if (options.verbose) {
            try stderr.print("wrote {d} rows to {s}\n", .{ rows.items.len, path });
            try stderr.flush();
        }
    }
}

// ============================================================================
// Summary stats
// ============================================================================

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

fn unixTimestampS(io: Io) i64 {
    const ts = Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    return @intCast(@divTrunc(ts, std.time.ns_per_s));
}

fn printSummary(out: *Io.Writer, rows: []const ResultRow) !void {
    try out.writeAll("\nresults:\n");
    for (rows) |r| {
        try out.print(
            "  {s}: median={d}ns p95={d}ns p99={d}ns throughput={d:.2}ops/s (stddev={d:.2})\n",
            .{
                r.scenario_name,
                r.wall_ns_p50,
                r.wall_ns_p95,
                r.wall_ns_p99,
                r.throughput_ops_per_sec,
                r.throughput_stddev_ops_per_sec,
            },
        );
    }
    try out.flush();
}

// ============================================================================
// JSON output
// ============================================================================

fn writeJson(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    rows: []const ResultRow,
    generated_at_unix_s: i64,
) !void {
    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.fmt(.{
        .generated_at_unix_s = generated_at_unix_s,
        .rows = rows,
    }, .{ .whitespace = .indent_2 }).format(&aw.writer);
    try aw.writer.writeByte('\n');
    const bytes = aw.written();

    var f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw = f.writer(io, &write_buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

// ============================================================================
// Tracking allocator
// ============================================================================

/// Wraps another allocator, counting calls and live bytes. Use when you
/// want per-iteration allocation totals attached to results. Not
/// thread-safe; pass per-iteration instances.
pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live: u64 = 0,

    pub fn init(backing: std.mem.Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.alloc_count += 1;
            self.alloc_bytes += len;
            self.live_bytes += len;
            if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
        }
        return result;
    }

    fn resize(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            const old_len = buf.len;
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.alloc_bytes += delta;
                self.live_bytes += delta;
                if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
            } else {
                self.live_bytes -= (old_len - new_len);
            }
        }
        return ok;
    }

    fn remap(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.backing.rawRemap(buf, alignment, new_len, ret_addr);
        if (result != null) {
            const old_len = buf.len;
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.alloc_bytes += delta;
                self.live_bytes += delta;
                if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
            } else {
                self.live_bytes -= (old_len - new_len);
            }
        }
        return result;
    }

    fn free(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(buf, alignment, ret_addr);
        self.live_bytes -= buf.len;
    }
};

// ============================================================================
// Environment capture
// ============================================================================

const Env = struct {
    git_sha: []const u8,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,

    fn deinit(self: Env, allocator: std.mem.Allocator) void {
        allocator.free(self.git_sha);
        allocator.free(self.cpu);
    }
};

fn captureEnv(allocator: std.mem.Allocator, io: Io) !Env {
    return .{
        .git_sha = try gitSha(allocator, io),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu = try allocator.dupe(u8, builtin.cpu.model.name),
    };
}

fn gitSha(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(512),
    }) catch return allocator.dupe(u8, "unknown");
    defer allocator.free(result.stderr);
    const exited = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    if (exited != 0) {
        allocator.free(result.stdout);
        return allocator.dupe(u8, "unknown");
    }
    defer allocator.free(result.stdout);
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}

// ============================================================================
// RSS (Linux only; zero elsewhere)
// ============================================================================

fn readRssCurrent() u64 {
    return readRssField("VmRSS:") orelse 0;
}

fn readRssPeak() u64 {
    return readRssField("VmHWM:") orelse 0;
}

fn readRssField(comptime field: []const u8) ?u64 {
    if (builtin.os.tag != .linux) return null;
    var buf: [4096]u8 = undefined;
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        "/proc/self/status",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    ) catch return null;
    defer _ = std.os.linux.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch return null;
        if (n == 0) break;
        total += n;
    }
    const contents = buf[0..total];
    const start = std.mem.indexOf(u8, contents, field) orelse return null;
    const line_end = std.mem.indexOfScalarPos(u8, contents, start, '\n') orelse contents.len;
    const line = contents[start + field.len .. line_end];
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const num = it.next() orelse return null;
    const kb = std.fmt.parseInt(u64, num, 10) catch return null;
    return kb * 1024;
}
