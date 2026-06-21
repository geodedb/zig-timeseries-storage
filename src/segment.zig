// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const types = @import("types.zig");
const limits = @import("limits.zig");
const gorilla = @import("encoding/gorilla.zig");
const crypto_backend = @import("crypto_backend");

const Allocator = std.mem.Allocator;
const owner_only_file_mode = 0o600;
// fips-exempt: non-security — CRC32C per-block framing checksum for plaintext
// (TSSEG002) segments; encrypted (TSSEG003) blocks use the AES-GCM tag instead.
const Crc32C = std.hash.crc.Crc32Iscsi;
// fips-exempt: compile-time nonce/tag sizes only; AEAD goes through the seam.
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

/// AES-256-GCM nonce size in bytes (96-bit random nonce).
pub const ENCRYPTION_NONCE_SIZE: usize = Aes256Gcm.nonce_length; // 12
/// AES-256-GCM auth tag size in bytes.
pub const ENCRYPTION_TAG_SIZE: usize = Aes256Gcm.tag_length; // 16

/// Segment file format magic.
///
/// `TSSEG002` (plaintext segments) introduces per-block CRC32C
/// integrity (SEC-004): each block header carries a `crc32c` field
/// covering the header (excluding the CRC field itself) plus the
/// compressed data payload. Reads verify the CRC before decoding,
/// surfacing `error.BlockCorrupted` on mismatch.
///
/// `TSSEG003` (encrypted segments, GAP-0001) adds AES-256-GCM
/// per-block framing. Block layout:
///   body(88) || nonce(12) || tag(16) || ciphertext(data_len)
/// `data_len` continues to mean the on-disk payload size — i.e.
/// the ciphertext byte count, NOT the decoded plaintext length.
/// The AAD is `graph_uuid(16) || "seg"(3) || segment_id(u64 LE) ||
/// block_index(u32 LE)`. The GCM authentication tag replaces the
/// CRC32C field; integrity is enforced cryptographically.
///
/// `TSSEG001` (legacy) had no per-block checksum. `SegmentReader`
/// rejects v1 files with `error.InvalidMagic`. See
/// `migration.migrateSegment` for v1 -> v2 upgrade (GAP-0009).
pub const SEGMENT_MAGIC: [8]u8 = .{ 'T', 'S', 'S', 'E', 'G', '0', '0', '2' };
pub const SEGMENT_MAGIC_V3: [8]u8 = .{ 'T', 'S', 'S', 'E', 'G', '0', '0', '3' };

/// Errors specific to segment file integrity. Functions that touch
/// the segment files may ALSO return allocator or file-system errors
/// (`error.OutOfMemory`, `error.FileNotFound`, etc.); those keep an
/// inferred error set rather than being named here because the
/// resulting union would be unwieldy and would not add discrimination
/// value over the standard library types.
pub const SegmentError = error{
    /// File is shorter than the magic header.
    InvalidFile,
    /// First 8 bytes of the segment do not match `SEGMENT_MAGIC`.
    InvalidMagic,
    /// `Block.decodePoints` rejected `data_len` for exceeding
    /// `limits.MAX_BLOCK_DATA_LEN`.
    BlockTooLarge,
    /// `GorillaEncoder.encodePoint` refused to grow the bitset past
    /// `limits.MAX_POINTS_PER_BLOCK_ABSOLUTE`.
    BlockPointLimitExceeded,
    /// Read returned fewer bytes than requested.
    UnexpectedEOF,
    /// `crc32c` field on the block header did not match the CRC32C
    /// computed over header(excluding crc) + payload. Indicates
    /// on-disk corruption or out-of-band tampering. Closes SEC-004.
    BlockCorrupted,
    /// Encrypted segment opened without a key, or AES-GCM tag check
    /// failed (wrong key or tampering). Closes GAP-0001.
    DecryptionFailed,
    /// Plaintext segment opened with an encryption key — refuse to
    /// read because the operator's expectation that everything is
    /// encrypted is violated by the on-disk artefact.
    UnexpectedPlaintextSegment,
};

/// Build the on-disk path for a segment file, e.g. `<data_dir>/<id>.tsseg`.
/// Caller owns the returned slice and must free it with `allocator.free`.
pub fn segmentPath(allocator: Allocator, data_dir: []const u8, id: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}.tsseg", .{ data_dir, id });
}

// ---------------------------------------------------------------------------
// P-ALGO-001 (partial): optional per-segment footer index
// ---------------------------------------------------------------------------
//
// Backwards-compatible additive change. The segment magic and the
// on-disk block format are UNCHANGED. After the last data block (and
// only when written by a footer-aware `SegmentWriter`) the file may
// carry an optional trailing footer:
//
//   [BLOCK_0]..[BLOCK_N]                ← unchanged
//   [FOOTER_BODY]                       ← NEW, optional
//   [FOOTER_OFFSET u64 LE]              ← NEW, 8 bytes before EOF
//   [FOOTER_MAGIC u64 LE]               ← NEW, last 8 bytes of file
//
// FOOTER_BODY layout:
//   entry_count: u32 LE
//   entries:     entry_count × FooterEntry (sorted ASC by series_id)
//   crc32c:      u32 LE   — CRC32C over [entry_count .. last entry]
//
// To detect the footer on open: read the last 16 bytes of the file. If
// the last 8 bytes equal `FOOTER_MAGIC`, the preceding 8 bytes give
// the byte offset where FOOTER_BODY begins. The reader then parses the
// body and verifies CRC32C; a CRC mismatch is treated as "no footer"
// (the reader falls back to the full-scan path) so a corrupt footer
// cannot lose data.
//
// Segments written before this change have no footer and continue to
// work unchanged: the EOF-probe simply does not see the magic, and the
// reader operates exactly as before.

/// Sentinel printed at the very end of an indexed segment file. Chosen
/// as an opaque 8-byte value with embedded non-text bytes (`\t\t\n`)
/// so an accidental match against a Gorilla-compressed payload is
/// vanishingly unlikely. ASCII reads as `TSEG\t\t\n` if you squint.
pub const FOOTER_MAGIC: u64 = 0x544553454709090A;

/// Errors specific to the optional footer index. The reader treats
/// these as "no footer present" and falls back to the full-scan path —
/// they are intentionally NOT lifted into `SegmentError` because the
/// caller does not need to distinguish "corrupt footer" from "no
/// footer" (the behaviour is identical: full scan).
pub const FooterError = error{
    /// The footer offset stored in the last 8 bytes points past EOF
    /// or below the segment magic, so the file cannot be indexed.
    FooterOffsetOutOfRange,
    /// The CRC32C check over the footer body failed.
    FooterChecksumMismatch,
    /// `entry_count × FooterEntry.encoded_size + tail bytes` exceeds
    /// the indexable region between the magic and the trailing
    /// `FOOTER_OFFSET || FOOTER_MAGIC` pair.
    FooterTruncated,
    /// `entry_count` is large enough that the body would extend past
    /// the file's reasonable bounds. Defence against a tampered footer
    /// driving a giant allocation.
    FooterEntryCountTooLarge,
};

