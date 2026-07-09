# Graph-Storage Parity Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the transferable defect fixes from graph-storage's last 20 days (v0.2.5 → v0.3.2) onto timeseries-storage so this engine does not carry the same defect classes: hostile-input arithmetic panics, unbounded attacker-controlled allocation, silent misparse of future on-disk formats, stale manifest-trusted state after crash recovery, dead persisted stats counters, and a clean-close durability hole.

**Architecture:** timeseries-storage is an LSM engine (WAL → sharded memtable → immutable Gorilla-compressed segments → dual-slot ping-pong manifest → tiered compaction). It has NO buffer pool and NO pager, so graph-storage's fixes are ported as *defect classes*, not code. Six code tasks target the exact sites a two-repo audit identified; a final docs task records the full audit mapping (including the graph-storage fixes that were audited and found not applicable here).

**Tech Stack:** Zig 0.16 (`zig build`), std.Io threaded runtime, CRC32C/CRC32, AES-256-GCM (optional TDE).

## Global Constraints

- All commands run from the repo root: `/home/benji/src/devnw/zig/timeseries-storage`.
- Unit tests are inline `test "..."` blocks in `src/*.zig`, run with `zig build test`. Integration suites: `zig build test-integration`, `zig build test-wal-recovery`.
- Full gate before any commit: the specific test step for the task must pass, plus `zig build check` (compile-all).
- Every new test must assert a *real* invariant and be proven RED first (graph-storage lesson 2915ec0), except where explicitly marked as a pinning test (Task 6 — reason documented in the task).
- Do not change the WAL wire format or segment file format. Task 4 changes ONLY the manifest serialization (with a version bump and v1-accept upgrade path).
- Commit style: match repo history (`fix:`, `feat:`, `test:` prefixes, one-line subject).

## Background: defect-class mapping (read once, then work your task)

| # | graph-storage fix | timeseries-storage site | Task |
|---|---|---|---|
| 1 | 2dcc678 checked page-offset arithmetic (hostile ids fail loud, never wrap) | `manifest.zig` deserialize reads segment table with no length gate → panic/OOB on forged plaintext manifest | 1 |
| 2 | same class (CWE-770) | `gorilla.zig decodeAll` eagerly reserves header-declared `stats.count` (up to ~64 GiB) | 2 |
| 3 | 49d85dc / 22b801c manifest downgrade gate + upgrade path | `format_version` is read and never checked — a future format would be silently misparsed | 3 |
| 4 | af37079 stale manifest stats + 2e0d3a4-F5 no-silent-default | `manifest.series_count`/`point_count` persisted but never maintained (always 0) | 4 |
| 5 | 2291ecc "recovery must re-derive from replayed WAL tail, not trust manifest" | strict-OoO watermark seeded from manifest segments only, ignores replayed WAL tail | 5 |
| 6 | close-durability cluster (0a0f9f0, 557a62d) | `Engine.deinit` performs no final WAL fsync → batched appends can be lost on power-fail after a "clean" close | 6 |

---

### Task 1: Manifest segment-table exact-length gate

The plaintext manifest CRC32 is unkeyed and forgeable. `deserialize` caps `num_segments` but never verifies the buffer actually contains `num_segments` entries, so a forged manifest with an inflated count panics on the `readU64` slice (safe builds) or reads out of bounds (ReleaseFast).

**Files:**
- Modify: `src/manifest.zig` (around lines 90, 622-624, 686-688)
- Test: inline in `src/manifest.zig`

**Interfaces:**
- Produces: file-private `const SEGMENT_ENTRY_BYTES: usize = 25;` — Task 4 renames this to `SEGMENT_ENTRY_BYTES_V1` and adds a V2 constant.
- Produces: `deserialize` returns `error.InvalidData` on any length/entry-count mismatch (exact-length check).

- [ ] **Step 1: Write the failing test**

Add at the end of `src/manifest.zig` (after the existing inline tests):

```zig
test "Manifest: deserialize rejects inflated num_segments with short body (CWE-770 parity)" {
    const allocator = std.testing.allocator;

    var m = Manifest{};
    const bytes = try m.serialize(allocator);
    defer allocator.free(bytes);

    // Forge: inflate num_segments (u32 LE at offset 68 — after
    // magic 8 + version 4 + uuid 16 + counter 8 + lsn 8 +
    // next_segment_id 8 + series_count 8 + point_count 8) without
    // providing entry bytes, then recompute the unkeyed CRC so the
    // forgery reaches the segment-table loop.
    const forged = try allocator.dupe(u8, bytes);
    defer allocator.free(forged);
    std.mem.writeInt(u32, forged[68..72], 1000, .little);
    const crc = Crc32.hash(forged[0 .. forged.len - 4]);
    std.mem.writeInt(u32, forged[forged.len - 4 ..][0..4], crc, .little);

    try std.testing.expectError(error.InvalidData, Manifest.deserialize(allocator, forged));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: the test binary CRASHES (index-out-of-bounds panic in `readU64` → `data[offset..][0..8]`) or reports the test failed. A panic here IS the RED signal — it is exactly the defect.

- [ ] **Step 3: Implement the gate**

In `src/manifest.zig`, next to `SERIALIZED_SIZE` (line 90), add:

```zig
/// Size in bytes of one serialized `SegmentMeta` entry
/// (id u64 + min_ts i64 + max_ts i64 + level u8).
const SEGMENT_ENTRY_BYTES: usize = 25;
```

In `serialize` (line 623), replace the magic number:

```zig
        const segment_bytes = self.segments.items.len * SEGMENT_ENTRY_BYTES;
