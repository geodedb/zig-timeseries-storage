const std = @import("std");
const types = @import("../types.zig");
const limits = @import("../limits.zig");

pub const BlockStats = struct {
    min_ts: i64,
    max_ts: i64,
    count: u32,
    min_value: i64,
    max_value: i64,
    sum: i128,
    first_value: i64,
    last_value: i64,
};

/// Gorilla compression context.
pub const GorillaEncoder = struct {
    bits: std.DynamicBitSet,
    bit_pos: usize,
    stats: BlockStats,
    prev_ts: i64,
    prev_delta: i64,
    prev_value: i64,
    prev_xor: u64,
    prev_leading: u8,
    prev_trailing: u8,

    /// Lower bound for the initial bitset capacity. Even when the
    /// caller knows zero points, we keep a minimum of 128 bits so the
    /// first `writeBit` does not trigger an immediate resize.
    pub const MIN_INITIAL_BITS: usize = 128;

    /// Typical Gorilla compression for "real" workloads lands near
    /// 1.3 bits per value plus the two 64-bit raw values for the
    /// first point. We use 18 bits / point as a slightly conservative
    /// average that covers both timestamp and value channels for a
    /// mid-range delta-of-delta + XOR encoding (real-world rates are
    /// typically 12–18 bits / point combined). Pre-sizing to this
    /// budget eliminates almost every realloc-doubling cycle on the
    /// hot writeBlock path. Closes P-MEM-002.
    pub const TYPICAL_BITS_PER_POINT: usize = 18;

    pub fn init(allocator: std.mem.Allocator) !GorillaEncoder {
        return initWithCapacity(allocator, 65536);
    }

    /// Allocate an encoder pre-sized for an estimated bit budget.
    /// `estimated_bits` is clamped to `[MIN_INITIAL_BITS,
    /// MAX_POINTS_PER_BLOCK_ABSOLUTE * 128]`. Closes P-MEM-002.
    ///
    /// The cap matches the upper limit of what `encodePoint` will
    /// ever produce — `MAX_POINTS_PER_BLOCK_ABSOLUTE` points at the
    /// theoretical worst-case 128 bits per point (no compression at
    /// all). Larger requests are silently clamped because anything
    /// above the cap would also be refused by `encodePoint`.
    pub fn initWithCapacity(allocator: std.mem.Allocator, estimated_bits: usize) !GorillaEncoder {
        const MAX_BITS = limits.MAX_POINTS_PER_BLOCK_ABSOLUTE * 128;
        var cap = estimated_bits;
        if (cap < MIN_INITIAL_BITS) cap = MIN_INITIAL_BITS;
        if (cap > MAX_BITS) cap = MAX_BITS;
        return .{
            .bits = try std.DynamicBitSet.initEmpty(allocator, cap),
            .bit_pos = 0,
            .stats = .{
                .min_ts = std.math.maxInt(i64),
                .max_ts = std.math.minInt(i64),
                .count = 0,
                .min_value = std.math.maxInt(i64),
                .max_value = std.math.minInt(i64),
                .sum = 0,
                .first_value = 0,
                .last_value = 0,
            },
            .prev_ts = 0,
            .prev_delta = 0,
            .prev_value = 0,
            .prev_xor = 0,
            .prev_leading = 0,
            .prev_trailing = 0,
        };
    }

    /// Convenience: pre-size for `num_points` using
    /// `TYPICAL_BITS_PER_POINT`. Closes P-MEM-002.
    pub fn initForPoints(allocator: std.mem.Allocator, num_points: usize) !GorillaEncoder {
        // Saturate the multiplication: the upper clamp inside
        // `initWithCapacity` will trim anything pathological.
        const estimated = if (num_points > std.math.maxInt(usize) / TYPICAL_BITS_PER_POINT)
            std.math.maxInt(usize)
        else
            num_points * TYPICAL_BITS_PER_POINT;
        return initWithCapacity(allocator, estimated);
    }

    pub fn deinit(self: *GorillaEncoder) void {
        self.bits.deinit();
    }

    /// Reset encoder state for a fresh block while retaining the
    /// `DynamicBitSet` backing allocation. ENT-003: callers that
    /// produce many blocks back-to-back (e.g. `SegmentWriter.writeBlock`
    /// loops in flush + compaction) avoid one bitset allocation per
    /// block by pooling the encoder and calling `reset()` between blocks
    /// instead of `init/deinit`.
    ///
    /// Equivalent to constructing a new encoder via `initWithCapacity`
    /// at the current capacity, minus the allocation. Logically the
    /// bitset behaves as if it had been re-initialised: subsequent
    /// `writeBit` / `writeBits` calls land starting at bit position 0
    /// and overwrite any residual bits.
    ///
    /// Implementation note: we deliberately do NOT call
    /// `self.bits.resize(0, false)` to "truncate". The Zig 0.16
    /// `DynamicBitSetUnmanaged.resize` implementation (see
    /// `lib/std/bit_set.zig:747-752`) explicitly frees the mask array
    /// when `new_len == 0`, which would defeat the entire purpose of
    /// pooling — the next `writeBit` would have to reallocate. Instead
    /// we leave `bits.bit_length` unchanged (preserving capacity) and
    /// rely on the fact that `writeBit` uses `setValue` and `writeBits`
    /// explicitly clear-then-set each destination bit, so residual
    /// contents from the previous block are unconditionally overwritten
    /// as new bits are written.
    ///
    /// If the next block exceeds the retained capacity, the bitset
    /// grows normally through `writeBit` / `writeBits` — that path is
    /// exactly what `initWithCapacity` would do on a fresh encoder.
    pub fn reset(self: *GorillaEncoder) void {
        self.bit_pos = 0;
        self.stats = .{
            .min_ts = std.math.maxInt(i64),
            .max_ts = std.math.minInt(i64),
            .count = 0,
            .min_value = std.math.maxInt(i64),
            .max_value = std.math.minInt(i64),
            .sum = 0,
            .first_value = 0,
            .last_value = 0,
        };
        self.prev_ts = 0;
        self.prev_delta = 0;
        self.prev_value = 0;
        self.prev_xor = 0;
        self.prev_leading = 0;
        self.prev_trailing = 0;
    }

    /// Encode a time-series point using Gorilla compression.
    ///
    /// On the first point, both the timestamp and the value are
    /// stored verbatim. From the second point onward the timestamp is
    /// encoded as delta-of-delta against the previous delta, and the
    /// value is encoded as XOR against the previous value — see
    /// `encodeTimestamp` and `encodeValue` for the per-field
    /// encodings.
    pub fn encodePoint(self: *GorillaEncoder, point: types.Point) !void {
        // CWE-770: hard cap on points per block. Without this the
        // internal `DynamicBitSet` would double its capacity every
        // time `writeBits` runs out of room; an adversarial caller
        // could OOM the process by encoding indefinitely. The cap
        // is checked on `count` *before* the increment so the limit
        // is inclusive.
        if (self.stats.count >= limits.MAX_POINTS_PER_BLOCK_ABSOLUTE) {
            return error.BlockPointLimitExceeded;
        }
        self.stats.count += 1;
        self.stats.sum += @as(i128, point.value);
        if (point.ts < self.stats.min_ts) self.stats.min_ts = point.ts;
        if (point.ts > self.stats.max_ts) self.stats.max_ts = point.ts;
        if (point.value < self.stats.min_value) self.stats.min_value = point.value;
        if (point.value > self.stats.max_value) self.stats.max_value = point.value;
        self.stats.last_value = point.value;

        if (self.stats.count == 1) {
            self.stats.first_value = point.value;
            try self.writeRaw(64, @bitCast(point.ts));
            try self.writeRaw(64, @bitCast(point.value));
            self.prev_ts = point.ts;
            self.prev_value = point.value;
            return;
        }

        try self.encodeTimestamp(point.ts);
        try self.encodeValue(point.value);
    }

    /// Emit the timestamp portion of a non-first point.
    ///
    /// Computes `delta_of_delta = (ts - prev_ts) - prev_delta` and
    /// stores it with a variable-length prefix code (Gorilla's
    /// standard buckets — 1, 7, 9, 12, or 32 significant bits) so
    /// near-regular interval streams collapse to a single zero bit
    /// per point. Updates `prev_delta` and `prev_ts` on success.
    fn encodeTimestamp(self: *GorillaEncoder, ts: i64) !void {
        const delta = ts - self.prev_ts;
        const delta_of_delta = delta - self.prev_delta;

        if (delta_of_delta == 0) {
            try self.writeBit(0);
        } else if (delta_of_delta >= -63 and delta_of_delta <= 64) {
            try self.writeBits(2, 0b10);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0x7F;
            try self.writeBits(7, v);
        } else if (delta_of_delta >= -255 and delta_of_delta <= 256) {
            try self.writeBits(3, 0b110);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0x1FF;
            try self.writeBits(9, v);
        } else if (delta_of_delta >= -2047 and delta_of_delta <= 2048) {
            try self.writeBits(4, 0b1110);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0xFFF;
            try self.writeBits(12, v);
        } else {
            try self.writeBits(4, 0b1111);
            const v: u64 = @as(u64, @bitCast(@as(i64, delta_of_delta))) & 0xFFFFFFFF;
            try self.writeBits(32, v);
        }

        self.prev_delta = delta;
        self.prev_ts = ts;
    }

    /// Emit the value portion of a non-first point.
    ///
    /// Computes `xor = value ^ prev_value` and stores:
    ///   * `0`            — value unchanged.
    ///   * `1 0 <bits>`   — XOR fits inside the previous
    ///     leading/trailing zero envelope (reuse).
    ///   * `1 1 <leading:5> <bits_count:6> <bits>` — new envelope.
    /// Updates `prev_value` and (on a new envelope) `prev_leading` /
    /// `prev_trailing`.
    fn encodeValue(self: *GorillaEncoder, value: i64) !void {
        const xor: u64 = @bitCast(value ^ self.prev_value);

        if (xor == 0) {
            try self.writeBit(0);
        } else {
            try self.writeBit(1);

            const leading = @clz(xor);
            const trailing = @ctz(xor);

            if (leading >= self.prev_leading and trailing >= self.prev_trailing) {
                try self.writeBit(0);
                const significant_bits = 64 - self.prev_leading - self.prev_trailing;
                const shifted = xor >> @intCast(self.prev_trailing);
                try self.writeBits(@intCast(significant_bits), shifted);
            } else {
                try self.writeBit(1);
                try self.writeBits(5, leading);
                const significant_bits = 64 - leading - trailing;
                try self.writeBits(6, significant_bits);
                const shifted = xor >> @intCast(trailing);
                try self.writeBits(@intCast(significant_bits), shifted);

                self.prev_leading = leading;
                self.prev_trailing = trailing;
            }
        }

        self.prev_value = value;
        self.prev_xor = xor;
    }

    fn writeBit(self: *GorillaEncoder, bit: u1) !void {
        if (self.bit_pos >= self.bits.capacity()) {
            try self.bits.resize(self.bits.capacity() * 2, false);
        }
        self.bits.setValue(self.bit_pos, bit == 1);
        self.bit_pos += 1;
    }

    /// Write up to 64 bits at once using direct mask manipulation.
    /// Bits are written MSB-first: the highest bit of `value` (bit num_bits-1)
    /// is placed at the current bit_pos, and the lowest bit (bit 0) at
    /// bit_pos + num_bits - 1.
    ///
    /// Performance: Single capacity check for all bits instead of per-bit,
    /// and direct mask pointer writes without per-bit bounds checking or
    /// function call overhead.
    fn writeBits(self: *GorillaEncoder, num_bits: u8, value: u64) !void {
        if (num_bits == 0) return;

        // Ensure capacity for all bits in one check instead of per-bit.
        const required = self.bit_pos + num_bits;
        if (required > self.bits.capacity()) {
            var new_cap = self.bits.capacity();
            while (new_cap < required) new_cap *= 2;
            try self.bits.resize(new_cap, false);
        }

        const masks = self.bits.unmanaged.masks;
        const mask_bits: u8 = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
        const ShiftInt = std.DynamicBitSetUnmanaged.ShiftInt;

        // Write bits directly into the mask words without per-bit capacity
        // checks. Each bit at position `p` maps to masks[p / mask_bits] at
        // bit (p % mask_bits). We write MSB-first: bit (num_bits-1) of
        // value goes to bit_pos, bit 0 goes to bit_pos + num_bits - 1.
        var bit_idx: u8 = num_bits;
        var pos = self.bit_pos;
        while (bit_idx > 0) {
            const word_idx = pos / mask_bits;
            const dst_bit: ShiftInt = @intCast(pos % mask_bits);
            const src_bit: u6 = @intCast(bit_idx - 1);
            const b: usize = @intCast((value >> src_bit) & 1);
            masks[word_idx] = (masks[word_idx] & ~(@as(usize, 1) << dst_bit)) | (b << dst_bit);
            bit_idx -= 1;
            pos += 1;
        }

        self.bit_pos = pos;
    }

    fn writeRaw(self: *GorillaEncoder, num_bits: u8, value: u64) !void {
        try self.writeBits(num_bits, value);
    }

    /// Extract compressed data as a byte array.
    ///
    /// Performance: Reads full words from the internal mask array and
    /// extracts bytes with bit-reversal, avoiding per-bit isSet() calls
    /// and their associated bounds checks.
    pub fn getCompressedData(self: *GorillaEncoder, allocator: std.mem.Allocator) ![]u8 {
        const byte_count = (self.bit_pos + 7) / 8;
        const result = try allocator.alloc(u8, byte_count);

        const masks = self.bits.unmanaged.masks;
        const mask_bits = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
        const bytes_per_word = mask_bits / 8;

        // Process full words: extract bytes directly from each mask word.
        // Within each word, bits are stored LSB-first (bit 0 = least significant).
        // Output bytes need MSB-first ordering (bitset position i*8+0 -> byte bit 7).
        // So each byte is @bitReverse of the corresponding 8 bits in the word.
        const full_words = byte_count / bytes_per_word;
        for (0..full_words) |word_idx| {
            const word = masks[word_idx];
            const base = word_idx * bytes_per_word;
            inline for (0..bytes_per_word) |b| {
                const raw: u8 = @truncate(word >> (b * 8));
                result[base + b] = @bitReverse(raw);
            }
        }

        // Process remaining bytes that don't fill a complete word.
        const remaining_start = full_words * bytes_per_word;
        if (remaining_start < byte_count) {
            const word = masks[full_words];
            for (remaining_start..byte_count) |i| {
                const byte_in_word = i - remaining_start;
                var raw: u8 = @truncate(word >> @intCast(byte_in_word * 8));
                // Mask off bits beyond bit_pos for the final byte.
                if (i == byte_count - 1 and self.bit_pos % 8 != 0) {
                    const valid_bits: u3 = @intCast(self.bit_pos % 8);
                    // Only the first `valid_bits` bits of this byte are valid.
                    // In the raw byte (LSB-first from the word), those are
                    // the lowest `valid_bits` bits.
                    const keep_mask: u8 = (@as(u8, 1) << valid_bits) - 1;
                    raw &= keep_mask;
                }
                result[i] = @bitReverse(raw);
            }
        }

        return result;
    }
};

