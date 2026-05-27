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
const safety = @import("safety.zig");
const thread_pool = @import("thread_pool");
const wal_record = @import("wal_record.zig");

/// Number of level-0 segments that triggers a compaction job.
/// Chosen to match the level-0 fan-in used by typical LSM designs;
/// keeps the read amplification on L0 bounded while still amortizing
/// compaction work over enough memtable flushes to matter.
const kL0CompactionThreshold: usize = 4;

/// Monotonic-clock nanoseconds helper used by the observability
/// counters (P-OBS-001). Uses the `.awake` clock (Linux:
/// `CLOCK_MONOTONIC`) so NTP slews and wall-clock adjustments do
/// not produce negative deltas that would underflow the unsigned
/// counters.
///
/// Each call is a `clock_gettime` (~30 ns on x86_64) — cheap enough
/// that we can stamp every `appendPoints`, `queryPoints`,
/// `flushInternal`, and compaction boundary without measurable
/// overhead. The same helper is used by the bench framework, so the
/// engine and the bench numbers share a clock source.
fn nowMonotonicNs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return if (ts < 0) 0 else @intCast(ts);
}

/// Engine-level error set, unioning the named sets from each module
/// the engine builds on plus a handful of engine-only conditions.
///
/// In practice most engine APIs still return inferred error sets
/// (`!T`) because they also produce allocator and file-system
/// errors whose union would balloon the surface. This set is the
/// canonical place for callers who want to discriminate
/// timeseries-storage failures from generic IO.
pub const EngineError = wal_manager.WalError || segment.SegmentError || manifest.ManifestError || error{
    /// `EngineConfig.data_dir` was empty.
    InvalidDataDir,
    /// `EngineConfig.data_dir` contained a `..` component.
    PathTraversal,
    /// `appendPoints` was called with more than `limits.MAX_APPEND_BATCH_POINTS`.
    BatchTooLarge,
    /// A segment file referenced by the manifest is missing on disk.
    SegmentFileMissing,
    /// A segment file is present but does not start with `SEGMENT_MAGIC`
    /// or is otherwise too short to be valid.
    SegmentCorrupted,
};

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
    /// Optional WAL encryption key (AES-256-GCM, 32 bytes). When
    /// set, every record appended to the WAL is encrypted in place
    /// by the underlying `wal_lib.WriteAheadLog`. `null` (the default)
    /// keeps the WAL plaintext.
    ///
    /// Caveat (partial GAP-0001): segments and the manifest are
    /// still written plaintext to disk. Full TDE coverage requires
    /// AES-GCM framing on `SegmentWriter` and `Manifest.writeToFile`,
    /// which is tracked under GAP-0001 as a follow-up.
    ///
    /// Security: callers MUST keep the key consistent across opens.
    /// Reopening the same `data_dir` with a different key (or no
    /// key, when the WAL was written with one) causes the WAL
    /// library to reject decryption and `Engine.init` to fail.
    encryption_key: ?[32]u8 = null,
    /// Age-based retention. When set, `Engine.pruneExpired` removes
    /// any whole segment whose `max_ts < (now - retention_max_age_ms)`.
    /// Treated as milliseconds because the spec's recommended ts
    /// unit is "ms since the Unix epoch" (see `Point.ts`). Callers
    /// using a different unit must scale accordingly.
    ///
    /// `null` disables retention; segments are kept until explicitly
    /// removed. Closes GAP-0004 (age-based pruning).
    retention_max_age_ms: ?i64 = null,
    /// Override for the "current time" reference used by
    /// `pruneExpired`. Defaults to `null`, meaning the engine reads
    /// the system real-time clock at prune time. Exposed primarily
    /// so tests can drive deterministic cutoffs without sleeping.
    retention_now_override: ?i64 = null,
};

/// Backwards-compatible alias. New code should use `EngineConfig`.
pub const Config = EngineConfig;

