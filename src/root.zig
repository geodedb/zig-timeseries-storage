// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! # timeseries-storage
//!
//! A Zig library for timeseries-storage
//!
//! ## Features
//!
//! - Feature 1
//! - Feature 2
//! - Feature 3
//!
//! ## Quick Start
//!
//! ```zig
//! const timeseries_storage = @import("timeseries_storage");
//!
//! pub fn main() !void {
//!     try timeseries_storage.init(.{});
//! }
//! ```
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

/// Library version. Keep in sync with build.zig.zon.
pub const version: []const u8 = "0.1.0";

// Re-export submodules here as the library grows:
// pub const submodule = @import("submodule.zig");

// ============================================================================
// Public Types
// ============================================================================

/// Example configuration structure.
pub const Config = struct {
    /// Enable debug output.
    debug: bool = false,
    /// Maximum retry attempts.
    max_retries: u32 = 3,
    /// Timeout in milliseconds.
    timeout_ms: u64 = 30_000,
};

// ============================================================================
// Public Functions
// ============================================================================

/// Initialize the library with the given configuration.
///
/// Returns an error if the configuration is invalid.
pub fn init(config: Config) !void {
    if (config.max_retries == 0) return error.InvalidConfig;
    if (config.timeout_ms == 0) return error.InvalidConfig;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Config default values" {
    const config = Config{};
    try std.testing.expectEqual(false, config.debug);
    try std.testing.expectEqual(@as(u32, 3), config.max_retries);
    try std.testing.expectEqual(@as(u64, 30_000), config.timeout_ms);
}

test "init with default config" {
    try init(.{});
}

test "init rejects zero max_retries" {
    try std.testing.expectError(error.InvalidConfig, init(.{ .max_retries = 0 }));
}

test "init rejects zero timeout" {
    try std.testing.expectError(error.InvalidConfig, init(.{ .timeout_ms = 0 }));
}

test {
    std.testing.refAllDecls(@This());
}
