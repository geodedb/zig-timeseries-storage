// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Read-only WAL pre-open check (SONNY-6615).
//!
//! `wal_lib.WriteAheadLog.init` scans the WAL and truncates the file at
//! the end of the last record it can decode. That is correct for a torn
//! tail, but the library cannot tell a torn tail from a WAL it cannot
//! read at all. A plaintext WAL opened with a key, an encrypted WAL
//! opened without one, or an encrypted WAL opened with the wrong key all
//! decode zero records, so the library truncated the whole file and every
//! point not yet flushed to a segment was lost.
//!
//! `check` scans the file read-only, with the same record rules as the
//! wal library's recovery scan (frame bounds, CRC32, AES-256-GCM tag,
//! inner CRC, strictly increasing LSNs), and classifies the first record
//! it cannot accept:
//!
//! - a record written in the other key mode → `WalEncryptionMismatch`;
//! - no record authenticates under the configured key → `WalAuthFailed`;
//! - valid records follow the bad one, so it is not a torn tail →
//!   `WalCorrupted` (or, with `salvage_corrupt_records`, point-in-time
//!   recovery up to the bad record, provided a valid prefix exists);
//! - nothing valid follows → torn tail; the open proceeds and the wal
//!   library truncates from the first bad record onward.
//!
//! The file is never modified here, so every error leaves it intact.
//!
//! On-disk framing (wal library, no file header; encryption is per record):
//!   plaintext: [lsn u64][payload_len u32][payload][crc32 u32]
//!   encrypted: [blob_len u32]["ZIGWALE\0"][nonce 12][tag 16][ciphertext]
//! where the ciphertext decrypts to a plaintext frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wal_lib = @import("wal");
const record = wal_lib.record;
const encryption = wal_lib.encryption;

const log = std.log.scoped(.timeseries_storage);

pub const PrecheckError = error{
    /// The WAL was written in the other key mode: a plaintext WAL opened
    /// with an encryption key, or an encrypted WAL opened without one.
    WalEncryptionMismatch,
    /// No WAL record authenticates under the configured key (wrong key).
    WalAuthFailed,
    /// A record before the end of the WAL is corrupt and valid records
    /// follow it, so it is not a torn tail.
    WalCorrupted,
};

pub const Options = struct {
    encryption_key: ?*const [32]u8 = null,
    /// Accept a corrupt record that valid records follow as the end of
    /// the log (point-in-time recovery), dropping it and everything after
    /// it. Never applies when no valid record precedes the bad one, and
    /// never applies to a key-mode mismatch or a wrong key.
    salvage_corrupt_records: bool = false,
};

pub const Report = struct {
    file_len: u64 = 0,
    /// Offset of the first byte the wal library will drop. Equal to
    /// `file_len` when the whole WAL is valid.
    valid_end: u64 = 0,
    record_count: u64 = 0,
    last_lsn: u64 = 0,
};

const PEEK = encryption.DETECT_PEEK_SIZE;
const MIN_ENCRYPTED_RECORD = encryption.ENCRYPTION_OVERHEAD + record.MIN_RECORD_SIZE;
const SCAN_WINDOW: usize = 1024 * 1024;

comptime {
    std.debug.assert(PEEK == record.HEADER_SIZE);
}

const Frame = union(enum) {
    valid: struct { lsn: u64, len: u64 },
    /// Extends past end of file.
    partial,
    /// Bad bounds, CRC, inner record, or non-monotonic LSN.
    bad,
    /// AES-GCM tag check failed.
    auth_failed,
    /// A well-formed record of the other key mode.
    foreign,
};

const Mode = enum { plaintext, encrypted };

