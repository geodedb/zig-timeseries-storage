// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Basic usage example for timeseries-storage.
//!
//! Run with `zig build example`.

const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("timeseries-storage Example (v{s})\n", .{lib.version});
    try out.writeAll("========================\n\n");

    const config = lib.Config{
        .debug = true,
        .max_retries = 5,
        .timeout_ms = 10_000,
    };
    try lib.init(config);

    try out.print(
        "Initialised with debug={}, max_retries={d}, timeout_ms={d}.\n",
        .{ config.debug, config.max_retries, config.timeout_ms },
    );
    try out.writeAll("Example completed successfully!\n");
    try out.flush();
}
