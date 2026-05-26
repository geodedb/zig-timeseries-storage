// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const types = @import("types.zig");
const gorilla = @import("encoding/gorilla.zig");

const Allocator = std.mem.Allocator;
const owner_only_file_mode = 0o600;

pub const SEGMENT_MAGIC: [8]u8 = .{ 'T', 'S', 'S', 'E', 'G', '0', '0', '1' };

/// Build the on-disk path for a segment file, e.g. `<data_dir>/<id>.tsseg`.
/// Caller owns the returned slice and must free it with `allocator.free`.
pub fn segmentPath(allocator: Allocator, data_dir: []const u8, id: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}.tsseg", .{ data_dir, id });
}

/// Header for a single block in a segment file.
pub const BlockHeader = struct {
    series_id: types.SeriesId,
    stats: gorilla.BlockStats,
    data_len: u32,

    pub const encoded_size = 16 + 8 + 8 + 4 + 8 + 8 + 16 + 8 + 8 + 4; // = 88 bytes

    pub fn serialize(self: BlockHeader, buf: []u8) void {
        var pos: usize = 0;
        std.mem.writeInt(u128, buf[pos..][0..16], self.series_id, .little);
        pos += 16;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.min_ts, .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.max_ts, .little);
        pos += 8;
        std.mem.writeInt(u32, buf[pos..][0..4], self.stats.count, .little);
        pos += 4;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.min_value, .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.max_value, .little);
        pos += 8;
        std.mem.writeInt(i128, buf[pos..][0..16], self.stats.sum, .little);
        pos += 16;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.first_value, .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], self.stats.last_value, .little);
        pos += 8;
        std.mem.writeInt(u32, buf[pos..][0..4], self.data_len, .little);
        pos += 4;
    }

    pub fn deserialize(buf: []const u8) BlockHeader {
        var h: BlockHeader = undefined;
        var pos: usize = 0;
        h.series_id = std.mem.readInt(u128, buf[pos..][0..16], .little);
        pos += 16;
        h.stats.min_ts = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.max_ts = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.count = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;
        h.stats.min_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.max_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.sum = std.mem.readInt(i128, buf[pos..][0..16], .little);
        pos += 16;
        h.stats.first_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.stats.last_value = std.mem.readInt(i64, buf[pos..][0..8], .little);
        pos += 8;
        h.data_len = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;
        return h;
    }
};

/// Streaming writer for immutable segment files.
///
/// A segment file begins with the 8-byte `SEGMENT_MAGIC` followed by
/// one or more `(BlockHeader, Gorilla-compressed payload)` pairs. The
/// writer is append-only: `writeBlock` Gorilla-encodes the supplied
/// points, computes block-level statistics (min/max ts and value,
/// count, sum, first/last value), writes the header, then writes the
/// compressed payload. Headers are fixed-size (88 bytes), making
/// random-access scans of just the headers cheap for query planning.
///
/// File permissions are owner-read/write only (0o600). The caller is
/// responsible for choosing the path; see `segmentPath` for the
/// canonical `<data_dir>/<id>.tsseg` form.
///
/// `deinit` closes the file but does NOT fsync; durability is the
/// engine's responsibility (it issues the fsync as part of the
/// manifest commit when the segment is added to the manifest).
pub const SegmentWriter = struct {
    file: std.Io.File,
    io_ctx: std.Io,
    allocator: Allocator,

    pub fn init(allocator: Allocator, path: []const u8) !SegmentWriter {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
        });

        // Write magic
        try file.writeStreamingAll(io, &SEGMENT_MAGIC);

        return SegmentWriter{
            .file = file,
            .io_ctx = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SegmentWriter) void {
        self.file.close(self.io_ctx);
    }

    /// Appends a block of points for a series.
    pub fn writeBlock(self: *SegmentWriter, series_id: types.SeriesId, points: []const types.Point) !void {
        if (points.len == 0) return;

        var encoder = try gorilla.GorillaEncoder.init(self.allocator);
        defer encoder.deinit();

        for (points) |p| {
            try encoder.encodePoint(p);
        }

        const data = try encoder.getCompressedData(self.allocator);
        defer self.allocator.free(data);

        var buf: [BlockHeader.encoded_size]u8 = undefined;
        const header = BlockHeader{
            .series_id = series_id,
            .stats = encoder.stats,
            .data_len = @intCast(data.len),
        };
        header.serialize(&buf);

        try self.file.writeStreamingAll(self.io_ctx, &buf);
        try self.file.writeStreamingAll(self.io_ctx, data);
    }
};