const Scanner = struct {
    allocator: Allocator,
    file: std.Io.File,
    file_len: u64,
    key: ?*const [32]u8,
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *Scanner) void {
        encryption.secureZero(self.buf.allocatedSlice());
        self.buf.deinit(self.allocator);
    }

    fn readExact(self: *Scanner, off: u64, len: usize) ![]u8 {
        try self.buf.resize(self.allocator, len);
        const io = std.Io.Threaded.global_single_threaded.io();
        const n = try self.file.readPositionalAll(io, self.buf.items, off);
        if (n != len) return error.UnexpectedEndOfFile;
        return self.buf.items;
    }

    /// Plaintext frame size from its header, or null if out of bounds.
    fn plaintextSize(self: *const Scanner, off: u64, header: *const [PEEK]u8) ?u64 {
        const payload_len = std.mem.readInt(u32, header[8..12], .little);
        const size = @as(u64, record.MIN_RECORD_SIZE) + payload_len;
        if (size > record.MAX_RECORD_SIZE) return null;
        if (size > self.file_len - off) return null;
        return size;
    }

    /// Encrypted frame size from its header, or null if out of bounds.
    fn encryptedSize(self: *const Scanner, off: u64, header: *const [PEEK]u8) ?u64 {
        const blob_len = std.mem.readInt(u32, header[0..4], .little);
        const size = @as(u64, encryption.BLOB_LEN_SIZE) + blob_len;
        if (size < MIN_ENCRYPTED_RECORD or size > record.MAX_RECORD_SIZE) return null;
        if (size > self.file_len - off) return null;
        return size;
    }

    fn plaintextValid(self: *Scanner, off: u64, size: u64) !?u64 {
        const bytes = try self.readExact(off, @intCast(size));
        const rec = record.deserialize(bytes) catch return null;
        return rec.lsn;
    }

    const Decrypted = union(enum) { lsn: u64, auth_failed, bad };

    fn decryptAt(self: *Scanner, off: u64, size: u64) !Decrypted {
        const key = self.key orelse unreachable;
        const bytes = try self.readExact(off, @intCast(size));
        defer encryption.secureZero(bytes);
        const plaintext = encryption.decryptRecordInPlace(key, bytes) catch |err| return switch (err) {
            error.DecryptionFailed => .auth_failed,
            else => .bad,
        };
        const rec = record.deserialize(plaintext) catch return .bad;
        return .{ .lsn = rec.lsn };
    }

    /// Decode the frame at `off` in the configured key mode.
    fn frameAt(self: *Scanner, off: u64) !Frame {
        if (self.file_len - off < PEEK) return .partial;
        const io = std.Io.Threaded.global_single_threaded.io();
        var header: [PEEK]u8 = undefined;
        if (try self.file.readPositionalAll(io, &header, off) != PEEK) return .partial;
        const has_magic = encryption.isEncrypted(&header);

        if (self.key == null) {
            if (has_magic) return if (self.encryptedSize(off, &header) != null) .foreign else .bad;
            const payload_len = std.mem.readInt(u32, header[8..12], .little);
            const claimed = @as(u64, record.MIN_RECORD_SIZE) + payload_len;
            if (claimed > record.MAX_RECORD_SIZE) return .bad;
            if (claimed > self.file_len - off) return .partial;
            const lsn = try self.plaintextValid(off, claimed) orelse return .bad;
            return .{ .valid = .{ .lsn = lsn, .len = claimed } };
        }

        if (!has_magic) {
            // SEC-0038: the wal library rejects plaintext frames under a
            // key. A CRC-valid one means the WAL is plaintext.
            const size = self.plaintextSize(off, &header) orelse return .bad;
            return if (try self.plaintextValid(off, size) != null) .foreign else .bad;
        }
        const blob_len = std.mem.readInt(u32, header[0..4], .little);
        const claimed = @as(u64, encryption.BLOB_LEN_SIZE) + blob_len;
        if (claimed < MIN_ENCRYPTED_RECORD or claimed > record.MAX_RECORD_SIZE) return .bad;
        if (claimed > self.file_len - off) return .partial;
        return switch (try self.decryptAt(off, claimed)) {
            .lsn => |lsn| .{ .valid = .{ .lsn = lsn, .len = claimed } },
            .auth_failed => .auth_failed,
            .bad => .bad,
        };
    }

    /// Search `(from, file_len)` for a record that is valid in `mode`.
    /// Plaintext candidates must carry an LSN in `(min_lsn, max_lsn]`.
    /// Encrypted candidates are authenticated when a key is configured,
    /// and accepted on magic plus in-bounds length when it is not.
    fn validRecordAfter(self: *Scanner, from: u64, mode: Mode, min_lsn: u64, max_lsn: u64) !bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        const window = try self.allocator.alloc(u8, SCAN_WINDOW);
        defer self.allocator.free(window);

        var win_start: u64 = from + 1;
        while (win_start + PEEK <= self.file_len) {
            const want: usize = @intCast(@min(@as(u64, SCAN_WINDOW), self.file_len - win_start));
            const got = try self.file.readPositionalAll(io, window[0..want], win_start);
            if (got < PEEK) return false;

            var i: usize = 0;
            while (i + PEEK <= got) : (i += 1) {
                const p = win_start + i;
                const header: *const [PEEK]u8 = window[i..][0..PEEK];
                switch (mode) {
                    .encrypted => {
                        if (!encryption.isEncrypted(header)) continue;
                        const size = self.encryptedSize(p, header) orelse continue;
                        if (self.key == null) return true;
                        if (try self.decryptAt(p, size) == .lsn) return true;
                    },
                    .plaintext => {
                        const lsn = std.mem.readInt(u64, header[0..8], .little);
                        if (lsn <= min_lsn or lsn > max_lsn) continue;
                        const size = self.plaintextSize(p, header) orelse continue;
                        if (try self.plaintextValid(p, size) != null) return true;
                    },
                }
            }
            // Overlap windows by PEEK-1 bytes so no header straddles a seam.
            win_start += got - (PEEK - 1);
        }
        return false;
    }
};

