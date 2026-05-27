// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Allocator wrapper that counts calls, bytes, and peak live bytes.
//!
//! Lifted out of the original framework.zig as part of Q-CPLX-005.
//! Not thread-safe; pass per-iteration instances.

const std = @import("std");

/// Wraps another allocator, counting calls and live bytes. Use when you
/// want per-iteration allocation totals attached to results. Not
/// thread-safe; pass per-iteration instances.
pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live: u64 = 0,

    pub fn init(backing: std.mem.Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.alloc_count += 1;
            self.alloc_bytes += len;
            self.live_bytes += len;
            if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
        }
        return result;
    }

    fn resize(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            const old_len = buf.len;
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.alloc_bytes += delta;
                self.live_bytes += delta;
                if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
            } else {
                self.live_bytes -= (old_len - new_len);
            }
        }
        return ok;
    }

    fn remap(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.backing.rawRemap(buf, alignment, new_len, ret_addr);
        if (result != null) {
            const old_len = buf.len;
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.alloc_bytes += delta;
                self.live_bytes += delta;
                if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
            } else {
                self.live_bytes -= (old_len - new_len);
            }
        }
        return result;
    }

    fn free(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(buf, alignment, ret_addr);
        self.live_bytes -= buf.len;
    }
};
