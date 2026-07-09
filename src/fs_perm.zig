// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Cross-platform "owner-only" file permissions for on-disk data files
//! (WAL segments, manifests, migration temp files, iterator scratch
//! files).
//!
//! `std.Io.File.Permissions` is a different concrete type per target:
//! on POSIX it wraps a `mode_t` and exposes `fromMode`; on Windows it
//! wraps a `DWORD` attributes bitset and has NO `fromMode` member (there
//! are no POSIX mode bits to translate). Calling `.fromMode` on the
//! Windows variant is a compile error, not a runtime one -- every call
//! site needs a target branch. Centralize it here so a single helper
//! stays correct instead of ~15 duplicated `if (windows) ... else ...`
//! blocks.
//!
//! `builtin.os.tag` is comptime-known, so the untaken branch below is
//! never semantically analyzed for the other target -- this is the
//! same zero-cost pattern `std.Io.File.Permissions` itself uses to pick
//! its underlying representation.

const std = @import("std");
const builtin = @import("builtin");

/// Returns owner-only permissions for a newly created file.
///
/// `mode` must be a comptime-known POSIX mode (e.g. `0o600`); it is
/// ignored on Windows, where `Permissions.default_file` is the closest
/// available equivalent (Windows has no per-owner POSIX mode bits --
/// access control there is ACL-based, not mode-based).
pub fn ownerOnlyMode(comptime mode: comptime_int) std.Io.File.Permissions {
    if (builtin.os.tag == .windows) {
        return .default_file;
    }
    return std.Io.File.Permissions.fromMode(@as(std.posix.mode_t, mode));
}