/// Gorilla decompression context -- reverses GorillaEncoder.
pub const GorillaDecoder = struct {
    data: []const u8,
    bit_pos: usize,
    total_bits: usize,
    prev_ts: i64,
    prev_delta: i64,
    prev_value: i64,
    prev_leading: u8,
    prev_trailing: u8,
    point_count: usize,
    num_points: u32,

    pub fn init(data: []const u8, num_points: u32) GorillaDecoder {
        return .{
            .data = data,
            .bit_pos = 0,
            .total_bits = data.len * 8,
            .prev_ts = 0,
            .prev_delta = 0,
            .prev_value = 0,
            .prev_leading = 0,
            .prev_trailing = 0,
            .point_count = 0,
            .num_points = num_points,
        };
    }

    fn readBit(self: *GorillaDecoder) !u1 {
        if (self.bit_pos >= self.total_bits) return error.EndOfStream;
        const byte_idx = self.bit_pos / 8;
        const bit_idx: u3 = @intCast(7 - (self.bit_pos % 8));
        const bit: u1 = @intCast((self.data[byte_idx] >> bit_idx) & 1);
        self.bit_pos += 1;
        return bit;
    }

    /// Bulk read up to 64 bits at once (P-ALGO-005).
    ///
    /// Builds a temporary 64-bit word by loading up to 9 consecutive
    /// bytes from the stream and shifting them into a register, then
    /// extracts `num_bits` from the MSB end. This replaces the previous
    /// per-bit loop that called `readBit` `num_bits` times, eliminating
    /// the per-iteration bounds check, modulo, and shift overhead.
    ///
    /// On-disk encoding (matches `GorillaEncoder.getCompressedData`):
    /// bytes are stored MSB-first — bit at stream position `p` is the
    /// `7 - (p % 8)` bit of `data[p / 8]`. To read `num_bits` starting
    /// at `bit_pos`, we:
    ///
    ///   1. Load 9 consecutive bytes into a u128 (handles up to a
    ///      7-bit start offset plus 64 bits of payload).
    ///   2. Shift the loaded value so the first bit of the payload is
    ///      at the MSB of the high u64 half.
    ///   3. Return the top `num_bits` bits.
    ///
    /// Carefully handles three edge cases:
    ///   * `num_bits == 0`: returns 0 immediately.
    ///   * `bit_pos % 8 != 0`: partial-byte alignment — the load picks
    ///     up `bit_pos % 8` junk bits at the top which the shift
    ///     discards.
    ///   * Reading past the end: returns `error.EndOfStream` BEFORE
    ///     any load happens, so the trailing-byte read never touches
    ///     out-of-bounds memory.
    fn readBits(self: *GorillaDecoder, num_bits: u8) !u64 {
        if (num_bits == 0) return 0;
        if (self.bit_pos + num_bits > self.total_bits) return error.EndOfStream;

        const start_byte = self.bit_pos / 8;
        const bit_offset: u7 = @intCast(self.bit_pos % 8);

        // Number of source bytes we must touch to cover the bit range.
        // Bits span [start_byte*8, start_byte*8 + bit_offset + num_bits).
        // Inclusive byte count is ceil((bit_offset + num_bits) / 8).
        const span_bits: usize = @as(usize, bit_offset) + @as(usize, num_bits);
        const byte_count: usize = (span_bits + 7) / 8;
        std.debug.assert(byte_count <= 9); // bit_offset≤7, num_bits≤64

        // Assemble the bytes into a u128 in big-endian order so the
        // highest stream bit ends up in the highest u128 bit.
        var word: u128 = 0;
        var i: usize = 0;
        while (i < byte_count) : (i += 1) {
            word = (word << 8) | @as(u128, self.data[start_byte + i]);
        }
        // After the loop, the LSB of `word` is the last bit of the
        // `byte_count`-th byte. Total loaded bits = byte_count * 8.
        // The payload starts at bit_offset bits into the first byte
        // and is num_bits long. The number of trailing bits below the
        // payload is: (byte_count * 8) - bit_offset - num_bits.
        const total_loaded: usize = byte_count * 8;
        const trailing: u7 = @intCast(total_loaded - @as(usize, bit_offset) - @as(usize, num_bits));
        // Shift the payload to the LSB end and mask to num_bits.
        const shifted: u128 = word >> trailing;
        const mask: u128 = if (num_bits == 64)
            std.math.maxInt(u64)
        else
            (@as(u128, 1) << @intCast(num_bits)) - 1;
        const value: u64 = @intCast(shifted & mask);

        self.bit_pos += num_bits;
        return value;
    }

    /// Sign-extend a value from `bits`-wide to i64.
    fn signExtend(value: u64, bits: u8) i64 {
        if (bits == 0 or bits >= 64) return @bitCast(value);
        const sign_bit: u64 = @as(u64, 1) << @intCast(bits - 1);
        if (value & sign_bit != 0) {
            // Negative: fill upper bits with 1s.
            const mask = @as(u64, std.math.maxInt(u64)) << @intCast(bits);
            return @bitCast(value | mask);
        }
        return @bitCast(value);
    }

    /// Decode the next point from the compressed bitstream.
    ///
    /// First point: raw 64-bit ts + raw 64-bit value. Every
    /// subsequent point is reconstructed from the delta-of-delta
    /// timestamp prefix code and the XOR value prefix code — see
    /// `decodeTimestamp` and `decodeValue` for the per-field reads.
    pub fn decodePoint(self: *GorillaDecoder) !types.Point {
        if (self.point_count >= self.num_points) return error.EndOfStream;

        if (self.point_count == 0) {
            // First point: raw 64-bit timestamp + raw 64-bit value.
            const ts_raw = try self.readBits(64);
            const val_raw = try self.readBits(64);
            self.prev_ts = @bitCast(ts_raw);
            self.prev_value = @bitCast(val_raw);
            self.point_count = 1;
            return .{ .ts = self.prev_ts, .value = self.prev_value };
        }

        self.point_count += 1;
        const ts = try self.decodeTimestamp();
        const value = try self.decodeValue();
        return .{ .ts = ts, .value = value };
    }

    /// Read the delta-of-delta prefix code, sign-extend the payload,
    /// fold it back into `(prev_delta, prev_ts)`, and return the new
    /// absolute timestamp.
    fn decodeTimestamp(self: *GorillaDecoder) !i64 {
        var delta_of_delta: i64 = 0;
        const first_bit = try self.readBit();
        if (first_bit == 0) {
            delta_of_delta = 0;
        } else {
            const second_bit = try self.readBit();
            if (second_bit == 0) {
                // Prefix 10: 7-bit value.
                const raw = try self.readBits(7);
                delta_of_delta = signExtend(raw, 7);
            } else {
                const third_bit = try self.readBit();
                if (third_bit == 0) {
                    // Prefix 110: 9-bit value.
                    const raw = try self.readBits(9);
                    delta_of_delta = signExtend(raw, 9);
                } else {
                    const fourth_bit = try self.readBit();
                    if (fourth_bit == 0) {
                        // Prefix 1110: 12-bit value.
                        const raw = try self.readBits(12);
                        delta_of_delta = signExtend(raw, 12);
                    } else {
                        // Prefix 1111: 32-bit value.
                        const raw = try self.readBits(32);
                        delta_of_delta = signExtend(raw, 32);
                    }
                }
            }
        }

        const delta = self.prev_delta + delta_of_delta;
        const ts = self.prev_ts + delta;
        self.prev_delta = delta;
        self.prev_ts = ts;
        return ts;
    }

    /// Read the XOR value prefix code and reconstruct the absolute
    /// value. Updates `prev_value` and (on a new envelope)
    /// `prev_leading` / `prev_trailing`.
    fn decodeValue(self: *GorillaDecoder) !i64 {
        const xor_control = try self.readBit();
        var value: i64 = undefined;
        if (xor_control == 0) {
            // XOR is 0: same value as previous.
            value = self.prev_value;
        } else {
            const xor_type = try self.readBit();
            var xor: u64 = undefined;
            if (xor_type == 0) {
                // Reuse previous leading/trailing: read significant bits.
                const significant_bits = 64 - @as(u8, self.prev_leading) - @as(u8, self.prev_trailing);
                const shifted = try self.readBits(significant_bits);
                xor = shifted << @intCast(self.prev_trailing);
            } else {
                // New leading/trailing.
                const leading: u8 = @intCast(try self.readBits(5));
                const significant_bits: u8 = @intCast(try self.readBits(6));
                const trailing: u8 = 64 - leading - significant_bits;
                const shifted = try self.readBits(significant_bits);
                xor = shifted << @intCast(trailing);
                self.prev_leading = leading;
                self.prev_trailing = trailing;
            }
            value = self.prev_value ^ @as(i64, @bitCast(xor));
        }

        self.prev_value = value;
        return value;
    }

    /// Decode all points from the compressed bitstream.
    pub fn decodeAll(self: *GorillaDecoder, allocator: std.mem.Allocator) ![]types.Point {
        var points: std.ArrayList(types.Point) = .empty;
        errdefer points.deinit(allocator);
        try points.ensureTotalCapacity(allocator, self.num_points);

        while (self.point_count < self.num_points) {
            const point = try self.decodePoint();
            try points.append(allocator, point);
        }

        return try points.toOwnedSlice(allocator);
    }
};

