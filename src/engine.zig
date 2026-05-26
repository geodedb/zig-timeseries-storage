// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const limits = @import("limits.zig");
const wal_manager = @import("wal_manager.zig");
const manifest = @import("manifest.zig");
const memtable = @import("memtable.zig");
const segment = @import("segment.zig");
const iterator = @import("iterator.zig");
const compaction = @import("compaction.zig");
const thread_pool = @import("thread_pool");
const wal_record = @import("wal_record.zig");

/// Number of level-0 segments that triggers a compaction job.
/// Chosen to match the level-0 fan-in used by typical LSM designs;
/// keeps the read amplification on L0 bounded while still amortizing
/// compaction work over enough memtable flushes to matter.
const kL0CompactionThreshold: usize = 4;

/// WAL recovery policy.
///
/// - `fail_closed` (default): any deserialisation failure or CRC32C
///   checksum mismatch encountered while replaying the WAL on
///   `Engine.init` aborts the open and surfaces the error
///   (`error.InvalidFormat` / `error.ChecksumMismatch`). This is the
///   safe default: silent data loss is invisible to operators, so we
///   refuse to start rather than pretend the WAL was clean.
/// - `salvage`: tolerate corrupt or non-deserialisable records by
///   falling back to the lossy `readFrom` path; the operator opts in
///   to a best-effort recovery that may drop records past the first
///   bad one. Intended for forensic recovery, not production use.
pub const WalRecoveryPolicy = enum { fail_closed, salvage };

/// Background-worker error phase. Surfaces *which* worker (flush vs
/// compaction vs WAL recovery) the error came from, so a single
/// callback can route by phase. WAL recovery currently fails fast in
/// `Engine.init` rather than through this callback; the variant is
/// reserved so a future async-recovery path can use it without an
/// ABI break.
pub const BgPhase = enum { flush, compaction, wal_recovery };

/// Optional error callback. Invoked by background workers under the
/// engine's internal lock when they encounter a non-fatal error. The
/// callback MUST NOT call back into the engine on the same thread
/// (that would deadlock). Set to `null` (the default) to use the
/// built-in `last_background_error` slot only.
pub const ErrorCallback = *const fn (ctx: *anyopaque, phase: BgPhase, err: anyerror) void;

/// Canonical engine configuration. The only configuration surface a
/// caller needs to construct an `Engine`. Replaces both the template
/// `root.Config` (removed in Phase B-1) and the unused `types.StoreConfig`.
pub const EngineConfig = struct {
    /// Filesystem directory where the manifest, WAL, and segment files
    /// live. Must exist before `Engine.init`; the engine does not create
    /// it for you (the CLI / example wrappers do).
    ///
    /// Must be a non-empty string. Strongly prefer absolute paths;
    /// relative paths (e.g. those produced by `std.testing.tmpDir`)
    /// are accepted for test convenience. Paths containing `..`
    /// substrings are rejected with `error.PathTraversal` to defang
    /// `data_dir = "../../etc"`-style misuse before it reaches the
    /// filesystem.
    data_dir: []const u8,
    /// Soft limit on the number of points held in the active memtable
    /// before a background flush is triggered. Higher values amortize
    /// flush cost but increase peak memory and replay time after a crash.
    max_memtable_points: usize = 100_000,
    /// When true, the WAL identity file (`ts.uuid`) is created on first
    /// open. When false, opening a fresh `data_dir` without an existing
    /// identity returns `error.FileNotFound`.
    create_identity_if_missing: bool = true,
    /// How `Engine.init` should respond to a corrupt WAL record during
    /// replay. See `WalRecoveryPolicy` for details.
    wal_recovery: WalRecoveryPolicy = .fail_closed,
    /// Optional callback invoked when a background worker encounters
    /// an error. When `null`, errors are still recorded in
    /// `last_background_error` (drainable via `lastBackgroundError`).
    error_callback: ?ErrorCallback = null,
    /// Opaque context handed to `error_callback`. Ignored when
    /// `error_callback` is null.
    error_callback_ctx: ?*anyopaque = null,
};

/// Backwards-compatible alias. New code should use `EngineConfig`.
pub const Config = EngineConfig;

