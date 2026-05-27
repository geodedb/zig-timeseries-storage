# Bench Architecture — Codec Micro and Mixed R/W

**Run directory:** `docs/performance/2026-05-27-codec-micro-mixed-rw/`
**Date:** 2026-05-27
**Engine:** timeseries-storage, Zig 0.16.0 mono-language
**Baseline ref:** `main` (commit `b938d22` at design time; A == B sanity run)

---

## 1. Goal

Three concrete gaps drive this design:

**Gap 1 — Micro coverage** (`benchmarks/micro/example.zig` lines 11-14): The
`TODO(GAP-0011)` comment names the exact functions that need individual
scenarios: Gorilla encode/decode, `SegmentWriter.writeBlock`,
`SegmentReader.readBlock + Block.decodePoints`, `MergeIterator.next` at
varying fan-in, WAL `appendRecord`, and manifest write+read.  The only
existing micro scenario (`memtable_insert_one_point`) is a placeholder; none
of the codec or I/O primitives are individually measured.

**Gap 2 — Integration coverage** (`docs/PERF_GAP_ANALYSIS.md` lines 182, 328):
No mixed concurrent R/W scenario exists. No out-of-order append scenario
exists. The existing six integration scenarios in `benchmarks/bench.zig` are
all single-path: either writes only, reads only, flush only, or compaction
only. The P-LOCK-001 won't-do decision establishes that lock decomposition
needs bench-validated proof before the architecture work starts; these
integration scenarios produce that proof.

**Gap 3 — Cross-OS bench**: `benchmarks/results/baseline.json` was produced on
a single machine (commit `6dfd585`, Linux/x86_64/znver2). macOS M1 and Windows
have no bench results at all — the CI audit notes "build + unit + integration +
stress only (no bench)" for those platforms.

**Expected gains targeted by future optimization passes (not yet landed):**