/// One entry of the per-segment footer index.
///
/// Wire layout (28 bytes, little-endian):
///    0..16  series_id (u128)
///   16..24  first_block_offset (u64) — byte offset of the FIRST
///           block header for this series within the segment file
///   24..28  block_count (u32) — number of consecutive blocks belonging
///           to this series starting at `first_block_offset`
///
/// The current writer accumulates blocks for the same series back-to-
/// back, but the reader does NOT assume that — `block_count` is used
/// to bound the scan, and the iterator still filters every visited
/// block header by `series_id` for safety.
pub const FooterEntry = struct {
    series_id: types.SeriesId,
    first_block_offset: u64,
    block_count: u32,

    pub const encoded_size: usize = 16 + 8 + 4; // 28 bytes

    pub fn serialize(self: FooterEntry, buf: []u8) void {
        std.debug.assert(buf.len >= encoded_size);
        std.mem.writeInt(u128, buf[0..16], self.series_id, .little);
        std.mem.writeInt(u64, buf[16..24], self.first_block_offset, .little);
        std.mem.writeInt(u32, buf[24..28], self.block_count, .little);
    }

    pub fn deserialize(buf: []const u8) FooterEntry {
        std.debug.assert(buf.len >= encoded_size);
        return .{
            .series_id = std.mem.readInt(u128, buf[0..16], .little),
            .first_block_offset = std.mem.readInt(u64, buf[16..24], .little),
            .block_count = std.mem.readInt(u32, buf[24..28], .little),
        };
    }
};

/// Trailing footer bytes (16): `[FOOTER_OFFSET u64 LE][FOOTER_MAGIC u64 LE]`.
pub const FOOTER_TAIL_SIZE: usize = 16;

/// Result of `Footer.lookup`. Returned by value to avoid a heap allocation.
pub const FooterLookup = struct {
    /// Byte offset within the segment file of the first block header
    /// belonging to this series.
    offset: u64,
    /// Number of consecutive blocks (starting at `offset`) that the
    /// writer recorded for this series.
    count: u32,
};