/// Point-in-time snapshot of the engine's observability counters.
///
/// Closes P-OBS-001 (and completes the metrics-counters portion of
/// SEC-014). Counters cover the four hot paths — ingest, query,
/// flush, compaction — plus two reliability flags (`wal_records_dropped`
/// and `segment_integrity_failures`) that operators most often
/// reach for when triaging.
///
/// Every count and total is read while holding `Engine.mu`, so the
/// snapshot is internally consistent — `*_total_ns / *_count` always
/// yields the average latency for the same window. The snapshot is a
/// value type; callers can hold onto it across engine ops without
/// fear of mutation.
///
/// All durations are in nanoseconds, sourced from the `.awake`
/// monotonic clock (see `nowMonotonicNs`). The clock is cheap enough
/// (~30 ns per read) that instrumenting every `appendPoints` call is
/// unmeasurable next to the WAL fsync amortised cost.
pub const StatsSnapshot = struct {
    /// Number of completed `appendPoints` calls (regardless of point
    /// count). Bumps after the memtable insert succeeds; failed calls
    /// are not counted.
    append_count: u64,
    /// Total number of points accepted across all `appendPoints`
    /// calls. Roughly correlates with ingest throughput.
    append_points: u64,
    /// Cumulative wall time spent inside `appendPoints` (including
    /// WAL append, memtable insert, and any flush-trigger work).
    append_total_ns: u64,

    /// Number of completed `queryPoints` calls. A call is counted on
    /// successful return regardless of the number of points yielded.
    query_count: u64,
    /// Cumulative wall time spent inside `queryPoints` (planning +
    /// disk reads + decode + iterator construction). Iteration time
    /// AFTER the call returns is not measured here.
    query_total_ns: u64,
    /// Total number of points returned across all `queryPoints`
    /// calls (counted by the engine as it filters and copies blocks
    /// into the merge iterator). Useful for read-throughput metrics.
    query_points_returned: u64,

    /// Number of memtable -> segment flushes that completed (success
    /// OR failure). Increments inside `flushInternal` just before
    /// `done_cv.broadcast`.
    flush_count: u64,
    /// Cumulative wall time spent inside `flushInternal` (the
    /// per-flush worker body — encode, write, fsync, manifest commit).
    flush_total_ns: u64,

    /// Number of L0 -> L1 compaction passes that completed (success
    /// OR failure). Increments inside `compactL0` / `compactL0Forced`.
    compaction_count: u64,
    /// Cumulative wall time spent inside compaction worker bodies.
    compaction_total_ns: u64,

    /// Number of WAL records the engine has explicitly dropped (e.g.
    /// payload-level malformed records in `applyWalRecord`). Hard
    /// failures bubble up as errors; this counter only tracks the
    /// silent drop path.
    wal_records_dropped: u64,
    /// Number of segment-integrity failures (`SegmentFileMissing`,
    /// `SegmentCorrupted`, `BlockCorrupted`) the engine has reported
    /// via the background error pipeline. Bumps on every recorded
    /// failure, NOT every read attempt.
    segment_integrity_failures: u64,
};

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
    /// Defence-in-depth tag for thread-pool ctx pointers (SEC-010).
    /// Every type-erased recovery of `*Engine` from a thread callback
    /// uses `safety.castCtx(Engine, ctx)`, which checks this magic
    /// before touching any other field. The constant is stable across
    /// process restarts; see `src/safety.zig` for the threat model and
    /// limitations.
    pub const MAGIC: u32 = safety.Magic.engine;
    magic: u32 = MAGIC,
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
    /// Engine-owned scratch buffer reused by `appendPoints` to
    /// serialise the WAL payload. Previously each call heap-allocated
    /// a fresh buffer (16 + 16*N bytes) only to free it a few
    /// microseconds later — pure allocator churn on the hot ingest
    /// path. The buffer is sized on first use and grown in-place when
    /// a larger batch arrives; it is only freed at `deinit`.
    ///
    /// Concurrency: every `appendPoints` call serialises through
    /// `self.mu` (writer-exclusive), so the buffer has a single
    /// writer at a time. No additional synchronisation is needed.
    /// Other call sites MUST NOT touch this buffer. Closes P-MEM-003.
    append_payload_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// Engine-wide latency / throughput counters. Updated under
    /// `self.mu` by every hot path (append, query, flush, compaction).
    /// Read out via `stats()`. Closes P-OBS-001.
    counters: StatsSnapshot = .{
        .append_count = 0,
        .append_points = 0,
        .append_total_ns = 0,
        .query_count = 0,
        .query_total_ns = 0,
        .query_points_returned = 0,
        .flush_count = 0,
        .flush_total_ns = 0,
        .compaction_count = 0,
        .compaction_total_ns = 0,
        .wal_records_dropped = 0,
        .segment_integrity_failures = 0,
    },

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

        // P-OBS-001: track integrity failures encountered during
        // segment verification so we can surface them in the first
        // stats() snapshot.
        var integrity_failures: u64 = 0;

        // Verify the on-disk segments referenced by the manifest before
        // we accept any traffic. In `fail_closed` mode any missing or
        // corrupt segment aborts the open; in `salvage` mode the
        // segment is silently dropped from the in-memory manifest so
        // the engine can come up. Closes GAP-0006.
        try verifySegments(allocator, &man, config.data_dir, config.wal_recovery, &integrity_failures);

        const io = std.Io.Threaded.global_single_threaded.io();
        const wal_dir = try std.Io.Dir.cwd().openDir(io, config.data_dir, .{});
        var wal = try wal_manager.WalManager.init(allocator, wal_dir, man.ts_uuid, man.last_checkpoint_lsn, .{
            .create_identity_if_missing = config.create_identity_if_missing,
            // Closes SEC-006 / partial GAP-0001 (WAL portion only).
            // The wal library handles AES-256-GCM framing; we just
            // thread the operator-provided key through. When null
            // the WAL stays plaintext, matching pre-D-9 behaviour.
            .encryption_key = config.encryption_key,
        });
        errdefer wal.deinit();

        var mem = memtable.Memtable.init(allocator, config.max_memtable_points);
        errdefer mem.deinit();

        // P-OBS-001: counter accumulates WAL drops during replay.
        var wal_drops: u64 = 0;

        // Replay WAL into the memtable. The default `fail_closed`
        // policy uses `forEachFromStrict`, which surfaces CRC32C
        // checksum mismatches and deserialisation errors instead of
        // silently dropping records (previous behaviour, tracked
        // under GAP-0005 / SEC-002 / SEC-003 / Q-REL-001). Operators
        // who explicitly accept lossy recovery can opt in with
        // `wal_recovery = .salvage`.
        try replayWalIntoMemtable(allocator, &wal, &mem, man.last_checkpoint_lsn + 1, config.wal_recovery, &wal_drops);

        return Engine{
            .allocator = allocator,
            .config = config,
            .wal = wal,
            .man = man,
            .active_mem = mem,
            .pool = pool,
            .counters = .{
                .append_count = 0,
                .append_points = 0,
                .append_total_ns = 0,
                .query_count = 0,
                .query_total_ns = 0,
                .query_points_returned = 0,
                .flush_count = 0,
                .flush_total_ns = 0,
                .compaction_count = 0,
                .compaction_total_ns = 0,
                .wal_records_dropped = wal_drops,
                .segment_integrity_failures = integrity_failures,
            },
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
        integrity_counter: ?*u64,
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
                if (integrity_counter) |c| c.* += 1;
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
        dropped_counter: ?*u64,
    ) !void {
        switch (policy) {
            .fail_closed => {
                const ReplayCtx = struct {
                    allocator: Allocator,
                    mem: *memtable.Memtable,
                    dropped: ?*u64,

                    fn apply(self: @This(), rec: *const wal_record.WalRecord) anyerror!void {
                        try applyWalRecord(self.allocator, self.mem, rec, self.dropped);
                    }
                };
                var failure: ?wal_manager.ReplayFailure = null;
                wal.forEachFromStrict(
                    start_lsn,
                    allocator,
                    &failure,
                    ReplayCtx{ .allocator = allocator, .mem = mem, .dropped = dropped_counter },
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
                    try applyWalRecord(allocator, mem, r, dropped_counter);
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
    ///
    /// `dropped_counter` (optional) is incremented for every payload
    /// silently skipped, feeding the `wal_records_dropped` observability
    /// counter (P-OBS-001). Non-`append_points` records do NOT count
    /// as drops — they are deliberately ignored, not dropped.
    fn applyWalRecord(
        allocator: Allocator,
        mem: *memtable.Memtable,
        rec: *const wal_record.WalRecord,
        dropped_counter: ?*u64,
    ) !void {
        if (rec.record_type != .append_points) return;
        if (rec.payload.len < 16 or (rec.payload.len - 16) % 16 != 0) {
            if (dropped_counter) |c| c.* += 1;
            return;
        }

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
        self.append_payload_buf.deinit(self.allocator);
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

        // P-OBS-001: time the entire critical section. nowMonotonicNs
        // is ~30 ns on commodity hardware — negligible next to the
        // WAL fsync this call ultimately amortises into.
        const t_start = nowMonotonicNs();

        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        // P-MEM-003: reuse the engine-owned scratch buffer instead of
        // heap-allocating a fresh payload per call. The writer lock is
        // already held, so `append_payload_buf` has a single owner for
        // the duration of this call.
        const payload = try self.encodeAppendPointsPayloadLocked(series_id, points);

        _ = try self.appendToWalLocked(payload);
        try self.active_mem.insert(series_id, points);
        try self.maybeTriggerFlushLocked(io);

        // Counters are bumped only on a clean return; failed calls
        // do not pollute the latency average. We are still under the
        // engine lock here.
        self.counters.append_count += 1;
        self.counters.append_points += @intCast(points.len);
        self.counters.append_total_ns += nowMonotonicNs() - t_start;
    }

    /// Serialise `(series_id, points)` into the engine-owned payload
    /// buffer and return a slice over the live bytes. The slice is
    /// only valid until the next `encodeAppendPointsPayloadLocked` /
    /// `appendPoints` call; the WAL append must consume it before
    /// releasing the writer lock.
    ///
    /// Layout matches `wal_record.WalRecord`:
    /// `series_id (u128 LE) || (i64 ts, i64 value)*`.
    ///
    /// MUST be called with `self.mu` held — the buffer is shared
    /// state and is not otherwise synchronised.
    fn encodeAppendPointsPayloadLocked(
        self: *Engine,
        series_id: types.SeriesId,
        points: []const types.Point,
    ) ![]const u8 {
        const payload_size = 16 + (points.len * 16);

        // Grow once if needed; subsequent calls reuse the capacity.
        self.append_payload_buf.clearRetainingCapacity();
        try self.append_payload_buf.ensureTotalCapacity(self.allocator, payload_size);
        self.append_payload_buf.items.len = payload_size;
        const buf = self.append_payload_buf.items;

        std.mem.writeInt(u128, buf[0..16], series_id, .little);
        var pos: usize = 16;
        for (points) |pt| {
            std.mem.writeInt(i64, buf[pos..][0..8], pt.ts, .little);
            pos += 8;
            std.mem.writeInt(i64, buf[pos..][0..8], pt.value, .little);
            pos += 8;
        }
        return buf;
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
        var self = safety.castCtx(Engine, ctx);
        const t_start = nowMonotonicNs();
        self.flushInternal() catch |err| {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.mu.lockUncancelable(io);
            if (self.flushing_mem) |*fm| fm.deinit();
            self.flushing_mem = null;
            // A failed flush still counts as a completed scheduling
            // round so flush() callers are not stuck waiting forever
            // for a flush that errored out. Counter likewise bumps —
            // operators want to see failed flushes in the rate too.
            self.flushes_completed += 1;
            self.counters.flush_count += 1;
            self.counters.flush_total_ns += nowMonotonicNs() - t_start;
            self.recordBackgroundErrorLocked(.flush, err);
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
        };
    }

    /// Store `err` as the engine's most recent background-worker
    /// failure and dispatch it to `error_callback` (if configured).
    /// Caller MUST hold `self.mu`. The callback runs under the lock
    /// — callers MUST NOT re-enter the engine from the callback.
    ///
    /// Side effect: integrity-class errors (segment file missing,
    /// segment corrupted, block corrupted) bump
    /// `counters.segment_integrity_failures` so operators can spot a
    /// growing corruption rate without filtering on the error
    /// callback. Closes the metrics-counters slice of P-OBS-001.
    fn recordBackgroundErrorLocked(self: *Engine, phase: BgPhase, err: anyerror) void {
        self.last_background_error = err;
        switch (err) {
            error.SegmentFileMissing,
            error.SegmentCorrupted,
            error.BlockCorrupted,
            error.InvalidMagic,
            error.InvalidFile,
            => self.counters.segment_integrity_failures += 1,
            else => {},
        }
        if (self.config.error_callback) |cb| {
            // The callback ctx may legitimately be null when the
            // caller has no per-instance state to thread through;
            // use a stable non-null sentinel so the callback's
            // `*anyopaque` parameter is well-defined either way.
            const ctx_ptr = self.config.error_callback_ctx orelse @as(*anyopaque, @ptrCast(self));
            cb(ctx_ptr, phase, err);
        }
    }

    /// Atomic snapshot of the engine's observability counters
    /// (P-OBS-001). All sub-counters are read together under
    /// `self.mu`, so derived ratios (`*_total_ns / *_count`) are
    /// computed against the same window.
    ///
    /// Counter semantics are documented on `StatsSnapshot` itself.
    /// Returning a value type avoids any aliasing or post-snapshot
    /// mutation: callers can stash, diff, or transport the result
    /// without re-acquiring the lock.
    ///
    /// Threading: takes the engine's lock; safe to call concurrently
    /// with other engine methods. Overhead is negligible (a struct copy).
    pub fn stats(self: *Engine) StatsSnapshot {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.counters;
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

        // P-OBS-001: time the entire flush worker body so the average
        // includes encode + write + fsync + manifest commit.
        const t_start = nowMonotonicNs();

        self.mu.lockUncancelable(io);
        var mem = self.flushing_mem orelse return;
        self.mu.unlock(io);

        if (mem.point_count == 0) {
            self.mu.lockUncancelable(io);
            mem.deinit();
            self.flushing_mem = null;
            self.flushes_completed += 1;
            self.counters.flush_count += 1;
            self.counters.flush_total_ns += nowMonotonicNs() - t_start;
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
            return;
        }

        // Lazy-sort (P-ALGO-003): the memtable may contain per-series
        // entries whose `sorted` flag was flipped to false by an
        // out-of-order append. We sort once here, just before flush,
        // rather than paying the cost on every OoO insert under the
        // writer lock.
        mem.ensureAllSorted();

        var it = mem.series.iterator();
        while (it.next()) |entry| {
            const items = entry.value_ptr.points.items;
            if (items.len > 0) {
                const first_ts = items[0].ts;
                const last_ts = items[items.len - 1].ts;
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
            try writer.writeBlock(entry.key_ptr.*, entry.value_ptr.points.items);
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
            self.counters.flush_count += 1;
            self.counters.flush_total_ns += nowMonotonicNs() - t_start;
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

    /// Force compaction of every L0 segment, blocking until the
    /// resulting L1 segment is durable and the manifest references it.
    ///
    /// Differs from the automatic background trigger in two ways:
    ///
    ///   1. Ignores the `kL0CompactionThreshold` — a single L0 segment
    ///      is enough to trigger a merge into L1. This is intentional:
    ///      operators driving the CLI `compact` subcommand or a
    ///      maintenance script want a single deterministic action, not
    ///      a "maybe" depending on how many L0 files happen to exist.
    ///   2. Runs synchronously on the caller's thread. The thread pool
    ///      is not involved — there is no benefit to deferring work the
    ///      caller is already blocking on.
    ///
    /// Threading: takes the engine's lock for the manifest snapshot
    /// and the swap; the actual segment write happens unlocked.
    /// Concurrent `appendPoints` calls will block briefly while the
    /// final swap commits, but otherwise proceed normally.
    pub fn compactAll(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Wait for any in-flight background compaction to drain. We do
        // not want two compactions racing over the same L0 segments.
        self.mu.lockUncancelable(io);
        while (self.compaction_running) {
            self.done_cv.waitUncancelable(io, &self.mu);
        }
        self.compaction_running = true;
        self.mu.unlock(io);

        // P-OBS-001: time the forced compaction body. Same accounting
        // policy as the background worker — counter bumps regardless
        // of success / failure.
        const t_start = nowMonotonicNs();

        defer {
            self.mu.lockUncancelable(io);
            self.counters.compaction_count += 1;
            self.counters.compaction_total_ns += nowMonotonicNs() - t_start;
            self.compaction_running = false;
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
        }

        try self.compactL0Forced();
    }

    /// Inner body of `compactAll`. Lifted from `compactL0` with the
    /// threshold gate removed so the synchronous path can fold even a
    /// single L0 segment into L1.
    fn compactL0Forced(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        var l0_segs = std.ArrayList(manifest.SegmentMeta).empty;
        defer l0_segs.deinit(self.allocator);
        var new_seg_id: u64 = 0;

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            for (self.man.segments.items) |seg| {
                if (seg.level == 0) {
                    try l0_segs.append(self.allocator, seg);
                }
            }
            if (l0_segs.items.len == 0) return;
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

        for (paths.items) |p| {
            std.Io.Dir.cwd().deleteFile(io, p) catch |err| {
                self.mu.lockUncancelable(io);
                self.recordBackgroundErrorLocked(.compaction, err);
                self.mu.unlock(io);
            };
        }
    }

    fn compactionWorker(ctx: *anyopaque, _: *thread_pool.TaskContext) void {
        var self = safety.castCtx(Engine, ctx);
        const t_start = nowMonotonicNs();
        const result = self.compactL0();
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mu.lockUncancelable(io);
        if (result) |_| {} else |err| {
            self.recordBackgroundErrorLocked(.compaction, err);
        }
        // Always count completed compactions — success or failure —
        // so the rate reflects work attempted, not just successful work.
        self.counters.compaction_count += 1;
        self.counters.compaction_total_ns += nowMonotonicNs() - t_start;
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

    /// Remove every segment whose `max_ts` is older than
    /// `now - config.retention_max_age_ms`. Returns the number of
    /// segments removed.
    ///
    /// Semantics:
    ///
    /// - Whole-segment only. A segment is removed iff its ENTIRE
    ///   timestamp range is older than the cutoff. Segments
    ///   straddling the cutoff (some points older, some newer) are
    ///   left in place; rewriting them would require a per-block
    ///   compaction pass that is out of scope for this entry point.
    ///   Operators who need that can invoke `compactAll` first; a
    ///   future commit may add a `pruneAndRewrite` helper.
    /// - Idempotent. Calling twice in quick succession (no new data
    ///   written) is safe; the second call removes nothing.
    /// - Atomic at the manifest level. The new segment list is saved
    ///   to the manifest BEFORE the segment files are unlinked, so a
    ///   crash mid-prune leaves orphan files on disk but never a
    ///   stale pointer in the manifest. The next prune (or operator
    ///   cleanup) reclaims the orphans.
    /// - No-op when `config.retention_max_age_ms == null`.
    ///
    /// Threading: takes the engine's lock for the manifest swap.
    /// Concurrent appends, queries, and compactions are blocked
    /// only briefly during the swap; the actual unlink loop runs
    /// without the lock to avoid stalling other ops on slow disks.
    pub fn pruneExpired(self: *Engine) !u32 {
        const max_age = self.config.retention_max_age_ms orelse return 0;
        const io = std.Io.Threaded.global_single_threaded.io();

        const now = self.config.retention_now_override orelse blk: {
            const ts_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
            break :blk @divTrunc(ts_ns, std.time.ns_per_ms);
        };
        const cutoff = now - max_age;

        var doomed_ids = std.ArrayList(u64).empty;
        defer doomed_ids.deinit(self.allocator);

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            var kept = std.ArrayListUnmanaged(manifest.SegmentMeta).empty;
            try kept.ensureTotalCapacity(self.allocator, self.man.segments.items.len);

            for (self.man.segments.items) |seg| {
                if (seg.max_ts < cutoff) {
                    try doomed_ids.append(self.allocator, seg.id);
                } else {
                    kept.appendAssumeCapacity(seg);
                }
            }

            if (doomed_ids.items.len == 0) {
                kept.deinit(self.allocator);
                return 0;
            }

            // Save the new manifest BEFORE we touch the files on
            // disk: the manifest is the source of truth for which
            // segments exist, so an orphan file is recoverable but
            // a stale manifest entry would corrupt queries.
            self.man.segments.deinit(self.allocator);
            self.man.segments = kept;
            try self.man.save();
        }

        // Best-effort unlink of the doomed files. A failure here
        // leaves an orphan on disk but the manifest is already
        // correct; surface the error via the background-error
        // pipeline so operators can reclaim space later.
        for (doomed_ids.items) |id| {
            const p = try segment.segmentPath(self.allocator, self.config.data_dir, id);
            defer self.allocator.free(p);
            std.Io.Dir.cwd().deleteFile(io, p) catch |err| {
                self.mu.lockUncancelable(io);
                self.recordBackgroundErrorLocked(.compaction, err);
                self.mu.unlock(io);
            };
        }

        return @intCast(doomed_ids.items.len);
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

        // P-OBS-001: latency timer. Covers iterator setup +
        // memtable scan + every segment open/decode. Iteration
        // performed by the caller after we return is NOT included.
        const t_start = nowMonotonicNs();
        var points_added: u64 = 0;

        const merge_it = try arena.create(iterator.MergeIterator);
        merge_it.* = iterator.MergeIterator.init(arena);

        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        try queryMemtable(arena, &self.active_mem, series_id, start_ts, end_ts, merge_it, &points_added);
        if (self.flushing_mem) |*mem| {
            try queryMemtable(arena, mem, series_id, start_ts, end_ts, merge_it, &points_added);
        }
        for (self.man.segments.items) |seg| {
            if (seg.min_ts > end_ts or seg.max_ts < start_ts) continue;
            try self.querySegment(arena, seg, series_id, start_ts, end_ts, merge_it, &points_added);
        }

        self.counters.query_count += 1;
        self.counters.query_points_returned += points_added;
        self.counters.query_total_ns += nowMonotonicNs() - t_start;
        return merge_it;
    }

    /// Drain points for `series_id` in `[start_ts, end_ts]` from a
    /// memtable into `merge_it`. Allocates the filtered slice on the
    /// supplied arena.
    ///
    /// Mutable receiver: `getSortedPoints` lazy-sorts the per-series
    /// list on demand (see P-ALGO-003). The engine's writer lock is
    /// held by `queryPoints` for the duration of this call, so the
    /// mutation is race-free.
    fn queryMemtable(
        arena: Allocator,
        mem: *memtable.Memtable,
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        merge_it: *iterator.MergeIterator,
        points_added: *u64,
    ) !void {
        const pts = mem.getSortedPoints(series_id);
        if (pts.len == 0) return;
        var filtered_pts = std.ArrayListUnmanaged(types.Point).empty;
        for (pts) |pt| {
            if (pt.ts >= start_ts and pt.ts <= end_ts) {
                try filtered_pts.append(arena, pt);
            }
        }
        if (filtered_pts.items.len == 0) return;

        points_added.* += filtered_pts.items.len;
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
        points_added: *u64,
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

            points_added.* += filtered_pts.items.len;
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

test "Engine: appendPoints reuses payload buffer across calls (P-MEM-003)" {
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

    // Before any append, the engine-owned scratch buffer is empty.
    try std.testing.expectEqual(@as(usize, 0), engine.append_payload_buf.capacity);

    // First append: buffer grows to fit (16 + 16*4 = 80 bytes).
    try engine.appendPoints(1, &.{
        .{ .ts = 1, .value = 10 },
        .{ .ts = 2, .value = 20 },
        .{ .ts = 3, .value = 30 },
        .{ .ts = 4, .value = 40 },
    });
    const cap_after_first = engine.append_payload_buf.capacity;
    try std.testing.expect(cap_after_first >= 80);

    // Second SMALLER append: capacity must not shrink (the reuse
    // contract). clearRetainingCapacity preserves the allocation.
    try engine.appendPoints(2, &.{.{ .ts = 5, .value = 50 }});
    try std.testing.expectEqual(cap_after_first, engine.append_payload_buf.capacity);

    // Third LARGER append: capacity grows.
    var bigger: [16]types.Point = undefined;
    for (&bigger, 0..) |*p, i| p.* = .{ .ts = @intCast(100 + i), .value = @intCast(i) };
    try engine.appendPoints(3, &bigger);
    try std.testing.expect(engine.append_payload_buf.capacity >= 16 + 16 * bigger.len);

    // Verify the points round-trip cleanly via query — the buffer
    // reuse must not have corrupted the WAL record contents.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    var merge_it = try engine.queryPoints(arena_alloc, 1, 0, 1000);
    var count: usize = 0;
    while (merge_it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 4), count);
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

test "Engine: compactAll folds L0 segments into a single L1 segment" {
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
        .max_memtable_points = 2,
    }, &pool);
    defer engine.deinit();

    // Drive enough appends to produce two L0 segments via the
    // auto-flush threshold (memtable holds at most 2 points).
    try engine.appendPoints(1, &.{ .{ .ts = 1, .value = 1 }, .{ .ts = 2, .value = 2 } });
    try engine.flush();
    try engine.appendPoints(1, &.{ .{ .ts = 3, .value = 3 }, .{ .ts = 4, .value = 4 } });
    try engine.flush();

    try std.testing.expect(engine.man.segments.items.len >= 2);

    // Forced compaction should consolidate them regardless of the
    // background threshold.
    try engine.compactAll();

    var l0_count: usize = 0;
    var l1_count: usize = 0;
    for (engine.man.segments.items) |seg| {
        if (seg.level == 0) l0_count += 1;
        if (seg.level == 1) l1_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), l0_count);
    try std.testing.expectEqual(@as(usize, 1), l1_count);

    // Data should still be queryable after compaction.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try engine.queryPoints(arena.allocator(), 1, 0, 100);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "Engine: compactAll is a no-op when there are no L0 segments" {
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

    try engine.compactAll();
    try std.testing.expectEqual(@as(usize, 0), engine.man.segments.items.len);
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

test "Engine: WAL encryption key round-trips append/recover/query" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key: [32]u8 = [_]u8{0x42} ** 32;

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: open with key, append, close WITHOUT flush — the
    // data lives only in the (encrypted) WAL.
    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .encryption_key = key,
        }, &pool);
        defer eng.deinit();

        const pts = [_]types.Point{
            .{ .ts = 1, .value = 11 },
            .{ .ts = 2, .value = 22 },
            .{ .ts = 3, .value = 33 },
        };
        try eng.appendPoints(7, &pts);
        try eng.sync();
    }

    // Phase 2: reopen with the SAME key, WAL replay should succeed
    // and the points come back via the active memtable.
    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .encryption_key = key,
        }, &pool);
        defer eng.deinit();

        try std.testing.expectEqual(@as(usize, 3), eng.active_mem.point_count);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 7, 0, 100);
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 3), count);
    }
}