```

In `deserialize`, immediately after the existing `num_segments > limits.MAX_SEGMENTS_PER_MANIFEST` check (line 686), add:

```zig
        // graph-storage 2dcc678 parity: every byte offset the
        // segment-table loop reads must be proven in-bounds BEFORE
        // the loop runs. The plaintext manifest CRC32 is unkeyed and
        // forgeable, so a hostile manifest can carry a valid CRC
        // with an inflated `num_segments` and a short body; without
        // this gate the `readU64` slices below panic in safe builds
        // and read out of bounds in ReleaseFast. The serialized
        // layout is exact (header + entries + trailing CRC), so
        // require exact length — fail closed, never guess.
        const expected_len = SERIALIZED_SIZE + 4 + @as(usize, num_segments) * SEGMENT_ENTRY_BYTES;
        if (data.len != expected_len) return error.InvalidData;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5` and `zig build check`
Expected: PASS (all unit tests, including the existing round-trip tests — the exact-length rule matches what `serialize` emits).

- [ ] **Step 5: Commit**

```bash
git add src/manifest.zig
git commit -m "fix: exact-length gate on manifest segment table — forged num_segments fails loud, never OOB (graph-storage 2dcc678 parity)"
```

---

### Task 2: Cap attacker-controlled point counts in block decode

`GorillaDecoder.decodeAll` reserves `num_points` entries up front. `num_points` comes from the on-disk block header (`stats.count`, u32), which for plaintext (v2) blocks is protected only by a forgeable CRC32C → up to ~64 GiB eager allocation (CWE-770). The encoder-side cap `limits.MAX_POINTS_PER_BLOCK_ABSOLUTE` (65 536) is not enforced on this decode path.

**Files:**
- Modify: `src/encoding/gorilla.zig:586-597` (`decodeAll`)
- Modify: `src/segment.zig:981-989` (`decodePoints`)
- Test: inline in both files

**Interfaces:**
- Consumes: `GorillaDecoder` fields `data: []const u8`, `num_points: u32`, `point_count: usize` (already exist, see `gorilla.zig:375-395`).
- Produces: `Block.decodePoints` returns `error.BlockCorrupted` when `stats.count > limits.MAX_POINTS_PER_BLOCK_ABSOLUTE`.

- [ ] **Step 1: Write the failing decoder test**

Add after the existing `decodeAll`-related tests in `src/encoding/gorilla.zig`:

```zig
test "GorillaDecoder: forged num_points cannot drive a giant up-front reservation (CWE-770)" {
    var fba_buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const allocator = fba.allocator();

    // 16 bytes of stream (exactly one first point: 64-bit ts +
    // 64-bit value) cannot hold maxInt(u32) points. The old code
    // reserved num_points entries up front and died with
    // OutOfMemory inside this small arena; the fixed code clamps
    // the reserve to what the bitstream could plausibly hold and
    // fails at the true end of the stream instead.
    const data = [_]u8{0} ** 16;
    var decoder = GorillaDecoder.init(&data, std.math.maxInt(u32));
    try std.testing.expectError(error.EndOfStream, decoder.decodeAll(allocator));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — actual error is `error.OutOfMemory` (the up-front reserve), not `error.EndOfStream`.

- [ ] **Step 3: Clamp the reserve in decodeAll**

Replace `decodeAll` in `src/encoding/gorilla.zig` (lines 586-597) with:

```zig
    /// Decode all points from the compressed bitstream.
    pub fn decodeAll(self: *GorillaDecoder, allocator: std.mem.Allocator) ![]types.Point {
        var points: std.ArrayList(types.Point) = .empty;
        errdefer points.deinit(allocator);
        // CWE-770 / graph-storage 2dcc678 parity: `num_points` comes
        // from an on-disk header an attacker may control. Never let
        // it reserve more memory than the bitstream could possibly
        // decode: after the first (64+64-bit literal) point,
        // Gorilla's minimum cost is 2 bits per point (dod=0 control
        // bit + xor=0 control bit), so `data.len` bytes hold at most
        // `data.len * 4 + 1` points. A forged count larger than that
        // previously reserved up to ~64 GiB up front; now the decode
        // loop reaches the true end of the stream first and fails
        // with `error.EndOfStream`.
        const max_plausible = self.data.len * 4 + 1;
        try points.ensureTotalCapacity(allocator, @min(self.num_points, max_plausible));

        while (self.point_count < self.num_points) {
            const point = try self.decodePoint();
            try points.append(allocator, point);
        }

        return try points.toOwnedSlice(allocator);
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Write the failing segment-level test**

Add to `src/segment.zig` right after the existing test `"Segment: decodePoints refuses oversized data_len"` (line 1311), mirroring its scaffold:

```zig
test "Segment: decodePoints refuses forged stats.count (CWE-770)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const seg_path = try std.fmt.allocPrint(allocator, "{s}/badcount.tsseg", .{path});
    defer allocator.free(seg_path);

    // Hand-craft a segment file: magic + a single header whose
    // stats.count exceeds the encoder-side absolute cap. The
    // decode-time cap must fire before any payload read, so no
    // payload (and no valid CRC) is needed.
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
                .count = @intCast(limits.MAX_POINTS_PER_BLOCK_ABSOLUTE + 1),
                .min_value = 0,
                .max_value = 1,
                .sum = 0,
                .first_value = 0,
                .last_value = 0,
            },
            .data_len = 16,
        };
        h.serialize(&hdr_buf);
        try f.writeStreamingAll(io, &hdr_buf);
        try f.sync(io);
    }

    var reader = try SegmentReader.init(allocator, seg_path);
    defer reader.deinit();
    var it = reader.iterator();
    const blk = (try it.next()).?;

    try std.testing.expectError(error.BlockCorrupted, blk.decodePoints(allocator));
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — with no payload bytes on disk the decode currently surfaces `error.UnexpectedEOF` (or a decode error), not `error.BlockCorrupted`.

- [ ] **Step 7: Add the count cap in decodePoints**

In `src/segment.zig`, inside `decodePoints` (line 981), right after the existing `data_len` cap (line 983), add:

```zig
        // CWE-770 / graph-storage 2dcc678 parity: `stats.count` is
        // attacker-influenceable for plaintext (v2) blocks — the
        // per-block CRC32C is unkeyed and forgeable. The encoder can
        // never legitimately emit more than
        // MAX_POINTS_PER_BLOCK_ABSOLUTE points per block, so a
        // larger count is corruption by definition. Reject it before
        // any payload read or decoder allocation.
        if (self.header.stats.count > limits.MAX_POINTS_PER_BLOCK_ABSOLUTE) return error.BlockCorrupted;
```

Also extend the doc comment error list above `decodePoints` (lines 975-980): add a line `///   * error.BlockCorrupted — stats.count exceeds MAX_POINTS_PER_BLOCK_ABSOLUTE.`