/// Reference per-bit decoder kept ONLY for the bulk-decode equivalence
/// test below. Preserves the pre-P-ALGO-005 implementation so we can
/// prove the optimised path is byte-identical against a known-good
/// baseline. Do NOT call from production code.
fn readBitsPerBitForTest(self: *GorillaDecoder, num_bits: u8) !u64 {
    var value: u64 = 0;
    for (0..num_bits) |_| {
        value = (value << 1) | @as(u64, try self.readBit());
    }
    return value;
}

test "GorillaDecoder: readBits bulk decode matches per-bit baseline (P-ALGO-005)" {
    const allocator = std.testing.allocator;

    // Encode a known-varied bit pattern: every prefix code shape +
    // a 64-bit literal, then a few odd-width payloads (7, 9, 12, 32).
    var enc = try GorillaEncoder.init(allocator);
    defer enc.deinit();

    // Some points whose deltas/XORs land in every Gorilla bucket.
    const pts = [_]types.Point{
        .{ .ts = 1000, .value = 0x0123_4567_89AB_CDEF },
        .{ .ts = 2000, .value = 0x0123_4567_89AB_CDEF }, // xor=0, dod=999
        .{ .ts = 3000, .value = 0x0123_4567_89AB_CDFF }, // xor small
        .{ .ts = 4000, .value = -1 }, // xor wide
        .{ .ts = 4100, .value = 7 }, // dod-of-delta small
        .{ .ts = 5000, .value = 1_000_000 }, // dod medium
        .{ .ts = 10_000, .value = 0 }, // dod large
        .{ .ts = 1_000_000, .value = std.math.minInt(i64) }, // dod 32-bit
    };
    for (pts) |p| try enc.encodePoint(p);

    const data = try enc.getCompressedData(allocator);
    defer allocator.free(data);

    // Decode with the optimised bulk path.
    var dec_bulk = GorillaDecoder.init(data, pts.len);
    const out_bulk = try dec_bulk.decodeAll(allocator);
    defer allocator.free(out_bulk);

    // Decode with the per-bit baseline. We do this manually by
    // exercising the public `decodePoint` while temporarily swapping
    // readBits — easier path: re-walk the same bit positions through
    // a second decoder and assert every readBits call returns the
    // same value via both paths.
    var dec_a = GorillaDecoder.init(data, pts.len);
    var dec_b = GorillaDecoder.init(data, pts.len);
    // Mirror a handful of mixed-width reads from the start of the stream.
    const widths = [_]u8{ 1, 1, 64, 1, 7, 1, 9, 1, 12, 1, 32, 1, 5, 6, 7, 64 };
    var total: usize = 0;
    for (widths) |w| {
        if (total + w > dec_a.total_bits) break;
        const a_val = try dec_a.readBits(w);
        const b_val = try readBitsPerBitForTest(&dec_b, w);
        try std.testing.expectEqual(b_val, a_val);
        total += w;
    }

    // Final point-by-point equivalence: bulk decode must return the
    // exact original sequence.
    try std.testing.expectEqual(pts.len, out_bulk.len);
    for (pts, 0..) |expected, i| {
        try std.testing.expectEqual(expected.ts, out_bulk[i].ts);
        try std.testing.expectEqual(expected.value, out_bulk[i].value);
    }
}

