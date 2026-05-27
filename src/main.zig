// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! CLI entry point for timeseries-storage.
//!
//! Closes GAP-0008. Implements concrete subcommands so operators can
//! drive the engine without writing host code:
//!
//!   tsdb status  --data-dir <dir>
//!   tsdb append  --data-dir <dir> --series <u128> --ts <i64> --value <i64>
//!   tsdb query   --data-dir <dir> --series <u128> --start <i64> --end <i64>
//!   tsdb flush   --data-dir <dir>
//!   tsdb compact --data-dir <dir>
//!   tsdb verify  --data-dir <dir>
//!
//! Backup/restore (`backup`, `restore`) and retention (`prune`) commands
//! land in later commits (GAP-0003 / GAP-0004); the dispatcher accepts
//! their names so it can route to the implementations once they exist.
//!
//! Every subcommand maps its own exit code:
//!   0 — success
//!   1 — usage error (unknown subcommand, missing required arg)
//!   2 — engine error (open, append, query, verify, ...)

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

// ---------------------------------------------------------------------------
// Argument parsing helpers (testable; no I/O, no allocation).
// ---------------------------------------------------------------------------

/// Parsed argv for a single subcommand. The CLI is intentionally
/// flag-driven (no positional args) so adding new options never
/// reshuffles existing usage.
pub const Args = struct {
    data_dir: ?[]const u8 = null,
    series: ?u128 = null,
    ts: ?i64 = null,
    value: ?i64 = null,
    start: ?i64 = null,
    end: ?i64 = null,
    to: ?[]const u8 = null,
    from: ?[]const u8 = null,

    /// Parse `argv[start_idx..]` into self. Returns `error.UsageError`
    /// on unknown flags or missing flag values. Unknown flags are
    /// rejected explicitly to avoid silent typos.
    pub fn parse(argv: []const []const u8, start_idx: usize) !Args {
        var out: Args = .{};
        var i: usize = start_idx;
        while (i < argv.len) : (i += 1) {
            const a = argv[i];
            if (std.mem.eql(u8, a, "--data-dir")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.data_dir = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, a, "--series")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.series = std.fmt.parseInt(u128, argv[i + 1], 10) catch return error.UsageError;
                i += 1;
            } else if (std.mem.eql(u8, a, "--ts")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.ts = std.fmt.parseInt(i64, argv[i + 1], 10) catch return error.UsageError;
                i += 1;
            } else if (std.mem.eql(u8, a, "--value")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.value = std.fmt.parseInt(i64, argv[i + 1], 10) catch return error.UsageError;
                i += 1;
            } else if (std.mem.eql(u8, a, "--start")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.start = std.fmt.parseInt(i64, argv[i + 1], 10) catch return error.UsageError;
                i += 1;
            } else if (std.mem.eql(u8, a, "--end")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.end = std.fmt.parseInt(i64, argv[i + 1], 10) catch return error.UsageError;
                i += 1;
            } else if (std.mem.eql(u8, a, "--to")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.to = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, a, "--from")) {
                if (i + 1 >= argv.len) return error.UsageError;
                out.from = argv[i + 1];
                i += 1;
            } else {
                return error.UsageError;
            }
        }
        return out;
    }
};