/// Scan `dir/filename` read-only and decide whether it is safe to hand it
/// to `wal_lib.WriteAheadLog.init`. Returns the expected recovery outcome
/// on success; a missing file is an empty WAL.
pub fn check(allocator: Allocator, dir: std.Io.Dir, filename: []const u8, opts: Options) !Report {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = dir.openFile(io, filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(io);

    var scanner = Scanner{
        .allocator = allocator,
        .file = file,
        .file_len = try file.length(io),
        .key = opts.encryption_key,
    };
    defer scanner.deinit();

    var report = Report{ .file_len = scanner.file_len };
    while (report.valid_end < report.file_len) {
        const frame = try scanner.frameAt(report.valid_end);
        switch (frame) {
            .valid => |v| {
                // SEC-0022: the wal library stops at a non-monotonic LSN.
                if (report.record_count == 0 or v.lsn > report.last_lsn) {
                    report.record_count += 1;
                    report.last_lsn = v.lsn;
                    report.valid_end += v.len;
                    continue;
                }
            },
            .foreign => return error.WalEncryptionMismatch,
            .partial, .bad, .auth_failed => {},
        }
        try classifyBadRecord(&scanner, &report, frame == .auth_failed, opts);
        return report;
    }
    return report;
}

/// The record at `report.valid_end` cannot be accepted. Return an error,
/// or leave `report` describing a truncation the caller may allow.
fn classifyBadRecord(scanner: *Scanner, report: *const Report, auth_failed: bool, opts: Options) !void {
    const bad_at = report.valid_end;
    const own: Mode = if (scanner.key != null) .encrypted else .plaintext;
    const other: Mode = if (scanner.key != null) .plaintext else .encrypted;

    // LSNs are dense within one WAL, so a genuine successor's LSN lies
    // within (last_lsn, last_lsn + records that fit in the rest]. With no
    // valid prefix there is no anchor and only LSN 0 is excluded.
    const rest_records = (report.file_len - bad_at) / record.MIN_RECORD_SIZE + 1;
    const own_max = if (report.record_count > 0) report.last_lsn +| rest_records else std.math.maxInt(u64);

    if (try scanner.validRecordAfter(bad_at, own, report.last_lsn, own_max)) {
        if (opts.salvage_corrupt_records and report.record_count > 0) {
            log.warn(
                "ts.wal: corrupt record at byte {d} with valid records after it; salvage keeps {d} record(s) up to LSN {d} and drops {d} byte(s)",
                .{ bad_at, report.record_count, report.last_lsn, report.file_len - bad_at },
            );
            return;
        }
        log.warn(
            "ts.wal: corrupt record at byte {d} of {d} with valid records after it; refusing to truncate ({d} valid record(s) precede it)",
            .{ bad_at, report.file_len, report.record_count },
        );
        return error.WalCorrupted;
    }

    if (report.record_count == 0) {
        if (try scanner.validRecordAfter(bad_at, other, 0, std.math.maxInt(u64))) {
            return error.WalEncryptionMismatch;
        }
        // Nothing authenticates under this key. A wrong key and a WAL
        // whose only complete record is damaged look the same; keep the
        // file either way.
        if (auth_failed) return error.WalAuthFailed;
    }

    log.warn(
        "ts.wal: torn tail at byte {d}; keeping {d} record(s) up to LSN {d}, dropping {d} trailing byte(s)",
        .{ bad_at, report.record_count, report.last_lsn, report.file_len - bad_at },
    );
}

// ---------------------------------------------------------------------------
// Tests. Engine-level coverage lives in tests/wal_open_safety.zig; these
// pin scanner branches that are awkward to reach through the Engine.
// ---------------------------------------------------------------------------

const testing = std.testing;
const TEST_KEY: [32]u8 = [_]u8{0x3C} ** 32;

fn writeTestWal(dir: std.Io.Dir, key: ?[32]u8, payloads: []const []const u8) !void {
    var wal = try wal_lib.WriteAheadLog.init(testing.allocator, dir, "t.wal", .{ .encryption_key = key });
    defer wal.deinit();
    for (payloads) |p| _ = try wal.append(p);
}

fn readTestWal(dir: std.Io.Dir) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return dir.readFileAlloc(io, "t.wal", testing.allocator, .unlimited);
}

