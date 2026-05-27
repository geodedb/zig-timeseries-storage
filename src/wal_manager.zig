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
///
/// ## Concurrency (P-LOCK-005 partial)
///
/// State-mutating methods (`appendRecord`, `sync`, `truncate`) and the
/// read accessors (`currentLsn`, `bytesSinceCompact`, `readFrom`,
/// `forEachFrom*`) take `mu` internally. Today this is redundant —
/// the engine already serialises every WAL touch through `Engine.mu`,
/// so `mu` is uncontended in practice. The infrastructure exists so a
/// future per-shard memtable change can drop `Engine.mu` around the
/// `wal.appendRecord` + memtable insert pair without introducing a
/// lost-update race on `current_lsn` or the underlying WAL file
/// handle. See `docs/PERF_GAP_ANALYSIS.md` P-LOCK-001 / P-LOCK-005.
pub const WalManager = struct {
    allocator: Allocator,
    inner: wal_lib.WriteAheadLog,
    current_lsn: u64,
    /// Internal mutex serialising state-mutating ops (`appendRecord`,
    /// `sync`, `truncate`) and read accessors. By itself this changes
    /// nothing observable today — `Engine.mu` is held across every
    /// WAL touch. It is the prerequisite for releasing `Engine.mu`
    /// around the WAL+memtable phase in a future per-shard memtable
    /// change without creating a lost-update race on `current_lsn`
    /// or the WAL file handle.
    ///
    /// `std.Io.Mutex` to match the rest of the storage engine; the
    /// `io` handle is fetched internally from
    /// `std.Io.Threaded.global_single_threaded` so the public WAL
    /// API stays unchanged. Recursion is avoided via the internal
    /// `*Locked` helpers (e.g. `syncLocked`); public methods take
    /// the lock and delegate.
    mu: std.Io.Mutex = std.Io.Mutex.init,

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

    /// Append a serialised record to the WAL and return its LSN.
    ///
    /// Concurrency: takes `self.mu`. Safe to call concurrently with
    /// other `WalManager` methods.
    pub fn appendRecord(self: *WalManager, record: *WalRecord) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.appendRecordLocked(record);
    }

    /// Mutex-held variant of `appendRecord`. Caller MUST hold
    /// `self.mu`. Exists so future intra-manager call sites can
    /// chain without re-acquiring the lock.
    fn appendRecordLocked(self: *WalManager, record: *WalRecord) !u64 {
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

    /// Force an fsync against the underlying WAL file.
    ///
    /// Concurrency: takes `self.mu`. Safe to call concurrently with
    /// other `WalManager` methods.
    pub fn sync(self: *WalManager) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.syncLocked();
    }

    /// Mutex-held variant of `sync`. Caller MUST hold `self.mu`.
    fn syncLocked(self: *WalManager) !void {
        try self.inner.sync();
    }

    pub fn readFrom(self: *WalManager, start_lsn: u64, allocator: Allocator) ![]WalRecord {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

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
        // The mutex is held across the whole iteration. In practice
        // this is recovery-only (single-threaded), but a defensive
        // lock here is cheap and prevents a concurrent appendRecord
        // from mutating the WAL underneath the iterator.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

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
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

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

    /// Compact the WAL up to and including `up_to_lsn`.
    ///
    /// Concurrency: takes `self.mu`. Safe to call concurrently with
    /// other `WalManager` methods.
    pub fn truncate(self: *WalManager, up_to_lsn: u64) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.truncateLocked(up_to_lsn);
    }

    /// Mutex-held variant of `truncate`. Caller MUST hold `self.mu`.
    fn truncateLocked(self: *WalManager, up_to_lsn: u64) !void {
        try self.inner.compact(up_to_lsn);
    }

    /// Returns a snapshot of the WAL's current LSN. The value can be
    /// stale immediately on return if another thread is appending.
    pub fn currentLsn(self: *WalManager) u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.inner.currentLsn();
    }

    /// Returns a snapshot of the bytes appended since the last
    /// compaction. The value can be stale immediately on return if
    /// another thread is appending or truncating.
    pub fn bytesSinceCompact(self: *WalManager) u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
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
