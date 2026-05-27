// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! # timeseries-storage
//!
//! An embedded LSM-style time-series storage engine. Every mutation is
//! first appended to a CRC32C-protected write-ahead log and inserted
//! into an in-memory memtable; when the memtable hits its point
//! threshold it is rotated and a background worker flushes it to an
//! immutable on-disk segment file. Background compaction merges
//! level-0 segments into larger level-1 segments to keep read
//! amplification bounded. Per-block payloads are encoded with Gorilla
//! (delta-of-delta on timestamps, XOR on values) for compact storage
//! and fast scans.
//!
//! The public surface is exposed as Zig sub-modules (`engine`,
//! `segment`, `wal_manager`, `manifest`, `memtable`, `iterator`,
//! `compaction`, `encoding/gorilla`, `types`); see
//! [docs/ts-storage-spec.md](../docs/ts-storage-spec.md) for the
//! on-disk format and [README.md](../README.md) for a Quick Start.
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

/// Library version. Keep in sync with build.zig.zon.
pub const version: []const u8 = "0.1.0";

pub const types = @import("types.zig");
pub const limits = @import("limits.zig");
pub const gorilla = @import("encoding/gorilla.zig");
pub const segment = @import("segment.zig");
pub const wal_record = @import("wal_record.zig");
pub const wal_manager = @import("wal_manager.zig");
pub const manifest = @import("manifest.zig");
pub const memtable = @import("memtable.zig");
pub const iterator = @import("iterator.zig");
pub const compaction = @import("compaction.zig");
pub const engine = @import("engine.zig");
pub const backup = @import("backup.zig");
pub const safety = @import("safety.zig");

// ============================================================================
// Re-exports — primary public API.
// ============================================================================

/// Top-level engine type. Construct with `Engine.init(allocator, config, &pool)`.
pub const Engine = engine.Engine;
/// Canonical engine configuration. See `engine.EngineConfig` for fields.
pub const EngineConfig = engine.EngineConfig;
/// Backwards-compatible alias for `EngineConfig`. New code should use `EngineConfig`.
pub const Config = engine.EngineConfig;

// ============================================================================
// Re-exports — named error sets. Most engine APIs still return inferred
// error sets (`!T`) since their union with allocator/filesystem errors
// is broad; these named sets are exposed for callers and tests that
// want to discriminate timeseries-storage failures from generic IO.
// ============================================================================

pub const WalError = wal_manager.WalError;
pub const SegmentError = segment.SegmentError;
pub const ManifestError = manifest.ManifestError;
pub const EngineError = engine.EngineError;

// ============================================================================
// Unit Tests
// ============================================================================

test {
    std.testing.refAllDecls(@This());
}

test "root: named error sets are reachable and well-formed" {
    // Spot-check the exposed named error sets so a future rename of
    // a tag inside a sub-module breaks at the boundary instead of
    // silently dropping a public API surface.
    const we: WalError = error.InvalidFormat;
    try std.testing.expect(we == error.InvalidFormat);

    const se: SegmentError = error.InvalidMagic;
    try std.testing.expect(se == error.InvalidMagic);

    const me: ManifestError = error.ChecksumMismatch;
    try std.testing.expect(me == error.ChecksumMismatch);

    const ee: EngineError = error.SegmentFileMissing;
    try std.testing.expect(ee == error.SegmentFileMissing);

    // The unioned EngineError must include every constituent set.
    const inherited_wal: EngineError = error.UuidMismatch;
    try std.testing.expect(inherited_wal == error.UuidMismatch);
    const inherited_seg: EngineError = error.BlockTooLarge;
    try std.testing.expect(inherited_seg == error.BlockTooLarge);
    const inherited_man: EngineError = error.ManifestTooLarge;
    try std.testing.expect(inherited_man == error.ManifestTooLarge);
}