test "Engine: reopening with a different key drops encrypted WAL records" {
    // The underlying wal library swallows decryption failures and
    // treats them as EOF (iterator.zig:122-130 — wrong key looks
    // identical to "no more records" on the read path). That gives
    // us two observable guarantees rather than one:
    //
    //   1. With the SAME key the records come back.
    //   2. With a DIFFERENT key the records are silently dropped —
    //      they are NOT decrypted as plaintext. So this test
    //      simultaneously proves the WAL was encrypted (otherwise
    //      the wrong-key replay would still return the points) and
    //      that the engine does not crash or hand back garbage.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key_a: [32]u8 = [_]u8{0xAA} ** 32;
    const key_b: [32]u8 = [_]u8{0xBB} ** 32;

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: write under key_a, sync, close (no flush — data is
    // WAL-only).
    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .encryption_key = key_a,
        }, &pool);
        defer eng.deinit();
        try eng.appendPoints(1, &.{.{ .ts = 1, .value = 11 }});
        try eng.sync();
    }

    // Phase 2: reopen with key_b — engine opens fine but the
    // memtable must be empty because every encrypted record failed
    // its AES-GCM tag check.
    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .encryption_key = key_b,
        }, &pool);
        defer eng.deinit();

        try std.testing.expectEqual(@as(usize, 0), eng.active_mem.point_count);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 1, 0, 100);
        try std.testing.expect(it.next() == null);
    }
}

