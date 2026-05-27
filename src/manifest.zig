// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const limits = @import("limits.zig");
const Crc32 = std.hash.crc.Crc32Iscsi;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const owner_only_file_mode = 0o600;

/// Plaintext manifest format magic. Layout matches `Manifest.serialize`
/// — see `deserialize` for the field-by-field decoder.
pub const MANIFEST_MAGIC: [8]u8 = .{ 'T', 'S', 'M', 'N', 'F', 'S', '0', '1' };

/// Encrypted manifest format magic (GAP-0001 / SEC-006). The on-disk
/// layout is:
///
///   [ 8] magic = "TSMNF002"
///   [16] ts_uuid (plaintext, identifies the engine instance)
///   [ 8] counter (u64 LE, plaintext — needed for AAD binding)
///   [12] nonce (random, per-write)
///   [ 4] ciphertext_len (u32 LE)
///   [ N] ciphertext (AES-256-GCM encryption of the full plaintext
///                    `serialize()` output, including its own magic
///                    and trailing CRC32)
///   [16] AES-GCM auth tag
///   [ 4] CRC32C over every preceding byte (defence-in-depth on top
///        of the GCM tag, also catches accidental bitflips before
///        the cryptographic check would have)
///
/// AAD = ts_uuid(16) || "mnf"(3) || counter(u64 LE)
///
/// Key reuse with the segment AES-256-GCM key is intentional: a single
/// operator-supplied 32-byte key covers WAL, segments, and manifest.
/// AAD domain separation (`"seg"` vs `"mnf"`, plus distinct shapes) is
/// what prevents cross-context ciphertext reuse.
pub const MANIFEST_MAGIC_V2: [8]u8 = .{ 'T', 'S', 'M', 'N', 'F', '0', '0', '2' };
pub const MANIFEST_VERSION: u32 = 1;

/// AES-256-GCM nonce length (96-bit, matches Zig stdlib).
const ENCRYPTION_NONCE_SIZE: usize = Aes256Gcm.nonce_length;
/// AES-256-GCM auth tag length (128-bit).
const ENCRYPTION_TAG_SIZE: usize = Aes256Gcm.tag_length;

/// Size of the encrypted-manifest fixed header before the ciphertext:
/// magic(8) + ts_uuid(16) + counter(8) + nonce(12) + ciphertext_len(4).
const ENCRYPTED_HEADER_SIZE: usize = 8 + 16 + 8 + ENCRYPTION_NONCE_SIZE + 4;
/// Size of the encrypted-manifest fixed footer after the ciphertext:
/// tag(16) + crc32(4).
const ENCRYPTED_FOOTER_SIZE: usize = ENCRYPTION_TAG_SIZE + 4;

/// Errors specific to the on-disk manifest. As with `SegmentError`,
/// functions may ALSO bubble up allocator and file-system errors
/// (`OutOfMemory`, `FileNotFound`, etc.); those stay on the inferred
/// error set.
pub const ManifestError = error{
    /// Header magic mismatch.
    InvalidMagic,
    /// CRC32C over the body did not match the stored CRC.
    ChecksumMismatch,
    /// File shorter than a serialised manifest header.
    FileTooSmall,
    /// Read returned fewer bytes than requested.
    UnexpectedEndOfFile,
    /// File or segment-count claim exceeded a defensive cap. See
    /// `limits.MAX_MANIFEST_SIZE` / `MAX_SEGMENTS_PER_MANIFEST`.
    ManifestTooLarge,
    /// Generic catch-all for malformed payload bytes.
    InvalidData,
    /// No on-disk manifest slot loaded cleanly.
    NoManifest,
    /// Encrypted (TSMNF002) manifest opened without a key, opened
    /// with the wrong key, or its AES-GCM tag check failed. Closes
    /// GAP-0001 (manifest TDE).
    DecryptionFailed,
    /// Plaintext (TSMNFS01) manifest opened when the engine was
    /// configured with an encryption key. Indicates a missing
    /// migration step or a mixed-mode data directory; fail closed
    /// rather than silently accept partial coverage.
    UnexpectedPlaintextManifest,
};

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

