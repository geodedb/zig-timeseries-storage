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

/// Number of level-1 segments that triggers an L1->L2 compaction job
/// (P-COMP-002). Picked larger than `kL0CompactionThreshold` so the
/// (more expensive) L1 merge runs less often than the L0 merge but
/// still bounds the L1 segment count to a constant — without this
/// trigger, L1 segments accumulate linearly with engine lifetime and
/// every query pays a linearly-growing segment-scan cost (compounds
/// with the per-series-index gap closed by P-ALGO-001).
const kL1CompactionThreshold: usize = 8;

/// Compute the per-series ArrayList capacity hint for a fresh
/// memtable, given the engine's `max_memtable_points` budget and the
/// expected number of distinct series. The hint floors at 64 so
/// wide-cardinality workloads (`expected_series` >> max_memtable_points)
/// don't end up with degenerate single-digit per-series buffers that
/// must double on every batch.
///
/// ENT-002 / ENT-005. Returns 0 when `expected_series == 0` so the
/// memtable falls back to the historical lazy-grow path.
fn computePointsPerSeriesHint(max_memtable_points: usize, expected_series: usize) usize {
    if (expected_series == 0) return 0;
    return @max(64, max_memtable_points / expected_series);
}

/// Default capacity of the per-engine SegmentReader LRU cache.
/// Each cache slot holds an open file descriptor + a small bookkeeping
/// struct (~48 bytes). 64 entries is a comfortable default — large
/// enough to keep the hot working set warm across queries, small enough
/// to stay well under default per-process FD limits even when several
/// engines share a process. Closes the LRU dimension of P-MEM-006.
pub const DEFAULT_SEGMENT_READER_CACHE_CAPACITY: usize = 64;

/// Bounded LRU cache of open `SegmentReader` handles, indexed by
/// segment id (P-IO-001 / P-MEM-006). Avoids reopening the same
/// segment file across successive queries.
///
/// Concurrency: every public method takes the internal mutex. Entries
/// carry a refcount; eviction only removes entries whose refcount is
/// zero, so a reader is never closed out from under an in-flight
/// query. The cache is invalidated on compaction (`invalidate(id)`).
const SegmentReaderCache = struct {
    const Entry = struct {
        reader: segment.SegmentReader,
        id: u64,
        /// Number of outstanding `acquire` callers. Eviction is gated
        /// on refcount == 0 — a reader currently being read by a query
        /// cannot be evicted.
        refcount: u32,
        /// LRU position counter; higher = more recently used. Filled in
        /// from `tick` on every acquire so eviction can pick the
        /// numerically smallest one.
        last_used: u64,
    };

    allocator: Allocator,
    mu: std.Io.Mutex = std.Io.Mutex.init,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .{},
    capacity: usize,
    tick: u64 = 0,

    fn init(allocator: Allocator, capacity: usize) SegmentReaderCache {
        return .{ .allocator = allocator, .capacity = capacity };
    }

    fn deinit(self: *SegmentReaderCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.reader.deinit();
        }
        self.entries.deinit(self.allocator);
    }

    /// Borrow a reader for segment `id`. If absent, opens the file at
    /// `path` and inserts it; if full, evicts the LRU entry whose
    /// refcount is zero. Returns a pointer to the borrowed reader.
    /// Caller MUST balance with `release(id)` exactly once.
    ///
    /// `encryption` (optional) is passed through to
    /// `SegmentReader.initWithEncryption` on a cache miss. Cache
    /// hits return whichever reader was previously inserted —
    /// callers MUST NOT mix encrypted and plaintext access patterns
    /// for the same segment id.
    fn acquire(
        self: *SegmentReaderCache,
        io: std.Io,
        id: u64,
        path: []const u8,
        encryption: ?segment.EncryptionContext,
    ) !*segment.SegmentReader {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        if (self.entries.getPtr(id)) |entry| {
            self.tick += 1;
            entry.last_used = self.tick;
            entry.refcount += 1;
            return &entry.reader;
        }

        // Miss: must open. Evict-then-insert order matters — we evict
        // FIRST so the new entry has somewhere to live without growing
        // the map past capacity. evictLruLocked is a no-op when the
        // map is below capacity.
        try self.evictLruLocked();

        const reader = try segment.SegmentReader.initWithEncryption(self.allocator, path, encryption);
        errdefer {
            var r = reader;
            r.deinit();
        }

        self.tick += 1;
        try self.entries.put(self.allocator, id, .{
            .reader = reader,
            .id = id,
            .refcount = 1,
            .last_used = self.tick,
        });
        return &self.entries.getPtr(id).?.reader;
    }

    /// Release a previously-acquired reader. Decrements the entry's
    /// refcount; the reader remains open in the cache for reuse.
    fn release(self: *SegmentReaderCache, io: std.Io, id: u64) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.entries.getPtr(id)) |entry| {
            if (entry.refcount > 0) entry.refcount -= 1;
        }
    }

    /// Remove the cached reader for `id` (if any) and close its file.
    /// MUST only be called when no query is using the entry. Compaction
    /// calls this AFTER the manifest has been updated to drop the old
    /// segment — at that point any in-flight query that previously
    /// snapshotted the old manifest may still be holding a refcount,
    /// so we honour it by skipping the close (the reader stays live
    /// until the last release; the slot is reclaimable thereafter via
    /// the LRU path).
    fn invalidate(self: *SegmentReaderCache, io: std.Io, id: u64) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.entries.fetchRemove(id)) |kv| {
            // If a query is still holding a borrow, we can't close
            // the file safely — re-insert. The next eviction round
            // will catch it once the refcount drops to zero.
            if (kv.value.refcount > 0) {
                self.entries.put(self.allocator, id, kv.value) catch {
                    // OOM during reinsert: leak the reader rather than
                    // close it underneath an in-flight query. This is
                    // a one-FD leak in a pathological case.
                };
                return;
            }
            var r = kv.value.reader;
            r.deinit();
        }
    }

    /// Evict the LRU entry (smallest `last_used`) whose refcount is
    /// zero, if the cache is at or above capacity. Holds the mutex.
    /// No-op if no eviction is needed or no eligible entry exists.
    fn evictLruLocked(self: *SegmentReaderCache) !void {
        if (self.entries.count() < self.capacity) return;

        var victim_id: ?u64 = null;
        var victim_ts: u64 = std.math.maxInt(u64);
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.refcount != 0) continue;
            if (kv.value_ptr.last_used < victim_ts) {
                victim_ts = kv.value_ptr.last_used;
                victim_id = kv.key_ptr.*;
            }
        }

        if (victim_id) |id| {
            if (self.entries.fetchRemove(id)) |kv| {
                var r = kv.value.reader;
                r.deinit();
            }
        }
        // No-op if every entry is borrowed: we let the cache exceed
        // its bound temporarily rather than block. The next query
        // returning a borrow will allow eviction on the next miss.
    }
};

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
    /// An encrypted (TSSEG003) segment was opened with the wrong key,
    /// no key, or its AES-GCM tag check failed. Closes GAP-0001.
    DecryptionFailed,
    /// A plaintext (TSSEG002) segment was opened when the engine
    /// was configured with an encryption key. Indicates a missing
    /// migration step or a mixed-mode data directory.
    UnexpectedPlaintextSegment,
    /// `EngineConfig.access_controller` refused an operation.
    /// Surfaced by `appendPoints` and `queryPoints` when the
    /// pluggable seam returns this error from `check`. Adapters
    /// MAY return any error from `check`; the engine treats them
    /// all identically (propagate unchanged) — `AccessDenied` is
    /// the convention used by the reference
    /// `DenyAllAccessController` and by callers wiring a custom
    /// authoriser. Closes GAP-0002 / SEC-007.
    AccessDenied,
    /// `appendPoints` received a point whose timestamp falls
    /// before the engine's running per-series watermark while
    /// `EngineConfig.allow_cross_segment_ooo == false`. Closes
    /// GAP-0010. Permissive mode (the default) never returns this
    /// error; OoO points land in the active memtable and are
    /// reconciled at compaction time.
    OutOfOrderTimestamp,
};

/// WAL durability mode (P-IO-002).
///
/// Trade-off:
///
/// * `batch` (default): `appendPoints` does NOT call `wal.sync()`.
///   The engine spawns a background syncer thread that fsyncs the
///   WAL every `wal_sync_interval_ms` milliseconds. Maximises
///   throughput at the cost of up to `wal_sync_interval_ms` of
///   data loss on a crash between syncs. Matches the historical
///   pre-F-6 behaviour.
/// * `per_call`: `appendPoints` calls `wal.sync()` before returning.
///   Lower throughput (one fsync per call), but a successful return
///   means the record is durable on disk — no data loss on crash.
///
/// Callers who want write-ahead durability without per-call cost
/// should keep the default `batch` mode and shorten
/// `wal_sync_interval_ms`. Callers who treat every appendPoints
/// return as a durability fence (replication ack, two-phase commit,
/// etc.) should use `per_call`.
pub const DurabilityMode = enum { batch, per_call };

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

/// Operations the access controller can authorise. Discriminator is
/// kept narrow on purpose: the engine has exactly two
/// caller-visible per-series operations (read and write), and adding
/// more would require corresponding callbacks in every adapter that
/// implements `AccessController.check`. Future fan-out (e.g. a
/// distinct `admin` op for retention/compaction) can extend this
/// enum without breaking the binary contract.
pub const AccessOp = enum {
    /// `appendPoints` — writer-side. Triggered before any WAL or
    /// memtable mutation, so a denied check leaves the engine state
    /// untouched.
    append,
    /// `queryPoints` — reader-side. Triggered before any segment
    /// reader is acquired or memtable scanned.
    query,
};

/// Pluggable per-call authorisation seam (GAP-0002 / SEC-007).
///
/// The engine itself has no concept of tenants, users, or scopes —
/// those live in the calling adapter (Geode, an HTTP layer, etc.).
/// `AccessController` is the seam that lets that adapter veto an
/// individual `appendPoints` or `queryPoints` call BEFORE the engine
/// mutates any state.
///
/// Threading: `check` is called WITHOUT the engine's internal mutex
/// held. Implementations are free to take their own locks, do I/O,
/// or call into a remote ACL service — anything except call back
/// into the originating `Engine` (which would deadlock).
///
/// Failure: returning any error (the convention is
/// `error.AccessDenied` for a clean reject) propagates out of
/// `appendPoints` / `queryPoints` unchanged. The engine surfaces
/// no error of its own at this layer.
///
/// Two reference adapters live alongside this declaration:
///   * `PermissiveAccessController` — always allows. Wire this when
///     wiring up the seam in a single-tenant deployment where
///     authorisation already happens in a higher layer.
///   * `DenyAllAccessController` — always denies. Useful in tests
///     and in fail-closed defaults.
pub const AccessController = struct {
    /// Opaque caller context passed back to `check`. May be null.
    ctx: ?*anyopaque = null,
    /// Authorisation entry point. Implementations should return
    /// `error.AccessDenied` (or any other error) to refuse the
    /// operation; returning `void` accepts it. The engine does NOT
    /// retry on transient failures — adapters that need retry
    /// semantics must layer them above this seam.
    check: *const fn (
        ctx: ?*anyopaque,
        op: AccessOp,
        series_id: types.SeriesId,
    ) anyerror!void,
};

/// Reference `AccessController` implementation that allows every
/// call. Equivalent to leaving `EngineConfig.access_controller`
/// null, but exposed as a value so it can be passed to APIs that
/// want a concrete non-null seam.
pub const PermissiveAccessController = AccessController{
    .ctx = null,
    .check = struct {
        fn check(_: ?*anyopaque, _: AccessOp, _: types.SeriesId) anyerror!void {
            return;
        }
    }.check,
};

/// Reference `AccessController` that denies every call with
/// `error.AccessDenied`. Used in tests and as a fail-closed
/// default when wiring custody adapters that have not yet
/// supplied a real implementation.
pub const DenyAllAccessController = AccessController{
    .ctx = null,
    .check = struct {
        fn check(_: ?*anyopaque, _: AccessOp, _: types.SeriesId) anyerror!void {
            return error.AccessDenied;
        }
    }.check,
};