test "Engine: reopening an encrypted WAL with no key drops records" {
    // Same shape as the wrong-key case: when the WAL is encrypted
    // and the engine is opened without a key, the iterator's
    // encrypted-record path is disabled and the magic-byte check
    // rejects the record (iterator.zig:145-149), again returning
    // EOF rather than data. Proves an attacker who learns
    // data_dir without the key cannot replay the WAL.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key_a: [32]u8 = [_]u8{0x77} ** 32;
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .encryption_key = key_a,
        }, &pool);
        defer eng.deinit();
        try eng.appendPoints(1, &.{.{ .ts = 1, .value = 1 }});
        try eng.sync();
    }

    // Reopen without a key.
    var eng = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = null,
    }, &pool);
    defer eng.deinit();

    try std.testing.expectEqual(@as(usize, 0), eng.active_mem.point_count);
}

test "Engine: pruneExpired returns 0 when retention disabled" {
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
        .max_memtable_points = 10,
    }, &pool);
    defer engine.deinit();

    const pts = [_]types.Point{.{ .ts = 1, .value = 1 }};
    try engine.appendPoints(1, &pts);
    try engine.flush();

    // No retention configured: pruneExpired must be a no-op.
    try std.testing.expectEqual(@as(u32, 0), try engine.pruneExpired());
    try std.testing.expect(engine.man.segments.items.len >= 1);
}