- [ ] **Step 8: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5` and `zig build check`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/encoding/gorilla.zig src/segment.zig
git commit -m "fix: cap attacker-controlled block point counts at decode (CWE-770) — reject forged stats.count, clamp Gorilla up-front reserve"
```

---

### Task 3: Manifest version gate — fail closed on unknown formats

`format_version` is read and never compared to anything. A manifest written by a future layout with the same magic would be silently misparsed (the segment-entry stride is version-specific). Worse, if only ONE ping-pong slot is future-format, the loader would silently fall back to the older slot — time-travelling the store (stale `next_segment_id`, stale checkpoint LSN) and risking segment overwrite. graph-storage shipped exactly this bug (49d85dc) and it caused silent corruption.

**Files:**
- Modify: `src/manifest.zig` (`deserialize` line 667-668, `initWithEncryption` lines 266-290)
- Test: inline in `src/manifest.zig`

**Interfaces:**
- Produces: `error.IncompatibleManifestVersion` from `deserialize` (version 0 or > `MANIFEST_VERSION`) and from `initWithEncryption` (either slot future-format ⇒ whole open fails).
- Task 4 relies on this gate existing before it introduces v2.

- [ ] **Step 1: Write the failing deserialize test**

Add at the end of `src/manifest.zig`:

```zig
test "Manifest: deserialize fails closed on a future format_version (49d85dc parity)" {
    const allocator = std.testing.allocator;

    var m = Manifest{};
    const bytes = try m.serialize(allocator);
    defer allocator.free(bytes);

    // Stamp a future version (u32 LE at offset 8) and recompute the
    // CRC so only the version gate can reject it.
    const forged = try allocator.dupe(u8, bytes);
    defer allocator.free(forged);
    std.mem.writeInt(u32, forged[8..12], MANIFEST_VERSION + 1, .little);
    const crc = Crc32.hash(forged[0 .. forged.len - 4]);
    std.mem.writeInt(u32, forged[forged.len - 4 ..][0..4], crc, .little);

    try std.testing.expectError(error.IncompatibleManifestVersion, Manifest.deserialize(allocator, forged));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — deserialize currently accepts the forged version and returns a manifest.

- [ ] **Step 3: Implement the gate in deserialize**

In `src/manifest.zig` `deserialize`, right after `m.format_version = readU32(data, pos); pos += 4;` (lines 667-668), add:

```zig
        // graph-storage 49d85dc parity: fail CLOSED on any manifest
        // format this binary does not understand. Without this gate
        // a future layout under the same magic would be silently
        // misparsed (the segment-entry stride is version-specific).
        // Version 0 never shipped — treat it as corruption rather
        // than guessing.
        if (m.format_version == 0 or m.format_version > MANIFEST_VERSION) {
            return error.IncompatibleManifestVersion;
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Write the failing no-silent-fallback test**

Add at the end of `src/manifest.zig`:

```zig
test "Manifest: open fails closed when one slot is future-format — no silent fallback to the older slot" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const dir_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);

    // Slot B: a valid current-format manifest (counter=1 → "b").
    {
        var m = Manifest{ .counter = 1 };
        const path_b = try std.fmt.allocPrint(allocator, "{s}/manifest.b", .{dir_path});
        defer allocator.free(path_b);
        try m.writeToFile(allocator, path_b);
    }

    // Slot A: a future-format manifest with a HIGHER counter
    // (counter=2 → "a"), as a newer binary would have written it.
    {
        var m = Manifest{ .counter = 2 };
        const bytes = try m.serialize(allocator);
        defer allocator.free(bytes);
        const forged = try allocator.dupe(u8, bytes);
        defer allocator.free(forged);
        std.mem.writeInt(u32, forged[8..12], MANIFEST_VERSION + 1, .little);
        const crc = Crc32.hash(forged[0 .. forged.len - 4]);
        std.mem.writeInt(u32, forged[forged.len - 4 ..][0..4], crc, .little);

        const path_a = try std.fmt.allocPrint(allocator, "{s}/manifest.a", .{dir_path});
        defer allocator.free(path_a);
        const f = try std.Io.Dir.cwd().createFile(io, path_a, .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, forged);
        try f.sync(io);
    }

    // Opening must surface the incompatibility — falling back to the
    // stale slot B would time-travel next_segment_id / checkpoint
    // LSN and let this binary overwrite the newer binary's segments.
    try std.testing.expectError(
        error.IncompatibleManifestVersion,
        Manifest.initWithEncryption(allocator, dir_path, null),
    );
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `initWithEncryption` currently swallows the slot-A error and opens on slot B.

- [ ] **Step 7: Hard-fail the open on either future-format slot**

In `src/manifest.zig` `initWithEncryption`, immediately after the two `readFromFileWithKey` calls (after line 266, BEFORE the `if (a == null and b == null)` block), add:

```zig
        // graph-storage 49d85dc parity: a slot written by a NEWER
        // binary must fail the whole open — even when the other slot
        // still parses. Falling back to the older slot would
        // time-travel the store (stale next_segment_id / stale
        // checkpoint LSN) and let this binary overwrite segments the
        // newer binary created.
        for ([_]?anyerror{ err_a, err_b }) |maybe_err| {
            if (maybe_err) |e| {
                if (e == error.IncompatibleManifestVersion) return e;
            }
        }
```

Note: if `a` or `b` loaded before this early return, nothing needs freeing — the early return happens before either could have loaded when its error is set; the OTHER slot's manifest may have loaded, so free it first:

```zig
        // (place the frees inside the return path)
        for ([_]?anyerror{ err_a, err_b }) |maybe_err| {
            if (maybe_err) |e| {
                if (e == error.IncompatibleManifestVersion) {
                    if (a) |*ma| ma.segments.deinit(allocator);
                    if (b) |*mb| mb.segments.deinit(allocator);
                    return e;
                }
            }
        }
```

Use the second form (leak-free). `a` and `b` are `?Manifest` — adjust to `var` bindings if the compiler requires mutability for `deinit` (they are already `var` at lines 259/263).

- [ ] **Step 8: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5` and `zig build check`
Expected: PASS (run with the testing allocator's leak detection — the test in Step 5 must not leak).

- [ ] **Step 9: Commit**

```bash
git add src/manifest.zig
git commit -m "fix: fail closed on unknown manifest format_version — gate deserialize AND slot selection (graph-storage 49d85dc parity)"
```

---

### Task 4: Manifest v2 — per-segment point counts, honest totals, v1 upgrade path

`manifest.series_count` and `point_count` are serialized but never maintained — every manifest on disk carries zeros (a stale/dead trusted counter, graph-storage af37079 class). Fix by carrying `point_count` per segment (known exactly at flush and compaction time) and deriving the manifest total at serialize time. This is an on-disk format change → bump `MANIFEST_VERSION` to 2 with a v1-accept upgrade path (graph-storage 22b801c pattern: length + embedded-version discrimination, old checksum validation, serialize-always-current). The new `SegmentMeta.point_count` field has **no default value** so the compiler forces every construction site to state it (graph-storage 2e0d3a4-F5 lesson: a silent `= 0` default wipes data on rebuild paths).

**Files:**
- Modify: `src/manifest.zig` (MANIFEST_VERSION line 42, `SegmentMeta` lines 92-97, entry-size consts from Task 1, `serialize` lines 622-654, `deserialize` lines 656-702, `SegmentMeta` literal in test at line ~1369)
- Modify: `src/engine.zig` (flush `WriteCtx` lines 1968-1976, flush `new_seg` line 2031, compaction `new_seg` line 2512, compactor call line 2470)
- Modify: `src/compaction.zig` (`compactSegments` line 143, `compactSegmentsWithEncryption` line 152, `compactOneSeries` line 211, internal test call sites)
- Test: inline in `src/manifest.zig`; integration test in `tests/integration.zig`

**Interfaces:**
- Consumes: `SEGMENT_ENTRY_BYTES` from Task 1 (renamed here), version gate from Task 3.
- Produces: `pub const SegmentMeta = struct { id: u64, min_ts: i64, max_ts: i64, level: u8, point_count: u64 };` (no default on `point_count`).
- Produces: `Compactor.compactSegmentsWithEncryption(...) !u64` and `Compactor.compactSegments(...) !u64` — return total points written to the output segment.
- Produces: `MANIFEST_VERSION = 2`; v1 manifests deserialize with `point_count = 0` per segment ("unknown/legacy") and upgrade in memory; serialize always emits v2.

- [ ] **Step 1: Write the failing round-trip test**

Add at the end of `src/manifest.zig`:

```zig
test "Manifest: v2 round-trip preserves per-segment point_count and derives the total" {
    const allocator = std.testing.allocator;

    var m = Manifest{};
    defer m.segments.deinit(allocator);
    try m.segments.append(allocator, .{ .id = 1, .min_ts = 0, .max_ts = 9, .level = 0, .point_count = 123 });
    try m.segments.append(allocator, .{ .id = 2, .min_ts = 10, .max_ts = 19, .level = 1, .point_count = 77 });

    const bytes = try m.serialize(allocator);
    defer allocator.free(bytes);

    var m2 = try Manifest.deserialize(allocator, bytes);
    defer m2.segments.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 123), m2.segments.items[0].point_count);
    try std.testing.expectEqual(@as(u64, 77), m2.segments.items[1].point_count);
    // The manifest-level total is DERIVED at serialize time so the
    // persisted stat can never silently go stale (graph-storage
    // af37079 parity).
    try std.testing.expectEqual(@as(u64, 200), m2.point_count);
}
```

- [ ] **Step 2: Write the failing v1-upgrade test**

Add at the end of `src/manifest.zig`:

```zig
test "Manifest: v1 manifest (25-byte entries) upgrades in memory (22b801c parity)" {
    const allocator = std.testing.allocator;

    // Hand-build a version-1 manifest: 72-byte header + one 25-byte
    // segment entry + CRC. This is the exact layout every store
    // written before manifest v2 carries on disk — rejecting it
    // would brick existing stores (the graph-storage 22b801c bug).
    var buf: [72 + 25 + 4]u8 = undefined;
    var pos: usize = 0;
    @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC);
    pos += 8;
    writeU32(&buf, &pos, 1); // format_version = 1
    @memset(buf[pos..][0..16], 0xAB); // ts_uuid
    pos += 16;
    writeU64(&buf, &pos, 9); // counter
    writeU64(&buf, &pos, 100); // last_checkpoint_lsn
    writeU64(&buf, &pos, 5); // next_segment_id
    writeU64(&buf, &pos, 0); // series_count (reserved)
    writeU64(&buf, &pos, 0); // point_count
    writeU32(&buf, &pos, 1); // num_segments
    writeU64(&buf, &pos, 3); // seg.id
    writeU64(&buf, &pos, @bitCast(@as(i64, 10))); // seg.min_ts
    writeU64(&buf, &pos, @bitCast(@as(i64, 20))); // seg.max_ts
    buf[pos] = 1; // seg.level
    pos += 1;
    const crc = Crc32.hash(buf[0..pos]);
    writeU32(&buf, &pos, crc);

    var m = try Manifest.deserialize(allocator, &buf);
    defer m.segments.deinit(allocator);

    // Upgraded in memory — the next save persists v2.
    try std.testing.expectEqual(MANIFEST_VERSION, m.format_version);
    try std.testing.expectEqual(@as(u64, 9), m.counter);
    try std.testing.expectEqual(@as(u64, 100), m.last_checkpoint_lsn);
    try std.testing.expectEqual(@as(u64, 5), m.next_segment_id);
    try std.testing.expectEqual(@as(usize, 1), m.segments.items.len);
    try std.testing.expectEqual(@as(u64, 3), m.segments.items[0].id);
    try std.testing.expectEqual(@as(i64, 10), m.segments.items[0].min_ts);
    try std.testing.expectEqual(@as(i64, 20), m.segments.items[0].max_ts);
    try std.testing.expectEqual(@as(u8, 1), m.segments.items[0].level);
    // v1 carries no per-segment count: 0 means "unknown (legacy)".
    try std.testing.expectEqual(@as(u64, 0), m.segments.items[0].point_count);
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: COMPILE ERROR (`SegmentMeta` has no field `point_count`) — that is the RED signal for both tests.

- [ ] **Step 4: Implement manifest v2**

In `src/manifest.zig`:

(a) Line 42: `pub const MANIFEST_VERSION: u32 = 2;`

(b) `SegmentMeta` (lines 92-97) — add the field with NO default:

```zig
pub const SegmentMeta = struct {
    id: u64,
    min_ts: i64,
    max_ts: i64,
    level: u8,
    /// Total points stored in this segment. Exact for segments
    /// written at manifest v2+ (flush and compaction both know the
    /// count at publish time); 0 = unknown for segments inherited
    /// from a v1 manifest (healed to exact on their next
    /// compaction).
    ///
    /// NO default value on purpose (graph-storage 2e0d3a4-F5
    /// lesson): every construction site must state the count
    /// explicitly, so a rebuild/migration path can never silently
    /// zero it.
    point_count: u64,
};
```

(c) Replace the Task-1 constant with both strides:

```zig
/// Serialized `SegmentMeta` entry sizes per manifest format version.
/// v1: id u64 + min_ts i64 + max_ts i64 + level u8.
/// v2: v1 fields + point_count u64.
const SEGMENT_ENTRY_BYTES_V1: usize = 25;
const SEGMENT_ENTRY_BYTES_V2: usize = 33;
```

(d) `serialize`: use the v2 stride, always emit the CURRENT version, derive the total, and append `point_count` per entry:

```zig
    pub fn serialize(self: *const Manifest, allocator: Allocator) ![]u8 {
        const segment_bytes = self.segments.items.len * SEGMENT_ENTRY_BYTES_V2;
        const full_size = SERIALIZED_SIZE + 4 + segment_bytes;
        const buf = try allocator.alloc(u8, full_size);
        errdefer allocator.free(buf);

        var pos: usize = 0;

        @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC);
        pos += 8;

        // Always emit the current format (22b801c pattern: accept
        // old on read, auto-migrate on the next write).
        writeU32(buf, &pos, MANIFEST_VERSION);
        @memcpy(buf[pos..][0..16], &self.ts_uuid);
        pos += 16;
        writeU64(buf, &pos, self.counter);
        writeU64(buf, &pos, self.last_checkpoint_lsn);
        writeU64(buf, &pos, self.next_segment_id);
        writeU64(buf, &pos, self.series_count);
        // Derive the total from the per-segment counts so the
        // persisted stat can never silently go stale (af37079
        // parity). Saturating add: a corrupt-but-parsed count must
        // not panic the save path.
        var total_points: u64 = 0;
        for (self.segments.items) |seg| total_points +|= seg.point_count;
        writeU64(buf, &pos, total_points);
        writeU32(buf, &pos, @intCast(self.segments.items.len));
        for (self.segments.items) |seg| {
            writeU64(buf, &pos, seg.id);
            writeU64(buf, &pos, @bitCast(seg.min_ts));
            writeU64(buf, &pos, @bitCast(seg.max_ts));
            buf[pos] = seg.level;
            pos += 1;
            writeU64(buf, &pos, seg.point_count);
        }

        const crc = Crc32.hash(buf[0..pos]);
        writeU32(buf, &pos, crc);

        return buf;
    }
```

(e) `deserialize`: version-aware stride in the exact-length gate; read `point_count` for v2, explicit 0 for v1; upgrade in memory after a successful parse. Replace the segment-table portion (from the `num_segments` cap through the loop) with:

```zig
        if (num_segments > limits.MAX_SEGMENTS_PER_MANIFEST) return error.ManifestTooLarge;

        // graph-storage 2dcc678 parity: every byte offset the
        // segment-table loop reads must be proven in-bounds BEFORE
        // the loop runs (see Task-1 comment). The stride is
        // version-specific; the version gate above guarantees
        // format_version is 1 or 2 here.
        const entry_bytes: usize = if (m.format_version == 1) SEGMENT_ENTRY_BYTES_V1 else SEGMENT_ENTRY_BYTES_V2;
        const expected_len = SERIALIZED_SIZE + 4 + @as(usize, num_segments) * entry_bytes;
        if (data.len != expected_len) return error.InvalidData;

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
            // v1 entries carry no count; 0 = unknown (legacy). Made
            // exact on the segment's next compaction.
            const point_count: u64 = if (m.format_version >= 2) blk: {
                const pc = readU64(data, pos);
                pos += 8;
                break :blk pc;
            } else 0;
            try m.segments.append(allocator, .{ .id = id, .min_ts = min_ts, .max_ts = max_ts, .level = level, .point_count = point_count });
        }

        // Upgrade-in-memory (22b801c pattern): a valid v1 manifest
        // is accepted verbatim and re-persisted as v2 on next save.
        m.format_version = MANIFEST_VERSION;

        return m;
    }
