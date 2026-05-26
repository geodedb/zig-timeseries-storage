// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");

/// Time-series data point.
pub const Point = struct {
    ts: i64, // Unix timestamp in milliseconds
    value: i64,
};

/// Floating-point time-series point for advanced analytics.
pub const PointF64 = struct {
    ts: i64,
    value: f64,
};

/// Unique identifier for a time-series.
pub const SeriesId = u128;

/// Configuration for the time-series store.
pub const StoreConfig = struct {
    /// Directory where timeseries files are stored.
    data_dir: []const u8,

    /// Target chunk size for L0 flushes.
    max_points_per_block: usize = 4096,

    /// True to skip creating identity file if missing.
    create_identity_if_missing: bool = true,
};