/// LSM-style time-series storage engine.
///
/// Every mutation is appended to a CRC32C-protected write-ahead log and
/// inserted into an in-memory memtable. When the memtable hits its point
/// threshold it is rotated into a flushing slot and a background worker
/// writes it to an immutable on-disk segment. A second background worker
/// merges level-0 segments into larger level-1 segments to bound read
/// amplification.
///
/// Threading model: `appendPoints`, `flush`, `queryPoints`, and `sync`
/// are safe to call concurrently from multiple threads; they take the
/// engine's internal lock. Background flush and compaction tasks run on
/// the user-supplied `thread_pool.ThreadPool`. `deinit` must not be
/// called concurrently with any other operation.
pub const Engine = struct {
    /// Exclusive lock protecting every other field on the struct.
    /// Previously a `RwLock`, but the engine's shared-lock usages were
    /// all brief reads that the lock-then-cv wait pattern needs to be
    /// paired with a `Condition`, which `std.Io.Condition` only knows
    /// how to pair with an `Io.Mutex`. Switching to a plain mutex
    /// removes a class of spin loops and simplifies reasoning.
    mu: std.Io.Mutex = std.Io.Mutex.init,
    /// Broadcast whenever a background flush or compaction worker
    /// clears its in-flight flag (`flushing_mem = null` or
    /// `compaction_running = false`). Waiters in `deinit`, `flush`,
    /// and the back-pressure branch of `appendPoints` use this to
    /// block efficiently instead of `Thread.yield`-spinning. Pair
    /// with `mu`.
    done_cv: std.Io.Condition = std.Io.Condition.init,
    allocator: Allocator,
    config: EngineConfig,
    wal: wal_manager.WalManager,
    man: manifest.Manifest,
    active_mem: memtable.Memtable,
    flushing_mem: ?memtable.Memtable = null,
    pool: *thread_pool.ThreadPool,
    compaction_running: bool = false,
    /// Most recent error observed by a background flush or compaction
    /// worker. Cleared by `lastBackgroundError`. Workers set this under
    /// `mu` so concurrent reads always observe a consistent value;
    /// callers use `lastBackgroundError` to drain it.
    last_background_error: ?anyerror = null,
    /// Monotonically increasing counter tracking the number of
    /// flushes that have COMPLETED (success or failure).
    /// `flush()` snapshots `flushes_completed` plus the number of
    /// flushes it has either submitted or is waiting on, then waits
    /// until the counter reaches that target. This avoids the bug
    /// where flush() returned after "some" flush completed rather
    /// than "the flush I scheduled" (Q-REL-010).
    flushes_completed: u64 = 0,

    /// Open (or create) an engine over `config.data_dir`.
    ///
    /// On open, the engine loads the manifest (if present), opens the
    /// WAL, and replays any WAL records past the last manifest checkpoint
    /// into the in-memory memtable. The supplied `pool` is borrowed for
    /// the lifetime of the engine (background flush and compaction tasks
    /// are submitted to it); the caller retains ownership and must
    /// outlive the engine.
    ///
    /// Errors:
    /// - `error.FileNotFound` if `config.data_dir` does not exist or, when
    ///   `config.create_identity_if_missing == false`, when `ts.uuid` is
    ///   missing.
    /// - `error.InvalidMagic`/`error.ChecksumMismatch` on a corrupt manifest.
    /// - `error.OutOfMemory` on allocator failure.
    /// - Any I/O error from the underlying WAL or filesystem.
    ///
    /// Allocator lifetime: `allocator` must outlive the engine; it is
    /// used both for engine-owned state (manifest, memtable) and for
    /// transient buffers inside `appendPoints`.
    pub fn init(allocator: Allocator, config: EngineConfig, pool: *thread_pool.ThreadPool) !Engine {
        try validateDataDir(config.data_dir);

        var man = try manifest.Manifest.init(allocator, config.data_dir);
        errdefer man.deinit();

        // Verify the on-disk segments referenced by the manifest before
        // we accept any traffic. In `fail_closed` mode any missing or
        // corrupt segment aborts the open; in `salvage` mode the
        // segment is silently dropped from the in-memory manifest so
        // the engine can come up. Closes GAP-0006.
        try verifySegments(allocator, &man, config.data_dir, config.wal_recovery);

        const io = std.Io.Threaded.global_single_threaded.io();
        const wal_dir = try std.Io.Dir.cwd().openDir(io, config.data_dir, .{});
        var wal = try wal_manager.WalManager.init(allocator, wal_dir, man.ts_uuid, man.last_checkpoint_lsn, .{
            .create_identity_if_missing = config.create_identity_if_missing,
        });
        errdefer wal.deinit();

        var mem = memtable.Memtable.init(allocator, config.max_memtable_points);
        errdefer mem.deinit();

        // Replay WAL into the memtable. The default `fail_closed`
        // policy uses `forEachFromStrict`, which surfaces CRC32C
        // checksum mismatches and deserialisation errors instead of
        // silently dropping records (previous behaviour, tracked
        // under GAP-0005 / SEC-002 / SEC-003 / Q-REL-001). Operators
        // who explicitly accept lossy recovery can opt in with
        // `wal_recovery = .salvage`.
        try replayWalIntoMemtable(allocator, &wal, &mem, man.last_checkpoint_lsn + 1, config.wal_recovery);

        return Engine{
            .allocator = allocator,
            .config = config,
            .wal = wal,
            .man = man,
            .active_mem = mem,
            .pool = pool,
        };
    }

    /// Iterate every segment referenced by `man` and prove that the
    /// underlying file exists, starts with `SEGMENT_MAGIC`, and is at
    /// least one block-header long. The block header sanity check
    /// catches the case where the magic was written but the writer
    /// died before the first block landed.
    ///
    /// In `fail_closed` mode any failure aborts the open. In
    /// `salvage` mode the broken segment is removed from the
    /// in-memory manifest (no on-disk change) so the engine can come
    /// up; this is documented as a recovery escape hatch.
    fn verifySegments(
        allocator: Allocator,
        man: *manifest.Manifest,
        data_dir: []const u8,
        policy: WalRecoveryPolicy,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        var kept = std.ArrayListUnmanaged(manifest.SegmentMeta).empty;
        defer kept.deinit(allocator);
        try kept.ensureTotalCapacity(allocator, man.segments.items.len);

        for (man.segments.items) |seg| {
            const path = try segment.segmentPath(allocator, data_dir, seg.id);
            defer allocator.free(path);

            const verify_result = verifyOneSegment(io, path);
            if (verify_result) |_| {
                kept.appendAssumeCapacity(seg);
                continue;
            } else |err| {
                switch (policy) {
                    .fail_closed => return err,
                    .salvage => {
                        // Drop the bad segment but keep going. We
                        // do NOT touch the on-disk manifest here —
                        // the next legitimate save() will rewrite it.
                        continue;
                    },
                }
            }
        }

        // Replace the in-memory segment list with the verified subset.
        // Only matters in salvage mode (in fail_closed we would have
        // returned above); harmless otherwise (kept == segments).
        if (policy == .salvage and kept.items.len != man.segments.items.len) {
            man.segments.deinit(allocator);
            man.segments = .empty;
            try man.segments.appendSlice(allocator, kept.items);
        }
    }

    /// Verify a single segment file. Returns
    /// `error.SegmentFileMissing` if the file does not exist,
    /// `error.SegmentCorrupted` if the magic bytes are wrong or the
    /// file is too short to even hold one block header.
    fn verifyOneSegment(io: std.Io, path: []const u8) !void {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.SegmentFileMissing,
                else => err,
            };
        };
        defer file.close(io);

        const file_len = try file.length(io);
        if (file_len < segment.SEGMENT_MAGIC.len + segment.BlockHeader.encoded_size) {
            return error.SegmentCorrupted;
        }

        var magic_buf: [segment.SEGMENT_MAGIC.len]u8 = undefined;
        const read_len = try file.readPositionalAll(io, &magic_buf, 0);
        if (read_len != segment.SEGMENT_MAGIC.len) return error.SegmentCorrupted;
        if (!std.mem.eql(u8, &magic_buf, &segment.SEGMENT_MAGIC)) {
            return error.SegmentCorrupted;
        }
    }

    /// Reject `data_dir` values that are empty or contain a `..`
    /// component. We refuse `..` substrings outright rather than try to
    /// canonicalise the path — the engine has no reliable way to know
    /// what "safe" means in the caller's environment, so the safest
    /// behaviour is to fail fast and force the caller to pass a clean,
    /// pre-resolved path. Absolute paths are preferred but not
    /// required (test helpers like `std.testing.tmpDir` produce
    /// relative paths under the cwd).
    ///
    /// Exposed for unit tests; production code reaches it via `init`.
    pub fn validateDataDir(data_dir: []const u8) !void {
        if (data_dir.len == 0) return error.InvalidDataDir;
        if (std.mem.indexOf(u8, data_dir, "..") != null) return error.PathTraversal;
    }

    /// Stream the WAL forward from `start_lsn` into `mem` according
    /// to `policy`. In `fail_closed` mode, any error encountered while
    /// iterating the WAL bubbles up (including `error.InvalidFormat`
    /// for deserialisation failures and `error.ChecksumMismatch` for
    /// CRC32C mismatches). In `salvage` mode the lossy `readFrom`
    /// path is used and bad records are dropped silently — the
    /// operator opts in to this with eyes open.
    fn replayWalIntoMemtable(
        allocator: Allocator,
        wal: *wal_manager.WalManager,
        mem: *memtable.Memtable,
        start_lsn: u64,
        policy: WalRecoveryPolicy,
    ) !void {
        switch (policy) {
            .fail_closed => {
                const ReplayCtx = struct {
                    allocator: Allocator,
                    mem: *memtable.Memtable,

                    fn apply(self: @This(), rec: *const wal_record.WalRecord) anyerror!void {
                        try applyWalRecord(self.allocator, self.mem, rec);
                    }
                };
                var failure: ?wal_manager.ReplayFailure = null;
                wal.forEachFromStrict(
                    start_lsn,
                    allocator,
                    &failure,
                    ReplayCtx{ .allocator = allocator, .mem = mem },
                    ReplayCtx.apply,
                ) catch |err| return err;
            },
            .salvage => {
                const records = try wal.readFrom(start_lsn, allocator);
                defer {
                    for (records) |*r| r.deinit(allocator);
                    allocator.free(records);
                }
                for (records) |*r| {
                    try applyWalRecord(allocator, mem, r);
                }
            },
        }
    }

    /// Apply a single decoded WAL record to the memtable. Only
    /// `append_points` records are replayed — other record types are
    /// metadata-only and have already taken effect by the time the
    /// manifest reaches a consistent state. Malformed payload
    /// (truncated header or non-16-byte point stride) is skipped per
    /// the original recovery behaviour; the strict path validates the
    /// envelope (header + CRC32C) but cannot diagnose payload-level
    /// corruption short of an inner re-encoding.
    fn applyWalRecord(
        allocator: Allocator,
        mem: *memtable.Memtable,
        rec: *const wal_record.WalRecord,
    ) !void {
        if (rec.record_type != .append_points) return;
        if (rec.payload.len < 16 or (rec.payload.len - 16) % 16 != 0) return;

        const series_id = std.mem.readInt(u128, rec.payload[0..16], .little);
        const num_points = (rec.payload.len - 16) / 16;
        var points = try allocator.alloc(types.Point, num_points);
        defer allocator.free(points);

        var pos: usize = 16;
        for (0..num_points) |i| {
            points[i] = .{
                .ts = std.mem.readInt(i64, rec.payload[pos..][0..8], .little),
                .value = std.mem.readInt(i64, rec.payload[pos + 8 ..][0..8], .little),
            };
            pos += 16;
        }

        try mem.insert(series_id, points);
    }

    /// Tear down the engine and release its resources.
    ///
    /// Blocks until any in-flight background flush or compaction task
    /// has finished, then closes the WAL, manifest, and memtable.
    /// Callers must ensure no other engine methods are in flight on
    /// other threads before invoking `deinit` (it is not safe to call
    /// concurrently with `appendPoints`, `flush`, `queryPoints`, or
    /// `sync`).
    ///
    /// Does not flush the active memtable to disk — that is the
    /// caller's responsibility via `flush()` or `sync()`. Data only
    /// present in the active memtable will be recovered from the WAL
    /// on the next open.
    pub fn deinit(self: *Engine) void {
        const io = std.Io.Threaded.global_single_threaded.io();

        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        // Wait for all background tasks to finish. Park on the condition
        // variable so we burn no CPU; workers broadcast it as they
        // clear `flushing_mem` / `compaction_running`.
        while (self.flushing_mem != null or self.compaction_running) {
            self.done_cv.waitUncancelable(io, &self.mu);
        }

        self.wal.deinit();
        self.man.deinit();
        self.active_mem.deinit();
        if (self.flushing_mem) |*fm| fm.deinit();
    }

    /// Append a batch of points to the given series.
    ///
    /// The batch is first persisted to the WAL (CRC32C-checksummed,
    /// LSN-ordered) and then inserted into the in-memory memtable.
    /// When the memtable's point count crosses `config.max_memtable_points`,
    /// the engine rotates it into a flushing slot and submits a flush
    /// job to the thread pool; this call returns as soon as the rotation
    /// completes, without waiting for the segment to land on disk.
    ///
    /// Durability: data is durable on disk only after a successful call
    /// to `sync()` (or after `flush()` returns, which also fsyncs the
    /// new segment + manifest). A `try eng.appendPoints(...)` that
    /// returns without error guarantees the WAL has accepted the record
    /// in memory, **not** that it has been fsync'd; a crash before the
    /// next `sync()` may lose recent appends (they will be replayed
    /// from the WAL on the next open).
    ///
    /// Threading: callers may invoke this concurrently from multiple
    /// threads; the engine serialises WAL appends and memtable inserts
    /// under its internal lock. The call blocks while the engine waits
    /// for an in-flight flush to release the flushing slot under back-
    /// pressure (memtable already full and a flush is still in progress).
    ///
    /// Ownership: `points` is read-only; the engine copies the data
    /// into the memtable. Caller retains ownership of the slice.
    ///
    /// Errors:
    /// - `error.OutOfMemory` if the payload buffer or memtable cannot grow.
    /// - WAL I/O errors (disk full, permissions, fsync failures) bubble
    ///   up unchanged.
    /// - Thread-pool submission failure on a memtable rotation aborts
    ///   the rotation and returns the underlying error; the memtable
    ///   state is consistent.
    pub fn appendPoints(self: *Engine, series_id: types.SeriesId, points: []const types.Point) !void {
        if (points.len == 0) return;
        // CWE-770: cap attacker-influenced batch size before any
        // allocation. The transient payload buffer below is 16 bytes
        // per point; bounding the batch bounds the worst-case
        // allocation an external caller can force.
        if (points.len > limits.MAX_APPEND_BATCH_POINTS) return error.BatchTooLarge;

        const payload = try encodeAppendPointsPayload(self.allocator, series_id, points);
        defer self.allocator.free(payload);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        _ = try self.appendToWalLocked(payload);
        try self.active_mem.insert(series_id, points);
        try self.maybeTriggerFlushLocked(io);
    }

    /// Serialise `(series_id, points)` into the WAL record payload
    /// format expected by `wal_record.WalRecord`. Layout is
    /// `series_id (u128 LE) || (i64 ts, i64 value)*`. Caller owns the
    /// returned buffer.
    fn encodeAppendPointsPayload(
        allocator: Allocator,
        series_id: types.SeriesId,
        points: []const types.Point,
    ) ![]u8 {
        const payload_size = 16 + (points.len * 16);
        const payload = try allocator.alloc(u8, payload_size);
        errdefer allocator.free(payload);

        std.mem.writeInt(u128, payload[0..16], series_id, .little);
        var pos: usize = 16;
        for (points) |pt| {
            std.mem.writeInt(i64, payload[pos..][0..8], pt.ts, .little);
            pos += 8;
            std.mem.writeInt(i64, payload[pos..][0..8], pt.value, .little);
            pos += 8;
        }
        return payload;
    }

    /// Append an already-encoded payload to the WAL and return the
    /// assigned LSN. Must be called with `self.mu` held — the WAL
    /// library is not internally synchronised.
    fn appendToWalLocked(self: *Engine, payload: []const u8) !u64 {
        var rec = wal_record.WalRecord{
            .lsn = 0,
            .record_type = .append_points,
            .payload = payload,
            .checksum = 0,
        };
        // The returned LSN isn't surfaced through appendPoints today,
        // but is captured here so a future "wait until durable" API
        // can return it without reshaping the call site. See
        // manifest.last_checkpoint_lsn for the related watermark.
        return try self.wal.appendRecord(&rec);
    }

    /// If the active memtable has tripped its flush threshold,
    /// rotate it into the flushing slot and submit a flush worker.
    /// Honours back-pressure: parks on `done_cv` when a previous
    /// flush is still in flight. Must be called with `self.mu` held.
    fn maybeTriggerFlushLocked(self: *Engine, io: std.Io) !void {
        while (self.active_mem.shouldFlush() and self.flushing_mem != null) {
            self.done_cv.waitUncancelable(io, &self.mu);
        }
        if (!self.active_mem.shouldFlush()) return;

        self.flushing_mem = self.active_mem;
        self.active_mem = memtable.Memtable.init(self.allocator, self.config.max_memtable_points);
        _ = self.pool.submit(flushWorker, self, .{}) catch |err| {
            self.flushing_mem.?.deinit();
            self.flushing_mem = null;
            self.done_cv.broadcast(io);
            return err;
        };
    }

    fn flushWorker(ctx: *anyopaque, _: *thread_pool.TaskContext) void {
        var self: *Engine = @ptrCast(@alignCast(ctx));
        self.flushInternal() catch |err| {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.mu.lockUncancelable(io);
            if (self.flushing_mem) |*fm| fm.deinit();
            self.flushing_mem = null;
            // A failed flush still counts as a completed scheduling
            // round so flush() callers are not stuck waiting forever
            // for a flush that errored out.
            self.flushes_completed += 1;
            self.recordBackgroundErrorLocked(.flush, err);
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
        };
    }

    /// Store `err` as the engine's most recent background-worker
    /// failure and dispatch it to `error_callback` (if configured).
    /// Caller MUST hold `self.mu`. The callback runs under the lock
    /// — callers MUST NOT re-enter the engine from the callback.
    fn recordBackgroundErrorLocked(self: *Engine, phase: BgPhase, err: anyerror) void {
        self.last_background_error = err;
        if (self.config.error_callback) |cb| {
            // The callback ctx may legitimately be null when the
            // caller has no per-instance state to thread through;
            // use a stable non-null sentinel so the callback's
            // `*anyopaque` parameter is well-defined either way.
            const ctx_ptr = self.config.error_callback_ctx orelse @as(*anyopaque, @ptrCast(self));
            cb(ctx_ptr, phase, err);
        }
    }

    /// Drain and return the most recent background-worker error
    /// recorded by a flush or compaction worker (or null if none).
    ///
    /// Reading clears the slot, so two successive calls to
    /// `lastBackgroundError` cannot return the same error — operators
    /// who want a persistent audit trail must wire `error_callback`.
    ///
    /// Threading: takes the engine's lock; safe to call concurrently
    /// with other engine methods.
    pub fn lastBackgroundError(self: *Engine) ?anyerror {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const err = self.last_background_error;
        self.last_background_error = null;
        return err;
    }

    /// Force any data in the active memtable to a new segment on disk,
    /// then block until that segment is durable.
    ///
    /// If the active memtable is empty this is a no-op. Otherwise, the
    /// memtable is rotated into the flushing slot, a flush job is
    /// submitted, and the call blocks until `flushing_mem` is cleared
    /// (segment header written, manifest updated, WAL truncated past
    /// the checkpoint).
    ///
    /// Threading: safe to call concurrently with other engine methods,
    /// but the engine serialises flushes one at a time — overlapping
    /// `flush()` callers will queue up behind one another.
    ///
    /// Errors: thread-pool submission failure or any WAL/segment I/O
    /// error bubbles up. On error the engine state is consistent and
    /// the call may be retried.
    pub fn flush(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        // Snapshot the current completion counter and decide what the
        // target value must be before we can return. The target rises
        // by one for every flush we submit OR are already waiting on.
        //
        // Three cases:
        //  1. Active memtable has data AND no flush is in flight —
        //     submit one, target = completed + 1.
        //  2. Active memtable has data AND a flush is in flight —
        //     wait for the in-flight one to drain the slot, then
        //     submit ours. Target = completed + 2 (two flushes will
        //     finish before we can return: theirs + ours).
        //  3. Active memtable empty AND no flush in flight — no-op
        //     return.
        //  4. Active memtable empty AND a flush in flight — wait for
        //     it. Target = completed + 1.
        var target: u64 = self.flushes_completed;
        if (self.flushing_mem != null) target += 1;

        if (self.active_mem.point_count > 0) {
            // Wait for any in-flight flush to release the slot.
            while (self.flushing_mem != null) {
                self.done_cv.waitUncancelable(io, &self.mu);
            }
            self.flushing_mem = self.active_mem;
            self.active_mem = memtable.Memtable.init(self.allocator, self.config.max_memtable_points);
            target = self.flushes_completed + 1;
            _ = self.pool.submit(flushWorker, self, .{}) catch |err| {
                self.flushing_mem.?.deinit();
                self.flushing_mem = null;
                self.done_cv.broadcast(io);
                return err;
            };
        }

        // Wait until our specific submission (and any prior one we
        // were already waiting for) has reached the target counter.
        // Using a counter rather than "while flushing_mem != null"
        // closes Q-REL-010: a concurrent caller's flush completing
        // before ours can no longer cause us to return prematurely.
        while (self.flushes_completed < target) {
            self.done_cv.waitUncancelable(io, &self.mu);
        }
    }

    fn flushInternal(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var min_ts: i64 = std.math.maxInt(i64);
        var max_ts: i64 = std.math.minInt(i64);

        self.mu.lockUncancelable(io);
        var mem = self.flushing_mem orelse return;
        self.mu.unlock(io);

        if (mem.point_count == 0) {
            self.mu.lockUncancelable(io);
            mem.deinit();
            self.flushing_mem = null;
            self.flushes_completed += 1;
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
            return;
        }

        var it = mem.series.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.items.len > 0) {
                const first_ts = entry.value_ptr.items[0].ts;
                const last_ts = entry.value_ptr.items[entry.value_ptr.items.len - 1].ts;
                if (first_ts < min_ts) min_ts = first_ts;
                if (last_ts > max_ts) max_ts = last_ts;
            }
        }

        self.mu.lockUncancelable(io);
        const seg_id = self.man.getNextSegmentId();
        self.mu.unlock(io);

        const seg_name = try segment.segmentPath(self.allocator, self.config.data_dir, seg_id);
        defer self.allocator.free(seg_name);

        var writer = try segment.SegmentWriter.init(self.allocator, seg_name);
        defer writer.deinit();

        it = mem.series.iterator();
        while (it.next()) |entry| {
            try writer.writeBlock(entry.key_ptr.*, entry.value_ptr.items);
        }

        // Durability ordering: fsync the segment file BEFORE adding
        // it to the manifest. A crash between manifest commit and the
        // OS background flush would otherwise leave the manifest
        // referencing a segment whose blocks have not actually
        // landed on disk (Q-REL-008 / P-IO-003).
        try writer.sync();

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            try self.man.addSegment(.{
                .id = seg_id,
                .min_ts = min_ts,
                .max_ts = max_ts,
                .level = 0,
            });

            self.man.last_checkpoint_lsn = self.wal.currentLsn();
            try self.wal.truncate(self.man.last_checkpoint_lsn);
            try self.man.save();

            mem.deinit();
            self.flushing_mem = null;
            self.flushes_completed += 1;
            self.done_cv.broadcast(io);
        }

        self.triggerCompaction() catch |err| {
            // A failed compaction trigger is not fatal — the flush
            // itself already succeeded and persisted a new segment.
            // Record under the lock so callers can drain it via
            // `lastBackgroundError`.
            self.mu.lockUncancelable(io);
            self.recordBackgroundErrorLocked(.compaction, err);
            self.mu.unlock(io);
        };
    }

    fn triggerCompaction(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        var l0_count: usize = 0;
        for (self.man.segments.items) |seg| {
            if (seg.level == 0) l0_count += 1;
        }
        self.mu.unlock(io);

        if (l0_count >= kL0CompactionThreshold) {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            if (!self.compaction_running) {
                self.compaction_running = true;
                _ = self.pool.submit(compactionWorker, self, .{}) catch {
                    self.compaction_running = false;
                    // No worker actually ran, so wake anyone parked
                    // on the "compaction_running == false" predicate.
                    self.done_cv.broadcast(io);
                };
            }
        }
    }

    fn compactionWorker(ctx: *anyopaque, _: *thread_pool.TaskContext) void {
        var self: *Engine = @ptrCast(@alignCast(ctx));
        const result = self.compactL0();
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        if (result) |_| {} else |err| {
            self.recordBackgroundErrorLocked(.compaction, err);
        }
        self.compaction_running = false;
        self.done_cv.broadcast(io);
        self.mu.unlock(io);
    }

    fn compactL0(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        var l0_segs = std.ArrayList(manifest.SegmentMeta).empty;
        defer l0_segs.deinit(self.allocator);
        var new_seg_id: usize = 0;

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            for (self.man.segments.items) |seg| {
                if (seg.level == 0) {
                    try l0_segs.append(self.allocator, seg);
                }
            }
            if (l0_segs.items.len < kL0CompactionThreshold) {
                return;
            }
            new_seg_id = self.man.getNextSegmentId();
        }

        var paths = std.ArrayList([]const u8).empty;
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }

        var min_ts: i64 = std.math.maxInt(i64);
        var max_ts: i64 = std.math.minInt(i64);

        for (l0_segs.items) |seg| {
            const p = try segment.segmentPath(self.allocator, self.config.data_dir, seg.id);
            try paths.append(self.allocator, p);
            if (seg.min_ts < min_ts) min_ts = seg.min_ts;
            if (seg.max_ts > max_ts) max_ts = seg.max_ts;
        }

        const out_path = try segment.segmentPath(self.allocator, self.config.data_dir, new_seg_id);
        defer self.allocator.free(out_path);

        var compactor = compaction.Compactor.init(self.allocator, self.pool);
        try compactor.compactSegments(paths.items, out_path);

        // Build an O(1)-lookup hash set of the IDs we just compacted so
        // the "kept segments" filter below is O(n) over the manifest,
        // not O(n × k) where k is the number of L0 segments folded into
        // the new L1. Closes P-ALGO-004 / Q-CPLX-002.
        var compacted_ids = std.AutoHashMap(u64, void).init(self.allocator);
        defer compacted_ids.deinit();
        try compacted_ids.ensureTotalCapacity(@intCast(l0_segs.items.len));
        for (l0_segs.items) |seg| compacted_ids.putAssumeCapacity(seg.id, {});

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            var new_segments = std.ArrayListUnmanaged(manifest.SegmentMeta).empty;
            for (self.man.segments.items) |seg| {
                if (!compacted_ids.contains(seg.id)) {
                    try new_segments.append(self.allocator, seg);
                }
            }

            try new_segments.append(self.allocator, .{
                .id = new_seg_id,
                .min_ts = min_ts,
                .max_ts = max_ts,
                .level = 1,
            });

            self.man.segments.deinit(self.allocator);
            self.man.segments = new_segments;

            try self.man.save();
        }

        for (paths.items, l0_segs.items) |p, seg| {
            _ = seg;
            std.Io.Dir.cwd().deleteFile(io, p) catch |err| {
                // The new compacted segment is already durable and
                // referenced by the manifest; the old L0 segment file
                // is now an orphan on disk. Surface the failure so
                // operators can find and reclaim the leak via
                // `lastBackgroundError` / `error_callback` instead of
                // silently dropping it on the floor.
                self.mu.lockUncancelable(io);
                self.recordBackgroundErrorLocked(.compaction, err);
                self.mu.unlock(io);
            };
        }
    }

    /// Query all points in the inclusive timestamp range
    /// `[start_ts, end_ts]` for `series_id`, returning a `MergeIterator`
    /// that streams the points in ascending `(ts, value)` order.
    ///
    /// The iterator merges three sources: the active memtable, the
    /// flushing memtable (if any), and every overlapping on-disk
    /// segment. Segment blocks are decoded on the fly via Gorilla.
    ///
    /// Allocator ownership: every allocation made for the returned
    /// iterator (the iterator itself, its child `SliceIterator`s, and
    /// the decoded `Point` slices that back them) is made on `arena`.
    /// The caller MUST keep `arena` alive for the lifetime of the
    /// iterator, and must NOT call `deinit` on the iterator — freeing
    /// the arena reclaims everything in one shot. This is intentional:
    /// it removes the need for per-iterator cleanup paths and lets
    /// callers drive multiple queries off the same arena cheaply.
    ///
    /// Threading: takes the engine's shared lock for the duration of
    /// the call (so concurrent appends are blocked while the query is
    /// reading the manifest segment list). The returned iterator is
    /// independent: once the call returns, segments may be compacted
    /// out from underneath it (segment readers were opened during the
    /// call and the decoded points have been copied into arena memory).
    ///
    /// Errors:
    /// - `error.OutOfMemory` from the arena.
    /// - Segment read errors are currently silently skipped for the
    ///   affected segment (per-segment best-effort) — this is tracked
    ///   under Q-REL-003 and will be tightened in a follow-up.
    pub fn queryPoints(self: *Engine, arena: Allocator, series_id: types.SeriesId, start_ts: i64, end_ts: i64) !*iterator.MergeIterator {
        const io = std.Io.Threaded.global_single_threaded.io();

        const merge_it = try arena.create(iterator.MergeIterator);
        merge_it.* = iterator.MergeIterator.init(arena);

        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        try queryMemtable(arena, &self.active_mem, series_id, start_ts, end_ts, merge_it);
        if (self.flushing_mem) |*mem| {
            try queryMemtable(arena, mem, series_id, start_ts, end_ts, merge_it);
        }
        for (self.man.segments.items) |seg| {
            if (seg.min_ts > end_ts or seg.max_ts < start_ts) continue;
            try self.querySegment(arena, seg, series_id, start_ts, end_ts, merge_it);
        }

        return merge_it;
    }

    /// Drain points for `series_id` in `[start_ts, end_ts]` from a
    /// memtable into `merge_it`. Allocates the filtered slice on the
    /// supplied arena.
    fn queryMemtable(
        arena: Allocator,
        mem: *const memtable.Memtable,
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        merge_it: *iterator.MergeIterator,
    ) !void {
        const pts = mem.series.get(series_id) orelse return;
        var filtered_pts = std.ArrayListUnmanaged(types.Point).empty;
        for (pts.items) |pt| {
            if (pt.ts >= start_ts and pt.ts <= end_ts) {
                try filtered_pts.append(arena, pt);
            }
        }
        if (filtered_pts.items.len == 0) return;

        var slice_it = try arena.create(iterator.SliceIterator);
        slice_it.* = .{ .slice = try filtered_pts.toOwnedSlice(arena) };
        try merge_it.addIterator(slice_it.iterator());
    }

    /// Open `seg` from disk and append any overlapping blocks for
    /// `series_id` to `merge_it`.
    ///
    /// Error handling, post Q-REL-003 / Q-REL-009 / Q-REL-010:
    ///
    /// - If the segment file is gone, the most likely cause is a
    ///   benign race with a concurrent compaction worker that has
    ///   already swapped the manifest entry. We swallow
    ///   `error.FileNotFound` and treat the segment as empty.
    /// - Every other open error propagates (permissions, I/O failure,
    ///   bad magic).
    /// - Block iterator and decode errors propagate — they indicate
    ///   on-disk corruption that the caller should know about
    ///   instead of silently receiving truncated results.
    /// - Arena allocation failures propagate; the caller is the only
    ///   place that knows how to surface them up the stack.
    fn querySegment(
        self: *Engine,
        arena: Allocator,
        seg: manifest.SegmentMeta,
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        merge_it: *iterator.MergeIterator,
    ) !void {
        const p = try segment.segmentPath(self.allocator, self.config.data_dir, seg.id);
        defer self.allocator.free(p);

        var seg_reader = segment.SegmentReader.init(self.allocator, p) catch |err| switch (err) {
            // Benign race with compaction: the segment was just
            // unlinked but the in-memory manifest snapshot we
            // captured still references it. Skip.
            error.FileNotFound => return,
            else => return err,
        };
        defer seg_reader.deinit();

        var block_it = seg_reader.iterator();
        while (try block_it.next()) |block| {
            if (block.header.series_id != series_id) continue;
            if (block.header.stats.max_ts < start_ts) continue;
            if (block.header.stats.min_ts > end_ts) continue;

            const pts = try block.decodePoints(arena);
            var filtered_pts = std.ArrayListUnmanaged(types.Point).empty;
            for (pts) |pt| {
                if (pt.ts >= start_ts and pt.ts <= end_ts) {
                    try filtered_pts.append(arena, pt);
                }
            }
            if (filtered_pts.items.len == 0) continue;

            var slice_it = try arena.create(iterator.SliceIterator);
            slice_it.* = .{ .slice = try filtered_pts.toOwnedSlice(arena) };
            try merge_it.addIterator(slice_it.iterator());
        }
    }

    /// Force the WAL and manifest to durable storage (fsync the WAL,
    /// re-write the manifest to its current dual-file slot).
    ///
    /// This does NOT flush the active memtable to a segment — use
    /// `flush()` for that. `sync()` provides a "make currently
    /// accepted appends durable" guarantee without paying the cost of
    /// closing the active memtable.
    ///
    /// Threading: takes the engine's exclusive lock; concurrent
    /// `appendPoints` calls will block briefly while `sync()` is in
    /// flight. Safe to call from any thread.
    ///
    /// Errors: WAL fsync or manifest write errors bubble up unchanged.
    pub fn sync(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.wal.sync();
        try self.man.save();
    }
};