```

(f) Document `series_count` as reserved where it is declared (line ~175):

```zig
    /// RESERVED — always 0. Distinct-series-across-segments is not
    /// derivable from per-segment metadata (segments overlap in
    /// series); persisting a wrong number is worse than none
    /// (graph-storage af37079 lesson). Kept in the wire format for
    /// layout stability.
    series_count: u64 = 0,
```

(g) Fix the `SegmentMeta` literal in the inline test at line ~1369 (and any other literal the compiler flags): add an explicit `.point_count = 0,` (or a meaningful value where the test asserts totals).

- [ ] **Step 5: Update the flush path to record the count**

In `src/engine.zig`, replace the flush `WriteCtx` (lines 1968-1976) with:

```zig
        // Emit one block per (series_id, points) pair across every
        // shard. `forEachSeries` holds the shard mutex during each
        // visit so the slice the writer reads is stable.
        // `points_written` counts exactly what lands in the segment
        // — it feeds the manifest's per-segment point_count.
        const WriteCtx = struct {
            writer: *segment.SegmentWriter,
            points_written: *u64,

            fn visit(self_ctx: @This(), id: types.SeriesId, items: []const types.Point) anyerror!void {
                if (items.len == 0) return;
                try self_ctx.writer.writeBlock(id, items);
                self_ctx.points_written.* += items.len;
            }
        };
        var flushed_points: u64 = 0;
        try mem.forEachSeries(WriteCtx{ .writer = &writer, .points_written = &flushed_points }, WriteCtx.visit);
