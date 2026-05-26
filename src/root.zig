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
pub const gorilla = @import("encoding/gorilla.zig");
pub const segment = @import("segment.zig");
pub const wal_record = @import("wal_record.zig");
pub const wal_manager = @import("wal_manager.zig");
pub const manifest = @import("manifest.zig");
pub const memtable = @import("memtable.zig");
pub const iterator = @import("iterator.zig");
pub const compaction = @import("compaction.zig");
pub const engine = @import("engine.zig");

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
// Unit Tests
// ============================================================================

test {
    std.testing.refAllDecls(@This());
}