fn writeRaw(dir: std.Io.Dir, bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.writeFile(io, .{ .sub_path = "t.wal", .data = bytes });
}

test "wal_precheck: missing file is an empty WAL" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const report = try check(testing.allocator, tmp.dir, "t.wal", .{});
    try testing.expectEqual(@as(u64, 0), report.file_len);
    try testing.expectEqual(@as(u64, 0), report.record_count);
}

test "wal_precheck: corrupt record found across a scan-window seam is mid-log" {
    // Record 2 is ~1 MiB, so record 3's header straddles the first scan
    // window's end. The overlap must still find it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const big = try testing.allocator.alloc(u8, SCAN_WINDOW - 20);
    defer testing.allocator.free(big);
    @memset(big, 0x61);
    try writeTestWal(tmp.dir, null, &.{ "first", big, "third" });

    const bytes = try readTestWal(tmp.dir);
    defer testing.allocator.free(bytes);
    const rec2 = record.MIN_RECORD_SIZE + "first".len;
    bytes[rec2 + record.HEADER_SIZE + 10] ^= 0xFF;
    try writeRaw(tmp.dir, bytes);

    const rec3 = rec2 + record.MIN_RECORD_SIZE + big.len;
    try testing.expect(rec3 < rec2 + 1 + SCAN_WINDOW);
    try testing.expect(rec3 + PEEK > rec2 + 1 + SCAN_WINDOW);

    try testing.expectError(error.WalCorrupted, check(testing.allocator, tmp.dir, "t.wal", .{}));

    const salvaged = try check(testing.allocator, tmp.dir, "t.wal", .{ .salvage_corrupt_records = true });
    try testing.expectEqual(@as(u64, rec2), salvaged.valid_end);
    try testing.expectEqual(@as(u64, 1), salvaged.record_count);
}

test "wal_precheck: non-monotonic LSN at the end is a torn tail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestWal(tmp.dir, null, &.{ "a", "b" });

    const good = try readTestWal(tmp.dir);
    defer testing.allocator.free(good);
    var stale: [record.MIN_RECORD_SIZE + 1]u8 = undefined;
    record.serializeInto(&stale, 1, "c");
    const bytes = try std.mem.concat(testing.allocator, u8, &.{ good, &stale });
    defer testing.allocator.free(bytes);
    try writeRaw(tmp.dir, bytes);

    const report = try check(testing.allocator, tmp.dir, "t.wal", .{});
    try testing.expectEqual(@as(u64, good.len), report.valid_end);
    try testing.expectEqual(@as(u64, 2), report.last_lsn);
}

test "wal_precheck: plaintext frame after encrypted records is a mismatch, not a tail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestWal(tmp.dir, TEST_KEY, &.{ "a", "b" });

    const good = try readTestWal(tmp.dir);
    defer testing.allocator.free(good);
    var injected: [record.MIN_RECORD_SIZE + 1]u8 = undefined;
    record.serializeInto(&injected, 3, "c");
    const bytes = try std.mem.concat(testing.allocator, u8, &.{ good, &injected });
    defer testing.allocator.free(bytes);
    try writeRaw(tmp.dir, bytes);

    try testing.expectError(error.WalEncryptionMismatch, check(testing.allocator, tmp.dir, "t.wal", .{ .encryption_key = &TEST_KEY }));
}

test "wal_precheck: partial first record with nothing else is a torn tail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestWal(tmp.dir, TEST_KEY, &.{"only"});
    const bytes = try readTestWal(tmp.dir);
    defer testing.allocator.free(bytes);
    try writeRaw(tmp.dir, bytes[0 .. bytes.len - 3]);

    const report = try check(testing.allocator, tmp.dir, "t.wal", .{ .encryption_key = &TEST_KEY });
    try testing.expectEqual(@as(u64, 0), report.valid_end);
    try testing.expectEqual(@as(u64, 0), report.record_count);
}