/// In-memory representation of the parsed footer index.
pub const Footer = struct {
    /// Sorted ascending by `series_id`.
    entries: []FooterEntry,
    /// CRC32C as read from disk (already verified at construction time).
    crc32c: u32,

    pub fn deinit(self: *Footer, allocator: Allocator) void {
        allocator.free(self.entries);
        self.entries = &[_]FooterEntry{};
    }

    /// O(log entries) binary search over the sorted entry slice.
    /// Returns `null` when the series is not indexed in this footer —
    /// the caller MUST treat that as "fall back to the full scan",
    /// because the absence of an entry could also mean the series has
    /// no blocks in this segment.
    pub fn lookup(self: *const Footer, series_id: types.SeriesId) ?FooterLookup {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = self.entries[mid];
            if (entry.series_id == series_id) {
                return .{ .offset = entry.first_block_offset, .count = entry.block_count };
            } else if (entry.series_id < series_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

/// Upper bound on the number of footer entries we are willing to
/// allocate from a tampered footer. One entry per series; we cap at
/// 16 million which is several orders of magnitude above any sane
/// per-segment cardinality and still under `MAX_BLOCK_DATA_LEN` worth
/// of footer bytes.
const FOOTER_MAX_ENTRIES: u32 = 16 * 1024 * 1024;

/// Header for a single block in a segment file.
///
/// ## Wire layout (TSSEG002, 92 bytes, little-endian)
///
///   off  size  field
///   ---  ----  ----------------------------------------------
///     0    16  series_id (u128)
///    16     8  stats.min_ts (i64)
///    24     8  stats.max_ts (i64)
///    32     4  stats.count (u32)
///    36     8  stats.min_value (i64)
///    44     8  stats.max_value (i64)
///    52    16  stats.sum (i128)
///    68     8  stats.first_value (i64)
///    76     8  stats.last_value (i64)
///    84     4  data_len (u32)
///    88     4  crc32c (u32) — covers bytes [0..88) of THIS header
///               plus the `data_len` payload bytes that follow it
///               on disk. Verified on read; mismatch surfaces
///               `error.BlockCorrupted`. Closes SEC-004.
///
/// The `crc32c` field is intentionally placed at the END so every
/// other field keeps the same offset it had under TSSEG001 — a
/// future migration tool can copy v1 headers and append a freshly
/// computed CRC without re-encoding the body. Computation uses
/// CRC32C (Castagnoli polynomial 0x1EDC6F41) for consistency with
/// the WAL and manifest checksums.
pub const BlockHeader = struct {
    series_id: types.SeriesId,
    stats: gorilla.BlockStats,
    data_len: u32,
    crc32c: u32 = 0,

    /// Bytes serialised PRIOR to the trailing crc32c. Used both as
    /// a serialiser offset and as the slice the CRC covers.
    pub const body_size = 16 + 8 + 8 + 4 + 8 + 8 + 16 + 8 + 8 + 4; // = 88
    pub const encoded_size = body_size + 4; // 92 bytes total

    /// Serialise the body (everything except crc32c) into the
    /// caller's buffer. Useful for `SegmentWriter.writeBlock`, which
    /// needs to compute the CRC over `(body, data)` and only then
    /// stamp the trailing crc bytes into the header buffer.
    pub fn serializeBody(self: BlockHeader, buf: []u8) void {
        std.debug.assert(buf.len >= body_size);
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
        std.debug.assert(pos == body_size);
    }

    /// Serialise the full 92-byte header including the trailing
    /// crc32c. The CRC must already be set on `self`.
    pub fn serialize(self: BlockHeader, buf: []u8) void {
        std.debug.assert(buf.len >= encoded_size);
        self.serializeBody(buf);
        std.mem.writeInt(u32, buf[body_size..][0..4], self.crc32c, .little);
    }

    pub fn deserialize(buf: []const u8) BlockHeader {
        std.debug.assert(buf.len >= encoded_size);
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
        std.debug.assert(pos == body_size);
        h.crc32c = std.mem.readInt(u32, buf[pos..][0..4], .little);
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
/// Encryption context for a SegmentWriter/Reader. When provided, every
/// block is AES-256-GCM encrypted using the supplied key and per-block
/// random nonce. The AAD binds the block to (graph_uuid, file_type,
/// segment_id, block_index) so a cut-and-paste swap from another
/// segment or file would fail GCM verification. Closes GAP-0001.
pub const EncryptionContext = struct {
    key: [32]u8,
    graph_uuid: [16]u8,
    segment_id: u64,
};

pub const SegmentWriter = struct {
    file: std.Io.File,
    io_ctx: std.Io,
    allocator: Allocator,
    encryption: ?EncryptionContext = null,
    block_index: u32 = 0,
    /// Pooled Gorilla encoder reused across `writeBlock` calls (ENT-003).
    /// Lazily initialised on the first `writeBlock` so a writer that is
    /// constructed but never appended to (e.g. an error path between
    /// `init` and the first append) never allocates the bitset. After
    /// the first block the encoder is retained and `reset()` is called
    /// between blocks instead of `init/deinit`, eliminating one bitset
    /// allocation per block on the hot flush + compaction paths.
    encoder: ?gorilla.GorillaEncoder = null,

    /// P-ALGO-001 (partial): byte offset of the next write within the
    /// segment file. Kept in sync with `writeBlock` so the optional
    /// footer can record each series' first block offset without
    /// having to `stat` the file. Starts at the post-magic position
    /// (8 bytes) since `init` writes the magic before returning.
    current_offset: u64 = 0,

    /// P-ALGO-001 (partial): accumulator for the optional footer
    /// index. Each entry records `(series_id, first_block_offset,
    /// block_count)`. The map is populated lazily on the first call
    /// to `writeBlock` so a writer that is constructed but never
    /// appended to does not allocate. Sorted at `sync()` time into a
    /// dense ascending slice.
    series_index: std.AutoHashMapUnmanaged(types.SeriesId, FooterEntry) = .empty,

    /// Once true, `sync()` has already stamped the trailing footer +
    /// `[FOOTER_OFFSET || FOOTER_MAGIC]` pair into the file, so a
    /// second `sync()` MUST NOT re-emit them (which would corrupt the
    /// file). All public callers issue exactly one `sync()` per
    /// writer, but the guard exists for paranoia.
    footer_written: bool = false,

    pub fn init(allocator: Allocator, path: []const u8) !SegmentWriter {
        return initWithEncryption(allocator, path, null);
    }

    pub fn initWithEncryption(
        allocator: Allocator,
        path: []const u8,
        encryption: ?EncryptionContext,
    ) !SegmentWriter {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
        });

        // Magic depends on whether the file is encrypted.
        if (encryption != null) {
            try file.writeStreamingAll(io, &SEGMENT_MAGIC_V3);
        } else {
            try file.writeStreamingAll(io, &SEGMENT_MAGIC);
        }

        return SegmentWriter{
            .file = file,
            .io_ctx = io,
            .allocator = allocator,
            .encryption = encryption,
            // Magic length is 8 for both v2 and v3.
            .current_offset = SEGMENT_MAGIC.len,
        };
    }

    pub fn deinit(self: *SegmentWriter) void {
        if (self.encoder) |*enc| enc.deinit();
        self.encoder = null;
        self.series_index.deinit(self.allocator);
        self.file.close(self.io_ctx);
    }

    /// Force every previously-written byte to durable storage by
    /// issuing fsync(2) (or the platform equivalent) against the
    /// underlying file. Callers must invoke this BEFORE the segment
    /// is referenced from the manifest — without the fsync, a crash
    /// between manifest commit and the kernel's background flush
    /// would leave the manifest pointing at a segment whose blocks
    /// have not actually hit disk yet (P-IO-003 / Q-REL-008).
    ///
    /// `deinit` deliberately does NOT call this for you: closing the
    /// file is a cleanup operation, while fsyncing is a durability
    /// operation, and the two have different semantics. The engine's
    /// flush and compaction paths call `sync` explicitly at the
    /// correct point in the commit ordering.
    pub fn sync(self: *SegmentWriter) !void {
        try self.writeFooterIfNeeded();
        try self.file.sync(self.io_ctx);
    }

    /// Serialise the accumulated `series_index` into the optional
    /// trailing footer + sentinel tail (P-ALGO-001 partial). No-op if
    /// no blocks were written, or if the footer has already been
    /// emitted for this writer instance.
    ///
    /// On error mid-write, the file may end up with a partial footer
    /// but NO trailing magic — the reader's EOF probe will not see
    /// `FOOTER_MAGIC` and will treat the segment as un-indexed. The
    /// block region of the file is untouched, so the segment remains
    /// fully readable via the existing block-iterator path.
    fn writeFooterIfNeeded(self: *SegmentWriter) !void {
        if (self.footer_written) return;
        if (self.series_index.count() == 0) return;

        const entry_count = self.series_index.count();
        // Sort the entries ascending by series_id so the reader can
        // binary-search. The intermediate array is allocator-owned and
        // freed before `sync` returns.
        const entries = try self.allocator.alloc(FooterEntry, entry_count);
        defer self.allocator.free(entries);

        var idx: usize = 0;
        var map_it = self.series_index.iterator();
        while (map_it.next()) |kv| {
            entries[idx] = kv.value_ptr.*;
            idx += 1;
        }
        std.debug.assert(idx == entry_count);

        std.mem.sort(FooterEntry, entries, {}, struct {
            fn lessThan(_: void, a: FooterEntry, b: FooterEntry) bool {
                return a.series_id < b.series_id;
            }
        }.lessThan);

        // The footer's starting offset on disk is our current write
        // cursor — the very next byte we are about to emit becomes the
        // first byte of the FOOTER_BODY.
        const footer_offset: u64 = self.current_offset;

        // Build the body in a single contiguous buffer so we can CRC
        // it without a streaming hasher juggling chunks. Layout:
        //   [entry_count u32 LE][entry_count × FooterEntry][crc32c u32 LE]
        const body_bytes: usize = 4 + @as(usize, entry_count) * FooterEntry.encoded_size + 4;
        const body = try self.allocator.alloc(u8, body_bytes);
        defer self.allocator.free(body);

        std.mem.writeInt(u32, body[0..4], @intCast(entry_count), .little);
        var pos: usize = 4;
        for (entries) |e| {
            e.serialize(body[pos..][0..FooterEntry.encoded_size]);
            pos += FooterEntry.encoded_size;
        }
        // CRC32C covers everything except the trailing CRC field
        // itself — i.e. [entry_count .. last entry], matching the spec
        // in the type-level doc on `Footer`.
        var hasher = Crc32C.init();
        hasher.update(body[0..pos]);
        const crc = hasher.final();
        std.mem.writeInt(u32, body[pos..][0..4], crc, .little);
        pos += 4;
        std.debug.assert(pos == body_bytes);

        try self.file.writeStreamingAll(self.io_ctx, body);
        self.current_offset += body_bytes;

        // Trailing tail: [FOOTER_OFFSET u64 LE][FOOTER_MAGIC u64 LE].
        var tail: [FOOTER_TAIL_SIZE]u8 = undefined;
        std.mem.writeInt(u64, tail[0..8], footer_offset, .little);
        std.mem.writeInt(u64, tail[8..16], FOOTER_MAGIC, .little);
        try self.file.writeStreamingAll(self.io_ctx, &tail);
        self.current_offset += FOOTER_TAIL_SIZE;

        self.footer_written = true;
    }

    /// Appends a block of points for a series.
    ///
    /// On-disk layout depends on encryption mode:
    ///
    /// * Plaintext (v2): body(88) || crc32c(4) || data_len bytes of
    ///   Gorilla payload. The CRC32C covers the body and the payload.
    /// * Encrypted (v3): body(88) || nonce(12) || tag(16) || data_len
    ///   bytes of CIPHERTEXT. AAD binds the block to its position.
    ///
    /// In v3 the `crc32c` header field is repurposed: bytes [88..92)
    /// hold the low 32 bits of the nonce_counter / index pair used to
    /// derive the per-block nonce — see encryption design notes. The
    /// integrity check is the GCM tag, not CRC32C.
    ///
    /// Closes SEC-004 (v2 CRC) and GAP-0001 (v3 TDE).
    pub fn writeBlock(self: *SegmentWriter, series_id: types.SeriesId, points: []const types.Point) !void {
        if (points.len == 0) return;

        // ENT-003: pool the Gorilla encoder across `writeBlock` calls.
        // The first call lazily allocates the encoder pre-sized via
        // `initForPoints` (P-MEM-002). Every subsequent call reuses the
        // retained `DynamicBitSet` allocation by calling `reset()`,
        // which clears the bit position and stats without freeing the
        // mask array. If a later block is larger than any prior block
        // the bitset grows normally inside `writeBit` / `writeBits`.
        //
        // We use the optional-payload-pointer pattern (`|*e|`) so the
        // encoder pointer is stable across ReleaseFast / ReleaseSmall
        // builds; taking `&self.encoder.?` is fragile in those modes
        // because the optional unwrap can produce a value copy.
        const encoder: *gorilla.GorillaEncoder = blk: {
            if (self.encoder) |*existing| {
                existing.reset();
                break :blk existing;
            }
            self.encoder = try gorilla.GorillaEncoder.initForPoints(self.allocator, points.len);
            // After the assignment above, `self.encoder` is non-null —
            // take the payload pointer through the same payload-capture
            // pattern to keep the lifetime semantics identical to the
            // reuse branch.
            if (self.encoder) |*fresh| {
                break :blk fresh;
            }
            unreachable;
        };

        for (points) |p| {
            try encoder.encodePoint(p);
        }

        const plaintext = try encoder.getCompressedData(self.allocator);
        defer self.allocator.free(plaintext);

        // Record the FOOTER index entry BEFORE the I/O so we capture
        // the offset where this block header will land. If the I/O
        // subsequently fails the writer is in an aborted state and
        // `sync()` is not expected to succeed; the next caller writes
        // a fresh segment so the stale index entry is harmless.
        const block_offset = self.current_offset;
        const gop = try self.series_index.getOrPut(self.allocator, series_id);
        if (gop.found_existing) {
            // Subsequent block for an already-seen series: bump the
            // count. The `first_block_offset` stays at the offset of
            // the very first block for this series.
            gop.value_ptr.block_count += 1;
        } else {
            gop.value_ptr.* = .{
                .series_id = series_id,
                .first_block_offset = block_offset,
                .block_count = 1,
            };
        }

        if (self.encryption) |enc| {
            try self.writeEncryptedBlock(series_id, encoder.stats, plaintext, enc);
        } else {
            try self.writePlaintextBlock(series_id, encoder.stats, plaintext);
        }
        self.block_index += 1;
    }

    fn writePlaintextBlock(
        self: *SegmentWriter,
        series_id: types.SeriesId,
        stats: gorilla.BlockStats,
        data: []const u8,
    ) !void {
        var buf: [BlockHeader.encoded_size]u8 = undefined;
        var header = BlockHeader{
            .series_id = series_id,
            .stats = stats,
            .data_len = @intCast(data.len),
            .crc32c = 0,
        };
        header.serializeBody(buf[0..BlockHeader.body_size]);

        var hasher = Crc32C.init();
        hasher.update(buf[0..BlockHeader.body_size]);
        hasher.update(data);
        header.crc32c = hasher.final();
        std.mem.writeInt(u32, buf[BlockHeader.body_size..][0..4], header.crc32c, .little);

        try self.file.writeStreamingAll(self.io_ctx, &buf);
        try self.file.writeStreamingAll(self.io_ctx, data);
        self.current_offset += BlockHeader.encoded_size + data.len;
    }

    fn writeEncryptedBlock(
        self: *SegmentWriter,
        series_id: types.SeriesId,
        stats: gorilla.BlockStats,
        plaintext: []const u8,
        enc: EncryptionContext,
    ) !void {
        // Generate a random 12-byte nonce. FIPS-0006: per-block random nonce
        // via the seam (FIPS DRBG under -Dfips).
        var nonce: [ENCRYPTION_NONCE_SIZE]u8 = undefined;
        crypto_backend.Csprng.bytes(&nonce) catch return error.EncryptionFailed;

        // Build the AAD: graph_uuid(16) || "seg"(3) || segment_id(u64 LE) || block_index(u32 LE)
        var aad: [16 + 3 + 8 + 4]u8 = undefined;
        @memcpy(aad[0..16], &enc.graph_uuid);
        @memcpy(aad[16..19], "seg");
        std.mem.writeInt(u64, aad[19..27], enc.segment_id, .little);
        std.mem.writeInt(u32, aad[27..31], self.block_index, .little);

        // Body for v3: same shape as v2, but the trailing 4-byte field
        // is unused (set to 0). The integrity check is the GCM tag.
        var hdr_buf: [BlockHeader.encoded_size]u8 = undefined;
        const header = BlockHeader{
            .series_id = series_id,
            .stats = stats,
            .data_len = @intCast(plaintext.len),
            .crc32c = 0,
        };
        header.serializeBody(hdr_buf[0..BlockHeader.body_size]);
        std.mem.writeInt(u32, hdr_buf[BlockHeader.body_size..][0..4], 0, .little);

        // Encrypt. AAD-binds the block to its position so an attacker
        // cannot swap two ciphertext blocks within the same segment
        // without invalidating the tag.
        const ciphertext = try self.allocator.alloc(u8, plaintext.len);
        defer self.allocator.free(ciphertext);
        var tag: [ENCRYPTION_TAG_SIZE]u8 = undefined;
        // FIPS-0006: block AES-256-GCM seal via the seam.
        crypto_backend.Aead.seal(.aes_256_gcm, &enc.key, &nonce, &aad, plaintext, ciphertext, &tag) catch return error.EncryptionFailed;

        try self.file.writeStreamingAll(self.io_ctx, &hdr_buf);
        try self.file.writeStreamingAll(self.io_ctx, &nonce);
        try self.file.writeStreamingAll(self.io_ctx, &tag);
        try self.file.writeStreamingAll(self.io_ctx, ciphertext);
        self.current_offset += BlockHeader.encoded_size + ENCRYPTION_NONCE_SIZE +
            ENCRYPTION_TAG_SIZE + ciphertext.len;
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
    /// Byte offset (exclusive) at which the data-block region ends.
    /// For un-indexed segments this equals `file_size`. For segments
    /// that carry a footer this is the FOOTER_BODY's starting offset,
    /// so the `BlockIterator` correctly stops at the last data block
    /// rather than parsing the footer body as a `BlockHeader`.
    data_end_offset: u64,
    encrypted: bool = false,
    encryption: ?EncryptionContext = null,
    /// Optional per-segment footer index (P-ALGO-001 partial). `null`
    /// when the segment was written without one OR when the footer
    /// CRC32C check failed — both cases are handled identically by
    /// the caller: fall back to the full-scan block iterator.
    footer: ?Footer = null,

    pub fn init(allocator: Allocator, path: []const u8) !SegmentReader {
        return initWithEncryption(allocator, path, null);
    }

    /// Open a segment with optional encryption context.
    ///
    /// Behaviour matrix:
    ///   * v2 file + no key  → plaintext open, success.
    ///   * v3 file + correct key → encrypted open, success.
    ///   * v2 file + key → error.UnexpectedPlaintextSegment.
    ///   * v3 file + no key → error.DecryptionFailed (the decode
    ///     path also returns this when the tag check fails).
    ///   * any other magic → error.InvalidMagic.
    pub fn initWithEncryption(
        allocator: Allocator,
        path: []const u8,
        encryption: ?EncryptionContext,
    ) !SegmentReader {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});

        const file_size = try file.length(io);
        if (file_size < SEGMENT_MAGIC.len) {
            file.close(io);
            return error.InvalidFile;
        }

        var magic_buf: [8]u8 = undefined;
        const read_len = try file.readPositionalAll(io, &magic_buf, 0);
        if (read_len != 8) {
            file.close(io);
            return error.InvalidMagic;
        }

        const is_v2 = std.mem.eql(u8, &magic_buf, &SEGMENT_MAGIC);
        const is_v3 = std.mem.eql(u8, &magic_buf, &SEGMENT_MAGIC_V3);

        if (!is_v2 and !is_v3) {
            file.close(io);
            return error.InvalidMagic;
        }
        if (is_v2 and encryption != null) {
            // The operator expects encryption; refuse a plaintext
            // segment to fail closed on the durability promise.
            file.close(io);
            return error.UnexpectedPlaintextSegment;
        }
        if (is_v3 and encryption == null) {
            // Can't decrypt without a key.
            file.close(io);
            return error.DecryptionFailed;
        }

        // P-ALGO-001 (partial): probe for an optional footer index at
        // EOF. A footer is identified by the last 8 bytes matching
        // `FOOTER_MAGIC`. We do this BEFORE returning so the iterator
        // can rely on `data_end_offset` from the very first call. On
        // any parse failure (corrupt CRC, truncated body, etc.) we
        // treat the segment as un-indexed — the file remains fully
        // readable via the existing block-iterator path.
        var footer_opt: ?Footer = null;
        var data_end_offset: u64 = file_size;
        if (file_size >= SEGMENT_MAGIC.len + FOOTER_TAIL_SIZE) {
            const probe = loadFooter(allocator, io, file, file_size) catch null;
            if (probe) |loaded| {
                footer_opt = loaded.footer;
                data_end_offset = loaded.footer_offset;
            }
        }

        return SegmentReader{
            .file = file,
            .io_ctx = io,
            .allocator = allocator,
            .file_size = file_size,
            .data_end_offset = data_end_offset,
            .encrypted = is_v3,
            .encryption = encryption,
            .footer = footer_opt,
        };
    }

    pub fn deinit(self: *SegmentReader) void {
        if (self.footer) |*f| f.deinit(self.allocator);
        self.footer = null;
        self.file.close(self.io_ctx);
    }

    /// Result of a successful footer parse — used internally by `init`.
    const LoadedFooter = struct {
        footer: Footer,
        footer_offset: u64,
    };

    /// Detect + parse the optional footer at the end of the segment
    /// file. Returns `null` (via the caller's `catch null`) when:
    ///   * The trailing 8 bytes do not match `FOOTER_MAGIC` (the
    ///     overwhelmingly common case for legacy v2/v3 segments).
    ///   * The footer offset is out of range.
    ///   * The CRC32C does not verify.
    ///   * `entry_count` exceeds `FOOTER_MAX_ENTRIES`.
    /// In every failure mode the segment is treated as un-indexed and
    /// the reader falls back to the existing block-iterator path.
    fn loadFooter(
        allocator: Allocator,
        io: std.Io,
        file: std.Io.File,
        file_size: u64,
    ) !LoadedFooter {
        // 1. Read the 16-byte tail.
        var tail: [FOOTER_TAIL_SIZE]u8 = undefined;
        const tail_offset = file_size - FOOTER_TAIL_SIZE;
        const tail_read = try file.readPositionalAll(io, &tail, tail_offset);
        if (tail_read != FOOTER_TAIL_SIZE) return error.FooterTruncated;

        const magic = std.mem.readInt(u64, tail[8..16], .little);
        if (magic != FOOTER_MAGIC) return error.FooterTruncated;

        const footer_offset = std.mem.readInt(u64, tail[0..8], .little);
        // Footer body must lie strictly inside the file, AFTER the
        // segment magic, and BEFORE the trailing tail.
        if (footer_offset < SEGMENT_MAGIC.len) return error.FooterOffsetOutOfRange;
        if (footer_offset > tail_offset) return error.FooterOffsetOutOfRange;

        // 2. Read entry_count first so we can size the body buffer
        //    without trusting the on-disk length.
        if (footer_offset + 4 > tail_offset) return error.FooterTruncated;
        var count_buf: [4]u8 = undefined;
        const cnt_read = try file.readPositionalAll(io, &count_buf, footer_offset);
        if (cnt_read != 4) return error.FooterTruncated;
        const entry_count = std.mem.readInt(u32, &count_buf, .little);
        if (entry_count > FOOTER_MAX_ENTRIES) return error.FooterEntryCountTooLarge;

        // 3. Bounds-check the body extent.
        const body_len: u64 = 4 + @as(u64, entry_count) * FooterEntry.encoded_size + 4;
        if (footer_offset + body_len != tail_offset) return error.FooterTruncated;

        // 4. Read the entries + trailing CRC32C in one shot.
        const entries_bytes: usize = @as(usize, entry_count) * FooterEntry.encoded_size;
        const tail_buf_len: usize = entries_bytes + 4;
        const body_buf = try allocator.alloc(u8, tail_buf_len);
        defer allocator.free(body_buf);
        const body_read = try file.readPositionalAll(io, body_buf, footer_offset + 4);
        if (body_read != tail_buf_len) return error.FooterTruncated;

        // 5. Verify CRC32C over [entry_count .. last entry].
        var hasher = Crc32C.init();
        hasher.update(&count_buf);
        hasher.update(body_buf[0..entries_bytes]);
        const computed = hasher.final();
        const stored = std.mem.readInt(u32, body_buf[entries_bytes..][0..4], .little);
        if (computed != stored) return error.FooterChecksumMismatch;

        // 6. Materialise the entries into a sorted, allocator-owned slice.
        const entries = try allocator.alloc(FooterEntry, entry_count);
        errdefer allocator.free(entries);
        var pos: usize = 0;
        for (entries) |*e| {
            e.* = FooterEntry.deserialize(body_buf[pos..][0..FooterEntry.encoded_size]);
            pos += FooterEntry.encoded_size;
        }

        return .{
            .footer = .{ .entries = entries, .crc32c = stored },
            .footer_offset = footer_offset,
        };
    }

    /// O(log series) lookup for the first block belonging to
    /// `series_id`. Returns `null` when:
    ///   * The segment has no footer (un-indexed legacy segment).
    ///   * The series has no blocks in this segment.
    /// The caller MUST treat the `null` case as "fall back to the
    /// full block scan", because the two situations are not
    /// distinguishable without a probe.
    pub fn findSeries(self: *const SegmentReader, series_id: types.SeriesId) ?FooterLookup {
        const f = self.footer orelse return null;
        return f.lookup(series_id);
    }

    /// Block iterator for reading through a segment.
    pub const BlockIterator = struct {
        reader: *SegmentReader,
        offset: u64,
        block_index: u32 = 0,

        pub fn next(self: *BlockIterator) !?Block {
            // P-ALGO-001 (partial): stop at `data_end_offset`, which
            // equals `file_size` for un-indexed segments and the
            // footer's starting offset for indexed segments. This is
            // what prevents the iterator from trying to parse the
            // FOOTER_BODY bytes as a `BlockHeader`.
            if (self.offset >= self.reader.data_end_offset) return null;

            var hdr_buf: [BlockHeader.encoded_size]u8 = undefined;
            const read_len = try self.reader.file.readPositionalAll(self.reader.io_ctx, &hdr_buf, self.offset);
            if (read_len != BlockHeader.encoded_size) return error.UnexpectedEOF;

            const header = BlockHeader.deserialize(&hdr_buf);

            const header_offset = self.offset;
            const block_idx = self.block_index;
            const data_offset = if (self.reader.encrypted)
                self.offset + BlockHeader.encoded_size + ENCRYPTION_NONCE_SIZE + ENCRYPTION_TAG_SIZE
            else
                self.offset + BlockHeader.encoded_size;
            self.offset = data_offset + header.data_len;
            self.block_index += 1;

            return Block{
                .header = header,
                .header_offset = header_offset,
                .data_offset = data_offset,
                .reader = self.reader,
                .block_index = block_idx,
            };
        }
    };

    pub fn iterator(self: *SegmentReader) BlockIterator {
        return .{
            .reader = self,
            .offset = SEGMENT_MAGIC.len, // both v2 and v3 magics are the same length
        };
    }
};

/// A block of points inside a segment file.
pub const Block = struct {
    header: BlockHeader,
    /// Offset of the body bytes (88 bytes).
    header_offset: u64,
    /// Offset of the payload bytes. For v2, this is `header_offset +
    /// 92` (body + crc32c). For v3, this is `header_offset + 92 +
    /// nonce(12) + tag(16) = header_offset + 120`.
    data_offset: u64,
    reader: *SegmentReader,
    /// Index of this block within the segment, used as part of the
    /// AAD for encrypted blocks. Tracked by `BlockIterator`.
    block_index: u32 = 0,

    /// Decode the points in this block. Verifies block integrity
    /// BEFORE allocating the decode buffer or invoking the Gorilla
    /// decoder, so a corrupted block cannot drive an out-of-bounds
    /// decode or oversized allocation.
    ///
    /// Integrity check:
    ///   * v2 (plaintext): CRC32C over (body || data).
    ///   * v3 (encrypted): AES-256-GCM tag verification with the
    ///     block-position AAD. A tag mismatch surfaces
    ///     `error.DecryptionFailed`.
    ///
    /// Errors:
    ///   * `error.BlockTooLarge` — data_len exceeds the cap.
    ///   * `error.UnexpectedEOF` — truncated read.
    ///   * `error.BlockCorrupted` — v2 CRC mismatch.
    ///   * `error.DecryptionFailed` — v3 tag check failed.
    ///   * Gorilla decode errors propagate unchanged.
    pub fn decodePoints(self: Block, allocator: Allocator) ![]types.Point {
        // CWE-770 cap.
        if (self.header.data_len > limits.MAX_BLOCK_DATA_LEN) return error.BlockTooLarge;

        if (self.reader.encrypted) {
            return self.decodeEncryptedPoints(allocator);
        }
        return self.decodePlaintextPoints(allocator);
    }

    fn decodePlaintextPoints(self: Block, allocator: Allocator) ![]types.Point {
        const data = try allocator.alloc(u8, self.header.data_len);
        defer allocator.free(data);

        const read_len = try self.reader.file.readPositionalAll(self.reader.io_ctx, data, self.data_offset);
        if (read_len != self.header.data_len) return error.UnexpectedEOF;

        // SEC-004: verify CRC32C over (body || data) before decoding.
        var body_buf: [BlockHeader.body_size]u8 = undefined;
        const body_read = try self.reader.file.readPositionalAll(self.reader.io_ctx, &body_buf, self.header_offset);
        if (body_read != BlockHeader.body_size) return error.UnexpectedEOF;

        var hasher = Crc32C.init();
        hasher.update(&body_buf);
        hasher.update(data);
        const computed = hasher.final();
        if (computed != self.header.crc32c) return error.BlockCorrupted;

        var decoder = gorilla.GorillaDecoder.init(data, self.header.stats.count);
        return decoder.decodeAll(allocator);
    }

    fn decodeEncryptedPoints(self: Block, allocator: Allocator) ![]types.Point {
        const enc = self.reader.encryption.?;

        // v3 on-disk layout for this block (relative to header_offset):
        //   [0..88)   body
        //   [88..92)  unused (kept for alignment with v2 layout)
        //   [92..104) nonce (12 bytes)
        //   [104..120) tag (16 bytes)
        //   [120..120+data_len) ciphertext

        var nonce: [ENCRYPTION_NONCE_SIZE]u8 = undefined;
        const nonce_off = self.header_offset + BlockHeader.encoded_size;
        const nonce_read = try self.reader.file.readPositionalAll(self.reader.io_ctx, &nonce, nonce_off);
        if (nonce_read != ENCRYPTION_NONCE_SIZE) return error.UnexpectedEOF;

        var tag: [ENCRYPTION_TAG_SIZE]u8 = undefined;
        const tag_off = nonce_off + ENCRYPTION_NONCE_SIZE;
        const tag_read = try self.reader.file.readPositionalAll(self.reader.io_ctx, &tag, tag_off);
        if (tag_read != ENCRYPTION_TAG_SIZE) return error.UnexpectedEOF;

        const ciphertext = try allocator.alloc(u8, self.header.data_len);
        defer allocator.free(ciphertext);
        const ct_read = try self.reader.file.readPositionalAll(self.reader.io_ctx, ciphertext, self.data_offset);
        if (ct_read != self.header.data_len) return error.UnexpectedEOF;

        // Reconstruct AAD: graph_uuid || "seg" || segment_id || block_index.
        var aad: [16 + 3 + 8 + 4]u8 = undefined;
        @memcpy(aad[0..16], &enc.graph_uuid);
        @memcpy(aad[16..19], "seg");
        std.mem.writeInt(u64, aad[19..27], enc.segment_id, .little);
        std.mem.writeInt(u32, aad[27..31], self.block_index, .little);

        const plaintext = try allocator.alloc(u8, self.header.data_len);
        errdefer allocator.free(plaintext);
        // FIPS-0006: block AES-256-GCM open via the seam.
        crypto_backend.Aead.open(.aes_256_gcm, &enc.key, &nonce, &aad, ciphertext, &tag, plaintext) catch {
            return error.DecryptionFailed;
        };
        defer allocator.free(plaintext);

        var decoder = gorilla.GorillaDecoder.init(plaintext, self.header.stats.count);
        return decoder.decodeAll(allocator);
    }
};

test "Segment: encrypted round-trip with correct key (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/enc.tsseg", .{path});
    defer allocator.free(seg_path);

    const key: [32]u8 = [_]u8{0x42} ** 32;
    const uuid: [16]u8 = [_]u8{0x77} ** 16;
    const enc: EncryptionContext = .{ .key = key, .graph_uuid = uuid, .segment_id = 99 };

    const pts = [_]types.Point{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 200, .value = 2 },
        .{ .ts = 300, .value = 3 },
    };

    {
        var w = try SegmentWriter.initWithEncryption(allocator, seg_path, enc);
        defer w.deinit();
        try w.writeBlock(7, &pts);
        try w.sync();
    }

    var r = try SegmentReader.initWithEncryption(allocator, seg_path, enc);
    defer r.deinit();
    try std.testing.expect(r.encrypted);

    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    const decoded = try blk.decodePoints(allocator);
    defer allocator.free(decoded);
    try std.testing.expectEqual(pts.len, decoded.len);
    for (pts, 0..) |expected, i| {
        try std.testing.expectEqual(expected.ts, decoded[i].ts);
        try std.testing.expectEqual(expected.value, decoded[i].value);
    }
}

