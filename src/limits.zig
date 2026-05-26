// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Defensive size caps on attacker-influenced inputs.
//!
//! Every value in this module is a "refuse to allocate" gate, not a
//! tunable. The goal is to bound worst-case allocation requests
//! triggered by malformed or hostile on-disk artefacts (segments,
//! manifest, WAL) and by the public `appendPoints` API, so a single
//! crafted input cannot exhaust the process's address space (CWE-770).
//!
//! Choosing concrete numbers is necessarily a trade-off: too small
//! and legitimate workloads break, too large and the cap is useless.
//! The values here are sized for "fits comfortably in a few hundred
//! MiB working set" and are still 1-2 orders of magnitude above what
//! the steady-state engine produces. Operators who need to push past
//! one of them should raise the constant deliberately rather than
//! disable the check.

/// Maximum number of points accepted in a single `appendPoints` batch.
/// Bounds the transient payload buffer allocated in `Engine.appendPoints`
/// (currently 16 bytes per point, so this caps at ~256 KiB).
pub const MAX_APPEND_BATCH_POINTS: usize = 16_384;

/// Maximum `BlockHeader.data_len` accepted when decoding a segment
/// block. At 8 MiB any single block already represents tens of
/// thousands of Gorilla-compressed points; anything larger is almost
/// certainly malformed or hostile.
pub const MAX_BLOCK_DATA_LEN: u32 = 8 * 1024 * 1024;

/// Maximum manifest file size accepted on open. The manifest grows
/// with `segments.items.len * 25 bytes` plus a fixed 76-byte header;
/// 16 MiB leaves headroom for ~650k segments, which is well above
/// any realistic deployment.
pub const MAX_MANIFEST_SIZE: u64 = 16 * 1024 * 1024;

/// Maximum number of segments the manifest reader will allocate
/// space for. Independent of `MAX_MANIFEST_SIZE` because the header
/// value is read before the body is validated, so a crafted file
/// with a truthful size field but a lying `num_segments` could still
/// cause a huge `ensureTotalCapacity`.
pub const MAX_SEGMENTS_PER_MANIFEST: u32 = 1_000_000;

/// Absolute upper bound on the number of points the `GorillaEncoder`
/// will accept inside a single block. The internal `DynamicBitSet`
/// grows by doubling, and without a cap a pathological writer could
/// keep encoding forever and OOM the process. 65k points per block
/// is well above the steady-state flush size (a few thousand).
pub const MAX_POINTS_PER_BLOCK_ABSOLUTE: usize = 65_536;
