// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const limits = @import("limits.zig");
const Crc32 = std.hash.crc.Crc32Iscsi;
const owner_only_file_mode = 0o600;

pub const MANIFEST_MAGIC: [8]u8 = .{ 'T', 'S', 'M', 'N', 'F', 'S', '0', '1' };
pub const MANIFEST_VERSION: u32 = 1;

/// Size of the serialized manifest in bytes:
/// magic(8) + fields + CRC32(4)
const FIELD_SIZE: usize = 4 + 16 + 8 + 8 + 8 + 8 + 8; // = 60
const SERIALIZED_SIZE: usize = 8 + FIELD_SIZE + 4; // = 72

pub const SegmentMeta = struct {
    id: u64,
    min_ts: i64,
    max_ts: i64,
    level: u8,
};

/// On-disk manifest tracking the engine's persistent state.
///
/// Stores the list of segments, the next segment id, the last WAL
/// checkpoint LSN, and the engine's identity UUID. Persisted to two
/// files under the data directory — `manifest.a` and `manifest.b` —
/// in a "ping-pong" pattern: each `save()` increments `counter` and
/// writes to whichever slot the new counter parity selects.
///
/// ## Atomicity
///
/// Every write goes through `<filename>.tmp` first, is fsync'd, then
/// `rename(2)`-d into place. `rename(2)` is atomic on POSIX, so a
/// crash mid-write either leaves the slot at its previous contents
/// (rename never happened) or fully updated. Each file ends with a
/// CRC32 (Castagnoli, ISCSI variant) over the preceding bytes; on
/// load both slots are CRC-verified and the slot with the higher
/// `counter` wins. If both slots fail to load (missing or corrupted)
/// the engine starts from an empty manifest.
///
/// This dual-file ping-pong is intentional: a single-file atomic
/// rename is enough for atomicity, but two slots additionally protect
/// against the case where a fresh write is fsync'd and then the
/// underlying media corrupts that block before the next save() — the
/// older but still-valid slot remains usable.
pub const Manifest = struct {
    format_version: u32 = MANIFEST_VERSION,
    ts_uuid: [16]u8 = [_]u8{0} ** 16,
    counter: u64 = 0,
    last_checkpoint_lsn: u64 = 0,
    next_segment_id: u64 = 1,
    series_count: u64 = 0,
    point_count: u64 = 0,
    segments: std.ArrayListUnmanaged(SegmentMeta) = .empty,
    allocator: std.mem.Allocator = undefined,
    data_dir: []const u8 = undefined,

    pub fn init(allocator: Allocator, data_dir: []const u8) !Manifest {
        const path_a = try std.fmt.allocPrint(allocator, "{s}/manifest.a", .{data_dir});
        defer allocator.free(path_a);
        const path_b = try std.fmt.allocPrint(allocator, "{s}/manifest.b", .{data_dir});
        defer allocator.free(path_b);

        const a = readFromFile(allocator, path_a) catch null;
        const b = readFromFile(allocator, path_b) catch null;

        var m = selectManifest(a, b) catch Manifest{};
        m.allocator = allocator;
        m.data_dir = data_dir;
        return m;
    }

    pub fn deinit(self: *Manifest) void {
        self.segments.deinit(self.allocator);
    }

    pub fn save(self: *Manifest) !void {
        self.counter += 1;
        const filename = if (self.counter % 2 == 0) "manifest.a" else "manifest.b";
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.data_dir, filename });
        defer self.allocator.free(path);
        try self.writeToFile(self.allocator, path);
    }

    pub fn getNextSegmentId(self: *Manifest) u64 {
        const id = self.next_segment_id;
        self.next_segment_id += 1;
        return id;
    }

    pub fn addSegment(self: *Manifest, meta: SegmentMeta) !void {
        try self.segments.append(self.allocator, meta);
    }

    pub fn serialize(self: *const Manifest, allocator: Allocator) ![]u8 {
        const segment_bytes = self.segments.items.len * 25;
        const full_size = SERIALIZED_SIZE + 4 + segment_bytes;
        const buf = try allocator.alloc(u8, full_size);
        errdefer allocator.free(buf);

        var pos: usize = 0;

        @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC);
        pos += 8;

        writeU32(buf, &pos, self.format_version);
        @memcpy(buf[pos..][0..16], &self.ts_uuid);
        pos += 16;
        writeU64(buf, &pos, self.counter);
        writeU64(buf, &pos, self.last_checkpoint_lsn);
        writeU64(buf, &pos, self.next_segment_id);
        writeU64(buf, &pos, self.series_count);
        writeU64(buf, &pos, self.point_count);
        writeU32(buf, &pos, @intCast(self.segments.items.len));
        for (self.segments.items) |seg| {
            writeU64(buf, &pos, seg.id);
            writeU64(buf, &pos, @bitCast(seg.min_ts));
            writeU64(buf, &pos, @bitCast(seg.max_ts));
            buf[pos] = seg.level;
            pos += 1;
        }

        const crc = Crc32.hash(buf[0..pos]);
        writeU32(buf, &pos, crc);

        return buf;
    }

    pub fn deserialize(allocator: Allocator, data: []const u8) !Manifest {
        if (data.len < SERIALIZED_SIZE + 4) return error.InvalidData;
        if (!std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC)) return error.InvalidMagic;

        const stored_crc = readU32(data, data.len - 4);
        const computed_crc = Crc32.hash(data[0 .. data.len - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        var pos: usize = 8;
        var m = Manifest{};

        m.format_version = readU32(data, pos);
        pos += 4;
        @memcpy(&m.ts_uuid, data[pos..][0..16]);
        pos += 16;
        m.counter = readU64(data, pos);
        pos += 8;
        m.last_checkpoint_lsn = readU64(data, pos);
        pos += 8;
        m.next_segment_id = readU64(data, pos);
        pos += 8;
        m.series_count = readU64(data, pos);
        pos += 8;
        m.point_count = readU64(data, pos);
        pos += 8;
        const num_segments = readU32(data, pos);
        pos += 4;
        // CWE-770: defend against a manifest whose declared
        // `num_segments` field is wildly inflated. We still allocate
        // O(n) below; bounding `n` bounds the worst case.
        if (num_segments > limits.MAX_SEGMENTS_PER_MANIFEST) return error.ManifestTooLarge;

        m.segments = std.ArrayListUnmanaged(SegmentMeta).empty;
        for (0..num_segments) |_| {
            const id = readU64(data, pos);
            pos += 8;
            const min_ts = @as(i64, @bitCast(readU64(data, pos)));
            pos += 8;
            const max_ts = @as(i64, @bitCast(readU64(data, pos)));
            pos += 8;
            const level = data[pos];
            pos += 1;
            try m.segments.append(allocator, .{ .id = id, .min_ts = min_ts, .max_ts = max_ts, .level = level });
        }

        return m;
    }

    pub fn writeToFile(self: *const Manifest, allocator: Allocator, path: []const u8) !void {
        const data = try self.serialize(allocator);
        defer allocator.free(data);

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode) });
        defer tmp_file.close(io);

        try tmp_file.writeStreamingAll(io, data);
        try tmp_file.sync(io);

        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
    }

    pub fn readFromFile(allocator: Allocator, path: []const u8) !?Manifest {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(io);

        const file_len = try file.length(io);
        if (file_len < SERIALIZED_SIZE + 4) return error.FileTooSmall;
        // CWE-770: cap the on-disk manifest size before `@intCast` to
        // usize and before allocating a buffer for it. Without this
        // gate a hostile file claiming many GiB would attempt an
        // immediate large allocation.
        if (file_len > limits.MAX_MANIFEST_SIZE) return error.ManifestTooLarge;
        const data = try allocator.alloc(u8, @intCast(file_len));
        defer allocator.free(data);
        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != data.len) return error.UnexpectedEndOfFile;

        return try deserialize(allocator, data);
    }

    pub fn selectManifest(a: ?Manifest, b: ?Manifest) !Manifest {
        if (a == null and b == null) return error.NoManifest;
        if (a == null) return b.?;
        if (b == null) return a.?;
        return if (a.?.counter >= b.?.counter) a.? else b.?;
    }
};