test "Segment: encrypted segment rejects wrong key (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/enc_wrong.tsseg", .{path});
    defer allocator.free(seg_path);

    const key_a: [32]u8 = [_]u8{0xAA} ** 32;
    const key_b: [32]u8 = [_]u8{0xBB} ** 32;
    const uuid: [16]u8 = [_]u8{0x11} ** 16;
    const enc_a: EncryptionContext = .{ .key = key_a, .graph_uuid = uuid, .segment_id = 1 };
    const enc_b: EncryptionContext = .{ .key = key_b, .graph_uuid = uuid, .segment_id = 1 };

    {
        var w = try SegmentWriter.initWithEncryption(allocator, seg_path, enc_a);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    // Open with the wrong key: header read succeeds (the magic check
    // is independent of the key), the failure surfaces at decode time.
    var r = try SegmentReader.initWithEncryption(allocator, seg_path, enc_b);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectError(error.DecryptionFailed, blk.decodePoints(allocator));
}

test "Segment: encrypted segment rejects open with no key (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/enc_nokey.tsseg", .{path});
    defer allocator.free(seg_path);

    const key: [32]u8 = [_]u8{0x33} ** 32;
    const uuid: [16]u8 = [_]u8{0x55} ** 16;
    const enc: EncryptionContext = .{ .key = key, .graph_uuid = uuid, .segment_id = 2 };

    {
        var w = try SegmentWriter.initWithEncryption(allocator, seg_path, enc);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    try std.testing.expectError(error.DecryptionFailed, SegmentReader.init(allocator, seg_path));
}