/// Immutable, reference-counted snapshot of the manifest's segment
/// list plus the counter/checkpoint values that produced it.
///
/// Closes the in-memory leg of the manifest COW refactor described
/// under P-LOCK-001 / P-LOCK-003 in `docs/PERF_GAP_ANALYSIS.md`. A
/// snapshot is a fully self-contained read view: once `snapshot()`
/// returns, the caller can iterate `segments` without holding any
/// engine-level lock, even while a concurrent writer stages and
/// publishes a NEW snapshot. The old snapshot's backing memory is
/// freed only when its refcount drops to zero — late readers who
/// still hold a ref see a consistent view of the world as it was
/// when they acquired it.
///
/// The refcount is biased by ONE for the publication ref the
/// `Manifest` itself holds (so the snapshot survives as long as it
/// is the current published view). Readers add their own ref via
/// `acquire()` and drop it via `release()`. The publication ref is
/// dropped by the next `writeSlotAndPublish` call that swaps in a
/// fresh snapshot.
pub const Snapshot = struct {
    segments: []const SegmentMeta,
    counter: u64,
    last_checkpoint_lsn: u64,
    next_segment_id: u64,
    refcount: std.atomic.Value(u32) = .init(1),
    allocator: Allocator,

    pub fn acquire(self: *Snapshot) void {
        // acq_rel rather than monotonic: paired with the .acq_rel
        // fetchSub in release() so the happens-before edges the
        // last releaser needs (it must observe every prior
        // acquire/release) are preserved. The bias-of-one publication
        // ref keeps the snapshot alive for the publication window;
        // every other ref is purely cosmetic to refcount logic.
        _ = self.refcount.fetchAdd(1, .acq_rel);
    }

    pub fn release(self: *Snapshot) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            self.allocator.free(self.segments);
            self.allocator.destroy(self);
        }
    }
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
    /// Optional AES-256-GCM key (32 bytes). When set, `writeToFile`
    /// emits the encrypted TSMNF002 layout; when null, the legacy
    /// plaintext TSMNFS01 layout is used. Closes GAP-0001 (manifest
    /// TDE) and SEC-006 (full TDE coverage).
    ///
    /// Set on the in-memory manifest by `initWithEncryption` and
    /// propagated by `save()` automatically. Callers MUST keep the
    /// key consistent across opens of the same `data_dir` — mixing
    /// keyed and unkeyed opens is rejected with
    /// `UnexpectedPlaintextManifest` / `DecryptionFailed`.
    encryption_key: ?[32]u8 = null,
    /// Atomic pointer to the current immutable snapshot of the
    /// segment list + counters. Readers atomically load it and bump
    /// the refcount; writers stage a new `*Snapshot` and swap. The
    /// in-memory `segments` ArrayList above is the *writer-side*
    /// staging buffer (mutated under engine.mu); readers no longer
    /// touch it. Initialised lazily by `publishInitialSnapshot`,
    /// which the engine calls AFTER `verifySegments` has finalised
    /// the on-load segment set.
    ///
    /// We seed with `null` rather than `undefined` so callers that
    /// inspect a half-built `Manifest` (e.g. error paths in
    /// `initWithEncryption`) cannot accidentally dereference garbage.
    current_snapshot: std.atomic.Value(?*Snapshot) = .init(null),

    pub fn init(allocator: Allocator, data_dir: []const u8) !Manifest {
        return initWithEncryption(allocator, data_dir, null);
    }

    /// Open the manifest with an optional AES-256-GCM encryption key.
    /// Behaviour matches `init` when `encryption_key == null`.
    ///
    /// When a key is supplied:
    ///   * plaintext (TSMNFS01) slots are rejected with
    ///     `error.UnexpectedPlaintextManifest`,
    ///   * encrypted (TSMNF002) slots decrypt with the supplied key;
    ///     a wrong-key open surfaces `error.DecryptionFailed`,
    ///   * a fresh data dir (no slots) returns an empty in-memory
    ///     manifest with the key stashed, so the first `save()` will
    ///     write encrypted.
    ///
    /// Failure modes are designed so that an authentic-but-corrupted
    /// slot does NOT prevent the engine from coming up if the other
    /// slot is valid (the ping-pong design), but a hard-fail error
    /// like `UnexpectedPlaintextManifest` or `DecryptionFailed` on
    /// BOTH slots is surfaced rather than silently swallowed.
    pub fn initWithEncryption(
        allocator: Allocator,
        data_dir: []const u8,
        encryption_key: ?[32]u8,
    ) !Manifest {
        const path_a = try std.fmt.allocPrint(allocator, "{s}/manifest.a", .{data_dir});
        defer allocator.free(path_a);
        const path_b = try std.fmt.allocPrint(allocator, "{s}/manifest.b", .{data_dir});
        defer allocator.free(path_b);

        var err_a: ?anyerror = null;
        var err_b: ?anyerror = null;
        var a = readFromFileWithKey(allocator, path_a, encryption_key) catch |err| blk: {
            err_a = err;
            break :blk null;
        };
        var b = readFromFileWithKey(allocator, path_b, encryption_key) catch |err| blk: {
            err_b = err;
            break :blk null;
        };

        // Mixed-mode / wrong-key detection: if either slot was
        // present-but-rejected (not just FileNotFound), and the OTHER
        // slot did not load cleanly either, the engine must NOT silently
        // start fresh — that would mask a tampered or wrong-key open
        // and let the operator accidentally clobber the real manifest
        // on the next save.
        if (a == null and b == null) {
            // If either error is a hard security failure, surface it.
            for ([_]?anyerror{ err_a, err_b }) |maybe_err| {
                if (maybe_err) |e| switch (e) {
                    error.DecryptionFailed,
                    error.UnexpectedPlaintextManifest,
                    error.ChecksumMismatch,
                    error.InvalidMagic,
                    error.ManifestTooLarge,
                    error.InvalidData,
                    => return e,
                    else => {},
                };
            }
            // Otherwise both slots were genuinely missing
            // (FileNotFound) — fall through to empty manifest.
        }

        // Pick the higher-counter slot and free the segment list owned
        // by the loser. Previously the loser's `segments` ArrayList
        // leaked because `selectManifest` returned the winner by value
        // and the loser was dropped on the floor.
        var m = selectManifest(a, b) catch Manifest{};
        if (a) |*ma| {
            if (ma.counter != m.counter) ma.segments.deinit(allocator);
        }
        if (b) |*mb| {
            if (mb.counter != m.counter) mb.segments.deinit(allocator);
        }
        m.allocator = allocator;
        m.data_dir = data_dir;
        m.encryption_key = encryption_key;
        return m;
    }

    pub fn deinit(self: *Manifest) void {
        self.segments.deinit(self.allocator);
        // Drop the manifest's publication ref. If a reader still
        // holds a ref the snapshot will outlive us until they
        // release. Readers MUST NOT outlive the allocator, which the
        // engine enforces by joining all background workers in its
        // own `deinit` before tearing the manifest down.
        if (self.current_snapshot.load(.acquire)) |snap| {
            snap.release();
        }
    }

    /// Allocate the initial published `*Snapshot` from the current
    /// in-memory `segments` + counter state. Called by the engine
    /// AFTER `verifySegments` has finalised the on-load segment set
    /// so the very first snapshot reflects exactly the segments the
    /// engine will accept queries against.
    ///
    /// Idempotent and safe to call exactly once per manifest lifetime
    /// — calling twice would leak the prior snapshot.
    pub fn publishInitialSnapshot(self: *Manifest) !void {
        std.debug.assert(self.current_snapshot.load(.acquire) == null);
        const segs_copy = try self.allocator.dupe(SegmentMeta, self.segments.items);
        errdefer self.allocator.free(segs_copy);
        const snap = try self.allocator.create(Snapshot);
        snap.* = .{
            .segments = segs_copy,
            .counter = self.counter,
            .last_checkpoint_lsn = self.last_checkpoint_lsn,
            .next_segment_id = self.next_segment_id,
            .refcount = .init(1),
            .allocator = self.allocator,
        };
        self.current_snapshot.store(snap, .release);
    }

    /// Acquire a refcounted snapshot of the current manifest state.
    ///
    /// O(1): one atomic load + one atomic refcount increment. Returns
    /// a pointer the caller MUST eventually release via `.release()`.
    /// The snapshot is consistent — all fields reflect a single
    /// historical publish — and remains valid for the lifetime of
    /// the ref, even while concurrent writers stage and publish new
    /// versions.
    pub fn snapshot(self: *Manifest) *Snapshot {
        const snap = self.current_snapshot.load(.acquire).?;
        snap.acquire();
        return snap;
    }

    pub fn save(self: *Manifest) !void {
        // `save()` callers in the engine all hold `engine.mu`, which
        // serialises every mutation of `self.segments` / `self.counter`
        // against itself. A future `writeSlotAndPublish` that runs
        // OUTSIDE `engine.mu` will need its own internal mutex to
        // coordinate with us on the shared ping-pong slot file;
        // until then, the engine.mu invariant is sufficient.
        self.counter += 1;
        const filename = if (self.counter % 2 == 0) "manifest.a" else "manifest.b";
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.data_dir, filename });
        defer self.allocator.free(path);
        try self.writeToFile(self.allocator, path);

        // Republish the snapshot so post-save() readers observe the
        // new on-disk state. This is the in-memory leg of the COW —
        // the caller can keep using `save()` exactly as before, but
        // any reader holding the OLD snapshot keeps seeing the old
        // segment list until it calls `manifest.snapshot()` again.
        // `current_snapshot` may legitimately be null on a save()
        // call BEFORE `publishInitialSnapshot` (some tests construct
        // a Manifest{} literal and call save() directly without
        // going through the engine init path); skip the republish in
        // that case — the next reader path will read the on-disk
        // slot back through `initWithEncryption` instead.
        if (self.current_snapshot.load(.acquire) != null) {
            try self.republishSnapshotLocked();
        }
    }

    /// Internal: build a new `*Snapshot` from the current in-memory
    /// state (`segments`, `counter`, `last_checkpoint_lsn`,
    /// `next_segment_id`), atomically swap it into
    /// `current_snapshot`, and drop the previous publication ref.
    /// Caller is expected to hold whatever lock guards the in-memory
    /// state being snapshotted (typically `engine.mu` or
    /// `publish_mu`).
    fn republishSnapshotLocked(self: *Manifest) !void {
        const segs_copy = try self.allocator.dupe(SegmentMeta, self.segments.items);
        errdefer self.allocator.free(segs_copy);
        const new_snap = try self.allocator.create(Snapshot);
        new_snap.* = .{
            .segments = segs_copy,
            .counter = self.counter,
            .last_checkpoint_lsn = self.last_checkpoint_lsn,
            .next_segment_id = self.next_segment_id,
            .refcount = .init(1),
            .allocator = self.allocator,
        };
        const old = self.current_snapshot.swap(new_snap, .acq_rel);
        if (old) |o| o.release();
    }

    // NOTE: A future `writeSlotAndPublish(new_segments, new_lsn,
    // new_next_id)` method that the engine could call OUTSIDE
    // engine.mu (serialised by `publish_mu`) would finish closing
    // P-LOCK-003 for the flush + compaction publish paths. The
    // refactor is non-trivial because every engine-side reader of
    // `self.man.segments.items` (compaction triggers, OoO watermark
    // seeding, runMergeAndCommit's input-set scan) currently relies
    // on `engine.mu` to keep that ArrayList stable. Routing those
    // through `self.man.snapshot()` is a separate cleanup. The
    // queryPoints path — the only hot-path reader — is already
    // routed through `snapshot()` in this commit, which is the
    // biggest win.

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
        const plaintext = try self.serialize(allocator);
        defer allocator.free(plaintext);

        const final_bytes: []u8 = if (self.encryption_key) |key|
            try wrapEncrypted(allocator, plaintext, self.ts_uuid, self.counter, key)
        else
            try allocator.dupe(u8, plaintext);
        defer allocator.free(final_bytes);

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode) });
        defer tmp_file.close(io);

        try tmp_file.writeStreamingAll(io, final_bytes);
        try tmp_file.sync(io);

        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
    }

    pub fn readFromFile(allocator: Allocator, path: []const u8) !?Manifest {
        return readFromFileWithKey(allocator, path, null);
    }

    /// Read a manifest slot, decrypting if `encryption_key` is set.
    ///
    /// Magic-byte discrimination:
    ///   * TSMNFS01 (plaintext) + no key   → success.
    ///   * TSMNFS01 (plaintext) + key      → `UnexpectedPlaintextManifest`.
    ///   * TSMNF002 (encrypted) + key      → AES-GCM decrypt + deserialize.
    ///   * TSMNF002 (encrypted) + no key   → `DecryptionFailed`.
    ///   * any other magic                 → `InvalidMagic`.
    ///
    /// Returns `null` only when the file does not exist on disk; every
    /// other failure is an explicit error so callers can distinguish
    /// "no manifest yet" from "wrong key" / "tampered file".
    pub fn readFromFileWithKey(
        allocator: Allocator,
        path: []const u8,
        encryption_key: ?[32]u8,
    ) !?Manifest {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(io);

        const file_len = try file.length(io);
        // CWE-770: cap the on-disk manifest size before `@intCast` to
        // usize and before allocating a buffer for it. Without this
        // gate a hostile file claiming many GiB would attempt an
        // immediate large allocation. The cap applies to both
        // plaintext and encrypted layouts since both fit comfortably
        // under `MAX_MANIFEST_SIZE`.
        if (file_len > limits.MAX_MANIFEST_SIZE) return error.ManifestTooLarge;
        // Need at least the magic to discriminate.
        if (file_len < 8) return error.FileTooSmall;

        const data = try allocator.alloc(u8, @intCast(file_len));
        defer allocator.free(data);
        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != data.len) return error.UnexpectedEndOfFile;

        const is_v1 = std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC);
        const is_v2 = std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC_V2);

        if (!is_v1 and !is_v2) return error.InvalidMagic;

        if (is_v1) {
            // Plaintext slot. Refuse if the operator asked for
            // encryption — silent-acceptance would erode the TDE
            // promise (a downgrade attack on a stolen disk could
            // strip the wrapper and rewrite the bytes as plaintext).
            if (encryption_key != null) return error.UnexpectedPlaintextManifest;
            if (data.len < SERIALIZED_SIZE + 4) return error.FileTooSmall;
            return try deserialize(allocator, data);
        }

        // is_v2 = encrypted. A key is required.
        const key = encryption_key orelse return error.DecryptionFailed;
        const plaintext = try unwrapEncrypted(allocator, data, key);
        defer allocator.free(plaintext);

        return try deserialize(allocator, plaintext);
    }

    pub fn selectManifest(a: ?Manifest, b: ?Manifest) !Manifest {
        if (a == null and b == null) return error.NoManifest;
        if (a == null) return b.?;
        if (b == null) return a.?;
        return if (a.?.counter >= b.?.counter) a.? else b.?;
    }
};