```

And the flush `new_seg` literal (line 2031):

```zig
        const new_seg = manifest.SegmentMeta{
            .id = seg_id,
            .min_ts = min_ts,
            .max_ts = max_ts,
            .level = 0,
            .point_count = flushed_points,
        };
```

- [ ] **Step 6: Update the compactor to return points written**

In `src/compaction.zig`:

(a) `compactSegments` (line 143): change return type to `!u64` and `return self.compactSegmentsWithEncryption(input_paths, output_path, null);` (unchanged body, new type).

(b) `compactSegmentsWithEncryption` (line 152): change return type to `!u64`; declare `var total_points: u64 = 0;` before the per-series loop; accumulate `total_points += try self.compactOneSeries(...)` at the existing call site; `return total_points;` at the end.

(c) `compactOneSeries` (line 211): change return type to `!u64`; declare `var written: u64 = 0;` at the top; change the early return (line 217) to `if (blocks.len == 0) return 0;`; after each of the two `writer.writeBlock(series_id, out_buf.items)` calls (lines 297 and 304) add `written += out_buf.items.len;`; `return written;` at the end.

(d) Fix internal test call sites in `compaction.zig` that call `compactSegments`/`compactSegmentsWithEncryption` — either `_ = try ...` or assert the returned count where the test knows it (prefer asserting: e.g. the test at line ~327 writes 2+1 points for series 10 and 1 each for 20/30 — assert the total the merge should emit).

(e) In `src/engine.zig` `runMergeAndCommit` (line 2470): `const out_points = try compactor.compactSegmentsWithEncryption(paths.items, out_path, enc);` and the compaction `new_seg` literal (line 2512) gains `.point_count = out_points,`.

- [ ] **Step 7: Run unit tests**

Run: `zig build test 2>&1 | tail -10` and `zig build check`
Expected: PASS — including the two RED tests from Steps 1-2. The compiler-driven sweep (no-default field) will have flagged every remaining `SegmentMeta` construction site; fix each with an explicit, correct count (never a reflexive 0 — that is the F5 lesson).

- [ ] **Step 8: Write the failing end-to-end flush test**

Add at the end of `tests/integration.zig`:

```zig
test "integration: flush records exact per-segment point_count in the manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    var eng = try lib.Engine.init(allocator, .{
        .data_dir = data_dir,
        .max_memtable_points = 1_000_000,
    }, &pool);
    defer eng.deinit();

    const pts = [_]lib.types.Point{
        .{ .ts = 1, .value = 11 },
        .{ .ts = 2, .value = 22 },
        .{ .ts = 3, .value = 33 },
    };
    try eng.appendPoints(7, &pts);
    try eng.appendPoints(9, &.{.{ .ts = 5, .value = 55 }});
    try eng.flush();

    try std.testing.expectEqual(@as(usize, 1), eng.man.segments.items.len);
    try std.testing.expectEqual(@as(u64, 4), eng.man.segments.items[0].point_count);
}
```

- [ ] **Step 9: Run integration tests**

Run: `zig build test-integration 2>&1 | tail -5`
Expected: PASS (if Step 5 was done correctly this passes immediately; if it fails, the flush wiring is wrong — fix before proceeding).

- [ ] **Step 10: Run the full suite**

Run: `zig build test-all 2>&1 | tail -5`
Expected: PASS (compaction and e2e suites exercise the new count plumbing).

- [ ] **Step 11: Commit**

```bash
git add src/manifest.zig src/engine.zig src/compaction.zig tests/integration.zig
git commit -m "feat: manifest v2 — per-segment point_count with v1 upgrade path; manifest total derived at serialize (graph-storage 22b801c/af37079/F5 parity)"
```

---

### Task 5: Strict-OoO watermark re-derived from the replayed WAL tail

`checkOoOLocked` lazily seeds the per-series watermark from **manifest segment metadata only** (`engine.zig:1554-1560`). After a crash, points replayed from the WAL into the memtable are invisible to that seed, so strict mode silently accepts timestamps it rejected before the crash. This is exactly graph-storage 2291ecc's class: recovery trusting checkpoint-era manifest state instead of re-deriving from the replayed WAL tail.

**Files:**
- Modify: `src/engine.zig` (`Engine.init`, insert after the `replayWalIntoMemtable` call at line 1028; `Engine` struct literal at lines 1030-1044)
- Test: `tests/wal_recovery.zig`

**Interfaces:**
- Consumes: `mem.shards` (`[16]Shard`, each `.series: std.AutoHashMap(types.SeriesId, SeriesEntry)`, entry `.points.items: []types.Point` — see `src/memtable.zig:93,118-127`); `man.segments.items[].max_ts`; `config.allow_cross_segment_ooo`.
- Produces: `Engine.init` returns with `series_watermarks` pre-seeded for every series present in the recovered memtable (strict mode only).

- [ ] **Step 1: Write the failing test**

Add at the end of `tests/wal_recovery.zig`:

```zig
test "wal recovery: strict OoO watermark is re-derived from the replayed WAL tail (2291ecc parity)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Session 1: strict engine. Append ts=100, make the WAL durable,
    // close WITHOUT flushing — the point exists only in the WAL.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .allow_cross_segment_ooo = false,
        }, &pool);
        defer eng.deinit();
        try eng.appendPoints(7, &.{.{ .ts = 100, .value = 1 }});
        try eng.sync();
    }

    // Session 2: reopen strict. Recovery replays ts=100 into the
    // memtable; no segment exists, so a manifest-only watermark seed
    // sits at minInt(i64) and would silently accept the regression
    // strict mode rejected before the crash.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .allow_cross_segment_ooo = false,
        }, &pool);
        defer eng.deinit();

        try std.testing.expectError(
            error.OutOfOrderTimestamp,
            eng.appendPoints(7, &.{.{ .ts = 50, .value = 2 }}),
        );
        // Equal-to-watermark stays accepted (check is `ts < wm`).
        try eng.appendPoints(7, &.{.{ .ts = 100, .value = 3 }});
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-wal-recovery 2>&1 | tail -10`
Expected: FAIL — the ts=50 append currently succeeds, so `expectError` reports "expected error.OutOfOrderTimestamp, found ...".

- [ ] **Step 3: Seed the watermarks from the recovered memtable**

In `src/engine.zig` `Engine.init`, after the `replayWalIntoMemtable(...)` call (line 1028) and before the `return Engine{...}` literal, add:

```zig
        // graph-storage 2291ecc parity: state recovery derives must
        // come from the replayed WAL tail, not just checkpoint-era
        // manifest metadata. The strict-OoO watermark previously
        // seeded lazily from `man.segments[].max_ts` alone, so a
        // crash-recovered point sitting only in the memtable was
        // invisible to it and strict mode silently accepted
        // timestamps it rejected before the crash. Seed every
        // replayed series here with
        // max(segment-global max_ts, replayed per-series max ts) —
        // the same conservative segment seed checkOoOLocked uses,
        // widened by what the WAL tail actually contained.
        //
        // Single-threaded: init has not published the engine yet, so
        // the shard maps are safe to walk without their mutexes.
        var seeded_watermarks: std.AutoHashMapUnmanaged(types.SeriesId, i64) = .{};
        errdefer seeded_watermarks.deinit(allocator);
        if (!config.allow_cross_segment_ooo) {
            var seg_max: i64 = std.math.minInt(i64);
            for (man.segments.items) |seg| {
                if (seg.max_ts > seg_max) seg_max = seg.max_ts;
            }
            for (&mem.shards) |*shard| {
                var it = shard.series.iterator();
                while (it.next()) |entry| {
                    var series_max: i64 = seg_max;
                    for (entry.value_ptr.points.items) |pt| {
                        if (pt.ts > series_max) series_max = pt.ts;
                    }
                    try seeded_watermarks.put(allocator, entry.key_ptr.*, series_max);
                }
            }
        }