test "Segment: plaintext segment rejects open with key (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/plain.tsseg", .{path});
    defer allocator.free(seg_path);

    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    const key: [32]u8 = [_]u8{0x66} ** 32;
    const uuid: [16]u8 = [_]u8{0x77} ** 16;
    const enc: EncryptionContext = .{ .key = key, .graph_uuid = uuid, .segment_id = 1 };

    try std.testing.expectError(
        error.UnexpectedPlaintextSegment,
        SegmentReader.initWithEncryption(allocator, seg_path, enc),
    );
}

test "Segment: encrypted segment AAD binds segment_id (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/aad.tsseg", .{path});
    defer allocator.free(seg_path);

    const key: [32]u8 = [_]u8{0xDE} ** 32;
    const uuid: [16]u8 = [_]u8{0xAD} ** 16;
    const enc_write: EncryptionContext = .{ .key = key, .graph_uuid = uuid, .segment_id = 100 };
    // Decode with a DIFFERENT segment_id — the AAD will not match
    // and the GCM tag check must fail.
    const enc_read: EncryptionContext = .{ .key = key, .graph_uuid = uuid, .segment_id = 101 };

    {
        var w = try SegmentWriter.initWithEncryption(allocator, seg_path, enc_write);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    var r = try SegmentReader.initWithEncryption(allocator, seg_path, enc_read);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectError(error.DecryptionFailed, blk.decodePoints(allocator));
}

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

