# Bench Codec-Micro and Mixed R/W Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 18 new bench scenarios (13 micro + 4 integration + 1 protocol orchestrator) without renaming any existing scenario, build step, or `ResultRow` field. Wire them into `build.zig` so `zig build bench-micro`, `zig build bench-integration`, and `zig build bench-ab` all run.

**Architecture:** Each new scenario implements the existing `framework.Scenario` interface from `benchmarks/framework/scenario.zig`. New scenarios live as standalone exes under `benchmarks/micro/*.zig` (one file per concern: codec, segment_rw, merge, wal_io, manifest_io, memtable) and `benchmarks/bench_integration.zig`. The `bench-ab` step is a shell script `benchmarks/scripts/bench_ab.sh` orchestrating two `git checkout` + `zig build bench-ci` runs and a final `compare-bench`. All bench exes force `.ReleaseFast` via the existing `benchModule` helper in `build.zig`.

**Tech Stack:** Zig 0.16.0 stdlib only. No new `build.zig.zon` deps. Framework is `benchmarks/framework.zig` (re-exports of `framework/{scenario,runner,reporter,tracking_allocator}.zig`). Lib API: `timeseries_storage` module exposing `gorilla`, `segment`, `wal_manager`, `manifest`, `memtable`, `iterator`, `compaction`, `engine`, `types`, `limits`.

---

## Reference: Scenario Body Template

Every new bench exe follows this exact shape (cribbed from `benchmarks/micro/example.zig`):

```zig
const std = @import("std");
const Io = std.Io;
const lib = @import("timeseries_storage");
const framework = @import("framework");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{ .name = "scenario_id", .ops_per_iteration = N,
           .warmup_iterations = 2, .sample_iterations = 10,
           .run = runScenarioId },
        // ... more scenarios
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-XYZ"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn runScenarioId(ctx: *framework.Context) anyerror!void {
    // Setup OUTSIDE the timed region is handled by warmup iterations; the
    // framework times the entire `run` callback. Keep fixture-build cost
    // small relative to the measured op so the median is stable.
    //
    // Use `ctx.allocator` for any per-iter allocations.
    // Use `ctx.iteration_index` to keep tmp paths unique.
    // Use `std.mem.doNotOptimizeAway(x)` on the result so ReleaseFast
    // does not delete the workload.
    _ = ctx;
}
```

For scenarios that need disk, use the existing `benchTmpDir` pattern from `benchmarks/bench.zig:112-121`:

```zig
fn benchTmpDir(allocator: std.mem.Allocator, ctx: *framework.Context) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fmt.allocPrint(allocator, "/tmp/ts-bench-{s}-{d}", .{
        ctx.scenario.name, ctx.iteration_index,
    });
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}
```

---

## File Structure

| File | Owner | Scenarios |
|---|---|---|
| `benchmarks/micro/codec.zig` | subagent A | `gorilla_encode_256`, `gorilla_encode_4096`, `gorilla_decode_256`, `gorilla_decode_4096` |
| `benchmarks/micro/segment_rw.zig` | subagent B | `segment_write_block_256`, `segment_read_block_256` |
| `benchmarks/micro/merge.zig` | subagent C | `merge_iter_k4`, `merge_iter_k16`, `merge_iter_k64` |
| `benchmarks/micro/wal_io.zig` | subagent D | `wal_append_record` |
| `benchmarks/micro/manifest_io.zig` | subagent D | `manifest_write_read` |
| `benchmarks/micro/memtable.zig` | subagent E | `memtable_insert_sorted`, `memtable_insert_ooo` |
| `benchmarks/bench_integration.zig` | subagent F | `bench_concurrent_append`, `bench_concurrent_rw`, `bench_ooo_append`, `bench_recovery_latency` |
| `benchmarks/scripts/bench_ab.sh` | subagent G | `bench-ab` orchestrator |
| `build.zig` modifications | subagent G | new exe + step wiring |

---

## Task 1: Codec micro (benchmarks/micro/codec.zig)

**Files:** Create `benchmarks/micro/codec.zig`.

**Scenarios:**