test "GorillaDecoder: readBits handles every bit_pos alignment (P-ALGO-005)" {
    const allocator = std.testing.allocator;

    // Hand-craft a known byte stream: 0b10101010, 0b11001100, 0b11110000, 0b00001111.
    const raw = [_]u8{ 0xAA, 0xCC, 0xF0, 0x0F };
    // Sample expected values at every bit position for widths 1..16.
    for (0..(raw.len * 8)) |start_pos| {
        var max_w: usize = 16;
        if (start_pos + max_w > raw.len * 8) max_w = raw.len * 8 - start_pos;

        for (1..max_w + 1) |w| {
            var dec_bulk = GorillaDecoder.init(&raw, 0);
            dec_bulk.bit_pos = start_pos;
            const bulk_val = try dec_bulk.readBits(@intCast(w));

            var dec_perbit = GorillaDecoder.init(&raw, 0);
            dec_perbit.bit_pos = start_pos;
            const perbit_val = try readBitsPerBitForTest(&dec_perbit, @intCast(w));

            try std.testing.expectEqual(perbit_val, bulk_val);
            try std.testing.expectEqual(dec_perbit.bit_pos, dec_bulk.bit_pos);
        }
    }
    _ = allocator;
}

test "GorillaDecoder: readBits surfaces EndOfStream past the buffer (P-ALGO-005)" {
    const raw = [_]u8{0xFF};
    var dec = GorillaDecoder.init(&raw, 0);
    dec.bit_pos = 4;
    try std.testing.expectError(error.EndOfStream, dec.readBits(8));
    // Position MUST NOT advance on error.
    try std.testing.expectEqual(@as(usize, 4), dec.bit_pos);
}