/// Derive an unguessable `SeriesId` from a `(tenant, app_key, key)`
/// triple via HMAC-SHA256 (GAP-0002 / SEC-008).
///
/// Background: the engine stores `SeriesId` as a raw `u128`. When
/// callers derive the ID deterministically from `(tenant_id, metric)`
/// — a common pattern — an attacker who learns the derivation can
/// enumerate every series in the namespace. The opaque-ID design
/// pattern routes the deterministic input through a keyed PRF so
/// the on-disk ID is uncorrelated with its plaintext inputs.
///
/// Construction:
///   HMAC-SHA256(key, tenant_le || app_key_le)[0..16] → u128
///
/// Properties:
///   * Same `(tenant, app_key, key)` always produces the same ID
///     (deterministic — required so the writer and the reader can
///     find each other's series).
///   * Without the key, the relationship between `(tenant, app_key)`
///     and the resulting `SeriesId` is computationally hidden
///     (HMAC PRF security).
///   * Truncation to 128 bits is acceptable: HMAC-SHA256 is a PRF,
///     and the 128-bit truncation leaves a comfortable margin
///     against birthday collisions at realistic series counts
///     (2^64 / day is far above any conceivable workload).
///
/// Callers (e.g. Geode) own the per-tenant key. The engine never
/// sees or stores it. This function is a pure helper — no engine
/// state is consulted.
///
/// Security: rotate the `key` to invalidate previously-derived
/// IDs (effectively a per-tenant kill switch). The `tenant_id` and
/// `app_key` portions are caller-chosen and treated as opaque
/// 64-bit values; collision-resistance is delivered by the PRF, not
/// by their internal structure.
pub fn opaqueSeriesId(tenant: u64, app_key: u64, key: [32]u8) types.SeriesId {
    var input: [16]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], tenant, .little);
    std.mem.writeInt(u64, input[8..16], app_key, .little);

    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, &input, &key);

    // Take the first 16 bytes (128 bits) of the HMAC output as the
    // little-endian encoding of the u128 SeriesId. Endianness here
    // is a presentation detail — the engine treats SeriesId as an
    // opaque integer.
    return std.mem.readInt(u128, mac[0..16], .little);
}

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
    /// Optional AES-256-GCM encryption key (32 bytes) used for
    /// transparent data encryption (TDE) of every on-disk artefact:
    /// WAL records, segment blocks (TSSEG003), and the manifest
    /// (TSMNF002). When `null` (the default), every layer stays
    /// plaintext.
    ///
    /// Closes GAP-0001 / SEC-006 in full: the WAL, segment, and
    /// manifest paths all derive their per-record nonces and AAD
    /// domain-separation tags from this single operator-supplied key.
    /// AAD design (segments: `"seg" || segment_id || block_index`,
    /// manifest: `"mnf" || counter`) prevents cross-context
    /// ciphertext reuse: a stolen segment block cannot be replayed as
    /// a manifest block, and vice versa, even though they share the
    /// same 32-byte master key.
    ///
    /// Security: callers MUST keep the key consistent across opens.
    /// Reopening the same `data_dir` with a different key (or no
    /// key, when the artefacts were written with one) fails closed:
    /// WAL replay drops records, the manifest returns
    /// `error.DecryptionFailed`, and segment reads return the same.
    ///
    /// Operators rotating keys must drive a full read-and-re-encrypt
    /// migration (out of scope for the engine itself).
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

    /// WAL durability mode. See `DurabilityMode` for the trade-off
    /// matrix. Default is `.batch` (high throughput, periodic
    /// background syncer). Closes P-IO-002.
    durability_mode: DurabilityMode = .batch,

    /// Interval, in milliseconds, between background WAL fsyncs in
    /// `.batch` mode. Ignored in `.per_call` mode. Lower values
    /// reduce the worst-case data-loss window at the cost of more
    /// fsync syscalls per second. Defaults to 100 ms — fast enough
    /// to bound data loss to "barely noticeable", slow enough to
    /// amortise the fsync cost across thousands of appends on
    /// typical workloads.
    wal_sync_interval_ms: u32 = 100,

    /// Cross-segment out-of-order write policy (GAP-0010).
    ///
    /// When `true` (the default), `appendPoints` accepts a point
    /// whose timestamp falls earlier than the `max_ts` of an
    /// existing sealed segment for the same series. The new point
    /// lands in the active memtable and, on the next flush, produces
    /// an overlapping segment that compaction's overlap-aware merge
    /// folds back into time order — same-timestamp collisions
    /// resolve under last-write-wins (newer LSN wins).
    ///
    /// When `false`, `appendPoints` returns
    /// `error.OutOfOrderTimestamp` if any input point's `ts` is
    /// less than the engine's running per-series watermark. Use
    /// this when the upstream system guarantees monotonic time and
    /// any out-of-order arrival is a bug.
    ///
    /// Storage cost: in permissive mode, occasional OoO writes are
    /// O(1) on the write path but trigger an extra merge during
    /// the next compaction. In strict mode the engine never
    /// produces overlapping segments and compaction stays a clean
    /// L0->L1 fan-in. Closes GAP-0010.
    allow_cross_segment_ooo: bool = true,

    /// Optional pluggable authorisation seam (GAP-0002 / SEC-007).
    /// When set, `Engine.appendPoints` and `Engine.queryPoints`
    /// route every call through `access_controller.check(...)`
    /// before mutating any state. When `null` (the default), all
    /// operations are allowed — preserves backward compatibility
    /// with callers that already enforce authorisation in a layer
    /// above the engine.
    ///
    /// Rationale: tenant catalogs, ACL stores, and identity
    /// providers belong outside the storage engine. This seam is
    /// the minimum boundary the engine needs to expose so an
    /// adapter (Geode, an HTTP layer, etc.) can veto a hostile
    /// `appendPoints` or `queryPoints` call BEFORE any WAL or
    /// memtable mutation lands. The engine itself never enforces
    /// tenancy; it only honours the adapter's decision.
    ///
    /// Threading: `check` runs WITHOUT the engine lock held.
    /// Implementations must NOT call back into the originating
    /// `Engine` from `check` (that would deadlock).
    ///
    /// See `PermissiveAccessController` and `DenyAllAccessController`
    /// for reference implementations.
    access_controller: ?AccessController = null,

    /// Optional caller-supplied IO context. When `null` (default),
    /// `Engine.init` constructs a `std.Io.Threaded` with default
    /// options (async_limit = cpu_count - 1, concurrent_limit =
    /// unlimited) and OWNS it — the context is torn down by
    /// `Engine.deinit`. When non-null, the engine BORROWS this
    /// handle; the caller retains ownership and the underlying
    /// context must outlive the engine.
    ///
    /// Replaces the previous `std.Io.Threaded.global_single_threaded`
    /// usage. The global is a process-wide singleton with
    /// `async_limit = .nothing` and `concurrent_limit = .nothing`,
    /// which serialises every storage I/O call onto one async slot.
    /// Routing engine I/O through a per-engine multi-threaded
    /// context lets reads and writes overlap on a real thread pool,
    /// which is what P-IO-004 calls for. Closes P-IO-004.
    io: ?std.Io = null,
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
/// Every count and total is read via `.load(.acquire)` on the
/// matching atomic counter (P-LOCK-005 partial). The snapshot is
/// per-field consistent but NOT a single atomic read across the
/// struct — derived ratios (`*_total_ns / *_count`) can briefly
/// disagree if a writer is mid-update during the snapshot. The
/// snapshot is a value type; callers can hold onto it across
/// engine ops without fear of mutation.
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

    /// Number of compaction passes that completed (success OR
    /// failure), across every tier. Increments inside the background
    /// `compactionWorker` (which dispatches to either `compactL0` or
    /// `compactL1` per P-COMP-002) and inside `compactL0Forced` (the
    /// synchronous `compactAll` path).
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

