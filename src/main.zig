// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! CLI entry point for timeseries-storage.
//!
//! This binary is built when `-Dno-cli=true` is *not* passed to
//! `zig build`. It links against the library module exposed by
//! `src/root.zig`. Replace the body of `main` with whatever
//! command surface this project needs.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    try out.print("timeseries-storage v{s}\n", .{lib.version});

    if (args.len > 1) {
        try out.writeAll("args:\n");
        for (args[1..]) |arg| {
            try out.print("  - {s}\n", .{arg});
        }
    } else {
        try out.writeAll("no args provided. pass `-- <args>` to forward them.\n");
    }

    try lib.init(.{});
    try out.flush();
}