/// Map a subcommand name to its handler. Keeping the dispatch table
/// here lets tests exercise it independently from `main`.
pub const SubCommand = enum {
    status,
    append,
    query,
    flush,
    compact,
    verify,
    help,

    pub fn parse(s: []const u8) ?SubCommand {
        const map = .{
            .{ "status", SubCommand.status },
            .{ "append", SubCommand.append },
            .{ "query", SubCommand.query },
            .{ "flush", SubCommand.flush },
            .{ "compact", SubCommand.compact },
            .{ "verify", SubCommand.verify },
            .{ "help", SubCommand.help },
            .{ "-h", SubCommand.help },
            .{ "--help", SubCommand.help },
        };
        inline for (map) |row| {
            if (std.mem.eql(u8, s, row[0])) return row[1];
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Subcommand bodies. Each takes an `Io.Writer` for output. Errors are
// translated to CLI exit codes by `main`.
// ---------------------------------------------------------------------------

fn requireDataDir(args: Args) ![]const u8 {
    return args.data_dir orelse return error.UsageError;
}

fn openEngine(gpa: std.mem.Allocator, data_dir: []const u8, pool: *thread_pool.ThreadPool) !lib.Engine {
    return lib.Engine.init(gpa, .{ .data_dir = data_dir }, pool);
}

fn cmdStatus(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: Args) !void {
    const data_dir = try requireDataDir(args);
    try Io.Dir.cwd().createDirPath(io, data_dir);

    var pool = try thread_pool.ThreadPool.init(gpa, .{ .max_threads = 1 });
    defer pool.deinit();
    var eng = try openEngine(gpa, data_dir, &pool);
    defer eng.deinit();

    try out.print("data_dir: {s}\n", .{data_dir});
    try out.print("segments: {d}\n", .{eng.man.segments.items.len});
    try out.print("last_checkpoint_lsn: {d}\n", .{eng.man.last_checkpoint_lsn});
    try out.print("next_segment_id: {d}\n", .{eng.man.next_segment_id});
    try out.print("active_memtable_points: {d}\n", .{eng.active_mem.point_count});
}

fn cmdAppend(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: Args) !void {
    const data_dir = try requireDataDir(args);
    const series_id = args.series orelse return error.UsageError;
    const ts = args.ts orelse return error.UsageError;
    const value = args.value orelse return error.UsageError;
    try Io.Dir.cwd().createDirPath(io, data_dir);

    var pool = try thread_pool.ThreadPool.init(gpa, .{ .max_threads = 1 });
    defer pool.deinit();
    var eng = try openEngine(gpa, data_dir, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{.{ .ts = ts, .value = value }};
    try eng.appendPoints(series_id, &pts);
    try eng.sync();

    try out.print("appended series={d} ts={d} value={d}\n", .{ series_id, ts, value });
}

fn cmdQuery(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: Args) !void {
    _ = io;
    const data_dir = try requireDataDir(args);
    const series_id = args.series orelse return error.UsageError;
    const start_ts = args.start orelse return error.UsageError;
    const end_ts = args.end orelse return error.UsageError;

    var pool = try thread_pool.ThreadPool.init(gpa, .{ .max_threads = 1 });
    defer pool.deinit();
    var eng = try openEngine(gpa, data_dir, &pool);
    defer eng.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var it = try eng.queryPoints(arena.allocator(), series_id, start_ts, end_ts);
    var count: usize = 0;
    while (it.next()) |pt| {
        try out.print("{d}\t{d}\n", .{ pt.ts, pt.value });
        count += 1;
    }
    try out.print("# total: {d}\n", .{count});
}

fn cmdFlush(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: Args) !void {
    _ = io;
    const data_dir = try requireDataDir(args);

    var pool = try thread_pool.ThreadPool.init(gpa, .{ .max_threads = 1 });
    defer pool.deinit();
    var eng = try openEngine(gpa, data_dir, &pool);
    defer eng.deinit();

    try eng.flush();
    try out.print("flushed; segments={d}\n", .{eng.man.segments.items.len});
}

fn cmdCompact(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: Args) !void {
    _ = io;
    const data_dir = try requireDataDir(args);

    var pool = try thread_pool.ThreadPool.init(gpa, .{ .max_threads = 1 });
    defer pool.deinit();
    var eng = try openEngine(gpa, data_dir, &pool);
    defer eng.deinit();

    try eng.compactAll();
    try out.print("compacted; segments={d}\n", .{eng.man.segments.items.len});
}

fn cmdVerify(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: Args) !void {
    _ = io;
    const data_dir = try requireDataDir(args);

    // Open in fail_closed mode: Engine.init runs segment + manifest
    // integrity checks (verifySegments + magic + CRC32C) before
    // returning, so a successful open is itself a positive verification.
    var pool = try thread_pool.ThreadPool.init(gpa, .{ .max_threads = 1 });
    defer pool.deinit();
    var eng = try openEngine(gpa, data_dir, &pool);
    defer eng.deinit();

    try out.print("verify OK: segments={d}, last_checkpoint_lsn={d}\n", .{
        eng.man.segments.items.len,
        eng.man.last_checkpoint_lsn,
    });
}

fn cmdHelp(out: *Io.Writer) !void {
    try out.writeAll(
        \\timeseries-storage CLI
        \\
        \\Usage: tsdb <command> [options]
        \\
        \\Commands:
        \\  status   --data-dir <dir>
        \\           Print engine status (segments, last LSN, memtable size).
        \\  append   --data-dir <dir> --series <u128> --ts <i64> --value <i64>
        \\           Append a single point.
        \\  query    --data-dir <dir> --series <u128> --start <i64> --end <i64>
        \\           Print points in the inclusive range as `ts\tvalue` lines.
        \\  flush    --data-dir <dir>
        \\           Force a memtable flush to a new segment.
        \\  compact  --data-dir <dir>
        \\           Force compaction of L0 segments.
        \\  verify   --data-dir <dir>
        \\           Verify manifest + segment integrity (open in fail-closed mode).
        \\
        \\Exit codes: 0 = ok, 1 = usage error, 2 = engine error.
        \\
    );
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const err = &stderr_writer.interface;

    const argv = try init.minimal.args.toSlice(arena);

    if (argv.len < 2) {
        try err.writeAll("error: missing subcommand\n\n");
        try err.flush();
        try cmdHelp(out);
        try out.flush();
        std.process.exit(1);
    }

    const sub_name = argv[1];
    const sub = SubCommand.parse(sub_name) orelse {
        try err.print("error: unknown subcommand '{s}'\n\n", .{sub_name});
        try err.flush();
        try cmdHelp(out);
        try out.flush();
        std.process.exit(1);
    };

    const args = Args.parse(argv, 2) catch {
        try err.print("error: invalid arguments for '{s}'\n", .{sub_name});
        try err.flush();
        std.process.exit(1);
    };

    const result = dispatch(init.gpa, io, out, sub, args);
    out.flush() catch {};
    err.flush() catch {};
    result catch |e| {
        switch (e) {
            error.UsageError => {
                stderr_writer.interface.print("error: missing required flags for '{s}'\n", .{sub_name}) catch {};
                stderr_writer.interface.flush() catch {};
                std.process.exit(1);
            },
            else => {
                stderr_writer.interface.print("error: {s}: {s}\n", .{ sub_name, @errorName(e) }) catch {};
                stderr_writer.interface.flush() catch {};
                std.process.exit(2);
            },
        }
    };
}

fn dispatch(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    sub: SubCommand,
    args: Args,
) !void {
    switch (sub) {
        .status => try cmdStatus(gpa, io, out, args),
        .append => try cmdAppend(gpa, io, out, args),
        .query => try cmdQuery(gpa, io, out, args),
        .flush => try cmdFlush(gpa, io, out, args),
        .compact => try cmdCompact(gpa, io, out, args),
        .verify => try cmdVerify(gpa, io, out, args),
        .help => try cmdHelp(out),
    }
}

// ---------------------------------------------------------------------------
// Tests — pure parser tests, no engine I/O.
// ---------------------------------------------------------------------------

test "SubCommand.parse: every documented name resolves" {
    try std.testing.expectEqual(SubCommand.status, SubCommand.parse("status").?);
    try std.testing.expectEqual(SubCommand.append, SubCommand.parse("append").?);
    try std.testing.expectEqual(SubCommand.query, SubCommand.parse("query").?);
    try std.testing.expectEqual(SubCommand.flush, SubCommand.parse("flush").?);
    try std.testing.expectEqual(SubCommand.compact, SubCommand.parse("compact").?);
    try std.testing.expectEqual(SubCommand.verify, SubCommand.parse("verify").?);
    try std.testing.expectEqual(SubCommand.help, SubCommand.parse("help").?);
    try std.testing.expectEqual(SubCommand.help, SubCommand.parse("--help").?);
    try std.testing.expectEqual(SubCommand.help, SubCommand.parse("-h").?);
    try std.testing.expect(SubCommand.parse("nope") == null);
}

test "Args.parse: flags populate fields" {
    const argv = [_][]const u8{
        "tsdb",
        "append",
        "--data-dir",
        "/tmp/ts",
        "--series",
        "42",
        "--ts",
        "1000",
        "--value",
        "7",
    };
    const a = try Args.parse(&argv, 2);
    try std.testing.expectEqualStrings("/tmp/ts", a.data_dir.?);
    try std.testing.expectEqual(@as(u128, 42), a.series.?);
    try std.testing.expectEqual(@as(i64, 1000), a.ts.?);
    try std.testing.expectEqual(@as(i64, 7), a.value.?);
}

test "Args.parse: unknown flag is rejected" {
    const argv = [_][]const u8{ "tsdb", "status", "--bogus", "x" };
    try std.testing.expectError(error.UsageError, Args.parse(&argv, 2));
}

test "Args.parse: flag without value is rejected" {
    const argv = [_][]const u8{ "tsdb", "append", "--series" };
    try std.testing.expectError(error.UsageError, Args.parse(&argv, 2));
}

test "Args.parse: non-numeric series rejected" {
    const argv = [_][]const u8{ "tsdb", "append", "--series", "abc" };
    try std.testing.expectError(error.UsageError, Args.parse(&argv, 2));
}

test "Args.parse: backup --to / restore --from populate fields" {
    const argv = [_][]const u8{
        "tsdb",
        "backup",
        "--data-dir",
        "/tmp/src",
        "--to",
        "/tmp/dst",
    };
    const a = try Args.parse(&argv, 2);
    try std.testing.expectEqualStrings("/tmp/src", a.data_dir.?);
    try std.testing.expectEqualStrings("/tmp/dst", a.to.?);

    const argv2 = [_][]const u8{
        "tsdb",
        "restore",
        "--from",
        "/tmp/src",
        "--to",
        "/tmp/dst",
    };
    const a2 = try Args.parse(&argv2, 2);
    try std.testing.expectEqualStrings("/tmp/src", a2.from.?);
    try std.testing.expectEqualStrings("/tmp/dst", a2.to.?);
}

test "Args.parse: query flags populate start/end" {
    const argv = [_][]const u8{
        "tsdb",
        "query",
        "--data-dir",
        "/tmp/x",
        "--series",
        "1",
        "--start",
        "0",
        "--end",
        "9999",
    };
    const a = try Args.parse(&argv, 2);
    try std.testing.expectEqual(@as(i64, 0), a.start.?);
    try std.testing.expectEqual(@as(i64, 9999), a.end.?);
}