test "GorillaEncoder: initForPoints pre-sizes the bitset (P-MEM-002)" {
    const allocator = std.testing.allocator;

    // For 1000 points the estimated_bits = 1000 * 18 = 18_000. The
    // bitset rounds up to the nearest mask-int boundary internally,
    // but capacity must be at least 18_000.
    var enc = try GorillaEncoder.initForPoints(allocator, 1000);
    defer enc.deinit();

    try std.testing.expect(enc.bits.capacity() >= 18_000);
}

test "GorillaEncoder: initWithCapacity clamps below MIN and above MAX (P-MEM-002)" {
    const allocator = std.testing.allocator;

    // Below MIN — must be raised to MIN_INITIAL_BITS.
    var small = try GorillaEncoder.initWithCapacity(allocator, 1);
    defer small.deinit();
    try std.testing.expect(small.bits.capacity() >= GorillaEncoder.MIN_INITIAL_BITS);

    // Above the cap — must be clamped to MAX_POINTS_PER_BLOCK_ABSOLUTE * 128.
    var huge = try GorillaEncoder.initWithCapacity(allocator, std.math.maxInt(usize));
    defer huge.deinit();
    try std.testing.expect(huge.bits.capacity() <= limits.MAX_POINTS_PER_BLOCK_ABSOLUTE * 128 + 64);
}