test "Engine: pruneExpired removes segments older than the cutoff" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Use the deterministic "now" override so the test is hermetic.
    // Retention: 1000 ms. Now = 10000. Anything with max_ts < 9000 is doomed.
    var engine = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 10,
        .retention_max_age_ms = 1000,
        .retention_now_override = 10_000,
    }, &pool);
    defer engine.deinit();

    // Produce two segments: one all-old, one all-new.
    try engine.appendPoints(1, &.{ .{ .ts = 100, .value = 1 }, .{ .ts = 200, .value = 2 } });
    try engine.flush();
    try engine.appendPoints(1, &.{ .{ .ts = 9_500, .value = 3 }, .{ .ts = 9_700, .value = 4 } });
    try engine.flush();

    try std.testing.expectEqual(@as(usize, 2), engine.man.segments.items.len);

    const removed = try engine.pruneExpired();
    try std.testing.expectEqual(@as(u32, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), engine.man.segments.items.len);

    // The surviving segment must be the one whose points are inside
    // the retention window.
    try std.testing.expect(engine.man.segments.items[0].max_ts >= 9_000);

    // Query: only the recent points must come back.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try engine.queryPoints(arena.allocator(), 1, 0, std.math.maxInt(i64));
    var count: usize = 0;
    while (it.next()) |pt| {
        try std.testing.expect(pt.ts >= 9_000);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Engine: stats counters increment on append, query, flush, compaction (P-OBS-001)" {
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
        .max_memtable_points = 2,
    }, &pool);
    defer engine.deinit();

    // Baseline: every counter starts at zero on a fresh engine.
    {
        const s = engine.stats();
        try std.testing.expectEqual(@as(u64, 0), s.append_count);
        try std.testing.expectEqual(@as(u64, 0), s.append_points);
        try std.testing.expectEqual(@as(u64, 0), s.append_total_ns);
        try std.testing.expectEqual(@as(u64, 0), s.query_count);
        try std.testing.expectEqual(@as(u64, 0), s.query_points_returned);
        try std.testing.expectEqual(@as(u64, 0), s.query_total_ns);
        try std.testing.expectEqual(@as(u64, 0), s.flush_count);
        try std.testing.expectEqual(@as(u64, 0), s.flush_total_ns);
        try std.testing.expectEqual(@as(u64, 0), s.compaction_count);
        try std.testing.expectEqual(@as(u64, 0), s.compaction_total_ns);
        try std.testing.expectEqual(@as(u64, 0), s.wal_records_dropped);
        try std.testing.expectEqual(@as(u64, 0), s.segment_integrity_failures);
    }

    // Two append batches (3 + 2 = 5 points). max_memtable_points = 2,
    // so the first batch alone trips the flush threshold.
    try engine.appendPoints(1, &.{
        .{ .ts = 1, .value = 1 },
        .{ .ts = 2, .value = 2 },
        .{ .ts = 3, .value = 3 },
    });
    try engine.appendPoints(1, &.{ .{ .ts = 4, .value = 4 }, .{ .ts = 5, .value = 5 } });
    try engine.flush();

    {
        const s = engine.stats();
        try std.testing.expectEqual(@as(u64, 2), s.append_count);
        try std.testing.expectEqual(@as(u64, 5), s.append_points);
        try std.testing.expect(s.append_total_ns > 0);
        try std.testing.expect(s.flush_count >= 1);
        try std.testing.expect(s.flush_total_ns > 0);
    }

    // Query: expect both count and points_returned to bump.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try engine.queryPoints(arena.allocator(), 1, 0, 100);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        try std.testing.expect(n >= 1);

        const s = engine.stats();
        try std.testing.expectEqual(@as(u64, 1), s.query_count);
        try std.testing.expect(s.query_points_returned >= @as(u64, n));
        try std.testing.expect(s.query_total_ns > 0);
    }

    // Force a compaction: drive enough flushes to surface an L0 fold,
    // then call compactAll.
    try engine.appendPoints(2, &.{ .{ .ts = 10, .value = 10 }, .{ .ts = 11, .value = 11 } });
    try engine.flush();
    try engine.compactAll();
    {
        const s = engine.stats();
        try std.testing.expect(s.compaction_count >= 1);
        try std.testing.expect(s.compaction_total_ns > 0);
    }
}