/// AAD builder: ts_uuid(16) || "mnf"(3) || counter(u64 LE). Binds the
/// ciphertext to the engine identity, the manifest domain (so the
/// same key/AAD shape cannot be reused for a segment), and the slot
/// counter (so an attacker cannot replay an older slot under a newer
/// counter without invalidating the tag). The counter is kept in
/// plaintext at the start of the file so we can build the AAD before
/// we have the decrypted payload — same trick the WAL framing uses.
fn buildManifestAad(ts_uuid: [16]u8, counter: u64) [16 + 3 + 8]u8 {
    var aad: [16 + 3 + 8]u8 = undefined;
    @memcpy(aad[0..16], &ts_uuid);
    @memcpy(aad[16..19], "mnf");
    std.mem.writeInt(u64, aad[19..27], counter, .little);
    return aad;
}

/// Wrap a plaintext manifest payload into the TSMNF002 on-disk
/// envelope. Caller owns the returned slice.
///
/// Layout:
///   magic(8) || ts_uuid(16) || counter(8 LE) || nonce(12) ||
///   ct_len(4 LE) || ciphertext(N) || tag(16) || crc32(4)
///
/// The CRC32 covers everything before it. It is a defence-in-depth
/// layer on top of GCM: it catches truncation and accidental
/// bitflips before the cryptographic check, and it matches the
/// integrity-check shape used by the plaintext format so the
/// dual-slot ping-pong's "pick the higher counter" logic does not
/// need a special encrypted-aware variant.
fn wrapEncrypted(
    allocator: Allocator,
    plaintext: []const u8,
    ts_uuid: [16]u8,
    counter: u64,
    key: [32]u8,
) ![]u8 {
    const total_size = ENCRYPTED_HEADER_SIZE + plaintext.len + ENCRYPTED_FOOTER_SIZE;
    const buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var pos: usize = 0;
    @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC_V2);
    pos += 8;
    @memcpy(buf[pos..][0..16], &ts_uuid);
    pos += 16;
    writeU64(buf, &pos, counter);

    // Generate a fresh random nonce. The OS CSPRNG is the same
    // entropy source used by the WAL/segment paths.
    var nonce: [ENCRYPTION_NONCE_SIZE]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    io.random(&nonce);
    @memcpy(buf[pos..][0..ENCRYPTION_NONCE_SIZE], &nonce);
    pos += ENCRYPTION_NONCE_SIZE;

    writeU32(buf, &pos, @intCast(plaintext.len));

    const aad = buildManifestAad(ts_uuid, counter);
    var tag: [ENCRYPTION_TAG_SIZE]u8 = undefined;
    Aes256Gcm.encrypt(
        buf[pos..][0..plaintext.len],
        &tag,
        plaintext,
        &aad,
        nonce,
        key,
    );
    pos += plaintext.len;

    @memcpy(buf[pos..][0..ENCRYPTION_TAG_SIZE], &tag);
    pos += ENCRYPTION_TAG_SIZE;

    const crc = Crc32.hash(buf[0..pos]);
    writeU32(buf, &pos, crc);
    std.debug.assert(pos == total_size);

    return buf;
}