fn writeU32(buf: []u8, pos: *usize, value: u32) void {
    @memcpy(buf[pos.*..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
    pos.* += 4;
}

fn writeU64(buf: []u8, pos: *usize, value: u64) void {
    @memcpy(buf[pos.*..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    pos.* += 8;
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.littleToNative(u32, @bitCast(data[offset..][0..4].*));
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.littleToNative(u64, @bitCast(data[offset..][0..8].*));
}

test "Manifest serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAB);

    const m = Manifest{
        .ts_uuid = uuid,
        .counter = 42,
        .next_segment_id = 100,
        .series_count = 50,
        .point_count = 1000,
    };

    const data = try m.serialize(allocator);
    defer allocator.free(data);

    var m2 = try Manifest.deserialize(allocator, data);

    try std.testing.expectEqual(m.format_version, m2.format_version);
    try std.testing.expectEqual(m.ts_uuid, m2.ts_uuid);
    try std.testing.expectEqual(m.counter, m2.counter);
    try std.testing.expectEqual(m.next_segment_id, m2.next_segment_id);
    try std.testing.expectEqual(m.series_count, m2.series_count);
    try std.testing.expectEqual(m.point_count, m2.point_count);
    m2.deinit();
}

test "Manifest: deserialize rejects inflated num_segments" {
    const allocator = std.testing.allocator;

    // Build a minimum-sized manifest with a num_segments value just
    // above MAX_SEGMENTS_PER_MANIFEST. We are NOT writing that many
    // segment entries — the field is consulted before the loop, so
    // the cap check fires first.
    const data = try allocator.alloc(u8, SERIALIZED_SIZE + 4);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..8], &MANIFEST_MAGIC);
    var pos: usize = 8;
    writeU32(data, &pos, MANIFEST_VERSION);
    pos += 16; // ts_uuid (zero-filled)
    writeU64(data, &pos, 1); // counter
    writeU64(data, &pos, 0); // last_checkpoint_lsn
    writeU64(data, &pos, 1); // next_segment_id
    writeU64(data, &pos, 0); // series_count
    writeU64(data, &pos, 0); // point_count
    writeU32(data, &pos, limits.MAX_SEGMENTS_PER_MANIFEST + 1);

    const crc = Crc32.hash(data[0..pos]);
    writeU32(data, &pos, crc);

    try std.testing.expectError(error.ManifestTooLarge, Manifest.deserialize(allocator, data));
}

test "Manifest: readFromFile rejects oversized file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const mf_path = try std.fmt.allocPrint(allocator, "{s}/oversized", .{path});
    defer allocator.free(mf_path);

    // Write a header followed by a hole punched to the cap+1 byte so
    // the sparse file's `length()` exceeds the limit. We use a
    // single positional write at the high offset to avoid actually
    // materialising the entire file.
    const f = try std.Io.Dir.cwd().createFile(io, mf_path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer f.close(io);

    var hdr: [SERIALIZED_SIZE + 4]u8 = undefined;
    @memset(&hdr, 0);
    @memcpy(hdr[0..8], &MANIFEST_MAGIC);
    try f.writeStreamingAll(io, &hdr);

    var sentinel: [1]u8 = .{0xAA};
    try f.writePositionalAll(io, &sentinel, limits.MAX_MANIFEST_SIZE + 1);
    try f.sync(io);

    try std.testing.expectError(error.ManifestTooLarge, Manifest.readFromFile(allocator, mf_path));
}
