// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Output helpers: summary printer, JSON writer, environment capture
//! (git SHA, Zig version, OS, arch, CPU model, RSS).
//!
//! Lifted out of the original framework.zig as part of Q-CPLX-005.
//! Pure presentation / introspection — no benchmark scheduling lives
//! here.

const std = @import("std");
const builtin = @import("builtin");
const scenario_mod = @import("scenario.zig");

const Io = std.Io;

const ResultRow = scenario_mod.ResultRow;

// =============================================================================
// Summary printer
// =============================================================================

pub fn printSummary(out: *Io.Writer, rows: []const ResultRow) !void {
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

// =============================================================================
// JSON output
// =============================================================================

pub fn writeJson(
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

pub fn unixTimestampS(io: Io) i64 {
    const ts = Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    return @intCast(@divTrunc(ts, std.time.ns_per_s));
}

// =============================================================================
// Environment capture
// =============================================================================

pub const Env = struct {
    git_sha: []const u8,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,

    pub fn deinit(self: Env, allocator: std.mem.Allocator) void {
        allocator.free(self.git_sha);
        allocator.free(self.cpu);
    }
};

pub fn captureEnv(allocator: std.mem.Allocator, io: Io) !Env {
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

// =============================================================================
// RSS (Linux only; zero elsewhere)
// =============================================================================

pub fn readRssCurrent() u64 {
    return readRssField("VmRSS:") orelse 0;
}

pub fn readRssPeak() u64 {
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
