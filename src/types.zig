// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");

/// Time-series data point.
pub const Point = struct {
    /// Caller-chosen monotonic timestamp. The engine treats this as an
    /// opaque `i64` and does not enforce a unit: it never reads a wall
    /// clock, never converts to or from time zones, and never assumes
    /// any particular epoch. The on-disk spec (`docs/ts-storage-spec.md`)
    /// describes this field in milliseconds since the Unix epoch as a
    /// convention for interop, but any monotonically non-decreasing
    /// `i64` chosen by the caller is accepted (e.g. nanoseconds,
    /// microseconds, logical counters). Mixing units within the same
    /// series will silently break range queries, segment min/max
    /// statistics, and Gorilla delta-of-delta compression — callers are
    /// responsible for picking one unit per series and sticking to it.
    ts: i64,
    value: i64,
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
