// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress tests for timeseries-storage.
//!
//! These tests run via `zig build test-stress` and are intended to
//! exercise the library under load: high iteration counts, concurrent
//! callers, large inputs, etc. They run in ReleaseFast by default
//! (ReleaseSafe under `-Dtsan`) so they finish in CI-acceptable time.
//! Replace the placeholder cases below with workload-specific stress
//! scenarios appropriate to this project.

const std = @import("std");
const lib = @import("timeseries_storage");

test "stress: repeated init/teardown cycles" {
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try lib.init(.{
            .debug = false,
            .max_retries = 1 + @as(u32, @intCast(i % 16)),
            .timeout_ms = 1 + @as(u64, @intCast(i % 1024)),
        });
    }
}
