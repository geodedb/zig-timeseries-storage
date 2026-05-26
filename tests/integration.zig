// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Integration tests for timeseries-storage.
//!
//! These tests run via `zig build test-integration` and exercise the
//! library through its public module surface (the same way a downstream
//! consumer would import it). Use this file for cross-module behaviour,
//! end-to-end flows, and anything that needs a real allocator.

const std = @import("std");
const lib = @import("timeseries_storage");

test "integration: library initializes successfully" {
    try lib.init(.{});
}

test "integration: custom configuration" {
    try lib.init(.{
        .debug = true,
        .max_retries = 5,
        .timeout_ms = 60_000,
    });
}

test "integration: version is defined" {
    try std.testing.expectEqualStrings("0.1.0", lib.version);
}

test "integration: invalid configuration is rejected" {
    try std.testing.expectError(error.InvalidConfig, lib.init(.{ .max_retries = 0 }));
}
