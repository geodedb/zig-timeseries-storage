// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const wal_lib = @import("wal");
const wal_record = @import("wal_record.zig");
const WalRecord = wal_record.WalRecord;
const TS_IDENTITY_FILE = "ts.uuid";

/// Errors specific to WAL recovery and integrity checks. Module
/// functions that can ALSO fail with allocator or file-system errors
/// keep an inferred error set (`!T`) so they pick up the underlying
/// errors automatically. This set is used for tests and for callers
/// that need to discriminate WAL-specific failures from generic IO.
pub const WalError = error{
    /// `WalRecord.deserialize` could not parse a record (length
    /// mismatch, invalid enum tag, etc.).
    InvalidFormat,
    /// CRC32C mismatch between stored and computed inner checksums
    /// during strict recovery.
    ChecksumMismatch,
    /// The WAL identity file (`ts.uuid`) on disk does not match the
    /// engine's expected UUID.
    UuidMismatch,
    /// A record's payload length exceeded `MAX_WAL_PAYLOAD`.
    WalRecordTooLarge,
};

/// Configuration for the WAL manager.
pub const WalConfig = struct {
    encryption_key: ?[32]u8 = null,
    create_identity_if_missing: bool = true,
};

pub const ReplayFailureKind = enum {
    deserialize_failed,
    checksum_mismatch,
};

pub const ReplayFailure = struct {
    artifact: []const u8 = "wal/ts.wal",
    lsn: u64,
    kind: ReplayFailureKind,
};

/// Manages WAL record persistence by delegating append-only storage to
/// the external wal library (gitlab.com/devnw/zig/wal).
///
/// ## Durability semantics
///
/// The underlying `wal_lib.WriteAheadLog` is opened with `manual_sync =
/// true`, so `appendRecord` does NOT issue an fsync — it just writes
/// the serialised record into the WAL's page cache and returns the
/// assigned LSN. Durability requires a separate, explicit `sync()`
/// call (delegated to `wal_lib.WriteAheadLog.sync`, which issues the
/// fsync against the underlying file).
///
/// This is intentional: the engine batches multiple `appendRecord`
/// calls and issues a single `sync()` at commit time (during `flush()`
/// and `Engine.sync()`), amortising the fsync cost across many
/// appends. Callers who want every record durable on disk before
/// `appendRecord` returns must invoke `sync()` immediately after.
///
/// On `appendRecord` the manager allocates a serialised buffer either
/// on the stack (records ≤ 16 KiB) or on the heap, computes the
/// CRC32C checksum, hands the slice to the WAL library, and returns
/// the LSN the WAL assigned. The LSN is monotonically increasing
/// across all appends.
pub const WalManager = struct {
    allocator: Allocator,
    inner: wal_lib.WriteAheadLog,
    current_lsn: u64,

    pub fn init(
        allocator: Allocator,
        wal_dir: std.Io.Dir,
        ts_uuid: [16]u8,
        start_lsn: u64,
        config: WalConfig,
    ) !WalManager {
        try ensureTsIdentity(wal_dir, ts_uuid, config.create_identity_if_missing);

        const inner = try wal_lib.WriteAheadLog.init(allocator, wal_dir, "ts.wal", .{
            .encryption_key = config.encryption_key,
            .manual_sync = true,
            .checkpoint = true,
        });

        return WalManager{
            .allocator = allocator,
            .inner = inner,
            .current_lsn = start_lsn,
        };
    }

    pub fn deinit(self: *WalManager) void {
        self.inner.deinit();
    }

    const STACK_BUF_SIZE: usize = 16 * 1024;

    pub fn appendRecord(self: *WalManager, record: *WalRecord) !u64 {
        self.current_lsn += 1;
        record.lsn = self.current_lsn;

        const needed = record.serializedSize();

        if (needed <= STACK_BUF_SIZE) {
            var buf: [STACK_BUF_SIZE]u8 = undefined;
            const n = try record.serializeInto(&buf);
            return try self.inner.append(buf[0..n]);
        } else {
            const buf = try self.allocator.alloc(u8, needed);
            defer self.allocator.free(buf);
            const n = try record.serializeInto(buf);
            return try self.inner.append(buf[0..n]);
        }
    }

    pub fn sync(self: *WalManager) !void {
        try self.inner.sync();
    }

    pub fn readFrom(self: *WalManager, start_lsn: u64, allocator: Allocator) ![]WalRecord {
        var all_records: std.ArrayList(WalRecord) = .empty;
        errdefer {
            for (all_records.items) |*r| r.deinit(allocator);
            all_records.deinit(allocator);
        }

        const iter_from = if (start_lsn > 0) start_lsn - 1 else 0;
        var iter = try self.inner.iterator(iter_from);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch continue;

            if (result.record.lsn >= start_lsn) {
                try all_records.append(allocator, result.record);
            } else {
                result.record.deinit(allocator);
            }
        }

        return all_records.toOwnedSlice(allocator);
    }

    pub fn forEachFrom(
        self: *WalManager,
        start_lsn: u64,
        allocator: Allocator,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), *const WalRecord) anyerror!void,
    ) !void {
        const iter_from = if (start_lsn > 0) start_lsn - 1 else 0;
        var iter = try self.inner.iterator(iter_from);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch continue;
            defer result.record.deinit(allocator);

            if (result.record.lsn >= start_lsn) {
                try callback(ctx, &result.record);
            }
        }
    }

    pub fn forEachFromStrict(
        self: *WalManager,
        start_lsn: u64,
        allocator: Allocator,
        failure: *?ReplayFailure,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), *const WalRecord) anyerror!void,
    ) !void {
        failure.* = null;

        const iter_from = if (start_lsn > 0) start_lsn - 1 else 0;
        var iter = try self.inner.iterator(iter_from);
        defer iter.deinit();

        while (try iter.next()) |entry_val| {
            var entry = entry_val;
            defer entry.deinit();

            const result = WalRecord.deserialize(allocator, entry.payload) catch {
                failure.* = .{
                    .lsn = entry.lsn,
                    .kind = .deserialize_failed,
                };
                return error.InvalidFormat;
            };
            defer result.record.deinit(allocator);

            if (result.record.checksum != result.record.computeChecksum()) {
                failure.* = .{
                    .lsn = result.record.lsn,
                    .kind = .checksum_mismatch,
                };
                return error.ChecksumMismatch;
            }

            if (result.record.lsn >= start_lsn) {
                try callback(ctx, &result.record);
            }
        }
    }

    pub fn truncate(self: *WalManager, up_to_lsn: u64) !void {
        try self.inner.compact(up_to_lsn);
    }

    pub fn currentLsn(self: *WalManager) u64 {
        return self.inner.currentLsn();
    }

    pub fn bytesSinceCompact(self: *WalManager) u64 {
        return self.inner.bytesSinceCompact();
    }
};