/// Verify and decrypt a TSMNF002 envelope. Caller owns the returned
/// plaintext slice.
///
/// Failure modes mapped to engine-visible errors:
///   * truncated / malformed bytes → `error.InvalidData`
///   * CRC32 mismatch              → `error.ChecksumMismatch`
///   * GCM tag mismatch (wrong key OR tampered)
///                                 → `error.DecryptionFailed`
fn unwrapEncrypted(
    allocator: Allocator,
    data: []const u8,
    key: [32]u8,
) ![]u8 {
    if (data.len < ENCRYPTED_HEADER_SIZE + ENCRYPTED_FOOTER_SIZE) {
        return error.InvalidData;
    }

    // CRC32 over everything except the trailing 4-byte CRC field.
    const stored_crc = readU32(data, data.len - 4);
    const computed_crc = Crc32.hash(data[0 .. data.len - 4]);
    if (stored_crc != computed_crc) return error.ChecksumMismatch;

    var pos: usize = 8; // already validated magic before calling us
    var ts_uuid: [16]u8 = undefined;
    @memcpy(&ts_uuid, data[pos..][0..16]);
    pos += 16;
    const counter = readU64(data, pos);
    pos += 8;

    var nonce: [ENCRYPTION_NONCE_SIZE]u8 = undefined;
    @memcpy(&nonce, data[pos..][0..ENCRYPTION_NONCE_SIZE]);
    pos += ENCRYPTION_NONCE_SIZE;

    const ct_len = readU32(data, pos);
    pos += 4;
    // Bounds check: header + ct_len + tag + crc must equal data.len.
    const expected_len: usize = ENCRYPTED_HEADER_SIZE + @as(usize, ct_len) + ENCRYPTED_FOOTER_SIZE;
    if (expected_len != data.len) return error.InvalidData;
    // Defence-in-depth bound: ct_len cannot exceed the manifest cap.
    if (ct_len > limits.MAX_MANIFEST_SIZE) return error.ManifestTooLarge;

    const ciphertext = data[pos..][0..ct_len];
    pos += ct_len;
    var tag: [ENCRYPTION_TAG_SIZE]u8 = undefined;
    @memcpy(&tag, data[pos..][0..ENCRYPTION_TAG_SIZE]);

    const aad = buildManifestAad(ts_uuid, counter);
    const plaintext = try allocator.alloc(u8, ct_len);
    errdefer allocator.free(plaintext);

    Aes256Gcm.decrypt(plaintext, ciphertext, tag, &aad, nonce, key) catch {
        return error.DecryptionFailed;
    };

    return plaintext;
}

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