/// Internal, lock-free counter storage for `Engine`. Each field
/// mirrors the same-named field in `StatsSnapshot` but is held as
/// `std.atomic.Value(u64)` so updates do NOT require the engine
/// lock. Reads use `.load(.acquire)`; writes use
/// `.fetchAdd(value, .release)`.
///
/// Partial P-LOCK-005: lifting the three append-path counter
/// updates out from under `Engine.mu` shrinks the lock-hold window
/// of `appendPoints`. The win is small per call (3 × ~1 ns) but
/// removes a hard dependency on the engine lock and keeps the
/// observability path independent from the writer lock.
pub const EngineCounters = struct {
    append_count: std.atomic.Value(u64) = .init(0),
    append_points: std.atomic.Value(u64) = .init(0),
    append_total_ns: std.atomic.Value(u64) = .init(0),

    query_count: std.atomic.Value(u64) = .init(0),
    query_total_ns: std.atomic.Value(u64) = .init(0),
    query_points_returned: std.atomic.Value(u64) = .init(0),

    flush_count: std.atomic.Value(u64) = .init(0),
    flush_total_ns: std.atomic.Value(u64) = .init(0),

    compaction_count: std.atomic.Value(u64) = .init(0),
    compaction_total_ns: std.atomic.Value(u64) = .init(0),

    wal_records_dropped: std.atomic.Value(u64) = .init(0),
    segment_integrity_failures: std.atomic.Value(u64) = .init(0),

    /// Snapshot every field into a plain-`u64` `StatsSnapshot`.
    /// Each load is `.acquire`; the resulting snapshot is internally
    /// consistent on a per-field basis but NOT a single atomic read
    /// across fields. In practice this matches the previous lock-
    /// based behaviour, which also returned a struct copy.
    pub fn snapshot(self: *const EngineCounters) StatsSnapshot {
        return .{
            .append_count = self.append_count.load(.acquire),
            .append_points = self.append_points.load(.acquire),
            .append_total_ns = self.append_total_ns.load(.acquire),
            .query_count = self.query_count.load(.acquire),
            .query_total_ns = self.query_total_ns.load(.acquire),
            .query_points_returned = self.query_points_returned.load(.acquire),
            .flush_count = self.flush_count.load(.acquire),
            .flush_total_ns = self.flush_total_ns.load(.acquire),
            .compaction_count = self.compaction_count.load(.acquire),
            .compaction_total_ns = self.compaction_total_ns.load(.acquire),
            .wal_records_dropped = self.wal_records_dropped.load(.acquire),
            .segment_integrity_failures = self.segment_integrity_failures.load(.acquire),
        };
    }
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
    /// Atomic pointer to the live active memtable (P-LOCK-005). Every
    /// `appendPoints` snapshots this pointer (lock-free), bumps the
    /// memtable's `pending_writers` barrier, and inserts WITHOUT
    /// holding `engine.mu`. Rotation (`maybeTriggerFlushLocked`,
    /// `flush`) is the only writer of this field and always runs
    /// under `engine.mu`, so the swap is single-publisher /
    /// multi-subscriber.
    ///
    /// Lifetime: the OLD pointer is moved to `flushing_mem` on
    /// rotation. The flush worker waits on the rotated memtable's
    /// `waitForQuiescence` before scanning, so a writer that
    /// snapshotted the OLD pointer pre-rotation has fully drained
    /// its `insert` before the flush worker begins reading.
    active_mem: std.atomic.Value(*memtable.Memtable),
    /// Memtable that is currently being flushed by a background
    /// worker. `null` between flushes. Guarded by `engine.mu`.
    /// Owned by the engine: the flush worker frees it after the
    /// segment commits and clears this slot to `null`.
    flushing_mem: ?*memtable.Memtable = null,
    pool: *thread_pool.ThreadPool,
    /// Heap-allocated multi-threaded IO context owned by this engine
    /// when the caller did NOT supply one in `EngineConfig.io`. Heap-
    /// allocated (rather than inline) so the `Io` handle below carries
    /// a stable `userdata` pointer that does not move when the Engine
    /// value is returned from `init` and copied into the caller's slot.
    /// Constructed with default options (async_limit = cpu_count - 1,
    /// concurrent_limit = unlimited); torn down by `deinit` AFTER the
    /// background workers (syncer + flushers + compactors waited on
    /// `done_cv`) have drained. Null when the caller supplied a
    /// borrowed `Io` via the config — in that mode the caller owns
    /// the underlying `Threaded`. Closes P-IO-004.
    threaded: ?*std.Io.Threaded = null,
    /// Active IO handle used by every engine method on the storage
    /// hot paths (append, query, flush, compaction, sync). Points
    /// into `self.threaded` when the engine owns the context, or
    /// into the caller-supplied context when borrowed. Replaces the
    /// previous per-call `std.Io.Threaded.global_single_threaded.io()`
    /// fetches across this file. Closes P-IO-004.
    io: std.Io,
    compaction_running: bool = false,
    /// Source level the in-flight background compaction worker should
    /// compact (P-COMP-002). Set under `engine.mu` by
    /// `triggerCompaction` BEFORE submitting the worker; read by the
    /// worker on entry. Valid values are 0 (L0->L1) and 1 (L1->L2).
    /// The single-binary `compaction_running` flag still gates the
    /// worker submission so only one compaction runs at a time across
    /// any tier.
    pending_compaction_level: u8 = 0,
    /// Number of flush worker invocations that have entered
    /// `flushWorker` and not yet returned. Distinct from
    /// `flushing_mem` — that slot is cleared inside the lock as
    /// soon as the manifest commit publishes the segment, but the
    /// worker MAY still be running post-publish I/O outside the
    /// lock (P-LOCK-003 WAL truncate, `triggerCompaction`). Used by
    /// `deinit` to wait for the worker to fully exit before
    /// tearing down `self.wal` / `self.man`.
    ///
    /// Concurrency: incremented at the top of `flushWorker` under
    /// `self.mu`, decremented at the bottom of `flushWorker` under
    /// `self.mu`, broadcast on `done_cv` so `deinit` wakes when it
    /// drains to zero.
    flush_workers_active: u32 = 0,
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
    /// (Vestigial) — superseded by per-call allocation under
    /// P-LOCK-005. The previous P-MEM-003 design reused a single
    /// engine-owned scratch buffer to avoid the per-call allocation,
    /// but the single-owner contract required `engine.mu` and that
    /// contention is exactly what blocked concurrent writer scaling.
    /// Kept as an unused field (no allocation) so external bench
    /// reflection (e.g. the P-MEM-003 regression test that read
    /// `append_payload_buf.capacity`) compiles unchanged; the field
    /// reports capacity == 0 forever.
    append_payload_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// Background WAL syncer thread (P-IO-002). `null` when
    /// `durability_mode == .per_call` (no background work needed) or
    /// before `startBackgroundSyncer` has been called. The thread
    /// polls `syncer_shutdown_event` via `waitTimeout`
    /// every `wal_sync_interval_ms` and issues `wal.sync()` between
    /// timeouts until shutdown is requested.
    syncer_thread: ?std.Thread = null,

    /// Event used both as the shutdown signal and the early-wake
    /// primitive for the syncer thread. `set` from `deinit` causes
    /// the syncer's `waitTimeout` to return immediately, after which
    /// it exits cleanly. The event is single-shot — once `set`, it
    /// stays set, which is exactly the shutdown semantic we want.
    syncer_shutdown_event: std.Io.Event = .unset,

    /// Bounded LRU cache of open SegmentReader handles (P-IO-001 /
    /// P-MEM-006). Initialised lazily in `queryPoints` so engines
    /// that never query don't pay for an unused HashMap allocation.
    /// Cleared on `deinit`; entries invalidated on compaction.
    reader_cache: SegmentReaderCache,

    /// Per-series highest timestamp ever observed by `appendPoints`
    /// (GAP-0010 strict-mode tracker). Only populated when
    /// `config.allow_cross_segment_ooo == false`; permissive mode
    /// skips the hashmap entirely to avoid the per-call lookup cost.
    /// Bounded by the number of distinct series the engine has
    /// touched in the current process — same growth shape as the
    /// memtable's series map.
    ///
    /// Concurrency: every read/write happens under `self.mu` from
    /// `appendPoints`, so no additional synchronisation is needed.
    series_watermarks: std.AutoHashMapUnmanaged(types.SeriesId, i64) = .{},

    /// Engine-wide latency / throughput counters. Each field is a
    /// `std.atomic.Value(u64)` updated lock-free by every hot path
    /// (append, query, flush, compaction). Reads (`stats()`) snapshot
    /// the full struct via `.load(.acquire)` on each field; writes use
    /// `.fetchAdd(value, .release)`. Closes P-OBS-001; the lock-free
    /// storage closes the counter-update slice of the partial
    /// P-LOCK-005 work.
    counters: EngineCounters = .{},

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

        // P-IO-004: construct (or borrow) the engine's IO context
        // BEFORE any I/O happens. The default path heap-allocates a
        // `std.Io.Threaded` with stdlib defaults
        // (async_limit = cpu_count - 1, concurrent_limit = unlimited),
        // which lets reads, fsyncs, and compactions overlap on a real
        // thread pool. The previous behaviour fetched
        // `global_single_threaded.io()` per call — a singleton with
        // both limits set to `.nothing`, serialising every storage
        // I/O onto one async slot. Heap allocation (rather than an
        // inline field) keeps the `Io.userdata` pointer stable across
        // the value-return from `init` into the caller's slot.
        var owned_threaded: ?*std.Io.Threaded = null;
        const io: std.Io = blk: {
            if (config.io) |caller_io| break :blk caller_io;
            const t = try allocator.create(std.Io.Threaded);
            errdefer allocator.destroy(t);
            t.* = std.Io.Threaded.init(allocator, .{});
            owned_threaded = t;
            break :blk t.io();
        };
        errdefer if (owned_threaded) |t| {
            t.deinit();
            allocator.destroy(t);
        };

        // GAP-0001 (manifest TDE): thread the operator-supplied key
        // into the manifest so on-disk slots are wrapped with the
        // TSMNF002 envelope. Plaintext mode (key == null) is
        // unchanged.
        var man = try manifest.Manifest.initWithEncryption(
            allocator,
            config.data_dir,
            config.encryption_key,
        );
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
        try verifySegments(allocator, io, &man, config.data_dir, config.wal_recovery, &integrity_failures);

        // P-LOCK-001 / P-LOCK-003 manifest COW: publish the initial
        // immutable snapshot AFTER verifySegments has finalised the
        // accepted segment set. From this point on, queryPoints can
        // observe the segment list via `man.snapshot()` without
        // holding engine.mu — concurrent writers stage new snapshots
        // and publish them atomically.
        try man.publishInitialSnapshot();

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

        // ENT-002 / ENT-005: pre-size the memtable's per-shard
        // AutoHashMaps and the per-series ArrayLists so the steady-state
        // ingest path does not pay the first-touch hashmap/array
        // growth allocation. The expected_series default comes from
        // `limits.DEFAULT_EXPECTED_SERIES`; the per-series hint is
        // `max_memtable_points / expected_series` floored at 64 to
        // keep wide-cardinality workloads sane.
        //
        // P-LOCK-005: the memtable is heap-allocated so rotation can
        // swap pointers atomically while the previous memtable
        // outlives any in-flight writer that snapshotted it before
        // the swap.
        const mem = try allocator.create(memtable.Memtable);
        errdefer allocator.destroy(mem);
        mem.* = try memtable.Memtable.initCapacity(
            allocator,
            config.max_memtable_points,
            limits.DEFAULT_EXPECTED_SERIES,
            computePointsPerSeriesHint(config.max_memtable_points, limits.DEFAULT_EXPECTED_SERIES),
        );
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
        try replayWalIntoMemtable(allocator, &wal, mem, man.last_checkpoint_lsn + 1, config.wal_recovery, &wal_drops);

        return Engine{
            .allocator = allocator,
            .config = config,
            .wal = wal,
            .man = man,
            .active_mem = std.atomic.Value(*memtable.Memtable).init(mem),
            .pool = pool,
            .threaded = owned_threaded,
            .io = io,
            .reader_cache = SegmentReaderCache.init(allocator, DEFAULT_SEGMENT_READER_CACHE_CAPACITY),
            .counters = .{
                .wal_records_dropped = .init(wal_drops),
                .segment_integrity_failures = .init(integrity_failures),
            },
        };
    }

    /// Spawn the background WAL syncer if `durability_mode == .batch`.
    /// Called by the engine builder right after `Engine.init` returns.
    /// MUST be called only ONCE per engine instance; the receiver is
    /// `*Engine` so the spawned thread can capture a stable pointer.
    ///
    /// Why this is a separate function rather than running inside
    /// `init`: spawning a thread that captures `*Engine` requires the
    /// engine to live at a stable address — i.e. the caller must
    /// already have moved the result of `init` into its final home.
    /// We expose a separate `startBackgroundSyncer` so the caller can
    /// say "now the engine is at its final address, start workers".
    /// The CLI / examples wire this in their `Engine.openAt` helpers.
    ///
    /// Closes the operator-facing slice of P-IO-002.
    pub fn startBackgroundSyncer(self: *Engine) !void {
        if (self.config.durability_mode != .batch) return;
        if (self.syncer_thread != null) return; // idempotent
        self.syncer_thread = try std.Thread.spawn(.{}, syncerLoop, .{self});
    }

    /// Body of the background WAL syncer thread. Sleeps for
    /// `config.wal_sync_interval_ms`, syncs the WAL, repeats until
    /// `syncer_shutdown_event` is set by `deinit`.
    fn syncerLoop(self: *Engine) void {
        const io = self.io;
        const interval_ns: u64 = @as(u64, self.config.wal_sync_interval_ms) * std.time.ns_per_ms;
        while (true) {
            // Wait up to interval_ns for the shutdown event. On
            // timeout we fall through to a sync. On set (shutdown)
            // we return immediately. Cancelable errors are swallowed
            // — the syncer is a fire-and-forget loop.
            const wait_result = self.syncer_shutdown_event.waitTimeout(
                io,
                .{ .duration = .{
                    .raw = .{ .nanoseconds = @intCast(interval_ns) },
                    .clock = .awake,
                } },
            );
            if (wait_result) |_| {
                // Event set: shutdown requested.
                return;
            } else |err| switch (err) {
                error.Timeout => {}, // expected — fall through to sync
                else => return, // cancelled — bail out
            }

            // Take the engine lock briefly and issue the sync.
            // `wal.sync()` is the cost we are amortising across all
            // the appends that happened since the last interval.
            self.mu.lockUncancelable(io);
            self.wal.sync() catch |err| {
                self.recordBackgroundErrorLocked(.flush, err);
            };
            self.mu.unlock(io);
        }
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
        io: std.Io,
        man: *manifest.Manifest,
        data_dir: []const u8,
        policy: WalRecoveryPolicy,
        integrity_counter: ?*u64,
    ) !void {
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
    /// file is too short to even hold one block header. Accepts
    /// both v2 (plaintext) and v3 (encrypted) magics — distinguishing
    /// between them is done by the reader on open, not by the
    /// integrity check.
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
        const is_v2 = std.mem.eql(u8, &magic_buf, &segment.SEGMENT_MAGIC);
        const is_v3 = std.mem.eql(u8, &magic_buf, &segment.SEGMENT_MAGIC_V3);
        if (!is_v2 and !is_v3) return error.SegmentCorrupted;
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
        // P-IO-004: use the engine-owned (or caller-borrowed) IO
        // handle for every internal mutex / condition variable touch
        // in this function. `self.io` is valid until the explicit
        // `Threaded.deinit` call below — after that we MUST NOT
        // dispatch any more I/O against it.
        const io = self.io;

        // Stop the background WAL syncer FIRST so it cannot try to
        // touch the WAL after we tear it down. The syncer takes
        // `self.mu` internally for the sync call, so signal it via
        // its own shutdown event before taking the engine lock.
        if (self.syncer_thread) |t| {
            self.syncer_shutdown_event.set(io);
            t.join();
            self.syncer_thread = null;
        }

        self.mu.lockUncancelable(io);

        // Wait for all background tasks to finish. Park on the condition
        // variable so we burn no CPU; workers broadcast it as they
        // clear `flushing_mem` / `compaction_running` /
        // `flush_workers_active`.
        //
        // `flush_workers_active` matters here because P-LOCK-003
        // moves the WAL truncate fsync OUTSIDE the engine lock —
        // `flushing_mem` is cleared as soon as the manifest commit
        // publishes the new segment, but the worker is still
        // running post-publish I/O (the truncate + the compaction
        // trigger) after that point. Waiting on
        // `flush_workers_active == 0` ensures the worker has fully
        // exited before we tear down `self.wal` / `self.man`.
        while (self.flushing_mem != null or self.compaction_running or self.flush_workers_active > 0) {
            self.done_cv.waitUncancelable(io, &self.mu);
        }

        self.wal.deinit();
        self.man.deinit();
        // P-LOCK-005: heap-allocated active memtable. Tear down the
        // value AND free the allocation. The flushing slot should
        // have been drained by the loop above; defensively free it
        // too if a worker left it behind on error.
        {
            const am = self.active_mem.load(.acquire);
            am.deinit();
            self.allocator.destroy(am);
        }
        if (self.flushing_mem) |fm| {
            fm.deinit();
            self.allocator.destroy(fm);
            self.flushing_mem = null;
        }
        self.append_payload_buf.deinit(self.allocator);
        self.series_watermarks.deinit(self.allocator);
        self.reader_cache.deinit();

        // Release the engine lock BEFORE tearing down the threaded
        // IO context. `Threaded.deinit` joins its worker pool; we
        // must not hold a mutex across that join (defensive: no
        // engine-owned worker takes `engine.mu` today, but a future
        // hook that does would deadlock otherwise). The unlock uses
        // the same `io` we locked with — both reference the still-
        // live Threaded instance.
        self.mu.unlock(io);

        // P-IO-004: tear down the engine-owned threaded IO context
        // last. By this point the syncer thread has been joined
        // above, the condition-variable loop drained any in-flight
        // flush / compaction worker, and `self.io` will not be used
        // again by this function. Borrowed contexts (caller-supplied
        // via `EngineConfig.io`) are left untouched — the caller
        // owns their lifetime.
        if (self.threaded) |t| {
            t.deinit();
            self.allocator.destroy(t);
            self.threaded = null;
        }
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

        // GAP-0002 / SEC-007: route through the pluggable authoriser
        // BEFORE any state mutation. The check runs without the
        // engine lock held (it may itself take locks, do I/O, or
        // consult a remote ACL — anything except call back into
        // this engine). A denied check leaves WAL, memtable, and
        // counters untouched.
        if (self.config.access_controller) |ac| {
            try ac.check(ac.ctx, .append, series_id);
        }

        // P-OBS-001: time the entire critical section. nowMonotonicNs
        // is ~30 ns on commodity hardware — negligible next to the
        // WAL fsync this call ultimately amortises into.
        const t_start = nowMonotonicNs();
        const io = self.io;

        // P-LOCK-005: take `engine.mu` ONLY for the strict-OoO check
        // (which touches the per-series watermark map). The default
        // permissive config skips this branch entirely and never
        // takes the engine lock on the write path.
        if (!self.config.allow_cross_segment_ooo) {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            try self.checkOoOLocked(series_id, points);
        }

        // P-LOCK-005: encode payload per-call. The previous
        // `append_payload_buf` reuse trick (P-MEM-003) required
        // `engine.mu` for single-owner access; that contention is
        // exactly what blocked concurrent writer scaling. The cost
        // here is one allocator round-trip per appendPoints (16 +
        // 16*N bytes) — measurably cheaper than the WAL fsync and
        // far cheaper than serialising all writers behind one lock.
        const payload_size = 16 + (points.len * 16);
        const payload = try self.allocator.alloc(u8, payload_size);
        defer self.allocator.free(payload);
        encodeAppendPointsPayload(payload, series_id, points);

        // WAL append: `WalManager` has its own internal mutex
        // (ENT-006) so concurrent calls serialise inside the WAL
        // layer without holding `engine.mu`.
        var rec = wal_record.WalRecord{
            .lsn = 0,
            .record_type = .append_points,
            .payload = payload,
            .checksum = 0,
        };
        _ = try self.wal.appendRecord(&rec);

        // P-IO-002: in per_call durability mode every append fsyncs
        // before returning. In batch mode the background syncer
        // covers durability on its own schedule.
        if (self.config.durability_mode == .per_call) {
            try self.wal.sync();
        }

        // P-LOCK-005: snapshot the active memtable pointer atomically
        // and bracket the insert with the pending-writers barrier so
        // a concurrent rotation that moves THIS pointer into
        // `flushing_mem` cannot let the flush worker begin scanning
        // until our insert has fully landed.
        //
        // Race analysis: rotation publishes a NEW pointer via the
        // atomic store (under `engine.mu`); any writer that loaded
        // the OLD pointer BEFORE that store has already bumped
        // `pending_writers` on the OLD memtable. The flush worker
        // calls `waitForQuiescence` on the OLD memtable AFTER the
        // rotation publishes, so it will spin until our `endAppend`
        // fires. After the rotation publishes, all new writers load
        // the NEW pointer and never touch the OLD one. The OLD
        // memtable is therefore quiesced from any further insert
        // before the flush worker reads it.
        const target_mem = self.active_mem.load(.acquire);
        target_mem.beginAppend();
        const insert_result = target_mem.insert(series_id, points);
        target_mem.endAppend();
        try insert_result;

        // Re-enter `engine.mu` briefly to (a) potentially rotate the
        // memtable if it tripped the flush threshold and (b) bump
        // the strict-mode watermark. Both are short critical sections
        // that touch engine-wide state.
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            try self.maybeTriggerFlushLocked(io);
            if (!self.config.allow_cross_segment_ooo) {
                try self.bumpWatermarkLocked(series_id, points);
            }
        }

        // Counters are bumped only on a clean return; failed calls
        // do not pollute the latency average. Atomic counters
        // (P-LOCK-005) — no lock needed.
        _ = self.counters.append_count.fetchAdd(1, .release);
        _ = self.counters.append_points.fetchAdd(@intCast(points.len), .release);
        _ = self.counters.append_total_ns.fetchAdd(nowMonotonicNs() - t_start, .release);
    }

    /// Strict-mode OoO check (GAP-0010). Verifies every point's
    /// timestamp is >= the running per-series watermark. Caller
    /// MUST hold `self.mu`.
    ///
    /// The watermark is the max of:
    ///   * the highest timestamp ever passed to `appendPoints` for
    ///     this series in this process, and
    ///   * the manifest's `max_ts` for the series across all sealed
    ///     segments (loaded lazily on first reference).
    ///
    /// In strict mode the engine refuses to widen the OoO window —
    /// every batch must be monotonically non-decreasing per series.
    /// The check costs one HashMap lookup per call regardless of
    /// `points.len`.
    fn checkOoOLocked(
        self: *Engine,
        series_id: types.SeriesId,
        points: []const types.Point,
    ) !void {
        // Lazily seed the watermark from the manifest. The manifest
        // tracks per-segment min/max; we approximate the per-series
        // watermark with the global max across all segments since
        // per-series block-level metadata is not in the manifest
        // (that is tracked under P-ALGO-001 as future work). This
        // is correct but conservative — strict mode will reject
        // points that are technically valid for a different series
        // but predate a segment that does NOT contain this series.
        // Callers that need finer-grained tracking must enable the
        // permissive mode and rely on overlap-aware compaction.
        if (!self.series_watermarks.contains(series_id)) {
            var seeded: i64 = std.math.minInt(i64);
            for (self.man.segments.items) |seg| {
                if (seg.max_ts > seeded) seeded = seg.max_ts;
            }
            try self.series_watermarks.put(self.allocator, series_id, seeded);
        }

        const wm = self.series_watermarks.get(series_id).?;
        for (points) |pt| {
            if (pt.ts < wm) return error.OutOfOrderTimestamp;
        }
    }

    /// Strict-mode watermark update (GAP-0010). Caller MUST hold
    /// `self.mu`. No-op in permissive mode.
    fn bumpWatermarkLocked(
        self: *Engine,
        series_id: types.SeriesId,
        points: []const types.Point,
    ) !void {
        var local_max: i64 = std.math.minInt(i64);
        for (points) |pt| {
            if (pt.ts > local_max) local_max = pt.ts;
        }
        const current = self.series_watermarks.get(series_id) orelse std.math.minInt(i64);
        if (local_max > current) {
            try self.series_watermarks.put(self.allocator, series_id, local_max);
        }
    }

    /// Serialise `(series_id, points)` into `buf` (which must be
    /// pre-sized to `16 + 16*points.len` bytes). Layout matches
    /// `wal_record.WalRecord`:
    /// `series_id (u128 LE) || (i64 ts, i64 value)*`.
    ///
    /// P-LOCK-005: lock-free helper — each `appendPoints` call
    /// allocates its own payload buffer so multiple writers can
    /// encode in parallel. The previous engine-owned scratch buffer
    /// (P-MEM-003) was abandoned because the single-owner contract
    /// it relied on required `engine.mu`, defeating the per-shard
    /// memtable parallelism we wanted to expose.
    fn encodeAppendPointsPayload(
        buf: []u8,
        series_id: types.SeriesId,
        points: []const types.Point,
    ) void {
        std.mem.writeInt(u128, buf[0..16], series_id, .little);
        var pos: usize = 16;
        for (points) |pt| {
            std.mem.writeInt(i64, buf[pos..][0..8], pt.ts, .little);
            pos += 8;
            std.mem.writeInt(i64, buf[pos..][0..8], pt.value, .little);
            pos += 8;
        }
    }

    /// If the active memtable has tripped its flush threshold,
    /// rotate it into the flushing slot and submit a flush worker.
    /// Honours back-pressure: parks on `done_cv` when a previous
    /// flush is still in flight. Must be called with `self.mu` held.
    ///
    /// P-LOCK-005: rotation moves the OLD `*Memtable` into
    /// `flushing_mem` and publishes a NEW `*Memtable` into the
    /// atomic `active_mem` slot. Writers that snapshotted the OLD
    /// pointer pre-rotation finish their insert into the OLD
    /// memtable; the flush worker calls `waitForQuiescence` on
    /// `flushing_mem` before scanning it, so no in-flight insert is
    /// lost.
    fn maybeTriggerFlushLocked(self: *Engine, io: std.Io) !void {
        const current = self.active_mem.load(.acquire);
        while (current.shouldFlush() and self.flushing_mem != null) {
            self.done_cv.waitUncancelable(io, &self.mu);
        }
        const cur2 = self.active_mem.load(.acquire);
        if (!cur2.shouldFlush()) return;

        // ENT-002 / ENT-005 + P-LOCK-005: build a new pre-sized,
        // heap-allocated memtable BEFORE we touch state so a mid-
        // allocation OOM cannot leave the engine in a partially
        // rotated condition.
        const new_mem = try self.allocator.create(memtable.Memtable);
        errdefer self.allocator.destroy(new_mem);
        new_mem.* = try memtable.Memtable.initCapacity(
            self.allocator,
            self.config.max_memtable_points,
            limits.DEFAULT_EXPECTED_SERIES,
            computePointsPerSeriesHint(self.config.max_memtable_points, limits.DEFAULT_EXPECTED_SERIES),
        );
        errdefer new_mem.deinit();

        // Publish the swap. The previous active pointer is moved
        // into `flushing_mem`; once `active_mem` reflects the new
        // pointer, no NEW writer can observe the old one.
        self.flushing_mem = cur2;
        self.active_mem.store(new_mem, .release);
        _ = self.pool.submit(flushWorker, self, .{}) catch |err| {
            // Roll back: the new memtable is the survivor, the old
            // memtable is freed. We do NOT reinstate the old as
            // active because writers may have already observed the
            // new pointer between the store above and the failure
            // here — reverting would split insertions across two
            // live memtables.
            const old = self.flushing_mem.?;
            old.deinit();
            self.allocator.destroy(old);
            self.flushing_mem = null;
            self.done_cv.broadcast(io);
            return err;
        };
    }

    fn flushWorker(ctx: *anyopaque, _: *thread_pool.TaskContext) void {
        var self = safety.castCtx(Engine, ctx);
        const io = self.io;

        // P-LOCK-003: count the worker as active across the entire
        // body (including the post-publish I/O that runs OUTSIDE
        // `engine.mu`). `deinit` parks on `flush_workers_active == 0`
        // so it never races with the trailing `wal.truncate` /
        // `triggerCompaction` calls that touch `self.wal` /
        // `self.man` after the lock has been released.
        self.mu.lockUncancelable(io);
        self.flush_workers_active += 1;
        self.mu.unlock(io);

        const t_start = nowMonotonicNs();
        self.flushInternal() catch |err| {
            self.mu.lockUncancelable(io);
            if (self.flushing_mem) |fm| {
                fm.deinit();
                self.allocator.destroy(fm);
            }
            self.flushing_mem = null;
            // A failed flush still counts as a completed scheduling
            // round so flush() callers are not stuck waiting forever
            // for a flush that errored out. Counter likewise bumps —
            // operators want to see failed flushes in the rate too.
            self.flushes_completed += 1;
            _ = self.counters.flush_count.fetchAdd(1, .release);
            _ = self.counters.flush_total_ns.fetchAdd(nowMonotonicNs() - t_start, .release);
            self.recordBackgroundErrorLocked(.flush, err);
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
        };

        self.mu.lockUncancelable(io);
        self.flush_workers_active -= 1;
        self.done_cv.broadcast(io);
        self.mu.unlock(io);
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
            => {
                _ = self.counters.segment_integrity_failures.fetchAdd(1, .release);
            },
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

    /// Build the per-segment encryption context for `segment_id`,
    /// or null when no key is configured. The graph_uuid comes from
    /// the engine's manifest (same uuid that identifies the WAL
    /// stream and the data directory). Closes GAP-0001.
    fn segmentEncryptionContext(self: *Engine, segment_id: u64) ?segment.EncryptionContext {
        const key = self.config.encryption_key orelse return null;
        return .{
            .key = key,
            .graph_uuid = self.man.ts_uuid,
            .segment_id = segment_id,
        };
    }

    /// Allocate a `CompactionEncryption` matching the input segment
    /// list. Caller owns the returned slice and must free it. Closes
    /// GAP-0001 (compaction path).
    fn buildCompactionEncryption(
        self: *Engine,
        in_seg_ids: []const u64,
        out_seg_id: u64,
    ) !?compaction.CompactionEncryption {
        if (self.config.encryption_key == null) return null;
        const inputs = try self.allocator.alloc(?segment.EncryptionContext, in_seg_ids.len);
        for (in_seg_ids, 0..) |id, i| inputs[i] = self.segmentEncryptionContext(id);
        return .{
            .inputs = inputs,
            .output = self.segmentEncryptionContext(out_seg_id),
        };
    }

    /// Snapshot of the engine's observability counters (P-OBS-001).
    /// Each sub-counter is read with `.load(.acquire)`; the result is
    /// per-field consistent but NOT a single atomic read across the
    /// struct. In practice this matches the previous lock-based
    /// behaviour, which also returned a struct copy.
    ///
    /// Counter semantics are documented on `StatsSnapshot` itself.
    /// Returning a value type avoids any aliasing or post-snapshot
    /// mutation: callers can stash, diff, or transport the result.
    ///
    /// Threading: lock-free (P-LOCK-005 partial); safe to call
    /// concurrently with any other engine method including the hot
    /// `appendPoints` path.
    pub fn stats(self: *Engine) StatsSnapshot {
        return self.counters.snapshot();
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
        const io = self.io;
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
    /// submitted, and the call blocks until the segment has been
    /// written and the manifest has been fsynced (which is the
    /// durability barrier — see Q-REL-008 / P-IO-003). The WAL
    /// truncate that reclaims the now-redundant log space runs
    /// asynchronously AFTER the manifest commit (P-LOCK-003) and
    /// MAY still be in flight when `flush()` returns. This is
    /// crash-safe: the manifest is the source of truth for
    /// durability, so recovery after a crash between manifest
    /// commit and WAL truncate simply skips the now-stale records
    /// past `last_checkpoint_lsn`.
    ///
    /// Threading: safe to call concurrently with other engine methods,
    /// but the engine serialises flushes one at a time — overlapping
    /// `flush()` callers will queue up behind one another.
    ///
    /// Errors: thread-pool submission failure or any WAL/segment I/O
    /// error bubbles up. On error the engine state is consistent and
    /// the call may be retried.
    pub fn flush(self: *Engine) !void {
        const io = self.io;
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

        const current_active = self.active_mem.load(.acquire);
        if (current_active.point_count.load(.acquire) > 0) {
            // Wait for any in-flight flush to release the slot.
            while (self.flushing_mem != null) {
                self.done_cv.waitUncancelable(io, &self.mu);
            }
            // ENT-002 / ENT-005 + P-LOCK-005: build the new
            // heap-allocated memtable BEFORE the pointer swap so a
            // mid-allocation OOM does not leave the engine in a
            // half-rotated state.
            const new_mem = try self.allocator.create(memtable.Memtable);
            errdefer self.allocator.destroy(new_mem);
            new_mem.* = try memtable.Memtable.initCapacity(
                self.allocator,
                self.config.max_memtable_points,
                limits.DEFAULT_EXPECTED_SERIES,
                computePointsPerSeriesHint(self.config.max_memtable_points, limits.DEFAULT_EXPECTED_SERIES),
            );
            errdefer new_mem.deinit();

            const old_mem = self.active_mem.load(.acquire);
            self.flushing_mem = old_mem;
            self.active_mem.store(new_mem, .release);
            target = self.flushes_completed + 1;
            _ = self.pool.submit(flushWorker, self, .{}) catch |err| {
                const old = self.flushing_mem.?;
                old.deinit();
                self.allocator.destroy(old);
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
        const io = self.io;
        var min_ts: i64 = std.math.maxInt(i64);
        var max_ts: i64 = std.math.minInt(i64);

        // P-OBS-001: time the entire flush worker body so the average
        // includes encode + write + fsync + manifest commit.
        const t_start = nowMonotonicNs();

        self.mu.lockUncancelable(io);
        const mem = self.flushing_mem orelse {
            self.mu.unlock(io);
            return;
        };
        self.mu.unlock(io);

        // P-LOCK-005 quiescence barrier: wait for any in-flight
        // `appendPoints` that snapshotted this memtable BEFORE the
        // rotation to finish its `insert`. After this point the
        // memtable is observed-quiescent — no new writer can target
        // it (the active pointer has already been swapped), and the
        // last pre-rotation writer has decremented `pending_writers`.
        mem.waitForQuiescence();

        if (mem.point_count.load(.acquire) == 0) {
            self.mu.lockUncancelable(io);
            mem.deinit();
            self.allocator.destroy(mem);
            self.flushing_mem = null;
            self.flushes_completed += 1;
            _ = self.counters.flush_count.fetchAdd(1, .release);
            _ = self.counters.flush_total_ns.fetchAdd(nowMonotonicNs() - t_start, .release);
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
            return;
        }

        // Lazy-sort (P-ALGO-003): the memtable may contain per-series
        // entries whose `sorted` flag was flipped to false by an
        // out-of-order append. We sort once here, just before flush.
        mem.ensureAllSorted();

        // Compute [min_ts, max_ts] across every shard.
        const BoundsCtx = struct {
            min_ts: *i64,
            max_ts: *i64,

            fn visit(self_ctx: @This(), _: types.SeriesId, items: []const types.Point) anyerror!void {
                if (items.len == 0) return;
                const first_ts = items[0].ts;
                const last_ts = items[items.len - 1].ts;
                if (first_ts < self_ctx.min_ts.*) self_ctx.min_ts.* = first_ts;
                if (last_ts > self_ctx.max_ts.*) self_ctx.max_ts.* = last_ts;
            }
        };
        try mem.forEachSeries(BoundsCtx{ .min_ts = &min_ts, .max_ts = &max_ts }, BoundsCtx.visit);

        self.mu.lockUncancelable(io);
        const seg_id = self.man.getNextSegmentId();
        self.mu.unlock(io);

        const seg_name = try segment.segmentPath(self.allocator, self.config.data_dir, seg_id);
        defer self.allocator.free(seg_name);

        var writer = try segment.SegmentWriter.initWithEncryption(
            self.allocator,
            seg_name,
            self.segmentEncryptionContext(seg_id),
        );
        defer writer.deinit();

        // Emit one block per (series_id, points) pair across every
        // shard. `forEachSeries` holds the shard mutex during each
        // visit so the slice the writer reads is stable.
        const WriteCtx = struct {
            writer: *segment.SegmentWriter,

            fn visit(self_ctx: @This(), id: types.SeriesId, items: []const types.Point) anyerror!void {
                if (items.len == 0) return;
                try self_ctx.writer.writeBlock(id, items);
            }
        };
        try mem.forEachSeries(WriteCtx{ .writer = &writer }, WriteCtx.visit);

        // Durability ordering: fsync the segment file BEFORE adding
        // it to the manifest. A crash between manifest commit and the
        // OS background flush would otherwise leave the manifest
        // referencing a segment whose blocks have not actually
        // landed on disk (Q-REL-008 / P-IO-003).
        try writer.sync();

        // P-LOCK-003 conservative scope-down: keep the manifest fsync
        // inside `engine.mu` (it mutates `self.man.segments` and
        // `self.man.counter` — both protected by the engine lock and
        // would require a manifest COW refactor to safely move out),
        // but lift the WAL truncate (and its fsync) OUT of the lock.
        // The WAL has its own internal mutex (ENT-006), so its
        // truncate is safe to call lock-free, and its fsync no
        // longer holds the engine lock against concurrent appends or
        // queries.
        //
        // Durability ordering: manifest MUST be durable BEFORE the
        // WAL is truncated. The previous code violated this — it
        // called `wal.truncate` BEFORE `man.save`, so a crash
        // between the two would lose the records covered by the new
        // segment because the manifest on disk would still point at
        // the OLD last_checkpoint_lsn while the WAL had already
        // dropped them. With the truncate moved AFTER the save and
        // AFTER the engine lock is released, a crash between
        // `man.save` returning and `wal.truncate` running merely
        // leaves stale records in the WAL past
        // `last_checkpoint_lsn`; recovery starts from
        // `last_checkpoint_lsn + 1` and skips them, so no data is
        // lost. The next successful flush will reclaim the space.
        //
        // We snapshot the checkpoint LSN inside the lock so the
        // unlock-side truncate uses exactly the value the manifest
        // recorded — concurrent appends past that point are
        // intentionally preserved.
        var checkpoint_lsn: u64 = 0;
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
            checkpoint_lsn = self.man.last_checkpoint_lsn;
            try self.man.save();

            mem.deinit();
            self.allocator.destroy(mem);
            self.flushing_mem = null;
            self.flushes_completed += 1;
            _ = self.counters.flush_count.fetchAdd(1, .release);
            _ = self.counters.flush_total_ns.fetchAdd(nowMonotonicNs() - t_start, .release);
            self.done_cv.broadcast(io);
        }

        // P-LOCK-003: WAL truncate runs OUTSIDE engine.mu. The
        // manifest above already records `checkpoint_lsn` as the new
        // durable boundary, so a failure here is non-fatal — it just
        // leaves space-reclaimable WAL bytes on disk. Surface the
        // failure through the background-error pipeline rather than
        // returning it, so the flush worker's error-path handler
        // does not double-bump the counters we already incremented
        // and does not try to deinit `flushing_mem` (which we
        // already cleared inside the lock).
        self.wal.truncate(checkpoint_lsn) catch |err| {
            self.mu.lockUncancelable(io);
            self.recordBackgroundErrorLocked(.flush, err);
            self.mu.unlock(io);
        };

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

    /// Decide whether a background compaction is warranted and, if so,
    /// dispatch one. Implements the tiered policy that closes
    /// P-COMP-002:
    ///
    ///   * `l0_count >= kL0CompactionThreshold` -> submit L0->L1.
    ///   * Else if `l1_count >= kL1CompactionThreshold` -> submit L1->L2.
    ///   * Else no-op.
    ///
    /// L0 takes priority because it is the freshest tier and growing
    /// L0 directly inflates write amplification on the next compaction
    /// fan-in. We only consider L1 when L0 is already below its
    /// trigger — the binary `compaction_running` gate ensures only one
    /// pass runs at a time across any tier.
    fn triggerCompaction(self: *Engine) !void {
        const io = self.io;
        self.mu.lockUncancelable(io);
        var l0_count: usize = 0;
        var l1_count: usize = 0;
        for (self.man.segments.items) |seg| {
            if (seg.level == 0) l0_count += 1 else if (seg.level == 1) l1_count += 1;
        }
        self.mu.unlock(io);

        var target_level: u8 = 0;
        var should_submit = false;
        if (l0_count >= kL0CompactionThreshold) {
            target_level = 0;
            should_submit = true;
        } else if (l1_count >= kL1CompactionThreshold) {
            target_level = 1;
            should_submit = true;
        }

        if (should_submit) {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            if (!self.compaction_running) {
                self.compaction_running = true;
                self.pending_compaction_level = target_level;
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
        const io = self.io;

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
            _ = self.counters.compaction_count.fetchAdd(1, .release);
            _ = self.counters.compaction_total_ns.fetchAdd(nowMonotonicNs() - t_start, .release);
            self.compaction_running = false;
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
        }

        try self.compactL0Forced();
    }

    /// Inner body of `compactAll`. Lifted from `compactL0` with the
    /// threshold gate removed so the synchronous path can fold even a
    /// single L0 segment into L1.
    ///
    /// GAP-0010: overlap-aware. After picking the L0 set, any
    /// higher-level segment whose `[min_ts, max_ts]` intersects the
    /// L0 range is folded into the merge too — otherwise a flush
    /// containing an OoO point would produce an overlapping segment
    /// that compaction silently leaves on disk forever.
    fn compactL0Forced(self: *Engine) !void {
        const io = self.io;

        var input_segs = std.ArrayList(manifest.SegmentMeta).empty;
        defer input_segs.deinit(self.allocator);
        var new_seg_id: u64 = 0;

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            try self.collectOverlappingInputsLocked(.{ .source_level = 0, .require_source = false }, &input_segs);
            if (input_segs.items.len == 0) return;
            new_seg_id = self.man.getNextSegmentId();
        }

        // Forced L0 path: target the next tier above the highest input
        // level seen (matches the pure-fan-in semantic). If any L1+
        // segment got folded in via overlap, the output stays at that
        // tier (see `targetLevelForInputs`).
        const target_level = targetLevelForInputs(input_segs.items, 0);
        try self.runMergeAndCommit(io, input_segs.items, new_seg_id, target_level);
    }

    fn compactionWorker(ctx: *anyopaque, _: *thread_pool.TaskContext) void {
        var self = safety.castCtx(Engine, ctx);
        const t_start = nowMonotonicNs();
        const io = self.io;

        // Snapshot the dispatch level under the lock so a racing
        // `triggerCompaction` cannot clobber it mid-run. The trigger
        // path gates on `compaction_running` so the only legitimate
        // writer of `pending_compaction_level` at this point is the
        // one that just submitted us.
        self.mu.lockUncancelable(io);
        const level = self.pending_compaction_level;
        self.mu.unlock(io);

        const result = switch (level) {
            0 => self.compactL0(),
            1 => self.compactL1(),
            else => self.compactL0(), // defensive fall-through to L0
        };

        self.mu.lockUncancelable(io);
        if (result) |_| {} else |err| {
            self.recordBackgroundErrorLocked(.compaction, err);
        }
        // Always count completed compactions — success or failure —
        // so the rate reflects work attempted, not just successful work.
        _ = self.counters.compaction_count.fetchAdd(1, .release);
        _ = self.counters.compaction_total_ns.fetchAdd(nowMonotonicNs() - t_start, .release);
        self.compaction_running = false;
        self.done_cv.broadcast(io);
        self.mu.unlock(io);
    }

    /// Background L0->L1 compaction worker body.
    ///
    /// GAP-0010: overlap-aware. After picking the L0 set, any
    /// higher-level segment whose `[min_ts, max_ts]` intersects
    /// the L0 range is folded into the merge too. Without this,
    /// a flush containing an OoO point would produce an
    /// overlapping segment that the engine would never reconcile,
    /// breaking the query-ordering contract.
    fn compactL0(self: *Engine) !void {
        const io = self.io;

        var input_segs = std.ArrayList(manifest.SegmentMeta).empty;
        defer input_segs.deinit(self.allocator);
        var new_seg_id: u64 = 0;
        var l0_count: usize = 0;

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            for (self.man.segments.items) |seg| {
                if (seg.level == 0) l0_count += 1;
            }
            if (l0_count < kL0CompactionThreshold) return;

            try self.collectOverlappingInputsLocked(.{ .source_level = 0, .require_source = true }, &input_segs);
            if (input_segs.items.len == 0) return;
            new_seg_id = self.man.getNextSegmentId();
        }

        // Background L0 path: same target-level rule as the forced
        // path — climb to L1 by default, but stay at the highest input
        // level when an OoO overlap folded an L1+ segment in.
        const target_level = targetLevelForInputs(input_segs.items, 0);
        try self.runMergeAndCommit(io, input_segs.items, new_seg_id, target_level);
    }

    /// Background L1->L2 compaction worker body (P-COMP-002).
    ///
    /// Folds every L1 segment into a single L2 segment when the L1
    /// count crosses `kL1CompactionThreshold`. Without this trigger,
    /// L1 segments accumulate one-per-L0-fan-in and every query pays
    /// a linearly-growing segment-scan cost over the engine lifetime.
    ///
    /// L2->L3+ is not yet implemented; the same pattern can extend
    /// upward once an L2 trigger threshold becomes useful.
    ///
    /// Overlap-awareness: like L0->L1, we fold in any higher-level
    /// (L2+) segment whose timestamp range intersects the chosen L1
    /// set. Today no L2+ segments exist outside this path so the
    /// overlap fold is a no-op on the first pass; on subsequent
    /// passes it keeps the OoO reconciliation invariant intact.
    fn compactL1(self: *Engine) !void {
        const io = self.io;

        var input_segs = std.ArrayList(manifest.SegmentMeta).empty;
        defer input_segs.deinit(self.allocator);
        var new_seg_id: u64 = 0;
        var l1_count: usize = 0;

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            for (self.man.segments.items) |seg| {
                if (seg.level == 1) l1_count += 1;
            }
            if (l1_count < kL1CompactionThreshold) return;

            try self.collectOverlappingInputsLocked(.{ .source_level = 1, .require_source = true }, &input_segs);
            if (input_segs.items.len == 0) return;
            new_seg_id = self.man.getNextSegmentId();
        }

        const target_level = targetLevelForInputs(input_segs.items, 1);
        try self.runMergeAndCommit(io, input_segs.items, new_seg_id, target_level);
    }

    /// Pure helper that computes the canonical output level for a
    /// completed compaction pass given the input segment set and the
    /// nominal "source" level the pass started from.
    ///
    /// Rules:
    ///   * Pure-source merge -> source+1 (standard tier promotion).
    ///   * Any input above source (folded in via the OoO overlap
    ///     scan) -> stay at the HIGHEST input level so the reconciled
    ///     segment replaces the older sibling at the same tier
    ///     rather than climbing the level ladder unboundedly with
    ///     every OoO arrival.
    fn targetLevelForInputs(inputs: []const manifest.SegmentMeta, source_level: u8) u8 {
        var max_level: u8 = source_level;
        for (inputs) |seg| {
            if (seg.level > max_level) max_level = seg.level;
        }
        // Pure-source: promote one tier. Mixed: stay at the highest
        // observed level (no unbounded climb on OoO overlap).
        return if (max_level == source_level) source_level + 1 else max_level;
    }

    /// Selection policy for `collectOverlappingInputsLocked`.
    ///
    /// `source_level` is the tier whose segments are unconditionally
    /// pulled in as the primary inputs (L0 for the original
    /// background path; L1 for the P-COMP-002 path). Any segment at a
    /// HIGHER level whose `[min_ts, max_ts]` overlaps the source
    /// range is folded into the merge too — this preserves the OoO
    /// reconciliation invariant across tier boundaries.
    ///
    /// When `require_source` is true the selection aborts if no
    /// source-level segment is present (background-worker policy:
    /// the trigger gated on a non-zero count). When false, an empty
    /// source set is acceptable (forced-compaction operator policy).
    const InputSelection = struct {
        source_level: u8,
        require_source: bool,
    };

    /// Collect the input segment set for a compaction pass
    /// (GAP-0010, generalised in P-COMP-002 to non-zero source
    /// levels). Selects every segment at `policy.source_level`, then
    /// expands the set with any HIGHER-level segment that overlaps
    /// the chosen range. The result is sorted by segment id
    /// ASCENDING (oldest first) so the downstream `MergeIterator`'s
    /// same-(ts, value) tie semantics put the newer LSN's point
    /// last, which the compactor's per-ts dedup loop then overwrites
    /// with — net behaviour: last-write-wins under cross-segment
    /// OoO writes, regardless of which tiers are being merged.
    ///
    /// Caller MUST hold `self.mu`.
    fn collectOverlappingInputsLocked(
        self: *Engine,
        policy: InputSelection,
        out: *std.ArrayList(manifest.SegmentMeta),
    ) !void {
        // First pass: collect source-level segments and bracket their
        // timestamp range.
        var src_min: i64 = std.math.maxInt(i64);
        var src_max: i64 = std.math.minInt(i64);
        var src_count: usize = 0;
        for (self.man.segments.items) |seg| {
            if (seg.level == policy.source_level) {
                try out.append(self.allocator, seg);
                if (seg.min_ts < src_min) src_min = seg.min_ts;
                if (seg.max_ts > src_max) src_max = seg.max_ts;
                src_count += 1;
            }
        }

        if (policy.require_source and src_count == 0) return;

        // Second pass: any HIGHER-level segment overlapping the
        // source range gets folded in. The "overlap" test is the
        // standard closed-interval intersection: NOT (other.max <
        // src_min OR other.min > src_max). When there is no source
        // segment (forced path on an empty source tier), there's
        // nothing to overlap with, so the higher-level pass is a
        // no-op.
        if (src_count > 0) {
            for (self.man.segments.items) |seg| {
                if (seg.level <= policy.source_level) continue;
                const overlaps = !(seg.max_ts < src_min or seg.min_ts > src_max);
                if (overlaps) try out.append(self.allocator, seg);
            }
        }

        // Sort by segment id ASCENDING so older LSNs come first.
        // The compactor's per-(ts) dedup overwrites with later
        // arrivals, so later (higher) segment ids win — i.e.
        // newest-write-wins. This is the OoO reconciliation rule.
        std.mem.sort(manifest.SegmentMeta, out.items, {}, struct {
            fn lessThan(_: void, a: manifest.SegmentMeta, b: manifest.SegmentMeta) bool {
                return a.id < b.id;
            }
        }.lessThan);
    }

    /// Run the actual merge and commit the result to the manifest.
    /// Hoisted out of `compactL0` / `compactL0Forced` so both paths
    /// share the same disk I/O, manifest swap, and cleanup body.
    ///
    /// P-LOCK-004 (Partial): the heavy work — opening input readers,
    /// running the compactor, writing+fsyncing the output segment —
    /// already runs OUTSIDE `engine.mu`. The residual cost inside
    /// the lock is the segment-list swap plus `man.save()` (a tmp-
    /// write + fsync + rename of the manifest slot). Moving the
    /// `man.save()` fsync outside the lock requires a manifest COW
    /// refactor (clone-and-publish) so the on-disk swap can happen
    /// against a stable local snapshot while concurrent
    /// flush/prune/compaction still see a coherent in-memory
    /// manifest. That COW is deferred (still XL; documented under
    /// P-LOCK-001 in `docs/PERF_GAP_ANALYSIS.md`); when it lands,
    /// the swap-and-save block below can split into two phases —
    /// stage outside the lock, publish under a brief reacquire.
    fn runMergeAndCommit(
        self: *Engine,
        io: std.Io,
        input_segs: []const manifest.SegmentMeta,
        new_seg_id: u64,
        target_level: u8,
    ) !void {
        var paths = std.ArrayList([]const u8).empty;
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }

        var min_ts: i64 = std.math.maxInt(i64);
        var max_ts: i64 = std.math.minInt(i64);
        for (input_segs) |seg| {
            const p = try segment.segmentPath(self.allocator, self.config.data_dir, seg.id);
            try paths.append(self.allocator, p);
            if (seg.min_ts < min_ts) min_ts = seg.min_ts;
            if (seg.max_ts > max_ts) max_ts = seg.max_ts;
        }

        const out_path = try segment.segmentPath(self.allocator, self.config.data_dir, new_seg_id);
        defer self.allocator.free(out_path);

        // GAP-0001: encryption descriptor for the compactor (no-op
        // when no key is configured).
        const in_seg_ids = try self.allocator.alloc(u64, input_segs.len);
        defer self.allocator.free(in_seg_ids);
        for (input_segs, 0..) |seg, i| in_seg_ids[i] = seg.id;
        const enc = try self.buildCompactionEncryption(in_seg_ids, new_seg_id);
        defer if (enc) |e| self.allocator.free(e.inputs);

        var compactor = compaction.Compactor.init(self.allocator, self.pool);
        try compactor.compactSegmentsWithEncryption(paths.items, out_path, enc);

        // Set of input segment IDs for the manifest swap.
        var compacted_ids = std.AutoHashMap(u64, void).init(self.allocator);
        defer compacted_ids.deinit();
        try compacted_ids.ensureTotalCapacity(@intCast(input_segs.len));
        for (input_segs) |seg| compacted_ids.putAssumeCapacity(seg.id, {});

        // Output level rule (P-COMP-002 generalisation):
        //   * The caller supplies `target_level` based on which tier
        //     it set out to compact (`targetLevelForInputs`). This is
        //     `source+1` for a pure-source pass, or the highest input
        //     level when an OoO overlap folded a higher-tier segment
        //     in (so the reconciled segment replaces the older
        //     sibling at the same tier rather than climbing the
        //     ladder unboundedly).
        //   * Defensive floor: never DEMOTE below the highest input
        //     level. A future caller bug that under-counts the
        //     target would otherwise create a stranded
        //     lower-tier segment that compaction never picks up.
        var out_level: u8 = target_level;
        for (input_segs) |seg| {
            if (seg.level > out_level) out_level = seg.level;
        }

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
                .level = out_level,
            });

            self.man.segments.deinit(self.allocator);
            self.man.segments = new_segments;

            try self.man.save();
        }

        // P-IO-001: invalidate FD cache entries for the compacted
        // segments before unlinking. Refcount-safe: deferred close
        // for entries still borrowed by an in-flight query.
        for (input_segs) |seg| self.reader_cache.invalidate(io, seg.id);

        for (paths.items) |p| {
            std.Io.Dir.cwd().deleteFile(io, p) catch |err| {
                // The new compacted segment is already durable and
                // referenced by the manifest; the old segment file
                // is now an orphan on disk. Surface the failure so
                // operators can find and reclaim the leak via
                // `lastBackgroundError` / `error_callback` instead
                // of silently dropping it on the floor.
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
        const io = self.io;

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

        // P-IO-001: invalidate FD cache entries for the pruned
        // segments before unlinking. Cache invalidate is refcount-
        // safe — in-flight queries finish on the live FD, then the
        // cache slot is reclaimable on the next eviction round.
        for (doomed_ids.items) |id| self.reader_cache.invalidate(io, id);

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
        const io = self.io;

        // GAP-0002 / SEC-007: route through the pluggable authoriser
        // BEFORE any segment reader is acquired or memtable scanned.
        // A denied check returns immediately; no iterator is
        // allocated, no FD cache slot is touched, and no counter is
        // bumped (the counter bump is gated behind a successful
        // return).
        if (self.config.access_controller) |ac| {
            try ac.check(ac.ctx, .query, series_id);
        }

        // P-OBS-001: latency timer. Covers iterator setup +
        // memtable scan + every segment open/decode. Iteration
        // performed by the caller after we return is NOT included.
        const t_start = nowMonotonicNs();
        var points_added: u64 = 0;

        const merge_it = try arena.create(iterator.MergeIterator);
        merge_it.* = iterator.MergeIterator.init(arena);

        // P-LOCK-001 / P-LOCK-003 manifest COW: acquire a refcounted
        // immutable snapshot of the segment list, lock-free. The
        // returned `*Snapshot` is stable for the lifetime of the ref
        // — concurrent writers may stage and publish NEW snapshots
        // but our view remains coherent until we `release()`.
        //
        // queryPoints no longer holds engine.mu at all on the
        // manifest-read path. The memtable drain still takes
        // engine.mu briefly (to guarantee POINTER lifetime against
        // the flush worker's `destroy(flushing_mem)`); the per-shard
        // mutex inside each memtable continues to serialise the
        // copy out against concurrent inserts.
        const man_snap = self.man.snapshot();
        defer man_snap.release();

        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            // Memtables are drained under `engine.mu` so the
            // flushing memtable cannot be freed by the flush worker
            // (which also takes `engine.mu` for the final destroy)
            // mid-scan. The per-shard mutex inside each memtable
            // still serialises against concurrent `appendPoints` —
            // we hold `engine.mu` only to guarantee POINTER lifetime
            // here, not to exclude writers. Concurrent writes
            // remain lock-free against engine.mu and contend only
            // on the per-shard mutex they touch.
            try queryMemtable(arena, self.active_mem.load(.acquire), series_id, start_ts, end_ts, merge_it, &points_added);
            if (self.flushing_mem) |fm| {
                try queryMemtable(arena, fm, series_id, start_ts, end_ts, merge_it, &points_added);
            }
        }

        // Iterate the manifest snapshot WITHOUT the engine lock.
        // Concurrent appends, flushes, and compactions are now free
        // to run. Compaction's invalidate() / our cache's refcount
        // guard ensure readers we are using cannot be closed under
        // us.
        for (man_snap.segments) |seg| {
            if (seg.min_ts > end_ts or seg.max_ts < start_ts) continue;
            try self.querySegment(arena, io, seg, series_id, start_ts, end_ts, merge_it, &points_added);
        }

        // Counters are atomic (P-LOCK-005 partial); no lock needed.
        _ = self.counters.query_count.fetchAdd(1, .release);
        _ = self.counters.query_points_returned.fetchAdd(points_added, .release);
        _ = self.counters.query_total_ns.fetchAdd(nowMonotonicNs() - t_start, .release);
        return merge_it;
    }

    /// Drain points for `series_id` in `[start_ts, end_ts]` from a
    /// memtable into `merge_it`. Allocates the filtered slice on the
    /// supplied arena.
    ///
    /// P-LOCK-005: the memtable's `copySortedPoints` takes the
    /// relevant shard mutex internally, lazy-sorts the per-series
    /// list on demand (P-ALGO-003), and copies the snapshot into
    /// caller-supplied arena memory. The shard mutex serialises
    /// against concurrent `appendPoints` targeting the same shard;
    /// inserts on other shards proceed in parallel.
    fn queryMemtable(
        arena: Allocator,
        mem: *memtable.Memtable,
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        merge_it: *iterator.MergeIterator,
        points_added: *u64,
    ) !void {
        var sorted_buf = std.ArrayListUnmanaged(types.Point).empty;
        // sorted_buf lives in arena memory; no explicit deinit.
        try mem.copySortedPoints(series_id, arena, &sorted_buf);
        if (sorted_buf.items.len == 0) return;

        var filtered_pts = std.ArrayListUnmanaged(types.Point).empty;
        for (sorted_buf.items) |pt| {
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
        io: std.Io,
        seg: manifest.SegmentMeta,
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        merge_it: *iterator.MergeIterator,
        points_added: *u64,
    ) !void {
        const p = try segment.segmentPath(self.allocator, self.config.data_dir, seg.id);
        defer self.allocator.free(p);

        // P-IO-001 / P-MEM-006: borrow a cached reader instead of
        // opening from scratch. Cache lookup is O(1) under its own
        // mutex; the engine lock is NOT held here.
        const reader_ptr = self.reader_cache.acquire(io, seg.id, p, self.segmentEncryptionContext(seg.id)) catch |err| switch (err) {
            // Benign race with compaction: the segment was just
            // unlinked but the in-memory manifest snapshot we
            // captured still references it. Skip.
            error.FileNotFound => return,
            else => return err,
        };
        defer self.reader_cache.release(io, seg.id);

        // P-ALGO-001 (partial): consult the segment's optional footer
        // index first. When present + the series has an entry, jump
        // directly to the first matching block and cap the scan at
        // the recorded block_count. When absent (legacy segment) or
        // the series is not present (also a fast O(log series) NO),
        // fall back to the existing full-scan loop unchanged.
        var block_it = reader_ptr.iterator();
        var remaining_blocks: ?u32 = null;
        if (reader_ptr.findSeries(series_id)) |hit| {
            block_it.offset = hit.offset;
            remaining_blocks = hit.count;
        } else if (reader_ptr.footer != null) {
            // Footer present and the series is not indexed -> the
            // segment provably has no blocks for `series_id`. Skip
            // the entire segment without a single header read.
            return;
        }

        while (true) {
            if (remaining_blocks) |rem| {
                if (rem == 0) break;
            }
            const maybe_block = try block_it.next();
            const block = maybe_block orelse break;
            if (remaining_blocks) |rem| remaining_blocks = rem - 1;

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
        const io = self.io;
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

test "Engine: appendPoints round-trips multiple variable-sized batches (P-LOCK-005)" {
    // Post-P-LOCK-005 the engine no longer reuses an internal scratch
    // buffer for the WAL payload (the single-owner contract required
    // `engine.mu`, which serialised all writers — see encodeAppend-
    // PointsPayload's comment). Each appendPoints allocates and frees
    // its own buffer. The behavioural contract this test enforces is
    // the same as the old P-MEM-003 test: multiple variable-sized
    // batches in a row round-trip cleanly through the WAL.
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

    // Three batches of different sizes — small, smaller, bigger.
    try engine.appendPoints(1, &.{
        .{ .ts = 1, .value = 10 },
        .{ .ts = 2, .value = 20 },
        .{ .ts = 3, .value = 30 },
        .{ .ts = 4, .value = 40 },
    });
    try engine.appendPoints(2, &.{.{ .ts = 5, .value = 50 }});
    var bigger: [16]types.Point = undefined;
    for (&bigger, 0..) |*p, i| p.* = .{ .ts = @intCast(100 + i), .value = @intCast(i) };
    try engine.appendPoints(3, &bigger);

    // Verify the points round-trip cleanly via query — no
    // payload encoding corruption.
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

        try std.testing.expectEqual(@as(usize, 3), eng.active_mem.load(.acquire).point_count.load(.acquire));

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 7, 0, 100);
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 3), count);
    }
}

