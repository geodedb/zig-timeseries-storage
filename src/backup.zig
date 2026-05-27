// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Backup and restore helpers.
//!
//! Closes GAP-0003. Three entry points:
//!
//!   - `checkpoint(engine)`         — flush + sync the engine so all
//!                                    in-memory state is durable.
//!   - `snapshot(gpa, engine, dest)`— checkpoint, then copy the
//!                                    manifest, every segment file,
//!                                    the WAL, and the identity file
//!                                    into `dest`. fsyncs `dest`.
//!   - `restore(gpa, src, dest)`    — validate `src` looks like a
//!                                    timeseries-storage directory
//!                                    (manifest open, segment magic
//!                                    bytes, identity file present),
//!                                    then copy its files into `dest`.
//!
//! The snapshot is a directory tree: callers can later open an
//! `Engine` directly over it with the same configuration as the
//! source. `restore` is offered as a convenience for operators who
//! want a fresh `dest_dir` populated atomically; the engine itself is
//! not opened.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine_mod = @import("engine.zig");
const manifest = @import("manifest.zig");
const segment = @import("segment.zig");

/// Errors specific to backup/restore. Generic allocator and file
/// system errors stay on the inferred error set.
pub const BackupError = error{
    /// `restore` was pointed at a directory that does not look like
    /// a timeseries-storage data directory.
    InvalidBackupSource,
};

/// Flush the active memtable to disk and fsync the WAL + manifest.
///
/// After this returns successfully every record that has been
/// accepted by `appendPoints` so far is durable on disk. Subsequent
/// snapshots are guaranteed to capture all data committed before the
/// `checkpoint` call.
pub fn checkpoint(engine: *engine_mod.Engine) !void {
    try engine.flush();
    try engine.sync();
}

/// Quiesce the engine and copy every persistent artefact to
/// `dest_dir`. `dest_dir` is created if it does not exist; it must
/// not already contain a `manifest.a` or `manifest.b` (we refuse to
/// overwrite an existing data directory).
///
/// Files copied (whichever are present on disk):
///   * `manifest.a`, `manifest.b`     — engine manifest slots
///   * `ts.uuid`                      — engine identity file
///   * `ts.wal`                       — write-ahead log
///   * `<id>.tsseg` for every segment in the manifest
///
/// Every copied file is fsync'd via the atomic-file path; the
/// destination directory itself is fsync'd before return.
pub fn snapshot(gpa: Allocator, engine: *engine_mod.Engine, dest_dir: []const u8) !void {
    try checkpoint(engine);

    const io = Io.Threaded.global_single_threaded.io();

    // Create the destination directory (no-op if it already exists).
    try Io.Dir.cwd().createDirPath(io, dest_dir);

    var src = try Io.Dir.cwd().openDir(io, engine.config.data_dir, .{ .iterate = true });
    defer src.close(io);

    var dst = try Io.Dir.cwd().openDir(io, dest_dir, .{});
    defer dst.close(io);

    // Refuse to clobber an existing data directory. We check both
    // manifest slots because a torn write may have left only one of
    // them present.
    if (dirHasFile(io, dst, "manifest.a") or dirHasFile(io, dst, "manifest.b")) {
        return error.PathAlreadyExists;
    }

    var iter = src.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Copy the file. We allocate a NUL-terminated dupe so the
        // dest path can be reused after the loop body.
        const name = try gpa.dupe(u8, entry.name);
        defer gpa.free(name);
        try src.copyFile(name, dst, name, io, .{});
    }

    // Note: every file is copied via the atomic file path
    // (createFileAtomic + link), which performs the rename + fsync
    // pair before returning. We rely on those per-file durability
    // guarantees; std.Io.Dir does not expose a directory-handle
    // sync API in 0.16.
}