```

And add to the `Engine{...}` return literal (lines 1030-1044):

```zig
            .series_watermarks = seeded_watermarks,
```

(Ownership transfers into the engine; `deinit` already frees it at line 1359.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-wal-recovery 2>&1 | tail -5`, then `zig build test 2>&1 | tail -5` and `zig build check`
Expected: PASS. Also run `zig build test-integration 2>&1 | tail -5` — permissive-mode tests must be untouched (the seeding is gated on strict mode).

- [ ] **Step 5: Commit**

```bash
git add src/engine.zig tests/wal_recovery.zig
git commit -m "fix: re-derive strict-OoO watermarks from the replayed WAL tail at recovery (graph-storage 2291ecc parity)"
```

---

### Task 6: Final WAL fsync on clean close

In `.batch` durability mode (the DEFAULT — `engine.zig:533`), appends since the last background-syncer tick sit in the OS page cache. `Engine.deinit` joins the syncer and tears the WAL down **without a final fsync**, so a power failure right after a "clean" close silently drops those records. graph-storage's close-durability cluster (0a0f9f0 / 557a62d) established the rule: clean shutdown must leave every durable-path structure actually durable.

**Note on TDD:** the fsync-vs-page-cache effect is not observable without power-fail fault injection — a same-OS-session reopen reads the page cache and passes either way. This task therefore uses a **pinning test** (green before AND after) that documents the close-then-reopen contract and guards ordering regressions (e.g. a future edit syncing after `wal.deinit`). The fix itself is verified by code review of the ordering: sync happens after the worker drain, before `wal.deinit`.