test "Manifest: encrypted write/read round-trip (GAP-0001)" {
    // End-to-end: serialise an in-memory manifest, wrap it under the
    // TSMNF002 envelope, persist it, reload it with the SAME key,
    // confirm every observable field round-trips.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key: [32]u8 = [_]u8{0x42} ** 32;
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xCD);

    // Construct a manifest with non-trivial content (uuid, segments,
    // counters) so we can detect any field flipped or swapped by the
    // encryption framing.
    var m = Manifest{
        .ts_uuid = uuid,
        .counter = 11, // pre-save counter; save() bumps it to 12.
        .last_checkpoint_lsn = 12345,
        .next_segment_id = 7,
        .series_count = 3,
        .point_count = 42,
        .allocator = allocator,
        .data_dir = data_dir,
        .encryption_key = key,
    };
    defer m.segments.deinit(allocator);
    try m.segments.append(allocator, .{ .id = 1, .min_ts = 100, .max_ts = 200, .level = 0 });
    try m.segments.append(allocator, .{ .id = 2, .min_ts = 300, .max_ts = 400, .level = 1 });

    try m.save();

    // The on-disk file MUST start with the encrypted-format magic.
    // This is the "not plaintext" assertion that proves AES-256-GCM
    // actually wrapped the payload.
    const mf_path = try std.fmt.allocPrint(allocator, "{s}/manifest.a", .{data_dir});
    defer allocator.free(mf_path);
    const f = try std.Io.Dir.cwd().openFile(io, mf_path, .{});
    defer f.close(io);
    var magic_buf: [8]u8 = undefined;
    _ = try f.readPositionalAll(io, &magic_buf, 0);
    try std.testing.expectEqualSlices(u8, &MANIFEST_MAGIC_V2, &magic_buf);

    // Reload via initWithEncryption with the SAME key and compare.
    var m2 = try Manifest.initWithEncryption(allocator, data_dir, key);
    defer m2.deinit();

    try std.testing.expectEqual(m.ts_uuid, m2.ts_uuid);
    try std.testing.expectEqual(@as(u64, 12), m2.counter); // bumped by save()
    try std.testing.expectEqual(m.last_checkpoint_lsn, m2.last_checkpoint_lsn);
    try std.testing.expectEqual(m.next_segment_id, m2.next_segment_id);
    try std.testing.expectEqual(m.series_count, m2.series_count);
    try std.testing.expectEqual(m.point_count, m2.point_count);
    try std.testing.expectEqual(@as(usize, 2), m2.segments.items.len);
    try std.testing.expectEqual(@as(u64, 1), m2.segments.items[0].id);
    try std.testing.expectEqual(@as(i64, 200), m2.segments.items[0].max_ts);
    try std.testing.expectEqual(@as(u8, 1), m2.segments.items[1].level);
}