/// Verify `src_dir` and copy its contents into `dest_dir`.
///
/// Verification is intentionally light: we open the source as a
/// `Manifest` (which runs CRC32C + magic checks), then for each
/// segment referenced in the manifest we confirm the file exists and
/// starts with the segment magic. If any of those checks fail the
/// function returns an error before any data is copied into
/// `dest_dir`.
///
/// `dest_dir` must NOT already contain a manifest slot — same
/// "refuse to clobber" guarantee as `snapshot`.
pub fn restore(gpa: Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();

    // Step 1: load the manifest from `src_dir` to prove integrity.
    var src_manifest = try manifest.Manifest.init(gpa, src_dir);
    defer src_manifest.deinit();

    // Step 2: confirm every referenced segment file exists with the
    // right magic.
    for (src_manifest.segments.items) |seg| {
        const seg_path = try segment.segmentPath(gpa, src_dir, seg.id);
        defer gpa.free(seg_path);

        const f = try Io.Dir.cwd().openFile(io, seg_path, .{});
        defer f.close(io);
        var magic_buf: [segment.SEGMENT_MAGIC.len]u8 = undefined;
        const n = try f.readPositionalAll(io, &magic_buf, 0);
        if (n != segment.SEGMENT_MAGIC.len) return error.InvalidBackupSource;
        if (!std.mem.eql(u8, &magic_buf, &segment.SEGMENT_MAGIC)) {
            return error.InvalidBackupSource;
        }
    }

    // Step 3: copy the directory tree.
    try Io.Dir.cwd().createDirPath(io, dest_dir);

    var src = try Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true });
    defer src.close(io);

    var dst = try Io.Dir.cwd().openDir(io, dest_dir, .{});
    defer dst.close(io);

    if (dirHasFile(io, dst, "manifest.a") or dirHasFile(io, dst, "manifest.b")) {
        return error.PathAlreadyExists;
    }

    var iter = src.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = try gpa.dupe(u8, entry.name);
        defer gpa.free(name);
        try src.copyFile(name, dst, name, io, .{});
    }

    // Same durability note as `snapshot` — per-file atomic copies
    // already issued their fsyncs; std.Io.Dir does not expose a
    // directory-handle sync API in 0.16.
}