test "Segment: decodePoints refuses oversized data_len" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/bad.tsseg", .{path});
    defer allocator.free(seg_path);

    // Hand-craft a segment file: magic + a single header with a
    // data_len that exceeds MAX_BLOCK_DATA_LEN. We never write the
    // payload — the decode-time check fires first.
    {
        const f = try std.Io.Dir.cwd().createFile(io, seg_path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer f.close(io);
        try f.writeStreamingAll(io, &SEGMENT_MAGIC);

        var hdr_buf: [BlockHeader.encoded_size]u8 = undefined;
        const h = BlockHeader{
            .series_id = 1,
            .stats = .{
                .min_ts = 0,
                .max_ts = 1,
                .count = 1,
                .min_value = 0,
                .max_value = 1,
                .sum = 0,
                .first_value = 0,
                .last_value = 0,
            },
            .data_len = limits.MAX_BLOCK_DATA_LEN + 1,
        };
        h.serialize(&hdr_buf);
        try f.writeStreamingAll(io, &hdr_buf);
        try f.sync(io);
    }

    var reader = try SegmentReader.init(allocator, seg_path);
    defer reader.deinit();
    var it = reader.iterator();
    const blk = (try it.next()).?;

    try std.testing.expectError(error.BlockTooLarge, blk.decodePoints(allocator));
}