fn ensureTsIdentity(wal_dir: std.Io.Dir, ts_uuid: [16]u8, create_if_missing: bool) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = wal_dir.openFile(io, TS_IDENTITY_FILE, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => if (!create_if_missing) {
            return error.FileNotFound;
        } else blk: {
            const new_file = try wal_dir.createFile(io, TS_IDENTITY_FILE, .{ .read = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
            break :blk new_file;
        },
        else => return err,
    };
    defer file.close(io);

    var stored_uuid: [16]u8 = undefined;
    const bytes_read = try file.readPositionalAll(io, &stored_uuid, 0);
    if (bytes_read == 0) {
        try file.writePositionalAll(io, &ts_uuid, 0);
        try file.sync(io);
        return;
    }
    if (bytes_read != stored_uuid.len) return error.InvalidData;
    if (!std.mem.eql(u8, &stored_uuid, &ts_uuid)) return error.UuidMismatch;
}

test "append records, sync, read back" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const uuid = [_]u8{0xAA} ** 16;

    var mgr = try WalManager.init(allocator, tmp_dir.dir, uuid, 0, .{});
    defer mgr.deinit();

    var rec1 = WalRecord{
        .lsn = 0,
        .record_type = .checkpoint_marker,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    const lsn1 = try mgr.appendRecord(&rec1);
    try std.testing.expect(lsn1 > 0);

    const payload = "page content";
    var rec2 = WalRecord{
        .lsn = 0,
        .record_type = .append_points,
        .payload = payload,
        .checksum = 0,
    };
    const lsn2 = try mgr.appendRecord(&rec2);
    try std.testing.expect(lsn2 > lsn1);

    try mgr.sync();

    const records = try mgr.readFrom(1, allocator);
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(@as(u64, 1), records[0].lsn);
    try std.testing.expectEqual(wal_record.WalRecordType.checkpoint_marker, records[0].record_type);
    try std.testing.expectEqual(@as(u64, 2), records[1].lsn);
    try std.testing.expectEqualStrings(payload, records[1].payload);
}