test "Engine: reopening with a different key fails closed (GAP-0001)" {
    // Post-GAP-0001 (manifest TDE), opening with the wrong key fails
    // CLOSED at the manifest layer rather than silently degrading
    // to "WAL records silently dropped". This is the correct
    // security contract: an attacker who possesses the on-disk
    // bytes without the key must not be able to bring the engine
    // up at all, because doing so could:
    //   * issue a new save() that clobbers the legitimate manifest,
    //   * accept new appends that are unrelated to the existing
    //     series namespace.
    // The pre-Manifest-TDE behaviour (engine opens, memtable empty)
    // is replaced by an explicit `error.DecryptionFailed`.
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

    // Phase 1: write under key_a, sync (which writes the encrypted
    // manifest), close.
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

    // Phase 2: reopen with key_b — must fail closed.
    try std.testing.expectError(error.DecryptionFailed, Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = key_b,
    }, &pool));
}

test "Engine: reopening an encrypted manifest with no key fails closed (GAP-0001)" {
    // Symmetric to the wrong-key case: opening an encrypted
    // (TSMNF002) manifest with no key must also fail closed, NOT
    // silently downgrade to "engine starts empty". This is the
    // contract that protects against an attacker who learns the
    // data_dir path but does not possess the key — they cannot
    // bring the engine up and start fresh on top of the existing
    // ciphertext slots.
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

    // Reopen without a key: manifest decryption fails before any
    // WAL is touched, so the call returns DecryptionFailed.
    try std.testing.expectError(error.DecryptionFailed, Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .encryption_key = null,
    }, &pool));
}