test "Engine basic operations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var engine = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 5,
    }, &pool);
    defer engine.deinit();

    const pts = [_]types.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
    };

    try engine.appendPoints(1, &pts);
    try engine.appendPoints(1, &pts);

    // Wait for async flush to finish
    try engine.flush();

    try std.testing.expectEqual(@as(usize, 1), engine.man.segments.items.len);
}

test "Engine: appendPoints rejects oversized batch" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var engine = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
    }, &pool);
    defer engine.deinit();

    // Constructing an actual MAX_APPEND_BATCH_POINTS+1 slice would
    // be wasteful; we synthesise a fake-length slice via a
    // zero-stride pointer trick that the type system accepts but
    // we never read from (the size check rejects before any deref).
    const fake_len = limits.MAX_APPEND_BATCH_POINTS + 1;
    const stub_pt: types.Point = .{ .ts = 0, .value = 0 };
    const oversize: []const types.Point = @as([*]const types.Point, @ptrCast(&stub_pt))[0..fake_len];

    try std.testing.expectError(error.BatchTooLarge, engine.appendPoints(1, oversize));
}

test "Engine: validateDataDir rejects empty and traversal" {
    try std.testing.expectError(error.InvalidDataDir, Engine.validateDataDir(""));
    try std.testing.expectError(error.PathTraversal, Engine.validateDataDir("../etc"));
    try std.testing.expectError(error.PathTraversal, Engine.validateDataDir("foo/../bar"));
    try Engine.validateDataDir("/tmp/safe");
    try Engine.validateDataDir("relative/safe");
}