| Hot path | Audit rank | Optimization target | Target gain |
|---|---|---|---|
| `GorillaEncoder.encodePoint` | 3 | `writeBits` inner loop vectorization | ≥5% throughput |
| `GorillaDecoder.decodePoint` | 3 | `readBits` bulk-word decode (P-ALGO-005 ships in `b938d22`) | baseline reference |
| `SegmentWriter.writeBlock` | 3 | Encoder pre-sizing (P-MEM-002 ships) | baseline reference |
| `flushInternal` | 4 | Lock-coupled blackout (P-LOCK-001 won't-do; measure current) | — |
| `compactL0` / `compactAll` | 5 | `MergeIterator` heap fan-in scaling (K=4/16/64) | ≥5% at K=64 |
| `appendPoints` mixed R/W | 1,2 | P-LOCK-001 decomposition candidate | measure baseline |

**This design establishes measurement targets.** No optimization code exists
yet. The first A/B run (A = `main`, B = `HEAD`) is a sanity baseline
confirming A == B medians within the noise gate. Subsequent optimization
passes will fork from `main`, land the change under a compile-time feature
flag, and run `zig build bench-ab` against that baseline.

---

## 2. Scope — Scenarios Per Layer, Per Language

All scenarios are Zig. The framework used is
`benchmarks/framework/` (stdlib-only, hand-rolled). New scenarios must
implement the existing `Scenario` interface from
`benchmarks/framework/scenario.zig` (lines 20-36).

### Layer: micro

Micro scenarios isolate a single function. Each scenario constructs only the
minimum state needed to exercise the target, measures one operation per
iteration, and asserts zero heap allocations where the target path is
expected to be allocation-free after setup.

| Scenario id | Target function | Source file (proposed) | Workload shape | Ops/iter | Zero-alloc? |
|---|---|---|---|---|---|
| `gorilla_encode_256` | `GorillaEncoder.encodePoint` | `benchmarks/micro/codec.zig` | Encode 256-point batch, uniform 1-second intervals | 256 | No — `DynamicBitSet` allocation is in setup; iteration must not re-alloc |
| `gorilla_encode_4096` | `GorillaEncoder.encodePoint` | `benchmarks/micro/codec.zig` | Encode 4096-point batch | 4096 | No |
| `gorilla_decode_256` | `GorillaDecoder.decodePoint` | `benchmarks/micro/codec.zig` | Decode 256 pre-encoded points | 256 | Yes (decoder is allocation-free post-init) |
| `gorilla_decode_4096` | `GorillaDecoder.decodePoint` | `benchmarks/micro/codec.zig` | Decode 4096 pre-encoded points | 4096 | Yes |
| `segment_write_block_256` | `SegmentWriter.writeBlock` | `benchmarks/micro/segment_rw.zig` | Write one block of 256 points to a tmpfs file | 256 | No |
| `segment_read_block_256` | `SegmentReader.readBlock` + `Block.decodePoints` | `benchmarks/micro/segment_rw.zig` | Read+decode one 256-point block | 256 | No |
| `merge_iter_k4` | `MergeIterator.next` | `benchmarks/micro/merge.zig` | Drain merge of K=4 sorted slices, 1000 points each | 4000 | No |
| `merge_iter_k16` | `MergeIterator.next` | `benchmarks/micro/merge.zig` | Drain merge of K=16 sorted slices, 1000 points each | 16000 | No |
| `merge_iter_k64` | `MergeIterator.next` | `benchmarks/micro/merge.zig` | Drain merge of K=64 sorted slices, 1000 points each | 64000 | No |
| `wal_append_record` | WAL `appendRecord` | `benchmarks/micro/wal_io.zig` | Write one WAL record (256-byte payload) to a tmpfs WAL file | 1 | No |
| `manifest_write_read` | `Manifest.serialize` + `deserialize` | `benchmarks/micro/manifest_io.zig` | Write then read a 16-segment manifest | 2 | No |
| `memtable_insert_sorted` | `Memtable.insert` (sorted path) | `benchmarks/micro/memtable.zig` | Insert one in-order 256-point batch | 256 | No |
| `memtable_insert_ooo` | `Memtable.insert` (OoO path, lazy-sort flag) | `benchmarks/micro/memtable.zig` | Insert one out-of-order batch, triggering flag flip | 256 | No |

**Rationale for batch sizes:** The Gorilla encoder's `initForPoints` pre-sizing
(`src/encoding/gorilla.zig` lines 85-93) was designed for ~18 bits/point
(`TYPICAL_BITS_PER_POINT = 18`). 256 points maps to the typical
`DEFAULT_TARGET_BLOCK_POINTS` constant used by the compactor
(`src/compaction.zig` line 98). 4096 points exercises the upper range before
the `MAX_POINTS_PER_BLOCK_ABSOLUTE = 65_536` cap (`src/limits.zig` line 49).

**Deterministic seeding:** All micro scenarios produce points with
`ts = i * 1000` (uniform 1-second interval) and `value = i * 7 + 13` for
index `i`. This is a fixed-pattern sequence that forces the encoder into the
`delta_of_delta == 0` branch (most-compressed path) and the XOR-reuse branch
for values, giving stable bit counts across runs. The WAL and manifest
scenarios use fixed-length payloads. Fixture bytes are computed once in the
scenario's `run` function before the timed region begins; the timed region
contains only the measured operation.

### Layer: integration

Integration scenarios exercise the engine end-to-end under realistic
workloads. They build on the existing `benchmarks/bench.zig` pattern: fresh
`Engine` per iteration over a per-iteration tmp directory. New scenarios are
additive — the six existing names (`append_single_series`,
`append_high_cardinality`, `query_recent`, `query_full_range`, `flush_cost`,
`compaction_cost`) are unchanged.

| Scenario id | Gap closed | Workload shape | Ops/iter | Concurrency shape |
|---|---|---|---|---|
| `bench_concurrent_append` | PERF_GAP_ANALYSIS.md:182 | 4 goroutines each appending 25k points to disjoint series, total 100k points | 100000 | N=4 (4 writer goroutines sharing one Engine) |
| `bench_concurrent_rw` | PERF_GAP_ANALYSIS.md:182 | 2 writers (25k pts each) + 2 readers (1k pts each) interleaved against same Engine | 52000 | N=4 (2W+2R) |
| `bench_ooo_append` | PERF_GAP_ANALYSIS.md:328 | 10k points in-order, then 1k late-arriving OoO points (ts below segment watermark), then flush | 11000 | N=1 |
| `bench_recovery_latency` | — (startup path not measured) | Engine.init over a 4-segment data directory (4 × 500 points each) that requires WAL replay | 1 | N=1 |

**Concurrency note:** The Zig 0.16 stdlib constraint (single-threaded global IO
context, `P-IO-004` won't-do) means these scenarios use multiple goroutines
(via `thread_pool`) sharing one `Engine` under the engine's existing
`std.Io.Mutex`. The IO context is obtained through
`std.Io.Threaded.global_single_threaded.io()` as all existing integration
scenarios do (`benchmarks/bench.zig` lines 113, 125).

### Layer: comparison

The comparison layer is not a new scenario file. It is the existing
`benchmarks/compare.zig` binary invoked with explicit `--baseline` and
`--current` flags. The `compare-bench` build step
(`build.zig` lines 253-268) is reused without modification.

The A/B runner protocol (see §5) produces two JSON files — one for ref-A
(`main` HEAD at the start of an optimization branch) and one for ref-B
(the optimization branch HEAD). `compare-bench` reads both and gates on the
variance-aware noise formula.

---

## 3. Result Schema Usage

All scenarios emit the standard `ResultRow` fields from
`benchmarks/framework/scenario.zig` (lines 45-68). The schema is additive-only.

### Fields every scenario emits

| Field | Source | Notes |
|---|---|---|
| `git_sha` | `reporter.captureEnv` | Populated by `git rev-parse HEAD` |
| `run_timestamp_unix_s` | `reporter.unixTimestampS` | Real-time clock |
| `zig_version`, `os`, `arch`, `cpu` | `builtin` | Compile-time + `/proc/self/status` |
| `scenario_name` | `Scenario.name` | Stable identifier used by `compare-bench` |
| `ops_per_iteration` | `Scenario.ops_per_iteration` | Divides wall time to yield ns/op |
| `sample_count` | `RunOptions.samples_override` or `Scenario.sample_iterations` | |
| `wall_ns_{min,p50,p95,p99,max,stddev}` | `runner.summarize` | Sorted sample array |
| `throughput_ops_per_sec`, `throughput_stddev_ops_per_sec` | Derived | `ops_per_iter / (wall_p50 / 1e9)` |
| `alloc_count`, `alloc_bytes`, `peak_live_bytes` | `TrackingAllocator` | Per-iteration average |
| `rss_current_bytes`, `rss_peak_bytes` | `/proc/self/status` VmRSS/VmHWM | Linux-only; zero on macOS/Windows |

### Per-scenario metric interpretation

**Micro — codec:** `wall_ns_p50 / ops_per_iteration` gives ns/point for the
codec path. `alloc_count == 0` after the warmup iteration asserts zero-alloc
decode (decoder holds no `DynamicBitSet`; encoder allocs are in the fixture
setup phase, not in the timed encode loop after the initial allocation).

**Micro — segment_write_block:** `alloc_count` reflects the encoder's
`initForPoints` allocation plus the compressed-data extraction. This is
expected to be 2 allocations per iteration (encoder bitset + output bytes).
A future optimization (encoder arena reuse) should reduce this to 0 in the
timed region.

**Micro — merge iterators:** K=4 vs K=16 vs K=64 `wall_ns_p50` directly
exposes the O(log K) heap scaling. Comparing `wall_ns_p50 / ops_per_iteration`
across these three variants shows whether the heap insert/pop dominates or
whether the point dispatch is the bottleneck.

**Integration — concurrent:** `throughput_ops_per_sec` at N=4 concurrency
divided by 4 × the N=1 baseline from `append_single_series` reveals the
lock-coupling cost (P-LOCK-001). A number significantly below 1.0 is the
quantitative proof needed before the lock-decomposition ADR.

**Integration — recovery:** `wall_ns_p50` with `ops_per_iteration = 1` gives
the raw startup latency in nanoseconds. Expected magnitude: sub-100ms for a
4-segment replay.

---

## 4. Repo-Native Commands

The existing build step names from `build.zig` are preserved exactly. New
steps follow the same naming convention.

### Existing steps (must not be renamed)

| Step | Command | Description |
|---|---|---|
| `bench` | `zig build bench` | Default integration suite (6 scenarios) |
| `scale-bench` | `zig build scale-bench` | 4-10x scale variants |
| `compare-bench` | `zig build compare-bench -- --baseline <f> --current <f>` | Diff and gate |
| `bench-micro` | `zig build bench-micro` | All micro scenarios (currently only `bench-micro-example`) |
| `bench-micro-example` | `zig build bench-micro-example` | Existing memtable placeholder |

### New steps to add

| Step | Command | Description |
|---|---|---|
| `bench-micro-codec` | `zig build bench-micro-codec` | Gorilla encode/decode scenarios |
| `bench-micro-segment-rw` | `zig build bench-micro-segment-rw` | `writeBlock`/`readBlock` scenarios |
| `bench-micro-merge` | `zig build bench-micro-merge` | `MergeIterator` K-fan-in scenarios |
| `bench-micro-wal` | `zig build bench-micro-wal` | WAL `appendRecord` scenario |
| `bench-micro-manifest` | `zig build bench-micro-manifest` | Manifest write+read scenario |
| `bench-micro-memtable` | `zig build bench-micro-memtable` | Memtable insert sorted+OoO |
| `bench-integration` | `zig build bench-integration` | New integration scenarios (concurrent, OoO, recovery) |
| `bench-ab` | `zig build bench-ab` | Orchestrates ref-A + ref-B runs, writes two JSON files, invokes compare-bench |
| `bench-ci` | `zig build bench-ci` | Fast CI subset: `bench` + `bench-micro` only |
| `bench-smoke` | `zig build bench-smoke` | Single-sample, single-warmup sanity run of all scenarios; suitable for every platform |

The `bench-micro` aggregate step is extended in `build.zig` to depend on all
new `bench-micro-*` steps. The `bench-ci` step runs `bench` (6 integration
scenarios, sample=5 or 3) plus `bench-micro` (all micro scenarios,
sample=6) and is the step wired to the existing `benchmark-regression` CI
job. The heavier `bench-integration` step (concurrent scenarios, ~2-5 min) is
promoted to the scheduled matrix only.

---

## 5. A/B Protocol

### Baseline ref policy

The baseline ref is always **the commit that was on `main` at the start of the
optimization branch**. Because there are no tags in this repo, the A-ref is
captured by recording the git SHA of `main` at branch creation time and
pinning it in the plan. The B-ref is `HEAD` of the feature branch at the time
the bench run is performed.

**First run special case:** At design time, `main` and `HEAD` are the same
commit (`b938d22`). The first A/B run is therefore a sanity baseline — it is
expected that A and B medians are within the noise gate. Any deviation
indicates measurement instability (thermal throttle, competing processes) and
requires re-running before any optimization work proceeds.

### Warmups and rounds

| Parameter | Value | Rationale |
|---|---|---|
| Warmup iterations | 1 | Matches the existing framework default (`Scenario.warmup_iterations = 1`, scenario.zig line 30) |
| Sample iterations | 10 | Doubled from the existing 5-6 defaults to reduce stddev on new micro scenarios. Overridable via `--samples` |
| Run order | 10 samples of A, then 10 samples of B | Sequential ref-then-branch is simpler than interleaved for single-machine runs; interleaved is optional for thermal sensitivity |
| Stress multiplier | 20 | For `bench-ab` under a sustained load: multiply `ops_per_iteration` by 20 to produce realistic thermal steady-state |

### Feature flags

Every optimization pass that modifies a hot path MUST introduce a Zig
compile-time option (a `const enable_<feature>: bool = true` in `build.zig`
passed as a `-D` option, or a comptime-constant in the affected module). The
A run uses the flag disabled; the B run uses the flag enabled. This ensures
a regression can be isolated by re-running with the flag flipped without
reverting commits.

Candidate flags (to be named by the implementing PR):

- `-Dgorilla-vectorize` — Gorilla `writeBits` SIMD path (if/when landed)
- `-Dencoder-arena` — encoder bitset arena reuse across blocks in `writeBlock`
- `-Dmerge-heap-k` — override merge iterator fan-in strategy (heap vs flat
  scan threshold)

---

## 6. Gating

### Variance-aware gate formula

Inherited from `benchmarks/compare.zig` (lines 83, 97):

```text
noise_gate = max(floor_pct, 3.0 * (baseline_throughput_stddev / baseline_throughput) * 100)
regression = tput_change < -noise_gate
```

Where `floor_pct` defaults to **15.0** (compare.zig line 36). The 15% floor
is intentionally conservative for first-time scenario wiring. Once a scenario
has three stable baseline runs with `throughput_stddev / throughput < 3%`,
the floor should be tightened to **3%** via `--floor 3` in the CI invocation
for that scenario.

### Fixed floor policy

- **15%** — initial wiring, all new scenarios for the first three CI runs.
- **5%** — scenarios with two prior stable baselines (stddev < 3%).
- **3%** — scenarios with five prior stable baselines and stddev < 1%;
  used for the micro codec scenarios once the encoder path stabilises.

The micro scenarios targeting zero-alloc paths are expected to stabilise
faster (lower variance) than the integration scenarios, which include
filesystem I/O.

### CI summary line

The `compare-bench` binary already emits one line per matched scenario to
stderr (compare.zig lines 85-94). The CI job should capture the exit code.
The stable one-line summary is:

```text
compare-bench: <N> scenarios matched, <M> regressions [exit 0|1]
```

This is not printed by `compare-bench` today. The implementation should add a
final summary line to the existing output in `compare.zig` (additive change,
no schema impact). Until that line is added, the CI step log line counts as
the summary.

### What triggers a gate failure

1. Any throughput regression exceeding `noise_gate` — `compare-bench` exits
   non-zero and the `benchmark-regression` CI job fails.
2. `alloc_count > 0` on a zero-alloc-expected scenario — the scenario body
   must check `ctx.allocator`-derived allocations via `TrackingAllocator`
   (tracking_allocator.zig lines 14-88) and fail the run explicitly.

---

## 7. Cross-Platform Coverage

### Current state

- **Linux x86_64 (znver2):** Full bench suite runs in CI (`benchmark-regression`
  job). `rss_*` fields populated from `/proc/self/status`
  (reporter.zig lines 131-163).
- **macOS M1:** Build + unit + integration + stress only. No bench.
- **Windows:** Build + unit + integration + stress only. No bench. `rss_*`
  always zero (reporter.zig line 131 `if (builtin.os.tag != .linux) return null`).

### Smoke plan

The `bench-smoke` step runs every scenario with `--warmup 1 --samples 1` and
`--quiet`. It produces a JSON result file but does not gate on regression
(single sample has no statistical power). Its purpose is to verify that the
scenario code compiles and does not panic on a given platform.

**Deployment for macOS M1 and Windows:** Add `zig build bench-smoke` to the
CI matrix for those platforms. This closes the "does it run at all" gap
without the 5-10 minute runtime of the full bench suite. The smoke step
should run on every push to `main`.

**Pin-CPU conventions:** On Linux CI, the existing `benchmark-regression` job
should set `taskset -c 0` or `numactl --physcpubind=0` before the bench
invocation to reduce cross-core migration noise. On macOS, `taskpolicy -c
utility` lowers the QoS class; combined with a dedicated self-hosted runner,
this is sufficient for the micro scenarios. Windows has no equivalent
pin-CPU mechanism in standard shells; accept higher variance on Windows
smoke runs.

**Cross-platform result comparison:** Do not compare Linux results against
macOS or Windows results in `compare-bench`. Results from different platforms
must live in separate JSON files and are compared only against prior results
from the same platform. The `os` + `arch` + `cpu` fields in `ResultRow` make
this explicit (scenario.zig lines 47-50).

### Deferred items

Full bench gating on macOS M1 is deferred until a self-hosted runner with
dedicated CPU affinity is available. Until then, macOS results are informational
only and not wired to the `benchmark-regression` gate.

---

## 8. Evidence Policy

### Retention

Every `bench-ab` run writes its output to a dated subdirectory under
`docs/performance/`:

```text
docs/performance/
  2026-05-27-codec-micro-mixed-rw/
    architecture.md        (this file)
    plan.json
    runs/                  (created at run time by bench-ab)
      <YYYY-MM-DD>-<sha-A>-vs-<sha-B>/
        ref_a.json         (baseline result)
        ref_b.json         (candidate result)
        compare.txt        (compare-bench stderr output)
        decision.md        (pass/fail + notes; written by engineer)
```

The `runs/` directory is committed alongside the architecture and plan files.
Decision files (`decision.md`) are the human-written record of why a result
was accepted or rolled back; they are required for every bench-ab run that
touches a CI-gated scenario.

### Rollback structure

If `compare-bench` exits non-zero:

1. The engineer records the regression in `decision.md` with the scenario
   name, measured delta, noise gate, and one of: `ACCEPT` (noise-floor
   false-positive with justification), `REVERT` (the optimization is backed
   out), or `INVESTIGATE` (further profiling needed before deciding).
2. A `REVERT` decision requires the feature flag to be toggled off in
   `build.zig` before the next merge to `main`.
3. An `INVESTIGATE` decision blocks the PR from merging until reclassified.

The existing `benchmarks/results/baseline.json` (SHA `6dfd585`,
`benchmarks/results/baseline.json` line 5) remains the CI gate file. New
scenarios added by this plan are NOT added to `baseline.json` until they
have completed at least one full `bench-ab` sanity run (A == B). At that
point the output `ref_a.json` from the sanity run is merged into
`baseline.json` via additive append to the `rows` array.

---

## 9. Risks and Language-Specific Caveats

### Zig / ReleaseFast inlining

All bench executables force `.ReleaseFast` (`build.zig` lines 230-231,
`benchModule` function lines 289-307). At `ReleaseFast`, the Zig compiler
aggressively inlines small functions. This is desirable for realistic numbers
but means the scenario body must use `std.mem.doNotOptimizeAway` on all
computed outputs (as the existing scenarios do, e.g. `bench.zig` line 150)
to prevent the optimizer from discarding the entire workload as dead code.

For micro scenarios that compute only a decoded value, the convention is:

```zig
var sink: i64 = 0;
while (...) |pt| { sink ^= pt.value; }
std.mem.doNotOptimizeAway(sink);
```

### No GC / no JIT

Zig has neither a garbage collector nor a JIT. The main sources of
non-determinism in timing are:

- Filesystem syscall latency (affects `bench-integration` and any scenario
  writing to a tmp file; use `tmpfs` or a RAM-backed path to reduce).
- Allocator `mmap`/`brk` latency on first-use (mitigated by the single
  warmup iteration, which seeds the ArenaAllocator).
- CPU frequency scaling (mitigate with `cpufreq-set -g performance` on Linux
  CI, or accept the 15% noise floor on cloud runners).

### `DynamicBitSet` growth in encoder micros

`GorillaEncoder.init` allocates a `DynamicBitSet` with capacity 65536 bits
(`gorilla.zig` line 43-44 calls `initWithCapacity(allocator, 65536)`). For
scenarios that re-create the encoder each iteration, this allocation appears
in `alloc_count`. For zero-alloc assertions on the decode path, use
`GorillaDecoder` which holds no allocator — `GorillaDecoder.init` is
allocation-free (`gorilla.zig` lines 333-347). The encode micro scenarios
are therefore not zero-alloc-expected; the decode scenarios are.

### Single-threaded IO context

`std.Io.Threaded.global_single_threaded.io()` is a process-global singleton
(P-IO-004). Concurrent integration scenarios that spawn multiple goroutines
must share it. Races on the IO context have been mitigated by the engine's
internal mutex but the bench runner itself does not hold any cross-scenario
lock. Run concurrent scenarios sequentially within the framework's scenario
loop; do not parallelize scenario execution at the framework level.

### `TrackingAllocator` per-iteration instances

`TrackingAllocator` is not thread-safe (tracking_allocator.zig line 14).
The runner creates one instance per iteration (runner.zig lines 103-107).
For concurrent integration scenarios, the `TrackingAllocator` wraps only the
outer scenario body's allocation budget. Allocations made inside goroutines
spawned by the scenario body pass a raw allocator and are not tracked. This
is an acknowledged gap in the allocation accounting for concurrent scenarios;
the `alloc_count` field will undercount in those cases. Document this in the
scenario's source comment.

### Manifest and WAL micro scenario isolation

The manifest write+read micro scenario must not share a data directory with
any integration scenario running concurrently. Use a per-scenario-per-iteration
tmp path (pattern established in `bench.zig` lines 112-121). The WAL scenario
must similarly use a per-iteration tmp path.

### Baseline split — two JSON files in CI

After the new scenarios are wired, `baseline.json` will contain rows for both
the original 6 integration scenarios and the new micro and integration
scenarios. The `compare-bench` match is by `scenario_name` string
(compare.zig lines 69, 142). There is no risk of collision as long as the new
scenario names do not duplicate existing ones. The preservation crosscheck
(§10) confirms this.

---

## 10. Preservation Crosscheck

The following table confirms that no protected name is renamed or removed by
this design.

### Protected scenario names (compare-bench matches by name)

| Name | Status |
|---|---|
| `append_single_series` | Preserved — `benchmarks/bench.zig` line 56 |
| `append_high_cardinality` | Preserved — `benchmarks/bench.zig` line 66 |
| `query_recent` | Preserved — `benchmarks/bench.zig` line 71 |
| `query_full_range` | Preserved — `benchmarks/bench.zig` line 76 |
| `flush_cost` | Preserved — `benchmarks/bench.zig` line 81 |
| `compaction_cost` | Preserved — `benchmarks/bench.zig` line 86 |

All new scenario names are additive and use the underscore-lowercase convention
consistent with the existing set.

### Protected build step names

| Step | Status |
|---|---|
| `bench` | Preserved — `build.zig` line 241 |
| `scale-bench` | Preserved — `build.zig` line 250 |
| `compare-bench` | Preserved — `build.zig` line 267 |
| `bench-micro` | Preserved — `build.zig` line 279; extended to depend on new steps |
| `bench-micro-example` | Preserved — `build.zig` line 276 |

### Protected `ResultRow` field names

All 21 fields in `ResultRow` (`benchmarks/framework/scenario.zig` lines 45-68)
are preserved. No fields are removed. Additions to the JSON output, if any,
must use `ignore_unknown_fields = true` in the reader, which is already
set in `compare-bench` (compare.zig line 138).

---

## Next steps

1. `/native-benchmarks:implement --plan docs/performance/2026-05-27-codec-micro-mixed-rw/plan.json`
2. `/native-benchmarks:run-ab --ref-a main --ref-b HEAD`
3. `/native-benchmarks:compare` and `/native-benchmarks:report` close out the run.