test "GorillaEncoder: pre-sized encoder produces the same bitstream as default-sized (P-MEM-002)" {
    const allocator = std.testing.allocator;

    const pts = [_]types.Point{
        .{ .ts = 1, .value = 1 },
        .{ .ts = 2, .value = 2 },
        .{ .ts = 3, .value = 3 },
        .{ .ts = 100, .value = -7 },
        .{ .ts = 200, .value = 99 },
    };

    var enc_default = try GorillaEncoder.init(allocator);
    defer enc_default.deinit();
    for (pts) |p| try enc_default.encodePoint(p);
    const out_default = try enc_default.getCompressedData(allocator);
    defer allocator.free(out_default);

    var enc_sized = try GorillaEncoder.initForPoints(allocator, pts.len);
    defer enc_sized.deinit();
    for (pts) |p| try enc_sized.encodePoint(p);
    const out_sized = try enc_sized.getCompressedData(allocator);
    defer allocator.free(out_sized);

    try std.testing.expectEqualSlices(u8, out_default, out_sized);
    try std.testing.expectEqual(enc_default.bit_pos, enc_sized.bit_pos);
}

test "GorillaEncoder: reset produces identical bitstream to fresh init (ENT-003)" {
    const allocator = std.testing.allocator;

    const pts_a = [_]types.Point{
        .{ .ts = 1, .value = 1 },
        .{ .ts = 2, .value = 2 },
        .{ .ts = 3, .value = 3 },
        .{ .ts = 100, .value = -7 },
        .{ .ts = 200, .value = 99 },
    };
    const pts_b = [_]types.Point{
        .{ .ts = 5000, .value = -42 },
        .{ .ts = 5100, .value = 17 },
        .{ .ts = 5200, .value = 17 },
        .{ .ts = 9000, .value = std.math.maxInt(i64) },
    };

    // Reference: encode pts_b with a fresh encoder.
    var enc_ref = try GorillaEncoder.initForPoints(allocator, pts_b.len);
    defer enc_ref.deinit();
    for (pts_b) |p| try enc_ref.encodePoint(p);
    const out_ref = try enc_ref.getCompressedData(allocator);
    defer allocator.free(out_ref);

    // Pooled: encode pts_a then reset and encode pts_b.
    var enc_pool = try GorillaEncoder.initForPoints(allocator, pts_a.len);
    defer enc_pool.deinit();
    for (pts_a) |p| try enc_pool.encodePoint(p);
    const cap_before_reset = enc_pool.bits.capacity();
    enc_pool.reset();
    // After reset: bit_pos must be 0, stats must be cleared, and
    // capacity must NOT have shrunk (the whole point of pooling).
    try std.testing.expectEqual(@as(usize, 0), enc_pool.bit_pos);
    try std.testing.expectEqual(@as(u32, 0), enc_pool.stats.count);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), enc_pool.stats.min_ts);
    try std.testing.expect(enc_pool.bits.capacity() >= cap_before_reset);

    for (pts_b) |p| try enc_pool.encodePoint(p);
    const out_pool = try enc_pool.getCompressedData(allocator);
    defer allocator.free(out_pool);

    // The pooled encoder's second block must be byte-identical to a
    // fresh encoder's encoding of the same points.
    try std.testing.expectEqualSlices(u8, out_ref, out_pool);
    try std.testing.expectEqual(enc_ref.bit_pos, enc_pool.bit_pos);
    try std.testing.expectEqual(enc_ref.stats.count, enc_pool.stats.count);
    try std.testing.expectEqual(enc_ref.stats.min_ts, enc_pool.stats.min_ts);
    try std.testing.expectEqual(enc_ref.stats.max_ts, enc_pool.stats.max_ts);

    // Round-trip: the pooled bitstream must decode back to pts_b.
    var dec = GorillaDecoder.init(out_pool, @intCast(pts_b.len));
    const decoded = try dec.decodeAll(allocator);
    defer allocator.free(decoded);
    try std.testing.expectEqual(pts_b.len, decoded.len);
    for (pts_b, 0..) |expected, i| {
        try std.testing.expectEqual(expected.ts, decoded[i].ts);
        try std.testing.expectEqual(expected.value, decoded[i].value);
    }
}