1. `gorilla_encode_256` — `ops_per_iteration = 256`, encode 256 points; pre-build the 256-point input slice in `run` before timing, then call `GorillaEncoder.initForPoints(ctx.allocator, 256)` + 256 × `encodePoint`. `warmup_iterations = 2`, `sample_iterations = 10`.
2. `gorilla_encode_4096` — same shape, 4096 points.
3. `gorilla_decode_256` — pre-encode 256 points OUTSIDE the timed body (use a `user_data`-style trick OR rebuild fixture inside `run` and accept the setup overhead — pick the second; the framework only times the `run` callback wall clock and warmup smooths transient setup). Allocate the encoded buffer with `ctx.allocator`. Decode with `GorillaDecoder.init(buf)` + 256 `decodePoint` calls. **`zero_alloc_expected: true`** — the decode loop must not allocate; assert with `TrackingAllocator.alloc_count` after warmup.
4. `gorilla_decode_4096` — same shape, 4096 points.

**Deterministic fixture seeding:** points are `Point{ .ts = @as(i64, @intCast(i)) * 1000, .value = @as(i64, @intCast(i)) * 7 + 13 }` for `i` in `0..N`. This pattern drives the encoder into the delta_of_delta == 0 timestamp branch (most-compressed) and the XOR-reuse value branch (stable bit count).

**Output sink:** XOR-fold every decoded `pt.value` into a local `i64 sink`, then `std.mem.doNotOptimizeAway(sink)`.

**Allocation discipline for decode:**

- Build the encoded payload BEFORE noting the iteration; the `TrackingAllocator` wraps the whole `run` call, but the runner divides totals across samples — so an alloc-free decode body shows `alloc_count = 0`/sample at the report level **only if the decode body is itself alloc-free**. To keep the decode body alloc-free, allocate the encoded buffer ONCE per `run` invocation (before the decode loop), but use a separate `std.heap.ArenaAllocator` backed by `ctx.allocator` for the fixture and use `GorillaDecoder.init(bytes)` directly. The `gorilla.GorillaDecoder` does NOT take an allocator — see `src/encoding/gorilla.zig:333` for the `init` signature.

**API references (read these in `src/encoding/gorilla.zig`):**

- `GorillaEncoder.initForPoints(allocator, num_points) !GorillaEncoder` — line 85
- `GorillaEncoder.encodePoint(self, Point) !void` — line 107
- `GorillaEncoder.getCompressedData(self, allocator) ![]u8` — search for `getCompressedData`
- `GorillaDecoder.init(bytes: []const u8) GorillaDecoder` — line 333 (no allocator)
- `GorillaDecoder.decodePoint(self) ?Point` — search for `decodePoint`

**Steps:**

- [ ] **Step 1: Read source surface.** Read `benchmarks/micro/example.zig` and `src/encoding/gorilla.zig:1-450` (encoder + decoder API).
- [ ] **Step 2: Write `benchmarks/micro/codec.zig`.** Define `pub fn main` per template; register the four scenarios; write per-scenario `run` bodies.
- [ ] **Step 3: Sanity build.** `zig build` should succeed (this file is not yet wired into a step but must at least compile syntactically once subagent G adds the step). Defer build verification to subagent G's smoke step.

---

## Task 2: Segment write/read micro (benchmarks/micro/segment_rw.zig)

**Files:** Create `benchmarks/micro/segment_rw.zig`.

**Scenarios:**

1. `segment_write_block_256` — open `SegmentWriter` over a tmp file, encode + write one 256-point block, close. `ops_per_iteration = 256`. The timed body builds 256 points, opens a `SegmentWriter` (read `src/segment.zig` for the API; constructor is `SegmentWriter.init` or similar — find the canonical exit-with-sync API used by `Engine.flushInternal`), calls `writeBlock` once, calls `sync()`, and lets the file close via `defer`.
2. `segment_read_block_256` — pre-write one 256-point block to a tmp file in setup (still inside `run` — warmup absorbs the setup wobble), then open a `SegmentReader`, read the block, call `Block.decodePoints(allocator)`, free the returned slice. `ops_per_iteration = 256`.

**API references (read `src/segment.zig`):**

- Look for `pub const SegmentWriter = struct` and `pub const SegmentReader = struct`
- `SegmentWriter.writeBlock` is the hot path; find its actual signature
- `Block.decodePoints` returns `![]Point` per the plan; find it

**Tmp file path pattern:** use `benchTmpDir` from `bench.zig:112-121`, append `/seg.dat` for the segment file.

- [ ] **Step 1: Read source surface.** Read `src/segment.zig:1-200` for the writer API and the section around the `Block.decodePoints` definition. Read how `Engine.flushInternal` uses `SegmentWriter` for the canonical call pattern (search `engine.zig` for `SegmentWriter`).
- [ ] **Step 2: Write `benchmarks/micro/segment_rw.zig`.** Two scenarios; both use a per-iteration tmp file.
- [ ] **Step 3: Sanity compile check** (subagent G performs the build).