test "Engine: AccessController denies appendPoints with AccessDenied (GAP-0002 / SEC-007)" {
    // Wires DenyAllAccessController and proves:
    //   1. appendPoints surfaces error.AccessDenied,
    //   2. NO WAL record was written (the seam runs before any
    //      mutation),
    //   3. counters did not bump (also gated behind the seam).
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
        .access_controller = DenyAllAccessController,
    }, &pool);
    defer engine.deinit();

    try std.testing.expectError(
        error.AccessDenied,
        engine.appendPoints(1, &.{.{ .ts = 1, .value = 1 }}),
    );

    // No state mutation, no counter bump.
    const stats = engine.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.append_count);
    try std.testing.expectEqual(@as(u64, 0), stats.append_points);
    try std.testing.expectEqual(@as(usize, 0), engine.active_mem.load(.acquire).point_count.load(.acquire));
}

test "Engine: AccessController denies queryPoints with AccessDenied (GAP-0002 / SEC-007)" {
    // Symmetric coverage for the read path.
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
        .access_controller = DenyAllAccessController,
    }, &pool);
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.AccessDenied,
        engine.queryPoints(arena.allocator(), 1, 0, 100),
    );

    // No counter bump on a denied query either.
    const stats = engine.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.query_count);
}

test "Engine: PermissiveAccessController allows operations (GAP-0002 / SEC-007)" {
    // Confirms the explicit allow-all reference implementation is
    // a no-op functionally — appends succeed, queries return data.
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
        .access_controller = PermissiveAccessController,
    }, &pool);
    defer engine.deinit();

    try engine.appendPoints(1, &.{
        .{ .ts = 1, .value = 11 },
        .{ .ts = 2, .value = 22 },
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try engine.queryPoints(arena.allocator(), 1, 0, 100);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Engine: AccessController receives the correct op and series_id (GAP-0002)" {
    // Captures the (op, series_id) the engine actually passes into
    // the controller. This is the contract the caller relies on
    // when implementing per-tenant ACL lookups.
    const Trace = struct {
        var last_op: AccessOp = .append;
        var last_series_id: types.SeriesId = 0;
        var call_count: usize = 0;

        fn check(_: ?*anyopaque, op: AccessOp, series_id: types.SeriesId) anyerror!void {
            call_count += 1;
            last_op = op;
            last_series_id = series_id;
        }

        fn reset() void {
            call_count = 0;
            last_series_id = 0;
        }
    };
    Trace.reset();

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
        .access_controller = .{ .ctx = null, .check = Trace.check },
    }, &pool);
    defer engine.deinit();

    const series: types.SeriesId = 0xDEADBEEF_CAFE_1234;
    try engine.appendPoints(series, &.{.{ .ts = 1, .value = 11 }});
    try std.testing.expectEqual(@as(usize, 1), Trace.call_count);
    try std.testing.expectEqual(AccessOp.append, Trace.last_op);
    try std.testing.expectEqual(series, Trace.last_series_id);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try engine.queryPoints(arena.allocator(), series, 0, 100);
    try std.testing.expectEqual(@as(usize, 2), Trace.call_count);
    try std.testing.expectEqual(AccessOp.query, Trace.last_op);
    try std.testing.expectEqual(series, Trace.last_series_id);
}