test "Manifest: encrypted reopen with wrong key fails with DecryptionFailed (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key_a: [32]u8 = [_]u8{0xAA} ** 32;
    const key_b: [32]u8 = [_]u8{0xBB} ** 32;
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xEF);

    // Save under key_a.
    {
        var m = Manifest{
            .ts_uuid = uuid,
            .counter = 1,
            .allocator = allocator,
            .data_dir = data_dir,
            .encryption_key = key_a,
        };
        defer m.segments.deinit(allocator);
        try m.save();
    }

    // Reopen with key_b — AES-GCM tag check fails.
    try std.testing.expectError(
        error.DecryptionFailed,
        Manifest.initWithEncryption(allocator, data_dir, key_b),
    );
}

test "Manifest: encrypted reopen with no key fails with DecryptionFailed (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key: [32]u8 = [_]u8{0xCC} ** 32;
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAB);

    {
        var m = Manifest{
            .ts_uuid = uuid,
            .counter = 1,
            .allocator = allocator,
            .data_dir = data_dir,
            .encryption_key = key,
        };
        defer m.segments.deinit(allocator);
        try m.save();
    }

    // Reopen with no key — the magic discriminator routes the file
    // to the decrypt path, which then sees a null key and refuses.
    try std.testing.expectError(
        error.DecryptionFailed,
        Manifest.initWithEncryption(allocator, data_dir, null),
    );
}

