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

    pub fn init(allocator: std.mem.Allocator) !GorillaEncoder {
        return .{
            .bits = try std.DynamicBitSet.initEmpty(allocator, 65536),
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

    pub fn deinit(self: *GorillaEncoder) void {
        self.bits.deinit();
    }

    /// Encode a time-series point using Gorilla compression.
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

        // Encode timestamp using delta-of-delta.
        const delta = point.ts - self.prev_ts;
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
        self.prev_ts = point.ts;

        // Encode value using XOR compression.
        const xor: u64 = @bitCast(point.value ^ self.prev_value);

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

        self.prev_value = point.value;
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

    fn readBits(self: *GorillaDecoder, num_bits: u8) !u64 {
        var value: u64 = 0;
        for (0..num_bits) |_| {
            value = (value << 1) | @as(u64, try self.readBit());
        }
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

        // Decode timestamp delta-of-delta.
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

        // Decode value using XOR compression.
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
        return .{ .ts = ts, .value = value };
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