test "Engine: stats() returns a value snapshot (no aliasing) (P-OBS-001)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var engine = try Engine.init(allocator, .{ .data_dir = data_dir }, &pool);
    defer engine.deinit();

    const snap_before = engine.stats();
    try engine.appendPoints(1, &.{.{ .ts = 1, .value = 1 }});
    const snap_after = engine.stats();

    // Snapshot semantics: snap_before was captured BEFORE the
    // append and must remain at zero counts even after the call.
    try std.testing.expectEqual(@as(u64, 0), snap_before.append_count);
    try std.testing.expectEqual(@as(u64, 1), snap_after.append_count);
    try std.testing.expectEqual(@as(u64, 1), snap_after.append_points);
}

test "Engine: pruneExpired keeps straddling segments untouched" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Cutoff = 10_000 - 1_000 = 9_000.
    var engine = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 10,
        .retention_max_age_ms = 1000,
        .retention_now_override = 10_000,
    }, &pool);
    defer engine.deinit();

    // Single segment with both old (ts=100) and new (ts=9_500) points.
    try engine.appendPoints(1, &.{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 9_500, .value = 2 },
    });
    try engine.flush();

    try std.testing.expectEqual(@as(usize, 1), engine.man.segments.items.len);

    // max_ts (9_500) > cutoff (9_000), so the segment is kept.
    const removed = try engine.pruneExpired();
    try std.testing.expectEqual(@as(u32, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), engine.man.segments.items.len);
}