/// Random-access reader for immutable segment files.
///
/// Validates the 8-byte magic on open and tracks the file size so the
/// block iterator can detect EOF without an extra `stat`. Reads are
/// positional (no internal seek state) so multiple `BlockIterator`s
/// can share a single `SegmentReader` if desired.
///
/// Lifetime: `deinit` closes the file. The caller must not use any
/// `Block` returned from a previous iteration after calling `deinit`
/// (the `Block` retains a `*SegmentReader` pointer for late payload
/// decoding).
pub const SegmentReader = struct {
    file: std.Io.File,
    io_ctx: std.Io,
    allocator: Allocator,
    file_size: u64,

    pub fn init(allocator: Allocator, path: []const u8) !SegmentReader {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});

        const file_size = try file.length(io);
        if (file_size < SEGMENT_MAGIC.len) return error.InvalidFile;

        var magic_buf: [8]u8 = undefined;
        const read_len = try file.readPositionalAll(io, &magic_buf, 0);
        if (read_len != 8 or !std.mem.eql(u8, &magic_buf, &SEGMENT_MAGIC)) {
            return error.InvalidMagic;
        }

        return SegmentReader{
            .file = file,
            .io_ctx = io,
            .allocator = allocator,
            .file_size = file_size,
        };
    }

    pub fn deinit(self: *SegmentReader) void {
        self.file.close(self.io_ctx);
    }

    /// Block iterator for reading through a segment.
    pub const BlockIterator = struct {
        reader: *SegmentReader,
        offset: u64,

        pub fn next(self: *BlockIterator) !?Block {
            if (self.offset >= self.reader.file_size) return null;

            var hdr_buf: [BlockHeader.encoded_size]u8 = undefined;
            const read_len = try self.reader.file.readPositionalAll(self.reader.io_ctx, &hdr_buf, self.offset);
            if (read_len != BlockHeader.encoded_size) return error.UnexpectedEOF;

            const header = BlockHeader.deserialize(&hdr_buf);

            const data_offset = self.offset + BlockHeader.encoded_size;
            self.offset = data_offset + header.data_len;

            return Block{
                .header = header,
                .data_offset = data_offset,
                .reader = self.reader,
            };
        }
    };

    pub fn iterator(self: *SegmentReader) BlockIterator {
        return .{
            .reader = self,
            .offset = SEGMENT_MAGIC.len,
        };
    }
};

/// A block of points inside a segment file.
pub const Block = struct {
    header: BlockHeader,
    data_offset: u64,
    reader: *SegmentReader,

    /// Decodes the points in this block.
    pub fn decodePoints(self: Block, allocator: Allocator) ![]types.Point {
        const data = try allocator.alloc(u8, self.header.data_len);
        defer allocator.free(data);

        const read_len = try self.reader.file.readPositionalAll(self.reader.io_ctx, data, self.data_offset);
        if (read_len != self.header.data_len) return error.UnexpectedEOF;

        var decoder = gorilla.GorillaDecoder.init(data, self.header.stats.count);
        return decoder.decodeAll(allocator);
    }
};

test "Segment roundtrip" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/test.tsseg", .{path});
    defer allocator.free(seg_path);

    const series_id: types.SeriesId = 12345;
    const pts = [_]types.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
    };

    {
        var writer = try SegmentWriter.init(allocator, seg_path);
        defer writer.deinit();
        try writer.writeBlock(series_id, &pts);
    }

    {
        var reader = try SegmentReader.init(allocator, seg_path);
        defer reader.deinit();

        var it = reader.iterator();
        const block = (try it.next()).?;
        try std.testing.expectEqual(series_id, block.header.series_id);
        try std.testing.expectEqual(@as(u32, 2), block.header.stats.count);

        const decoded = try block.decodePoints(allocator);
        defer allocator.free(decoded);

        try std.testing.expectEqual(@as(usize, 2), decoded.len);
        try std.testing.expectEqual(pts[0].ts, decoded[0].ts);
        try std.testing.expectEqual(pts[0].value, decoded[0].value);
        try std.testing.expectEqual(pts[1].ts, decoded[1].ts);
        try std.testing.expectEqual(pts[1].value, decoded[1].value);

        try std.testing.expect((try it.next()) == null);
    }
}