test "Manifest: plaintext slot rejected when caller expects encryption (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    // Save plaintext (no key).
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x11);
    {
        var m = Manifest{
            .ts_uuid = uuid,
            .counter = 1,
            .allocator = allocator,
            .data_dir = data_dir,
        };
        defer m.segments.deinit(allocator);
        try m.save();
    }

    // Reopen WITH a key — refuse silently-accepting a plaintext
    // artefact when the operator expects TDE coverage.
    const key: [32]u8 = [_]u8{0x99} ** 32;
    try std.testing.expectError(
        error.UnexpectedPlaintextManifest,
        Manifest.initWithEncryption(allocator, data_dir, key),
    );
}

test "Manifest: encrypted layout AAD binds ts_uuid (GAP-0001)" {
    // Tamper the plaintext ts_uuid header bytes after save().
    // Two layered defences fire in order:
    //   1. CRC32 over the whole envelope catches the bitflip first.
    //   2. If an attacker repaired the CRC, the AES-GCM AAD binding
    //      (which includes the original ts_uuid) would still cause
    //      the tag check to fail.
    // Either error is acceptable — both close the cut-and-paste
    // attack — but the engine MUST NOT silently load the tampered
    // manifest.
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();

    const dir_a = try tmp_a.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_a);

    const key: [32]u8 = [_]u8{0x55} ** 32;
    var uuid_a: [16]u8 = undefined;
    @memset(&uuid_a, 0x01);
    var uuid_b: [16]u8 = undefined;
    @memset(&uuid_b, 0x02);

    {
        var m = Manifest{ .ts_uuid = uuid_a, .counter = 0, .allocator = allocator, .data_dir = dir_a, .encryption_key = key };
        defer m.segments.deinit(allocator);
        try m.save();
    }

    // counter started at 0 then save() bumped it to 1, so the slot
    // written is `manifest.b` (counter is odd).
    const path_a_b = try std.fmt.allocPrint(allocator, "{s}/manifest.b", .{dir_a});
    defer allocator.free(path_a_b);
    const f = try std.Io.Dir.cwd().openFile(io, path_a_b, .{ .mode = .read_write });
    defer f.close(io);
    // Overwrite ts_uuid at offset 8 with uuid_b.
    try f.writePositionalAll(io, &uuid_b, 8);
    try f.sync(io);

    // The tampering changes the envelope CRC32; reopen must fail.
    // Accept either layered defence to close the attack window.
    const result = Manifest.initWithEncryption(allocator, dir_a, key);
    if (result) |loaded| {
        var l = loaded;
        l.deinit();
        try std.testing.expect(false); // unreachable: must fail
    } else |err| {
        try std.testing.expect(err == error.ChecksumMismatch or err == error.DecryptionFailed);
    }
}