test "opaqueSeriesId: deterministic and key-binding (GAP-0002 / SEC-008)" {
    const key_a: [32]u8 = [_]u8{0x11} ** 32;
    const key_b: [32]u8 = [_]u8{0x22} ** 32;

    // 1. Determinism: same inputs produce the same SeriesId.
    const id1 = opaqueSeriesId(42, 7, key_a);
    const id2 = opaqueSeriesId(42, 7, key_a);
    try std.testing.expectEqual(id1, id2);

    // 2. Key binding: different keys produce different SeriesIds
    //    even though (tenant, app_key) are identical. This is the
    //    "without the key you cannot enumerate" guarantee.
    const id3 = opaqueSeriesId(42, 7, key_b);
    try std.testing.expect(id1 != id3);

    // 3. Input separation: distinct (tenant, app_key) tuples
    //    produce distinct IDs (HMAC's PRF property).
    const id4 = opaqueSeriesId(43, 7, key_a);
    const id5 = opaqueSeriesId(42, 8, key_a);
    try std.testing.expect(id1 != id4);
    try std.testing.expect(id1 != id5);
    try std.testing.expect(id4 != id5);

    // 4. Not the identity function — caller-side input is not
    //    leaked as-is into the SeriesId.
    try std.testing.expect(id1 != @as(types.SeriesId, 42));
}

