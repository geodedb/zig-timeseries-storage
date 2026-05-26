// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
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

/// Canonical engine configuration. The only configuration surface a
/// caller needs to construct an `Engine`. Replaces both the template
/// `root.Config` (removed in Phase B-1) and the unused `types.StoreConfig`.
pub const EngineConfig = struct {
    /// Filesystem directory where the manifest, WAL, and segment files
    /// live. Must exist before `Engine.init`; the engine does not create
    /// it for you (the CLI / example wrappers do).
    data_dir: []const u8,
    /// Soft limit on the number of points held in the active memtable
    /// before a background flush is triggered. Higher values amortize
    /// flush cost but increase peak memory and replay time after a crash.
    max_memtable_points: usize = 100_000,
    /// When true, the WAL identity file (`ts.uuid`) is created on first
    /// open. When false, opening a fresh `data_dir` without an existing
    /// identity returns `error.FileNotFound`.
    create_identity_if_missing: bool = true,
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
    lock: std.Io.RwLock = std.Io.RwLock.init,
    allocator: Allocator,
    config: EngineConfig,
    wal: wal_manager.WalManager,
    man: manifest.Manifest,
    active_mem: memtable.Memtable,
    flushing_mem: ?memtable.Memtable = null,
    pool: *thread_pool.ThreadPool,
    compaction_running: bool = false,

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
        const man = try manifest.Manifest.init(allocator, config.data_dir);

        const io = std.Io.Threaded.global_single_threaded.io();
        const wal_dir = try std.Io.Dir.cwd().openDir(io, config.data_dir, .{});
        var wal = try wal_manager.WalManager.init(allocator, wal_dir, man.ts_uuid, man.last_checkpoint_lsn, .{
            .create_identity_if_missing = config.create_identity_if_missing,
        });

        var mem = memtable.Memtable.init(allocator, config.max_memtable_points);

        // Simple recovery: Replay WAL into memtable
        // In a production engine, WAL records would be replayed since the last manifest checkpoint.
        // For now, we will simply stream through WAL records and re-apply them.
        const records = try wal.readFrom(man.last_checkpoint_lsn + 1, allocator);
        defer {
            for (records) |*r| r.deinit(allocator);
            allocator.free(records);
        }
        for (records) |rec| {
            if (rec.record_type == .append_points) {
                if (rec.payload.len < 16 or (rec.payload.len - 16) % 16 != 0) continue;

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
        }

        return Engine{
            .allocator = allocator,
            .config = config,
            .wal = wal,
            .man = man,
            .active_mem = mem,
            .pool = pool,
        };
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

        // Wait for all background tasks to finish
        while (true) {
            self.lock.lockSharedUncancelable(io);
            const done = (self.flushing_mem == null and !self.compaction_running);
            self.lock.unlockShared(io);
            if (done) break;
            std.Thread.yield() catch {};
        }

        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
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

        const payload_size = 16 + (points.len * 16);
        const payload = try self.allocator.alloc(u8, payload_size);
        defer self.allocator.free(payload);

        std.mem.writeInt(u128, payload[0..16], series_id, .little);
        var pos: usize = 16;
        for (points) |pt| {
            std.mem.writeInt(i64, payload[pos..][0..8], pt.ts, .little);
            pos += 8;
            std.mem.writeInt(i64, payload[pos..][0..8], pt.value, .little);
            pos += 8;
        }

        var rec = wal_record.WalRecord{
            .lsn = 0,
            .record_type = .append_points,
            .payload = payload,
            .checksum = 0,
        };

        const io = std.Io.Threaded.global_single_threaded.io();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        // Capture the assigned LSN. We do not surface it from
        // appendPoints today, but having it bound to a named local
        // (rather than discarded with `_ = try ...`) makes it
        // trivially available for the in-memory watermark / future
        // ack-on-commit work referenced by manifest.last_checkpoint_lsn.
        // TODO: thread `lsn` into a per-call ack / return value when
        // the public API grows a "wait until durable" surface.
        const lsn = try self.wal.appendRecord(&rec);
        _ = lsn;

        // Write to Memtable
        try self.active_mem.insert(series_id, points);

        while (self.active_mem.shouldFlush() and self.flushing_mem != null) {
            self.lock.unlock(io);
            std.Thread.yield() catch {};
            self.lock.lockUncancelable(io);
        }

        if (self.active_mem.shouldFlush()) {
            self.flushing_mem = self.active_mem;
            self.active_mem = memtable.Memtable.init(self.allocator, self.config.max_memtable_points);
            _ = self.pool.submit(flushWorker, self, .{}) catch |err| {
                self.flushing_mem.?.deinit();
                self.flushing_mem = null;
                return err;
            };
        }
    }

    fn flushWorker(ctx: *anyopaque, _: *thread_pool.TaskContext) void {
        var self: *Engine = @ptrCast(@alignCast(ctx));
        self.flushInternal() catch |err| {
            std.debug.print("Background flush failed: {any}\n", .{err});
            const io = std.Io.Threaded.global_single_threaded.io();
            self.lock.lockUncancelable(io);
            if (self.flushing_mem) |*fm| fm.deinit();
            self.flushing_mem = null;
            self.lock.unlock(io);
        };
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
        self.lock.lockUncancelable(io);
        if (self.active_mem.point_count > 0) {
            while (self.flushing_mem != null) {
                self.lock.unlock(io);
                std.Thread.yield() catch {};
                self.lock.lockUncancelable(io);
            }
            self.flushing_mem = self.active_mem;
            self.active_mem = memtable.Memtable.init(self.allocator, self.config.max_memtable_points);
            _ = self.pool.submit(flushWorker, self, .{}) catch |err| {
                self.flushing_mem.?.deinit();
                self.flushing_mem = null;
                self.lock.unlock(io);
                return err;
            };
        }
        self.lock.unlock(io);

        // Wait for all flushing to complete
        while (true) {
            self.lock.lockSharedUncancelable(io);
            const done = (self.flushing_mem == null);
            self.lock.unlockShared(io);
            if (done) break;
            std.Thread.yield() catch {};
        }
    }

    fn flushInternal(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var min_ts: i64 = std.math.maxInt(i64);
        var max_ts: i64 = std.math.minInt(i64);

        self.lock.lockSharedUncancelable(io);
        var mem = self.flushing_mem orelse return;
        self.lock.unlockShared(io);

        if (mem.point_count == 0) {
            self.lock.lockUncancelable(io);
            mem.deinit();
            self.flushing_mem = null;
            self.lock.unlock(io);
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

        self.lock.lockUncancelable(io);
        const seg_id = self.man.getNextSegmentId();
        self.lock.unlock(io);

        const seg_name = try segment.segmentPath(self.allocator, self.config.data_dir, seg_id);
        defer self.allocator.free(seg_name);

        var writer = try segment.SegmentWriter.init(self.allocator, seg_name);
        defer writer.deinit();

        it = mem.series.iterator();
        while (it.next()) |entry| {
            try writer.writeBlock(entry.key_ptr.*, entry.value_ptr.items);
        }

        {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);

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
        }

        self.triggerCompaction() catch |err| {
            // A failed compaction trigger is not fatal — the flush
            // itself already succeeded and persisted a new segment.
            // Surface the failure so it shows up in logs and on stderr
            // instead of being silently dropped (the previous
            // `catch {}` could mask real bugs in the manifest walk or
            // pool submission).
            std.debug.print(
                "engine: triggerCompaction after flush failed: {s}\n",
                .{@errorName(err)},
            );
        };
    }

    fn triggerCompaction(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.lock.lockSharedUncancelable(io);
        var l0_count: usize = 0;
        for (self.man.segments.items) |seg| {
            if (seg.level == 0) l0_count += 1;
        }
        self.lock.unlockShared(io);

        if (l0_count >= kL0CompactionThreshold) {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            if (!self.compaction_running) {
                self.compaction_running = true;
                _ = self.pool.submit(compactionWorker, self, .{}) catch {
                    self.compaction_running = false;
                };
            }
        }
    }

    fn compactionWorker(ctx: *anyopaque, _: *thread_pool.TaskContext) void {
        var self: *Engine = @ptrCast(@alignCast(ctx));
        self.compactL0() catch |err| {
            std.debug.print("Background compaction failed: {any}\n", .{err});
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        self.lock.lockUncancelable(io);
        self.compaction_running = false;
        self.lock.unlock(io);
    }

    fn compactL0(self: *Engine) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        var l0_segs = std.ArrayList(manifest.SegmentMeta).empty;
        defer l0_segs.deinit(self.allocator);
        var new_seg_id: usize = 0;

        {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);

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

        {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);

            var new_segments = std.ArrayListUnmanaged(manifest.SegmentMeta).empty;
            for (self.man.segments.items) |seg| {
                var is_compacted = false;
                for (l0_segs.items) |c_seg| {
                    if (c_seg.id == seg.id) is_compacted = true;
                }
                if (!is_compacted) {
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
            std.Io.Dir.cwd().deleteFile(io, p) catch |err| {
                // The new compacted segment is already durable and
                // referenced by the manifest; the old L0 segment file
                // is now an orphan on disk. Log so operators can find
                // and reclaim the leak instead of silently dropping it
                // on the floor.
                std.debug.print(
                    "engine: orphan segment {d} ({s}) deletion failed: {s}\n",
                    .{ seg.id, p, @errorName(err) },
                );
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

        var merge_it = try arena.create(iterator.MergeIterator);
        merge_it.* = iterator.MergeIterator.init(arena);

        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        // 1. Query Active Memtable
        if (self.active_mem.series.get(series_id)) |pts| {
            var filtered_pts = std.ArrayListUnmanaged(types.Point).empty;
            for (pts.items) |pt| {
                if (pt.ts >= start_ts and pt.ts <= end_ts) {
                    try filtered_pts.append(arena, pt);
                }
            }
            if (filtered_pts.items.len > 0) {
                var slice_it = try arena.create(iterator.SliceIterator);
                slice_it.* = .{ .slice = try filtered_pts.toOwnedSlice(arena) };
                try merge_it.addIterator(slice_it.iterator());
            }
        }

        // 2. Query Flushing Memtable
        if (self.flushing_mem) |mem| {
            if (mem.series.get(series_id)) |pts| {
                var filtered_pts = std.ArrayListUnmanaged(types.Point).empty;
                for (pts.items) |pt| {
                    if (pt.ts >= start_ts and pt.ts <= end_ts) {
                        try filtered_pts.append(arena, pt);
                    }
                }
                if (filtered_pts.items.len > 0) {
                    var slice_it = try arena.create(iterator.SliceIterator);
                    slice_it.* = .{ .slice = try filtered_pts.toOwnedSlice(arena) };
                    try merge_it.addIterator(slice_it.iterator());
                }
            }
        }

        // 3. Query Segments
        for (self.man.segments.items) |seg| {
            if (seg.min_ts > end_ts or seg.max_ts < start_ts) continue;

            const p = try segment.segmentPath(self.allocator, self.config.data_dir, seg.id);
            defer self.allocator.free(p);

            var seg_reader = segment.SegmentReader.init(self.allocator, p) catch continue;
            defer seg_reader.deinit();

            var block_it = seg_reader.iterator();
            while (block_it.next() catch null) |block| {
                if (block.header.series_id != series_id) continue;
                if (block.header.stats.max_ts < start_ts) continue;
                if (block.header.stats.min_ts > end_ts) continue;

                if (block.decodePoints(arena) catch null) |pts| {
                    var filtered_pts = std.ArrayListUnmanaged(types.Point).empty;
                    for (pts) |pt| {
                        if (pt.ts >= start_ts and pt.ts <= end_ts) {
                            filtered_pts.append(arena, pt) catch continue;
                        }
                    }
                    if (filtered_pts.items.len > 0) {
                        var slice_it = try arena.create(iterator.SliceIterator);
                        slice_it.* = .{ .slice = try filtered_pts.toOwnedSlice(arena) };
                        try merge_it.addIterator(slice_it.iterator());
                    }
                }
            }
        }

        return merge_it;
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
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
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