test "Manifest: snapshot is stable across publish (P-LOCK-001 COW)" {
    // Acquire a snapshot, then publish a new state via save(), then
    // verify the OLD snapshot still sees the OLD segment list while
    // a freshly-acquired snapshot sees the NEW one. This is the
    // lock-free reader guarantee the COW gives queryPoints.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var m = try Manifest.init(allocator, data_dir);
    defer m.deinit();
    try m.segments.append(allocator, .{ .id = 1, .min_ts = 100, .max_ts = 200, .level = 0 });
    try m.publishInitialSnapshot();

    // Reader 1: holds the initial snapshot (1 segment).
    const snap1 = m.snapshot();
    defer snap1.release();
    try std.testing.expectEqual(@as(usize, 1), snap1.segments.len);
    try std.testing.expectEqual(@as(u64, 1), snap1.segments[0].id);

    // Writer: stage + publish a second segment.
    try m.segments.append(allocator, .{ .id = 2, .min_ts = 300, .max_ts = 400, .level = 0 });
    try m.save();

    // Reader 1 STILL sees the old list — refcounted snapshot is
    // immutable. The on-disk store advanced; in-memory the writer
    // republished a new snapshot for future readers.
    try std.testing.expectEqual(@as(usize, 1), snap1.segments.len);
    try std.testing.expectEqual(@as(u64, 1), snap1.segments[0].id);

    // Reader 2: freshly acquired, sees the NEW list (2 segments).
    const snap2 = m.snapshot();
    defer snap2.release();
    try std.testing.expectEqual(@as(usize, 2), snap2.segments.len);
    try std.testing.expectEqual(@as(u64, 1), snap2.segments[0].id);
    try std.testing.expectEqual(@as(u64, 2), snap2.segments[1].id);
}

test "Manifest: snapshot refcount frees backing memory after last release" {
    // Direct refcount semantics: an acquire bumps the count; the
    // publication ref keeps the snapshot alive while it is current;
    // republishing drops the publication ref; the last reader's
    // release frees the backing memory. Catches accidental refcount
    // drift that the leak detector in std.testing.allocator would
    // otherwise surface as an unfreed allocation.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var m = try Manifest.init(allocator, data_dir);
    defer m.deinit();
    try m.publishInitialSnapshot();

    const snap_old = m.snapshot();
    try m.save(); // republish — drops publication ref on snap_old, still alive via snap_old.acquire
    snap_old.release(); // drops the reader ref; backing memory freed here
    // m.deinit() drops the publication ref on the post-save snapshot.
}