test "Engine: lastBackgroundError is null on clean operation and drains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var engine = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 100,
    }, &pool);
    defer engine.deinit();

    // Clean engine: nothing in the slot.
    try std.testing.expect(engine.lastBackgroundError() == null);

    // Synthesise a worker error to prove the slot/callback wiring
    // works end-to-end without depending on filesystem races.
    {
        engine.mu.lockUncancelable(io);
        engine.recordBackgroundErrorLocked(.flush, error.TestInjected);
        engine.mu.unlock(io);
    }
    const err = engine.lastBackgroundError();
    try std.testing.expect(err != null);
    try std.testing.expect(err.? == error.TestInjected);

    // Slot must be drained after a read.
    try std.testing.expect(engine.lastBackgroundError() == null);
}

test "Engine: error_callback fires when a background error is recorded" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const Trace = struct {
        var count: usize = 0;
        var last_phase: BgPhase = undefined;
        var last_err: anyerror = undefined;

        fn cb(_: *anyopaque, phase: BgPhase, err: anyerror) void {
            count += 1;
            last_phase = phase;
            last_err = err;
        }

        fn reset() void {
            count = 0;
        }
    };
    Trace.reset();

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var engine = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 100,
        .error_callback = Trace.cb,
    }, &pool);
    defer engine.deinit();

    {
        engine.mu.lockUncancelable(io);
        engine.recordBackgroundErrorLocked(.compaction, error.TestInjected);
        engine.mu.unlock(io);
    }

    try std.testing.expectEqual(@as(usize, 1), Trace.count);
    try std.testing.expectEqual(BgPhase.compaction, Trace.last_phase);
    try std.testing.expect(Trace.last_err == error.TestInjected);
}
