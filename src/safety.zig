// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Defence-in-depth helpers for type-erased context pointers used by
//! thread-pool callbacks and vtable-style iterator dispatch.
//!
//! ## Why
//!
//! Several call sites in the engine and iterator code pass `*anyopaque`
//! through external interfaces (thread_pool.submit, PointIterator
//! vtable) and recover the typed pointer with
//! `@ptrCast(@alignCast(ctx))`. If the wrong pointer were ever
//! supplied — through a coding mistake during a refactor, a future
//! cross-module misuse, or a memory-safety bug elsewhere — the cast
//! would silently produce a corrupt typed pointer and the first field
//! access would either crash unpredictably or, worse, smash adjacent
//! memory.
//!
//! ## What
//!
//! Each "context-receiving" struct embeds a `magic: u32` field set to
//! a per-type compile-time constant declared as `pub const MAGIC: u32`
//! on the same struct. Callers that recover the typed pointer through
//! `castCtx` get a debug-time assertion that the recovered struct
//! really is of the expected type before any other field is touched.
//! Release builds skip the check (the cast still happens and is
//! correct when callers are not buggy); debug / safe builds get the
//! assertion.
//!
//! The check reads the `.magic` field through the typed pointer (a
//! compiler-managed offset), so it works regardless of whether Zig
//! reorders fields for alignment.
//!
//! ## Limitations
//!
//! - This is NOT a security control. An attacker with arbitrary write
//!   primitive can forge the magic value. The check defends against
//!   honest cross-type pointer mix-ups, not against malicious tampering.

const std = @import("std");

/// Per-type magic constants. Distinct values catch accidental
/// cross-type mixups (e.g. passing an Engine pointer where a
/// MergeIterator was expected).
pub const Magic = struct {
    pub const engine: u32 = 0xE0F1_C001; // "Engine context 0001"
    pub const slice_iterator: u32 = 0x5117_DEC0;
    pub const merge_iterator: u32 = 0x4E25_DEC1;
};

/// Validate that `ctx` really points at a struct of type `T` by
/// checking the `magic` field. In debug / safe builds the mismatch
/// panics with a clear message; in release-fast the check is elided.
/// Always returns the typed pointer.
///
/// Caller MUST ensure:
///   1. `T` has a `magic: u32` field (any position).
///   2. `T` declares `pub const MAGIC: u32` matching the field's
///      initialiser.
///   3. `ctx` is non-null and aligned for `T`.
pub fn castCtx(comptime T: type, ctx: *anyopaque) *T {
    const typed: *T = @ptrCast(@alignCast(ctx));
    if (std.debug.runtime_safety) {
        if (typed.magic != T.MAGIC) {
            std.debug.panic(
                "safety.castCtx: magic mismatch for {s} — got 0x{X:0>8}, expected 0x{X:0>8}. " ++
                    "This indicates a type-erased context pointer was passed across types.",
                .{ @typeName(T), typed.magic, T.MAGIC },
            );
        }
    }
    return typed;
}

test "castCtx accepts the matching magic" {
    const Good = struct {
        pub const MAGIC: u32 = Magic.engine;
        magic: u32 = MAGIC,
        payload: u32,
    };

    var g = Good{ .payload = 42 };
    const ctx: *anyopaque = &g;
    const back = castCtx(Good, ctx);
    try std.testing.expectEqual(@as(u32, 42), back.payload);
    try std.testing.expectEqual(@as(u32, Magic.engine), back.magic);
}

test "castCtx: distinct types use distinct magics" {
    try std.testing.expect(Magic.engine != Magic.slice_iterator);
    try std.testing.expect(Magic.engine != Magic.merge_iterator);
    try std.testing.expect(Magic.slice_iterator != Magic.merge_iterator);
}