test "GorillaEncoder: reset retains capacity for hot-loop pooling (ENT-003)" {
    const allocator = std.testing.allocator;

    // Pre-size for 256 points × 18 bits ≈ 4608 bits.
    var enc = try GorillaEncoder.initForPoints(allocator, 256);
    defer enc.deinit();
    const initial_capacity = enc.bits.capacity();
    try std.testing.expect(initial_capacity >= 256 * GorillaEncoder.TYPICAL_BITS_PER_POINT);

    // Drive several reset cycles. Capacity must monotonically retain.
    for (0..8) |i| {
        const ts_base = @as(i64, @intCast(i)) * 1_000_000;
        for (0..64) |j| {
            try enc.encodePoint(.{
                .ts = ts_base + @as(i64, @intCast(j)) * 1000,
                .value = @as(i64, @intCast(j)) * 7 + 13,
            });
        }
        try std.testing.expectEqual(@as(u32, 64), enc.stats.count);
        const cap_now = enc.bits.capacity();
        try std.testing.expect(cap_now >= initial_capacity);
        enc.reset();
        try std.testing.expectEqual(@as(usize, 0), enc.bit_pos);
        try std.testing.expectEqual(@as(u32, 0), enc.stats.count);
        // Critically: capacity must be retained across reset.
        try std.testing.expectEqual(cap_now, enc.bits.capacity());
    }
}

test "GorillaEncoder: refuses to grow past the absolute point cap" {
    const allocator = std.testing.allocator;
    var enc = try GorillaEncoder.init(allocator);
    defer enc.deinit();

    // Drive the encoder up to the cap without doing the full
    // limits.MAX_POINTS_PER_BLOCK_ABSOLUTE iterations (too slow for
    // a unit test). Spoof the internal count instead — the cap
    // check is purely on `self.stats.count`, so this proves the
    // gate fires correctly without burning seconds in the loop.
    enc.stats.count = limits.MAX_POINTS_PER_BLOCK_ABSOLUTE;
    try std.testing.expectError(
        error.BlockPointLimitExceeded,
        enc.encodePoint(.{ .ts = 1, .value = 1 }),
    );
}