test "opaqueSeriesId: round-trips through Engine append/query (GAP-0002)" {
    // Sanity check: a SeriesId derived from opaqueSeriesId is a
    // perfectly ordinary u128 from the engine's perspective. The
    // append/query lifecycle does not depend on any structure
    // beyond u128 equality.
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

    const key: [32]u8 = [_]u8{0x42} ** 32;
    const series = opaqueSeriesId(1000, 1, key);

    try engine.appendPoints(series, &.{
        .{ .ts = 1, .value = 11 },
        .{ .ts = 2, .value = 22 },
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try engine.queryPoints(arena.allocator(), series, 0, 100);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);

    // Different tenant under the same key derives a different
    // SeriesId — the query returns no points (no enumeration).
    const other_series = opaqueSeriesId(1001, 1, key);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    var it2 = try engine.queryPoints(arena2.allocator(), other_series, 0, 100);
    try std.testing.expect(it2.next() == null);
}

test "Engine: cross-segment OoO write reconciled by compaction (GAP-0010)" {
    // End-to-end demonstration of permissive OoO mode:
    //
    //   1. Write monotonic points (ts=100, 200, 300), flush — L0
    //      segment.
    //   2. Compact L0 → L1 so the engine's "newest disk segment"
    //      is at L1.
    //   3. Write an OoO point (ts=150) that falls INSIDE the L1
    //      segment's [100..300] range. This is the cross-segment
    //      OoO case the gap describes.
    //   4. Flush — produces a new L0 segment that overlaps L1.
    //   5. compactAll → overlap-aware merge folds both segments
    //      into a single reconciled L1 segment.
    //   6. Query returns all 4 points in correct order.
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
        // permissive default
    }, &pool);
    defer engine.deinit();

    // Phase 1: monotonic batch -> L0.
    try engine.appendPoints(1, &.{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 200, .value = 2 },
        .{ .ts = 300, .value = 3 },
    });
    try engine.flush();
    try std.testing.expectEqual(@as(usize, 1), engine.man.segments.items.len);

    // Phase 2: promote L0 -> L1 so the next flush produces a
    // cross-level overlap, not just adjacent L0 overlap.
    try engine.compactAll();
    var l1_count: usize = 0;
    for (engine.man.segments.items) |seg| if (seg.level == 1) {
        l1_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), l1_count);

    // Phase 3: cross-segment OoO write.
    try engine.appendPoints(1, &.{.{ .ts = 150, .value = 99 }});
    try engine.flush();
    try std.testing.expect(engine.man.segments.items.len >= 2);

    // Phase 4: force overlap-aware compaction. Result must be
    // a single segment (the L1 absorbs the overlapping L0).
    try engine.compactAll();

    var post_l0: usize = 0;
    var post_l1: usize = 0;
    for (engine.man.segments.items) |seg| {
        if (seg.level == 0) post_l0 += 1;
        if (seg.level == 1) post_l1 += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), post_l0);
    try std.testing.expectEqual(@as(usize, 1), post_l1);

    // Phase 5: every point must be queryable in correct order.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try engine.queryPoints(arena.allocator(), 1, 0, 1_000);
    var observed = std.ArrayList(i64).empty;
    defer observed.deinit(arena.allocator());
    while (it.next()) |pt| try observed.append(arena.allocator(), pt.ts);

    try std.testing.expectEqual(@as(usize, 4), observed.items.len);
    try std.testing.expectEqual(@as(i64, 100), observed.items[0]);
    try std.testing.expectEqual(@as(i64, 150), observed.items[1]);
    try std.testing.expectEqual(@as(i64, 200), observed.items[2]);
    try std.testing.expectEqual(@as(i64, 300), observed.items[3]);
}