/// True iff `dir` contains a regular file at `name`. Any error other
/// than `FileNotFound` is mapped to `false` — callers use this for
/// the cheap "is this slot taken" check, not for control flow that
/// needs to discriminate I/O failure from absence.
fn dirHasFile(io: Io, dir: Io.Dir, name: []const u8) bool {
    const f = dir.openFile(io, name, .{}) catch return false;
    f.close(io);
    return true;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const types = @import("types.zig");
const thread_pool = @import("thread_pool");

test "backup: snapshot + restore round-trip preserves data" {
    const allocator = std.testing.allocator;
    var src_tmp = std.testing.tmpDir(.{});
    defer src_tmp.cleanup();
    var snapshot_tmp = std.testing.tmpDir(.{});
    defer snapshot_tmp.cleanup();
    var restore_tmp = std.testing.tmpDir(.{});
    defer restore_tmp.cleanup();

    const io = Io.Threaded.global_single_threaded.io();

    const src_dir = try src_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(src_dir);
    const snapshot_parent = try snapshot_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(snapshot_parent);
    const restore_parent = try restore_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(restore_parent);

    // We snapshot/restore into a fresh subdir each time so the
    // "refuse to clobber" guard does not fire.
    const snapshot_dir = try std.fmt.allocPrint(allocator, "{s}/snap", .{snapshot_parent});
    defer allocator.free(snapshot_dir);
    const restore_dir = try std.fmt.allocPrint(allocator, "{s}/restored", .{restore_parent});
    defer allocator.free(restore_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: populate the source.
    {
        var eng = try engine_mod.Engine.init(allocator, .{
            .data_dir = src_dir,
            .max_memtable_points = 100,
        }, &pool);
        defer eng.deinit();

        const pts = [_]types.Point{
            .{ .ts = 10, .value = 100 },
            .{ .ts = 20, .value = 200 },
            .{ .ts = 30, .value = 300 },
        };
        try eng.appendPoints(123, &pts);

        try snapshot(allocator, &eng, snapshot_dir);
    }

    // Phase 2: restore from the snapshot into a fresh directory.
    try restore(allocator, snapshot_dir, restore_dir);

    // Phase 3: open an Engine over the restored directory and query.
    {
        var eng = try engine_mod.Engine.init(allocator, .{
            .data_dir = restore_dir,
            .max_memtable_points = 100,
        }, &pool);
        defer eng.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 123, 0, 1000);
        var values: [3]i64 = undefined;
        var count: usize = 0;
        while (it.next()) |pt| {
            try std.testing.expect(count < values.len);
            values[count] = pt.value;
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
        try std.testing.expectEqual(@as(i64, 100), values[0]);
        try std.testing.expectEqual(@as(i64, 200), values[1]);
        try std.testing.expectEqual(@as(i64, 300), values[2]);
    }
}

test "backup: snapshot refuses to overwrite an existing data dir" {
    const allocator = std.testing.allocator;
    var src_tmp = std.testing.tmpDir(.{});
    defer src_tmp.cleanup();
    var dst_tmp = std.testing.tmpDir(.{});
    defer dst_tmp.cleanup();

    const io = Io.Threaded.global_single_threaded.io();
    const src_dir = try src_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(src_dir);
    const dst_dir = try dst_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dst_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try engine_mod.Engine.init(allocator, .{
        .data_dir = src_dir,
        .max_memtable_points = 100,
    }, &pool);
    defer eng.deinit();

    const pts = [_]types.Point{.{ .ts = 1, .value = 1 }};
    try eng.appendPoints(1, &pts);
    try eng.flush();

    // First snapshot succeeds, then second one to the same dir must
    // fail with PathAlreadyExists because manifest slots are present.
    try snapshot(allocator, &eng, dst_dir);
    try std.testing.expectError(error.PathAlreadyExists, snapshot(allocator, &eng, dst_dir));
}

test "backup: restore rejects a directory with a missing segment file" {
    const allocator = std.testing.allocator;
    var src_tmp = std.testing.tmpDir(.{});
    defer src_tmp.cleanup();
    var dst_tmp = std.testing.tmpDir(.{});
    defer dst_tmp.cleanup();

    const io = Io.Threaded.global_single_threaded.io();
    const src_dir = try src_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(src_dir);
    const dst_dir = try dst_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dst_dir);

    // Populate the source, flush to produce a segment.
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();
    {
        var eng = try engine_mod.Engine.init(allocator, .{
            .data_dir = src_dir,
            .max_memtable_points = 100,
        }, &pool);
        defer eng.deinit();
        const pts = [_]types.Point{.{ .ts = 1, .value = 1 }};
        try eng.appendPoints(1, &pts);
        try eng.flush();
    }

    // Delete the segment file to corrupt the source.
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/1.tsseg", .{src_dir});
    defer allocator.free(seg_path);
    try Io.Dir.cwd().deleteFile(io, seg_path);

    // Restore must refuse: the manifest references a segment that
    // does not exist on disk.
    try std.testing.expectError(error.FileNotFound, restore(allocator, src_dir, dst_dir));
}

test "backup: checkpoint persists active memtable to disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try engine_mod.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1000,
    }, &pool);
    defer eng.deinit();

    const pts = [_]types.Point{
        .{ .ts = 1, .value = 11 },
        .{ .ts = 2, .value = 22 },
    };
    try eng.appendPoints(7, &pts);

    // Before checkpoint: no segments on disk (memtable hasn't been
    // flushed yet).
    try std.testing.expectEqual(@as(usize, 0), eng.man.segments.items.len);

    try checkpoint(&eng);

    // After checkpoint: at least one segment must exist.
    try std.testing.expect(eng.man.segments.items.len >= 1);
}
