// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! CLI entry point for timeseries-storage.
//!
//! This binary is built when `-Dno-cli=true` is *not* passed to
//! `zig build`. It links against the library module exposed by
//! `src/root.zig`.
//!
//! Usage:
//!   timeseries-storage [--data-dir <path>]
//!
//! Opens (or creates) the data directory, prints engine status
//! (segment count and last checkpoint LSN), and exits. Subcommands
//! such as `ingest` and `query` are tracked under GAP-0008 and will
//! land in a follow-up.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    try out.print("timeseries-storage v{s}\n", .{lib.version});

    var data_dir: []const u8 = "./ts-data";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--data-dir") and i + 1 < args.len) {
            data_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try out.writeAll("usage: timeseries-storage [--data-dir <path>]\n");
            try out.flush();
            return;
        }
    }

    // Ensure the data directory exists (create if missing).
    try std.Io.Dir.cwd().createDirPath(io, data_dir);

    try out.print("data dir: {s}\n", .{data_dir});

    var pool = try thread_pool.ThreadPool.init(init.gpa, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(init.gpa, .{ .data_dir = data_dir }, &pool);
    defer eng.deinit();

    try out.print("segments: {d}\n", .{eng.man.segments.items.len});
    try out.print("last_checkpoint_lsn: {d}\n", .{eng.man.last_checkpoint_lsn});

    try out.flush();
}