test "Segment: per-block CRC32C catches a flipped byte in the payload (SEC-004)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/corrupt.tsseg", .{path});
    defer allocator.free(seg_path);

    // Step 1: write a normal segment with a single block.
    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(42, &.{
            .{ .ts = 100, .value = 10 },
            .{ .ts = 200, .value = 20 },
            .{ .ts = 300, .value = 30 },
        });
        try w.sync();
    }

    // Step 2: flip exactly one byte in the payload area. The
    // payload begins at SEGMENT_MAGIC.len + BlockHeader.encoded_size.
    {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{ .mode = .read_write });
        defer f.close(io);
        const payload_offset: u64 = SEGMENT_MAGIC.len + BlockHeader.encoded_size;
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &byte, payload_offset);
        byte[0] ^= 0xFF;
        try f.writePositionalAll(io, &byte, payload_offset);
        try f.sync(io);
    }

    // Step 3: read and assert BlockCorrupted is surfaced.
    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;

    try std.testing.expectError(error.BlockCorrupted, blk.decodePoints(allocator));
}

test "Segment: per-block CRC32C catches a flipped byte in the header (SEC-004)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/corrupt_hdr.tsseg", .{path});
    defer allocator.free(seg_path);

    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(7, &.{
            .{ .ts = 1, .value = 1 },
            .{ .ts = 2, .value = 2 },
        });
        try w.sync();
    }

    // Flip a byte inside the stats portion of the header (between
    // series_id and data_len) — not in the crc field itself. The
    // CRC was computed over the body, so this flip MUST be caught.
    {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{ .mode = .read_write });
        defer f.close(io);
        // Offset of stats.first_value within the body = 16+8+8+4+8+8+16 = 68.
        const flip_offset: u64 = SEGMENT_MAGIC.len + 68;
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &byte, flip_offset);
        byte[0] ^= 0x01;
        try f.writePositionalAll(io, &byte, flip_offset);
        try f.sync(io);
    }

    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectError(error.BlockCorrupted, blk.decodePoints(allocator));
}

test "Segment: rejects v1 (TSSEG001) magic on open" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/v1.tsseg", .{path});
    defer allocator.free(seg_path);

    // Stamp a v1 magic + a body's worth of zero bytes so the file is
    // long enough to be considered a candidate.
    {
        const f = try std.Io.Dir.cwd().createFile(io, seg_path, .{
            .read = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer f.close(io);
        const v1_magic: [8]u8 = .{ 'T', 'S', 'S', 'E', 'G', '0', '0', '1' };
        try f.writeStreamingAll(io, &v1_magic);
        try f.sync(io);
    }

    try std.testing.expectError(error.InvalidMagic, SegmentReader.init(allocator, seg_path));
}

test "SegmentWriter.sync survives a roundtrip" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/sync.tsseg", .{path});
    defer allocator.free(seg_path);

    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(1, &.{
            .{ .ts = 100, .value = 1 },
            .{ .ts = 200, .value = 2 },
        });
        try w.sync();
    }

    // After sync + close, the reader should still see the block.
    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectEqual(@as(u32, 2), blk.header.stats.count);
}

// ---------------------------------------------------------------------------
// P-ALGO-001 (partial): footer-index tests
// ---------------------------------------------------------------------------

test "Footer: round-trip writes + reads a footer with 5 series (P-ALGO-001 partial)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/footer.tsseg", .{path});
    defer allocator.free(seg_path);

    // Five distinct series, two blocks each, written in interleaved
    // series order to exercise the writer's per-series accumulator.
    // Out-of-order series IDs verify that the footer is SORTED on
    // disk regardless of insertion order.
    const series_ids = [_]types.SeriesId{ 500, 100, 300, 700, 200 };
    var expected_first_offsets: [series_ids.len]u64 = undefined;
    var expected_counts: [series_ids.len]u32 = undefined;

    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        for (series_ids, 0..) |sid, i| {
            expected_first_offsets[i] = w.current_offset;
            expected_counts[i] = 2;
            try w.writeBlock(sid, &.{
                .{ .ts = 100, .value = 1 },
                .{ .ts = 200, .value = 2 },
            });
            try w.writeBlock(sid, &.{
                .{ .ts = 300, .value = 3 },
                .{ .ts = 400, .value = 4 },
            });
        }
        try w.sync();
    }

    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    try std.testing.expect(r.footer != null);
    try std.testing.expectEqual(@as(usize, series_ids.len), r.footer.?.entries.len);

    // Entries must be sorted ascending by series_id even though we
    // wrote them in scrambled order.
    var prev: types.SeriesId = 0;
    for (r.footer.?.entries) |e| {
        try std.testing.expect(e.series_id > prev);
        prev = e.series_id;
    }

    // findSeries must hand back the offsets we recorded at write time.
    for (series_ids, 0..) |sid, i| {
        const hit = r.findSeries(sid) orelse return error.MissingSeries;
        try std.testing.expectEqual(expected_first_offsets[i], hit.offset);
        try std.testing.expectEqual(expected_counts[i], hit.count);
    }

    // A series that was never written must not appear in the index.
    try std.testing.expect(r.findSeries(9999) == null);

    // The block iterator must stop at the footer, not stream into it.
    var it = r.iterator();
    var blocks_seen: u32 = 0;
    while (try it.next()) |_| blocks_seen += 1;
    try std.testing.expectEqual(@as(u32, series_ids.len * 2), blocks_seen);
}