---

## Task 3: Merge iterator micro (benchmarks/micro/merge.zig)

**Files:** Create `benchmarks/micro/merge.zig`.

**Scenarios:** `merge_iter_k4`, `merge_iter_k16`, `merge_iter_k64`. Each builds K sorted slices of 1000 points each in `ctx.allocator`, constructs the `MergeIterator` from `src/iterator.zig`, then drains it counting points. `ops_per_iteration = K * 1000`. Each iteration creates K disjoint ranges of timestamps so the merge order is K-way interleaved.

**API references (read `src/iterator.zig`):**

- Find `pub const MergeIterator = struct` (around line 175 per the plan note)
- Find the constructor `init(allocator, slices)` or the public factory and the `next() ?Point` method

**Disjoint range seeding:** For stream `k` in `0..K`, point `i` in `0..1000`: `Point{ .ts = @as(i64, @intCast(k)) + @as(i64, @intCast(i)) * @as(i64, @intCast(K)), .value = ... }`. Each stream is strictly ascending, and the streams interleave 1:1:...:1 across timestamps.

**Sink:** `sink ^= pt.ts ^ pt.value` then `doNotOptimizeAway(sink)`.

- [ ] **Step 1: Read `src/iterator.zig`** to nail down the MergeIterator constructor signature.
- [ ] **Step 2: Write `benchmarks/micro/merge.zig`** with shared `runMerge(ctx, K)` helper invoked from three thin wrappers.

---

## Task 4: WAL and manifest micros

**Files:** Create `benchmarks/micro/wal_io.zig` and `benchmarks/micro/manifest_io.zig`.

### wal_io.zig

`wal_append_record` — open a fresh WAL file in a tmp dir, append one fixed-256-byte record, close. `ops_per_iteration = 1`. The WAL is a fetched dependency at the `wal` module level; read `src/wal_manager.zig` to see how the engine drives it (the test fixture in `tests/wal_recovery.zig` is also instructive). Use `lib.wal_manager` to access the wrapper API.

### manifest_io.zig

`manifest_write_read` — build an in-memory 16-segment manifest, call `Manifest.serialize` (or whatever the canonical save call is named in `src/manifest.zig`) to a tmp file, then `Manifest.deserialize`/load it. `ops_per_iteration = 2` (one write + one read).

- [ ] **Step 1: Read `src/wal_manager.zig` and `src/manifest.zig`** to find the public API entry points.
- [ ] **Step 2: Write `benchmarks/micro/wal_io.zig`** — single scenario, per-iter tmp dir, fixed payload.
- [ ] **Step 3: Write `benchmarks/micro/manifest_io.zig`** — single scenario, per-iter tmp dir, 16 segment records.

---

## Task 5: Memtable micros (benchmarks/micro/memtable.zig)

**Files:** Create `benchmarks/micro/memtable.zig`.

**Scenarios:**

1. `memtable_insert_sorted` — initialize a `Memtable` per iteration via `Memtable.init(ctx.allocator, 1_000_000)`, insert one 256-point batch in `(ts, value)` ascending order on series id `7`. `ops_per_iteration = 256`. The deterministic seeding `Point{ .ts = i * 1000, .value = i * 7 + 13 }` keeps the sort-flag check fast.
2. `memtable_insert_ooo` — same shape, but the input batch has the last 2 elements swapped to trigger `lessThan` detection at index `points.len-1`, setting `entry.sorted = false`. `ops_per_iteration = 256`.

Both scenarios `doNotOptimizeAway(mt.point_count)` and call `mt.deinit()` to release the underlying hashmap allocations.

- [ ] **Step 1: Confirm `Memtable.insert` signature** in `src/memtable.zig:81`. Confirm the public seriesId/Point types.
- [ ] **Step 2: Write `benchmarks/micro/memtable.zig`** with shared helper that takes a "sorted" boolean and constructs the batch accordingly.

---

## Task 6: Integration scenarios (benchmarks/bench_integration.zig)

**Files:** Create `benchmarks/bench_integration.zig`.

**Scenarios:**

