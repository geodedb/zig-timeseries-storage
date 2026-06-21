// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

// fips-exempt: non-security — CRC32C WAL-record trailer checksum for
// corruption detection on replay; data-integrity only, not a cryptographic
// primitive (no FIPS-regulated algorithm).
const Crc32C = std.hash.crc.Crc32Iscsi;

pub const WalRecordType = enum(u8) {
    append_points = 1,
    create_series = 2,
    drop_partition = 3,
    checkpoint_marker = 4,
};

/// Header size: lsn(8) + record_type(1) + payload_len(4) = 13 bytes
/// Trailer: checksum(4)
/// Total overhead: 17 bytes
const HEADER_SIZE: usize = 13;
const CHECKSUM_SIZE: usize = 4;
const MIN_RECORD_SIZE: usize = HEADER_SIZE + CHECKSUM_SIZE;

/// Maximum WAL record payload size (1 MiB).
pub const MAX_WAL_PAYLOAD: u32 = 1024 * 1024;

/// A WAL record representing a single logged time-series operation.
pub const WalRecord = struct {
    lsn: u64,
    record_type: WalRecordType,
    payload: []const u8,
    checksum: u32,

    pub fn serializedSize(self: *const WalRecord) usize {
        return HEADER_SIZE + self.payload.len + CHECKSUM_SIZE;
    }

    pub fn serializeInto(self: *WalRecord, buf: []u8) error{BufferTooSmall}!usize {
        const total_size = self.serializedSize();
        if (buf.len < total_size) return error.BufferTooSmall;

        var hasher = Crc32C.init();
        var offset: usize = 0;

        // lsn
        const lsn_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, self.lsn));
        @memcpy(buf[offset..][0..8], &lsn_bytes);
        hasher.update(&lsn_bytes);
        offset += 8;

        // record_type
        buf[offset] = @intFromEnum(self.record_type);
        hasher.update(&[_]u8{buf[offset]});
        offset += 1;

        // payload_len
        const payload_len: u32 = @intCast(self.payload.len);
        const plen_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, payload_len));
        @memcpy(buf[offset..][0..4], &plen_bytes);
        hasher.update(&plen_bytes);
        offset += 4;

        // payload
        if (self.payload.len > 0) {
            @memcpy(buf[offset..][0..self.payload.len], self.payload);
            hasher.update(self.payload);
            offset += self.payload.len;
        }

        // checksum
        self.checksum = hasher.final();
        @memcpy(buf[offset..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, self.checksum)));
        offset += CHECKSUM_SIZE;

        return offset;
    }

    pub fn serialize(self: *WalRecord, allocator: Allocator) ![]u8 {
        const total_size = self.serializedSize();
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        // The buffer is sized exactly to `serializedSize()`, so `serializeInto`
        // cannot return BufferTooSmall here. Surface any future divergence
        // (e.g. if `serializedSize` and `serializeInto` ever drift) instead of
        // silently corrupting state with `catch unreachable`.
        const bytes_written = try self.serializeInto(buf);
        std.debug.assert(bytes_written == total_size);
        return buf;
    }

    pub fn deserialize(allocator: Allocator, data: []const u8) !struct { record: WalRecord, bytes_read: usize } {
        if (data.len < MIN_RECORD_SIZE) return error.InvalidFormat;

        var offset: usize = 0;

        const lsn = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, data[offset..][0..8]));
        offset += 8;

        const record_type_byte = data[offset];
        const record_type = std.enums.fromInt(WalRecordType, record_type_byte) orelse return error.InvalidFormat;
        offset += 1;

        const payload_len = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[offset..][0..4]));
        offset += 4;

        if (payload_len > MAX_WAL_PAYLOAD) return error.WalRecordTooLarge;
        if (data.len < offset + payload_len + CHECKSUM_SIZE) return error.InvalidFormat;

        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);
        if (payload_len > 0) {
            @memcpy(payload, data[offset..][0..payload_len]);
        }
        offset += payload_len;

        const checksum = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[offset..][0..4]));
        offset += CHECKSUM_SIZE;

        return .{
            .record = WalRecord{
                .lsn = lsn,
                .record_type = record_type,
                .payload = payload,
                .checksum = checksum,
            },
            .bytes_read = offset,
        };
    }

    pub fn computeChecksum(self: *const WalRecord) u32 {
        var hasher = Crc32C.init();
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, self.lsn)));
        hasher.update(&[_]u8{@intFromEnum(self.record_type)});
        const payload_len: u32 = @intCast(self.payload.len);
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, payload_len)));
        if (self.payload.len > 0) {
            hasher.update(self.payload);
        }
        return hasher.final();
    }

    pub fn deinit(self: *const WalRecord, allocator: Allocator) void {
        if (self.payload.len > 0) {
            allocator.free(self.payload);
        }
    }
};

test "WalRecord serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    const payload_data = "hello time series data";

    var record = WalRecord{
        .lsn = 42,
        .record_type = .append_points,
        .payload = payload_data,
        .checksum = 0,
    };
    record.checksum = record.computeChecksum();

    const bytes = try record.serialize(allocator);
    defer allocator.free(bytes);

    const result = try WalRecord.deserialize(allocator, bytes);
    defer result.record.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), result.record.lsn);
    try std.testing.expectEqual(WalRecordType.append_points, result.record.record_type);
    try std.testing.expectEqualStrings(payload_data, result.record.payload);
    try std.testing.expectEqual(record.checksum, result.record.checksum);
    try std.testing.expectEqual(bytes.len, result.bytes_read);
}
