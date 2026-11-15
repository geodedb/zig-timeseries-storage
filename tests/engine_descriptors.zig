// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! An Engine releases every descriptor it opens in its data directory
//! (SONNY-6623 item 4).
//!
//! `Engine.init` opened `data_dir` as the WAL directory and handed it to
//! the wal library, which does not own it; neither `Engine.deinit` nor
//! `init`'s error path closed it, so every engine left one descriptor on
//! its data directory for the life of the process. An embedder that checks
//! for live holders of a data directory (geode's offline CLI guard) then
//! saw a closed engine as a holder.
//!
//! The check reads `/proc/self/fd`, so it runs on Linux only.
//!
//! Pulled into `zig build test-integration` from `integration.zig`.

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Number of this process's descriptors that refer to `data_dir` itself
/// or to anything inside it.
fn descriptorsIn(data_dir: []const u8) !usize {
    var fd_dir = try std.Io.Dir.cwd().openDir(io(), "/proc/self/fd", .{ .iterate = true });
    defer fd_dir.close(io());

    var count: usize = 0;
    var it = fd_dir.iterate();
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next(io())) |entry| {
        // The iterator's own descriptor can vanish between list and read.
        const n = fd_dir.readLink(io(), entry.name, &target_buf) catch continue;
        const target = target_buf[0..n];
        if (std.mem.eql(u8, target, data_dir)) {
            count += 1;
        } else if (std.mem.startsWith(u8, target, data_dir) and target.len > data_dir.len and target[data_dir.len] == '/') {
            count += 1;
        }
    }
    return count;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,

    /// The data directory is a child of the tmp dir, so the tmp dir's own
    /// open handle is not counted.
    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io(), "data");
        const root = try tmp.dir.realPathFileAlloc(io(), ".", allocator);
        defer allocator.free(root);
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root});
        return .{ .tmp = tmp, .data_dir = data_dir };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

fn openAppendClose(allocator: std.mem.Allocator, data_dir: []const u8, key: ?[32]u8, pool: *thread_pool.ThreadPool) !void {
    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = key,
    }, pool);
    defer eng.deinit();
    try eng.appendPoints(3, &.{.{ .ts = 1, .value = 1 }});
    try std.testing.expect(try descriptorsIn(data_dir) > 0);
}

test "engine descriptors: open + deinit leaves no descriptor in the data dir" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), try descriptorsIn(fx.data_dir));
    for ([_]?[32]u8{ null, null, [_]u8{0x21} ** 32 }, 0..) |key, round| {
        // Fresh dir for the keyed round so the modes never mix.
        if (round == 2) {
            try fx.tmp.dir.createDirPath(io(), "data/keyed");
            const keyed = try std.fmt.allocPrint(allocator, "{s}/keyed", .{fx.data_dir});
            defer allocator.free(keyed);
            try openAppendClose(allocator, keyed, key, &pool);
        } else {
            try openAppendClose(allocator, fx.data_dir, key, &pool);
        }
        try std.testing.expectEqual(@as(usize, 0), try descriptorsIn(fx.data_dir));
    }
}

test "engine descriptors: a failed Engine.init leaves no descriptor in the data dir" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Plaintext WAL with points and no manifest, then open it with a key:
    // the WAL open fails after the WAL directory handle was taken.
    try openAppendClose(allocator, fx.data_dir, null, &pool);
    try std.testing.expectEqual(@as(usize, 0), try descriptorsIn(fx.data_dir));

    try std.testing.expectError(error.WalEncryptionMismatch, lib.Engine.init(allocator, .{
        .data_dir = fx.data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = [_]u8{0x42} ** 32,
    }, &pool));
    try std.testing.expectEqual(@as(usize, 0), try descriptorsIn(fx.data_dir));
}