test "Engine: cross-segment OoO with same-timestamp collision resolves last-write-wins (GAP-0010)" {
    // Two writers race the same (series_id, ts) but produce
    // different values. The newer write must win — that is the
    // documented dedup semantics under cross-segment OoO.
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

    // Older segment claims (ts=100, value=1).
    try engine.appendPoints(7, &.{.{ .ts = 100, .value = 1 }});
    try engine.flush();
    try engine.compactAll();

    // Newer segment writes (ts=100, value=999). This is the
    // overlap case: same ts as a sealed L1 segment.
    try engine.appendPoints(7, &.{.{ .ts = 100, .value = 999 }});
    try engine.flush();

    try engine.compactAll();

    // The query MUST yield exactly one point at ts=100 with the
    // newer value. Two points would mean dedup failed; the older
    // value would mean tie-break direction is reversed.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try engine.queryPoints(arena.allocator(), 7, 0, 1_000);
    var count: usize = 0;
    var last_value: i64 = 0;
    while (it.next()) |pt| {
        count += 1;
        last_value = pt.value;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(i64, 999), last_value);
}

test "Engine: strict OoO mode rejects out-of-order point (GAP-0010)" {
    // allow_cross_segment_ooo = false: any point whose ts falls
    // before the running per-series watermark must be rejected,
    // with no on-disk or in-memory state change.
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
        .allow_cross_segment_ooo = false,
    }, &pool);
    defer engine.deinit();

    try engine.appendPoints(1, &.{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 200, .value = 2 },
    });

    // OoO arrival.
    try std.testing.expectError(
        error.OutOfOrderTimestamp,
        engine.appendPoints(1, &.{.{ .ts = 150, .value = 99 }}),
    );

    // The rejected batch left no trace. Two points present, both
    // monotonic, no watermark drift.
    const stats = engine.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.append_count);
    try std.testing.expectEqual(@as(u64, 2), stats.append_points);

    // Monotonic continuation still works.
    try engine.appendPoints(1, &.{.{ .ts = 300, .value = 3 }});
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

test "SegmentReaderCache: acquire returns the same reader on hit (P-IO-001)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/test.tsseg", .{base});
    defer allocator.free(path);

    {
        var w = try segment.SegmentWriter.init(allocator, path);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    var cache = SegmentReaderCache.init(allocator, 8);
    defer cache.deinit();

    const a = try cache.acquire(io, 42, path, null);
    const b = try cache.acquire(io, 42, path, null);
    // Same pointer = same cached reader; no double-open.
    try std.testing.expectEqual(@intFromPtr(a), @intFromPtr(b));
    cache.release(io, 42);
    cache.release(io, 42);
}

test "SegmentReaderCache: invalidate closes the entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/test.tsseg", .{base});
    defer allocator.free(path);

    {
        var w = try segment.SegmentWriter.init(allocator, path);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    var cache = SegmentReaderCache.init(allocator, 8);
    defer cache.deinit();

    _ = try cache.acquire(io, 7, path, null);
    cache.release(io, 7);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());

    cache.invalidate(io, 7);
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
}

test "SegmentReaderCache: invalidate defers close for borrowed entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/test.tsseg", .{base});
    defer allocator.free(path);

    {
        var w = try segment.SegmentWriter.init(allocator, path);
        defer w.deinit();
        try w.writeBlock(1, &.{.{ .ts = 1, .value = 1 }});
        try w.sync();
    }

    var cache = SegmentReaderCache.init(allocator, 8);
    defer cache.deinit();

    _ = try cache.acquire(io, 7, path, null);
    // Don't release yet — borrowed.
    cache.invalidate(io, 7);
    // Entry must still be present (deferred close).
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
    cache.release(io, 7);
}

test "Engine: TDE — manifest is encrypted (TSMNF002) when key is set (GAP-0001)" {
    // Post-Phase-G the engine's manifest persistence is also under
    // AES-256-GCM. We assert the on-disk magic to prove the
    // encrypted wrapper actually wraps; if a regression flipped the
    // path back to plaintext we would see the TSMNFS01 magic here
    // and the test would fail before reaching the decrypt-roundtrip
    // body.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key: [32]u8 = [_]u8{0x77} ** 32;
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 100,
            .encryption_key = key,
        }, &pool);
        defer eng.deinit();
        try eng.appendPoints(1, &.{.{ .ts = 1, .value = 1 }});
        try eng.sync();
    }

    // Locate whichever slot file is on disk and inspect its magic.
    // We try both .a and .b since the parity-driven save() picks one.
    var found_v2_magic = false;
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |name| {
        const mf_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, name });
        defer allocator.free(mf_path);
        const f = std.Io.Dir.cwd().openFile(io, mf_path, .{}) catch continue;
        defer f.close(io);
        var magic_buf: [8]u8 = undefined;
        const n = try f.readPositionalAll(io, &magic_buf, 0);
        if (n == 8 and std.mem.eql(u8, &magic_buf, &manifest.MANIFEST_MAGIC_V2)) {
            found_v2_magic = true;
            break;
        }
    }
    try std.testing.expect(found_v2_magic);
}

test "Engine: TDE end-to-end — write encrypted, reopen with same key, query (GAP-0001)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    const key: [32]u8 = [_]u8{0x42} ** 32;

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: write some data with a key and flush so a v3 segment hits disk.
    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 100,
            .encryption_key = key,
        }, &pool);
        defer eng.deinit();

        try eng.appendPoints(1, &.{
            .{ .ts = 1, .value = 11 },
            .{ .ts = 2, .value = 22 },
            .{ .ts = 3, .value = 33 },
        });
        try eng.flush();
        try std.testing.expect(eng.man.segments.items.len >= 1);
    }

    // Phase 2: reopen with the SAME key and query.
    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 100,
            .encryption_key = key,
        }, &pool);
        defer eng.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 1, 0, 1000);
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 3), count);
    }
}

test "Engine: TDE — reopening encrypted segments with wrong key surfaces DecryptionFailed (GAP-0001)" {
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

    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 100,
            .encryption_key = key_a,
        }, &pool);
        defer eng.deinit();
        try eng.appendPoints(1, &.{.{ .ts = 1, .value = 1 }});
        try eng.flush();
    }

    // Reopen with the wrong key. Post-Manifest-TDE this fails at
    // open time (manifest decryption layer) rather than at query
    // time (segment decryption layer). The earlier failure point
    // is strictly safer — an attacker without the key cannot even
    // bring the engine up to attempt a query.
    try std.testing.expectError(error.DecryptionFailed, Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 100,
        .encryption_key = key_b,
    }, &pool));
}

test "Engine: per_call durability mode survives crash without explicit sync (P-IO-002)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: write in per_call mode, close WITHOUT calling sync().
    // The per_call contract is "every appendPoints fsyncs on return"
    // — so a subsequent reopen must see the data even though sync()
    // was never explicitly invoked.
    {
        var eng = try Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .durability_mode = .per_call,
        }, &pool);
        defer eng.deinit();

        try eng.appendPoints(1, &.{ .{ .ts = 1, .value = 11 }, .{ .ts = 2, .value = 22 } });
        // NOTE: NO eng.sync() call. per_call mode promises durability
        // already happened inside appendPoints.
    }

    // Phase 2: reopen and check that both points were replayed.
    var eng2 = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .durability_mode = .per_call,
    }, &pool);
    defer eng2.deinit();

    try std.testing.expectEqual(@as(usize, 2), eng2.active_mem.load(.acquire).point_count.load(.acquire));
}

test "Engine: batch durability mode background syncer drains the WAL (P-IO-002)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
        .durability_mode = .batch,
        // Short interval so the test does not sit on the CI clock.
        .wal_sync_interval_ms = 10,
    }, &pool);
    defer eng.deinit();

    try eng.startBackgroundSyncer();
    // The syncer thread is running by the time startBackgroundSyncer
    // returns — Thread.spawn does not race the callee.
    try std.testing.expect(eng.syncer_thread != null);

    try eng.appendPoints(1, &.{.{ .ts = 1, .value = 1 }});
    // Wait long enough for the syncer to have tripped at least once.
    std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};

    // Force an explicit sync as well to demonstrate the two paths
    // don't interfere. deinit() will join the syncer.
    try eng.sync();
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