**Files:**
- Modify: `src/engine.zig` (`deinit` — doc comment lines 1292-1304, body around line 1342)
- Test: `tests/integration.zig`

**Interfaces:**
- Consumes: `WalManager.sync()` (`wal_manager.zig:166` — takes its own internal mutex; safe to call while holding `engine.mu`).

- [ ] **Step 1: Write the pinning test**

Add at the end of `tests/integration.zig`:

```zig
test "integration: batched appends survive a clean close with no explicit sync (final WAL fsync on deinit)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const data_dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(data_dir);

    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 1 });
    defer pool.deinit();

    // Phase 1: batch mode (the default), append, close with NO
    // explicit sync() and no flush. deinit's final WAL fsync is the
    // only durability barrier for these records.
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .durability_mode = .batch,
        }, &pool);
        defer eng.deinit();
        try eng.appendPoints(9, &.{
            .{ .ts = 10, .value = 1 },
            .{ .ts = 20, .value = 2 },
        });
    }

    // Phase 2: reopen and prove the records replay from the WAL.
    // (Pinning: a same-session reopen cannot distinguish page-cache
    // from fsync durability — this guards the replay contract and
    // the sync-before-teardown ordering, not the power-fail case.)
    {
        var eng = try lib.Engine.init(allocator, .{
            .data_dir = data_dir,
            .max_memtable_points = 1_000_000,
            .durability_mode = .batch,
        }, &pool);
        defer eng.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var it = try eng.queryPoints(arena.allocator(), 9, 0, 1000);
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 2), count);
    }
}
```

- [ ] **Step 2: Run test — expect it to pass already (pinning)**

Run: `zig build test-integration 2>&1 | tail -5`
Expected: PASS (page-cache durability in-session). This pins the contract; it is NOT a RED test — reason documented in the task header.

- [ ] **Step 3: Add the final fsync in deinit**

In `src/engine.zig` `deinit`, immediately after the worker-drain loop (lines 1338-1340) and BEFORE `self.wal.deinit();` (line 1342), add:

```zig
        // graph-storage close-durability parity (0a0f9f0/557a62d
        // cluster): a clean close must leave the WAL tail durable.
        // In `.batch` mode records appended since the last syncer
        // tick are sitting in the OS page cache; without this fsync
        // a power failure right after a "clean" close silently
        // drops them. Best-effort by design: teardown must not
        // fail, and an fsync error here leaves exactly the
        // pre-existing exposure. WalManager.sync takes its own
        // internal mutex — safe under engine.mu.
        self.wal.sync() catch {};
```

Also update the `deinit` doc comment (lines 1301-1304). Replace:

```zig
    /// Does not flush the active memtable to disk — that is the
    /// caller's responsibility via `flush()` or `sync()`. Data only
    /// present in the active memtable will be recovered from the WAL
    /// on the next open.
```

with:

