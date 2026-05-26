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