test "Footer: backwards-compat reader handles segment with no footer (P-ALGO-001 partial)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/legacy.tsseg", .{path});
    defer allocator.free(seg_path);

    // Hand-craft a v2 segment that exactly matches the pre-footer
    // on-disk layout: magic followed by a single block (header +
    // body computed via the public `writeBlock` path against a
    // separate file), then truncated so no footer tail is present.
    // We build it by calling the writer normally, then truncating
    // the file BACK to the post-block-region offset to drop the
    // footer the writer just appended.
    var post_block_offset: u64 = 0;
    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(1, &.{
            .{ .ts = 100, .value = 1 },
            .{ .ts = 200, .value = 2 },
        });
        post_block_offset = w.current_offset;
        try w.sync();
    }

    // Re-open and truncate everything after the last data block to
    // simulate a legacy (pre-footer) segment on disk.
    {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{ .mode = .read_write });
        defer f.close(io);
        try f.setLength(io, post_block_offset);
        try f.sync(io);
    }

    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    try std.testing.expect(r.footer == null);
    try std.testing.expectEqual(post_block_offset, r.data_end_offset);
    try std.testing.expect(r.findSeries(1) == null);

    // The block must still be readable via the existing iterator path.
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectEqual(@as(u32, 2), blk.header.stats.count);
    try std.testing.expectEqual(@as(types.SeriesId, 1), blk.header.series_id);
    try std.testing.expect((try it.next()) == null);
}

test "Footer: corrupted CRC32C falls back to no-footer mode (P-ALGO-001 partial)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/badfooter.tsseg", .{path});
    defer allocator.free(seg_path);

    var footer_offset: u64 = 0;
    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.writeBlock(42, &.{
            .{ .ts = 10, .value = 1 },
            .{ .ts = 20, .value = 2 },
        });
        footer_offset = w.current_offset; // captured BEFORE sync
        try w.sync();
    }

    // Flip one byte inside the footer body — specifically the LAST
    // byte before the trailing 16-byte tail, which is the CRC32C
    // field. This guarantees a CRC mismatch without disturbing the
    // sentinel magic, so the reader still finds the footer but
    // rejects it on CRC.
    {
        const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{ .mode = .read_write });
        defer f.close(io);
        const file_len = try f.length(io);
        const crc_byte_offset = file_len - FOOTER_TAIL_SIZE - 1;
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &byte, crc_byte_offset);
        byte[0] ^= 0xFF;
        try f.writePositionalAll(io, &byte, crc_byte_offset);
        try f.sync(io);
    }

    var r = try SegmentReader.init(allocator, seg_path);
    defer r.deinit();
    // Footer rejected -> reader degrades to full-scan mode. The
    // segment is still fully readable; we MUST NOT lose data.
    try std.testing.expect(r.footer == null);
    try std.testing.expect(r.findSeries(42) == null);
    // data_end_offset falls back to the full file size because the
    // footer could not be parsed; the block iterator will stop on
    // its own when it reads past the last legitimate block header
    // and hits garbage. We only check that the FIRST block is still
    // recoverable — that's the backwards-compat guarantee.
    var it = r.iterator();
    const blk = (try it.next()) orelse return error.MissingBlock;
    try std.testing.expectEqual(@as(types.SeriesId, 42), blk.header.series_id);
    try std.testing.expectEqual(@as(u32, 2), blk.header.stats.count);
}

test "Footer: encrypted segments also get a (plaintext) footer (P-ALGO-001 partial)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/enc_footer.tsseg", .{path});
    defer allocator.free(seg_path);

    const key: [32]u8 = [_]u8{0x11} ** 32;
    const uuid: [16]u8 = [_]u8{0x22} ** 16;
    const enc: EncryptionContext = .{ .key = key, .graph_uuid = uuid, .segment_id = 42 };

    {
        var w = try SegmentWriter.initWithEncryption(allocator, seg_path, enc);
        defer w.deinit();
        try w.writeBlock(7, &.{ .{ .ts = 100, .value = 1 }, .{ .ts = 200, .value = 2 } });
        try w.writeBlock(9, &.{ .{ .ts = 300, .value = 3 }, .{ .ts = 400, .value = 4 } });
        try w.sync();
    }

    var r = try SegmentReader.initWithEncryption(allocator, seg_path, enc);
    defer r.deinit();
    try std.testing.expect(r.encrypted);
    try std.testing.expect(r.footer != null);
    try std.testing.expectEqual(@as(usize, 2), r.footer.?.entries.len);
    try std.testing.expect(r.findSeries(7) != null);
    try std.testing.expect(r.findSeries(9) != null);
    try std.testing.expect(r.findSeries(11) == null);

    // And the encrypted decode path must still work end-to-end.
    var it = r.iterator();
    var seen: u32 = 0;
    while (try it.next()) |blk| {
        const pts = try blk.decodePoints(allocator);
        defer allocator.free(pts);
        seen += @intCast(pts.len);
    }
    try std.testing.expectEqual(@as(u32, 4), seen);
}

test "Footer: writer that never appends emits no footer (P-ALGO-001 partial)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/empty.tsseg", .{path});
    defer allocator.free(seg_path);

    {
        var w = try SegmentWriter.init(allocator, seg_path);
        defer w.deinit();
        try w.sync(); // no writeBlock calls — footer must be skipped
    }

    // File should be exactly the magic with no trailing bytes.
    const f = try std.Io.Dir.cwd().openFile(io, seg_path, .{});
    defer f.close(io);
    try std.testing.expectEqual(@as(u64, SEGMENT_MAGIC.len), try f.length(io));
}

test "FooterEntry: serialize/deserialize round-trip" {
    var buf: [FooterEntry.encoded_size]u8 = undefined;
    const e: FooterEntry = .{
        .series_id = 0xDEADBEEF_CAFEBABE_1234567890ABCDEF,
        .first_block_offset = 0x123456789ABCDEF0,
        .block_count = 0x12345678,
    };
    e.serialize(&buf);
    const d = FooterEntry.deserialize(&buf);
    try std.testing.expectEqual(e.series_id, d.series_id);
    try std.testing.expectEqual(e.first_block_offset, d.first_block_offset);
    try std.testing.expectEqual(e.block_count, d.block_count);
}

test "Footer.lookup: binary search hits and misses" {
    const allocator = std.testing.allocator;
    const entries = try allocator.alloc(FooterEntry, 4);
    defer allocator.free(entries);
    entries[0] = .{ .series_id = 10, .first_block_offset = 100, .block_count = 1 };
    entries[1] = .{ .series_id = 20, .first_block_offset = 200, .block_count = 2 };
    entries[2] = .{ .series_id = 30, .first_block_offset = 300, .block_count = 3 };
    entries[3] = .{ .series_id = 40, .first_block_offset = 400, .block_count = 4 };

    const f: Footer = .{ .entries = entries, .crc32c = 0 };

    try std.testing.expectEqual(@as(u64, 100), f.lookup(10).?.offset);
    try std.testing.expectEqual(@as(u64, 200), f.lookup(20).?.offset);
    try std.testing.expectEqual(@as(u64, 300), f.lookup(30).?.offset);
    try std.testing.expectEqual(@as(u64, 400), f.lookup(40).?.offset);
    try std.testing.expect(f.lookup(5) == null);
    try std.testing.expect(f.lookup(15) == null);
    try std.testing.expect(f.lookup(45) == null);
    try std.testing.expectEqual(@as(u32, 3), f.lookup(30).?.count);
}

test "FIPS-0006: encrypted block path uses the seam (Aead decl reachable)" {
    // The full encrypted round-trip + tamper-detect is covered by the existing
    // "Segment: encrypted round-trip" tests, which now exercise the seam-routed
    // AES-256-GCM seal/open. This asserts the seam symbol the routing depends on.
    try std.testing.expect(@hasDecl(crypto_backend, "Aead"));
}