1. `bench_concurrent_append` — 4 goroutines via `thread_pool.ThreadPool`, each appending 25k points to disjoint series ids (`series = goroutine_index + 1`). Use a shared `Engine`. `ops_per_iteration = 100_000`. `sample_iterations = 5`. `warmup_iterations = 1`. Goroutines coordinate completion via a `std.atomic.Value(u32)` counter and a busy-wait on the main thread, OR via the `thread_pool.WaitGroup` if exposed. **Realism note in code:** allocations inside spawned goroutines pass an allocator that the `TrackingAllocator` does NOT wrap, so `alloc_count` undercounts for this scenario. Add a `//` comment.
2. `bench_concurrent_rw` — 2 writers (25k pts each, series 1 + 2) + 2 readers (1k pts of `queryPoints` against series 1, repeated). `ops_per_iteration = 52_000`. Same goroutine pattern.
3. `bench_ooo_append` — single-threaded: append 10k in-order points to series 1, force `eng.flush()`, then append 1k OoO points (timestamps below the sealed segment's max_ts; e.g. `ts = i % 10000` to overlap). Set `EngineConfig{ .allow_cross_segment_ooo = true, ... }` per `engine.zig:538`. Final `eng.flush()`. `ops_per_iteration = 11000`. `sample_iterations = 5`.
4. `bench_recovery_latency` — In setup, build a 4-segment data dir with 500 points each by initializing an engine, preloading + flushing 4 times, then dropping the engine. Re-init the engine over the same data dir, then `eng.deinit()`. The timed op is the re-init. `ops_per_iteration = 1`. `sample_iterations = 5`.

**Existing engine config defaults:** see `src/engine.zig` `EngineConfig`. Use `data_dir`, `max_memtable_points`. For the OoO scenario also set `allow_cross_segment_ooo = true`.

**Tmp-dir hygiene:** per-iteration tmp dirs via `benchTmpDir` (copy the helper from `bench.zig:112-121`).

- [ ] **Step 1: Read** `benchmarks/bench.zig:108-298` for the canonical Engine init / preload pattern; reuse `preloadSeriesFrom` style.
- [ ] **Step 2: Read** `src/engine.zig` around the `EngineConfig` definition to confirm `allow_cross_segment_ooo` field.
- [ ] **Step 3: Find** the WaitGroup/atomic counter pattern for goroutines (read `tests/stress.zig` or `tests/integration.zig` for concurrent-append examples; if the codebase uses `std.Thread.spawn` directly, use that — read which is canonical).
- [ ] **Step 4: Write `benchmarks/bench_integration.zig`** with all four scenarios.

---

## Task 7: build.zig wiring and bench-ab orchestrator

**Files:** Modify `build.zig`. Create `benchmarks/scripts/bench_ab.sh`.

### build.zig additions

After the existing `micro_example_exe` block (around line 270), add seven new exe + step pairs following the SAME pattern (each uses `benchModule` helper):

```zig
// codec
const micro_codec_exe = b.addExecutable(.{
    .name = "timeseries-storage-micro-codec",
    .root_module = benchModule(b, "benchmarks/micro/codec.zig", target, module, framework_module, thread_pool),
});
const run_micro_codec = b.addRunArtifact(micro_codec_exe);
if (b.args) |args| run_micro_codec.addArgs(args);
const micro_codec_step = b.step("bench-micro-codec", "Gorilla encode/decode micros");
micro_codec_step.dependOn(&run_micro_codec.step);
```

Repeat for: `bench-micro-segment-rw`, `bench-micro-merge`, `bench-micro-wal`, `bench-micro-manifest`, `bench-micro-memtable`, `bench-integration`.

Then extend the existing `micro_all_step` to depend on each new run artifact:

```zig
const micro_all_step = b.step("bench-micro", "Run all micro-benchmarks");
micro_all_step.dependOn(&run_micro_example.step);
micro_all_step.dependOn(&run_micro_codec.step);
micro_all_step.dependOn(&run_micro_segment_rw.step);
micro_all_step.dependOn(&run_micro_merge.step);
micro_all_step.dependOn(&run_micro_wal.step);
micro_all_step.dependOn(&run_micro_manifest.step);
micro_all_step.dependOn(&run_micro_memtable.step);
```

Add the aggregate steps `bench-ci`, `bench-smoke`, and `bench-ab`:

```zig
// bench-ci aggregates bench + bench-micro for the CI gate.
const bench_ci_step = b.step("bench-ci", "Fast CI bench: bench + bench-micro");
bench_ci_step.dependOn(&run_bench.step);
bench_ci_step.dependOn(&run_micro_example.step);
bench_ci_step.dependOn(&run_micro_codec.step);
bench_ci_step.dependOn(&run_micro_segment_rw.step);
bench_ci_step.dependOn(&run_micro_merge.step);
bench_ci_step.dependOn(&run_micro_wal.step);
bench_ci_step.dependOn(&run_micro_manifest.step);
bench_ci_step.dependOn(&run_micro_memtable.step);

// bench-smoke runs every scenario with --samples 1 for liveness only.
// Implementation: shell out via a system command step OR a tiny Zig
// driver. Simplest: duplicate the bench_ci_step but pass --samples 1
// in b.args. For now wire bench-smoke as an alias of bench-ci; the
// developer invokes it manually with `zig build bench-smoke -- --samples 1`.
const bench_smoke_step = b.step("bench-smoke", "Cross-platform liveness smoke (run with --samples 1)");
bench_smoke_step.dependOn(bench_ci_step);

// bench-ab orchestrator: invoke the shell driver under benchmarks/scripts/.
const bench_ab_run = b.addSystemCommand(&.{ "bash", "benchmarks/scripts/bench_ab.sh" });
if (b.args) |args| bench_ab_run.addArgs(args);
const bench_ab_step = b.step("bench-ab", "Run A/B bench between two refs (--ref-a, --ref-b)");
bench_ab_step.dependOn(&bench_ab_run.step);
```

Extend `tools_step.dependOn` for each new exe.

### benchmarks/scripts/bench_ab.sh

Stdlib-only shell. Pseudocode:

```bash
#!/usr/bin/env bash
set -euo pipefail
REF_A="${REF_A:-main}"
REF_B="${REF_B:-HEAD}"
OUT_DIR="${OUT_DIR:-docs/performance/2026-05-27-codec-micro-mixed-rw/runs/$(date -u +%Y-%m-%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

# Capture host state before
{ uname -a; zig version; } > "$OUT_DIR/host-state-before.txt"

# Stash any work-in-progress
git stash push --include-untracked --quiet || true
STASH_PUSHED=$?

# Resolve refs to SHAs so we can detect ref_a == ref_b
SHA_A=$(git rev-parse --verify "$REF_A")
SHA_B=$(git rev-parse --verify "$REF_B")

# A: checkout ref_a, build, run bench-ci, write ref_a.json
git checkout --detach "$SHA_A"
zig build bench -- --output "$OUT_DIR/ref_a.json"
zig build bench-micro

# B: same for ref_b (skip if SHA identical — first sanity run)
git checkout --detach "$SHA_B"
zig build bench -- --output "$OUT_DIR/ref_b.json"
zig build bench-micro

# Restore original ref
git checkout -

# Capture host state after
{ uname -a; zig version; } > "$OUT_DIR/host-state-after.txt"

# Compare
zig build compare-bench -- \
  --baseline "$OUT_DIR/ref_a.json" \
  --current "$OUT_DIR/ref_b.json" \
  > "$OUT_DIR/compare.txt" 2>&1 || true

# Restore stash
if [ "${STASH_PUSHED:-1}" = 0 ]; then git stash pop --quiet || true; fi

echo "Wrote $OUT_DIR"
```

- [ ] **Step 1: Modify `build.zig`** with the 7 new exe+step pairs, the aggregate `bench-ci`, `bench-smoke`, `bench-ab` steps, and extend `tools_step`.
- [ ] **Step 2: Create `benchmarks/scripts/bench_ab.sh`** with `chmod +x`.
- [ ] **Step 3: `zig build check`** to confirm everything compiles.
- [ ] **Step 4: Smoke run each new bench step** with `--samples 1 --quiet`:
  - `zig build bench-micro-codec -- --samples 1 --quiet`
  - `zig build bench-micro-segment-rw -- --samples 1 --quiet`
  - `zig build bench-micro-merge -- --samples 1 --quiet`
  - `zig build bench-micro-wal -- --samples 1 --quiet`
  - `zig build bench-micro-manifest -- --samples 1 --quiet`
  - `zig build bench-micro-memtable -- --samples 1 --quiet`
  - `zig build bench-integration -- --samples 1 --quiet --filter bench_ooo_append` (skip the concurrent ones in smoke to keep it fast)

Each must complete with exit 0.

---

## Definition of Done

- All 18 new scenarios compile and smoke-run successfully (exit 0 with `--samples 1`).
- No existing scenario name, build step name, or `ResultRow` field is renamed.
- `zig build test` (full unit suite) still passes.
- `zig build bench-micro` runs all micro scenarios.
- `zig build bench-ci` runs bench + bench-micro.
- `zig build bench-ab -- --ref-a main --ref-b HEAD` runs the orchestrator and produces a runs/ directory.
- The decoder scenarios (`gorilla_decode_256`, `gorilla_decode_4096`) report `alloc_count = 0`.