```zig
    /// Does not flush the active memtable to disk — that is the
    /// caller's responsibility via `flush()` or `sync()`. Data only
    /// present in the active memtable will be recovered from the WAL
    /// on the next open. As a final durability barrier, `deinit`
    /// issues a best-effort WAL fsync so `.batch`-mode records
    /// appended since the last syncer tick survive a power failure
    /// after a clean close.
```

- [ ] **Step 4: Run the full gate**

Run: `zig build test 2>&1 | tail -5`, `zig build test-integration 2>&1 | tail -5`, `zig build test-wal-recovery 2>&1 | tail -5`, `zig build check`
Expected: PASS everywhere.

- [ ] **Step 5: Commit**

```bash
git add src/engine.zig tests/integration.zig
git commit -m "fix: final WAL fsync on Engine.deinit — close the batch-mode clean-close durability window"
```

---

### Task 7: Record the parity audit (docs only)

Future readers need to know which graph-storage fixes were **audited and found not applicable**, so nobody re-audits (or worse, cargo-cults buffer-pool machinery into an LSM).

**Files:**
- Create: `docs/GRAPH_STORAGE_PARITY_AUDIT.md`

- [ ] **Step 1: Write the audit document**

Create `docs/GRAPH_STORAGE_PARITY_AUDIT.md` with this content (verbatim):

```markdown
# graph-storage → timeseries-storage Parity Audit (2026-07-09)

Cross-repo audit of every graph-storage improvement from 2026-06-19 →
2026-07-09 (v0.2.5 → v0.3.2), mapped onto this LSM engine. Six defect
classes transferred and were fixed (see the tasks in
`docs/superpowers/plans/2026-07-09-graph-storage-parity-hardening.md`);
the rest were audited and found not applicable. This file records the
NOT-APPLICABLE findings so they are not re-audited.

## Fixed here (see plan + git history)

| graph-storage fix | this repo |
|---|---|
| 2dcc678 checked offset arithmetic on hostile input | manifest segment-table exact-length gate |
| CWE-770 unbounded alloc class | block decode point-count cap + Gorilla reserve clamp |
| 49d85dc downgrade gate / 22b801c upgrade path | manifest format_version gate + v1→v2 upgrade |
| af37079 stale manifest stats + 2e0d3a4-F5 no-silent-default | manifest v2 per-segment point_count, derived total |
| 2291ecc recovery re-derives from replayed WAL tail | strict-OoO watermarks seeded from recovered memtable |
| close-durability cluster (0a0f9f0/557a62d) | final WAL fsync in Engine.deinit |

## Audited — no action needed (with reasons)

- **Buffer-pool fixes** (dirty-eviction race e8b784a, lock-free pin
  0e5a2a0, pin deadlock/lost-wakeup ad34882, O(1) CLOCK b2d0951,
  lazy anon-mmap backing df33faa, pool re-create hardening 4a5beb4):
  this engine has NO buffer pool. Reads copy decoded blocks into a
  per-query arena; the only shared cache is the SegmentReaderCache
  (FD/reader LRU), which is refcounted and mutex-guarded with
  deferred close for borrowed entries.
- **Pager checked arithmetic** (2dcc678 mechanism): no pager. Segment
  block iteration computes `offset = data_offset + data_len` in
  u64+u32 (cannot wrap); corrupt lengths yield short positional reads
  → `error.UnexpectedEOF`; `data_len` is capped at
  `MAX_BLOCK_DATA_LEN` before any allocation. The *class* was still
  found (and fixed) at two decode sites — see the fixed table.
- **Iterator/scan races** (LabelIndex scan-vs-add 27a6ef0, DESC
  cursor OOB a6d5a13): `queryPoints` copies memtable points out
  under the shard mutex and decodes segment blocks into an arena at
  call time; the returned iterator owns all its data. Segments
  compacted away mid-query are protected by reader-cache refcounts.
  No live-structure iteration exists to race.
- **WAL under-logging** (1c72e46, 6420221): every unsealed-data
  mutation (`appendPoints`) is WAL-logged before apply. Flush,
  compaction, and retention mutate only sealed state whose source of
  truth is the manifest, which is fsync'd atomically (tmp+rename,
  dual-slot) BEFORE the WAL is truncated. There is no delete/update
  path that could under-log. Verified ordering:
  segment fsync → manifest publish → WAL truncate.
- **Free-space map trusts checkpoint-era bitmap** (d05942d): no
  free-space map. Segment files are immutable and append-created;
  ids are allocated from `next_segment_id`, which only advances at
  publish time and is persisted in the same fsync'd manifest write.
- **Derived-index durability "Path B"** (be40df5, 605e266, 8d27f60,
  f6a325d, 557a62d): the only persisted derived structure is the
  segment footer sparse index, which lives INSIDE the immutable
  fsync'd segment file (CRC-protected, falls back to a full block
  scan when absent/corrupt). It cannot drift from primary data
  across a crash, so no epoch/covered-LSN reload contract is needed.
- **Counter re-derivation for id allocators** (2291ecc/84ea73c
  mechanism): `next_segment_id` advances only at flush/compaction
  publish and travels in the same atomic manifest write as the
  segment list — a replayed WAL tail never allocates segment ids, so
  the manifest value cannot be stale relative to the tail. (The
  watermark leg of 2291ecc DID transfer — see fixed table.)
- **Slab packing** (prop/var/adjacency/edge-prop trains): the analog
  amplification here is one block header (92 B plaintext / 120 B
  encrypted) per series per flush for wide-cardinality sparse
  workloads. Gorilla blocks already pack points; L0→L1 compaction
  re-chunks to ~256-point blocks and amortizes the header. A
  flush-time coalescer would only help pre-compaction L0 reads —
  noted as potential future work, not a defect.
- **Early-ready / lazy / parallel open** (211586b, 4ecc1d7, a6ba76e):
  open cost is already O(num_segments) 8-byte magic probes +
  O(WAL tail) replay. Footers, reader FDs, and caches are lazy.
  Nothing eager to defer; no shards to parallelize.
```

- [ ] **Step 2: Commit**

```bash
git add docs/GRAPH_STORAGE_PARITY_AUDIT.md
git commit -m "docs: record graph-storage parity audit — fixed classes + audited-not-applicable findings"
```
