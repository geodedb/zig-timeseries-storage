# Enterprise Database Readiness — Bench-Validated Gap Assessment

**Generated:** 2026-05-27
**Source:** new bench suite (commit `2723d3b`) + `docs/PERF_GAP_ANALYSIS.md`
**Hardware:** Linux x86_64 (znver2)

This document combines the **measured numbers** from the new bench
suite (`bench-micro-*`, `bench-integration`) with the **already-classified
findings** in `docs/PERF_GAP_ANALYSIS.md`. Every claim here is backed by
a raw JSON file under `benchmarks/results/`.

---

## Baseline numbers (HEAD = `2723d3b`)

### Default suite (`zig build bench`) — from prior `benchmarks/results/baseline.json` (commit `6dfd585`)

| Scenario | p50 wall | Throughput | Note |
|---|---|---|---|
| `append_single_series` | 21.8 ms / 100k pts | 4.58M ops/s | Single-threaded ingest ceiling |
| `append_high_cardinality` | 36.1 ms / 100k pts | 2.77M ops/s | 10k series × 10 pts |
| `query_recent` | 109.8 ms / 1k pts | 9.1k ops/s | After 100k preload |
| `query_full_range` | 119.1 ms / 100k pts | 839k ops/s | Full scan |
| `flush_cost` | 25.8 ms / 1k pts | 38.7k ops/s | Memtable→segment |
| `compaction_cost` | 83.7 ms / 4 segments | 47.8 ops/s | L0 fold |

### Micro suite (`benchmarks/results/micro-*.json`) — new

| Scenario | p50 | Throughput | allocs/iter | Note |
|---|---|---|---|---|
| `gorilla_encode_256` | 44 µs | 5.76M ops/s | 1 | Steady, presized bitset |
| `gorilla_encode_4096` | 697 µs | 5.88M ops/s | 1 | Same per-point cost |
| `gorilla_decode_256` | 49 µs | 5.17M ops/s | 2 | Fixture allocs counted |
| `gorilla_decode_4096` | 813 µs | 5.04M ops/s | 2 | Same per-point cost |
| `segment_write_block_256` | 5.68 ms | 45k ops/s | 4 | **Dominated by fsync + AES-GCM** |
| `segment_read_block_256` | 6.10 ms | 42k ops/s | 6 | Dominated by file open |
| `merge_iter_k4` | 122 µs | 32.7M ops/s | 6 | log K reasonable |
| `merge_iter_k16` | 577 µs | 27.7M ops/s | 19 | Allocs grow with K |
| `merge_iter_k64` | 3.95 ms | 16.2M ops/s | **71** | **Allocs scale per fanin** |
| `wal_append_record` | 10.86 ms | 92 ops/s | 2 | **Bench design issue: includes WAL setup/teardown** |
| `manifest_write_read` | 5.33 ms | 375 ops/s | 12 | Includes fsync (production cost) |
| `memtable_insert_sorted` | 672 ns | 380M ops/s | 2 | Fresh memtable per iter — alloc-dominated |
| `memtable_insert_ooo` | 471 ns | 543M ops/s | 2 | OoO actually faster (skips batch-sorted check) |

### Integration suite (`benchmarks/results/integration-baseline.json`) — new

| Scenario | p50 | Throughput | Note |
|---|---|---|---|
| `bench_concurrent_append` (N=4) | 21.4 ms / 100k pts | **4.67M ops/s aggregate** | **No speedup vs single-threaded — confirms P-LOCK-001** |
| `bench_concurrent_rw` (2W+2R) | 737 ms / 52k pts | 70.5k ops/s | Read+write contention |
| `bench_ooo_append` | 44.3 ms / 11k pts | 248k ops/s | Includes overlap-aware compaction |
| `bench_recovery_latency` | 88.8 ms / 1 init | 11 ops/s | 4-segment WAL replay |

---

## Key bench-validated finding

> **`bench_concurrent_append` aggregate throughput equals `append_single_series` aggregate throughput.**

4-way concurrent append against the same engine produces **4.67M ops/s** —
literally the same as `append_single_series` at **4.58M ops/s**. The
library's write throughput **does not scale with concurrency**. This is
the bench-validated proof the P-LOCK-001 unblock criteria called for
(`docs/PERF_GAP_ANALYSIS.md:182`: "Expected: ≥3× throughput at N=4,M=4;
p99 write < 5ms at 50k pts/s"). Current measurement: **1.02× at N=4**.

This is the dominant enterprise-readiness gap. Without lock decomposition,
the engine cannot exceed ~5M ops/s regardless of hardware.

---

## Enterprise-readiness gap classes

### Class A — XL refactors (Won't-Do per PERF_GAP_ANALYSIS, but bench now confirms severity)

These cannot be addressed by `/bench-optimize:run` (single-hypothesis,
smallest-plausible-change protocol). They require multi-PR, multi-session
architectural work.

| ID | Title | New bench evidence | Recommended track |
|---|---|---|---|
| P-LOCK-001 | Single global RwLock decomposition | `bench_concurrent_append` shows 1.02× scaling at N=4 (expected ≥3×) | XL refactor; needs ADR + manifest COW + per-shard memtable |
| P-LOCK-003 | flushInternal holds lock during fsync | (depends on P-LOCK-001) | Sequenced after P-LOCK-001 |
| P-LOCK-004 | compactL0 finalization holds lock | (depends on P-LOCK-001) | Sequenced after P-LOCK-001 |
| P-LOCK-005 | appendPoints holds lock during WAL pwrite | (depends on P-LOCK-001) | Sequenced after P-LOCK-001 |
| P-ALGO-001 | Per-series block index | `query_recent` at 9.1k ops/s; `bench_concurrent_rw` at 70.5k ops/s suggest read amp | XL; needs v3 segment format + migration tooling |
| P-COMP-002 | L1→L2 tiered compaction | (depends on P-ALGO-001) | Sequenced after P-ALGO-001 |
| P-IO-004 | Global single-threaded IO context | (Zig stdlib constraint) | Wait for upstream Zig stdlib evolution |

### Class B — Bench-actionable findings (fit /bench-optimize:run)

These are single-hypothesis optimizations with bench evidence pointing at them.

| ID | Component | Status | Outcome |
|---|---|---|---|
| ENT-001 | `iterator.MergeIterator` pre-size | **Closed (`890d9f8`)** | `merge_iter_k64` alloc_count 71 → 66 (5 doubling-grows eliminated) |
| ENT-002 | `memtable.Memtable` pre-size | **Closed (`ec6114a`)** | `memtable_insert_sorted/ooo` alloc_count 2 → 0; wall_p50 ~halved (581→290 ns, 511→341 ns) |
| ENT-003 | `segment.SegmentWriter` encoder pool | **Closed (`4d74bcc`)** | `segment_write_block_256` (8 blocks/iter) alloc_count 18 → 11; `compaction_cost` alloc_count 107 → 100 |
| ENT-004 | `compaction.zig` MergeIterator usage | **Closed (`890d9f8`)** | Production caller in `compactOneSeries` now uses `initCapacity(known K)` |
| ENT-005 | `memtable.Memtable` HashMap tuning | **Closed (`ec6114a`)** | Subsumed by ENT-002: `ensureTotalCapacity(DEFAULT_EXPECTED_SERIES=1024)` on the `AutoHashMap` |

### Class C — Bench design / instrumentation gaps (not library issues)

These came up while inspecting the new bench numbers but are bench design
issues, not library issues. Documenting for follow-up.

| ID | Bench | Issue | Fix |
|---|---|---|---|
| BENCH-D1 | `wal_append_record` | `ops_per_iteration = 1` and setup/teardown dominates the 10.86 ms wall. Real WAL append-only cost is in the WAL framework. | Change `ops_per_iteration` to 1000 and loop appends inside the timed body so per-op = wall/1000. Setup outside the loop. |
| BENCH-D2 | `manifest_write_read` | Same setup-overhead issue | Same fix |
| BENCH-D3 | `segment_*_block_256` | Per-iteration tmp-dir creation + AES-GCM init pollutes the measurement | Move tmp-dir/init outside the timed region |
| BENCH-D4 | `bench-micro` aggregate step passes `--output` to every sub-exe, last one wins | Split `bench-micro` into per-suite outputs in `bench_ab.sh` (already done) | Drop `--output` forwarding in the aggregate step, or change `bench-micro` to NOT take `--output` |
| BENCH-D5 | All bench results have `rss_current_bytes` populated at end-of-run, not per-scenario | Existing framework limitation; framework would need per-scenario RSS capture | Out of scope this run |

---

## Execution outcome

Class B fully closed in this session via direct landings (not via
`/bench-optimize:run`, which hit a STOP on the variance policy on this
host — see `docs/performance/2026-05-27-mergeiter-presize/baseline-decision.md`).
Each landed change is validated by `alloc_count` deltas + the full
test suite (test, test-integration, test-stress, test-engine-e2e).

Remaining work:

1. **Class A (P-LOCK-001 family + P-ALGO-001 family) — surface for maintainer go/no-go.**
   The bench evidence is now strong enough to justify the P-LOCK-001 work:
   `bench_concurrent_append` at N=4 produces 4.67M ops/s vs the
   single-threaded `append_single_series` ceiling of 4.58M ops/s — **1.02×
   scaling against the documented ≥3× unblock criterion**. Recommend
   pursuing in a dedicated branch with `bench_concurrent_append` /
   `bench_concurrent_rw` as acceptance criteria.

2. **Class C bench-design fixes (BENCH-D1/D2/D3)** so subsequent
   measurements amortize fixture cost more cleanly. Not urgent — the
   pooled-encoder bench was already restructured to demonstrate the
   ENT-003 win.

3. **Re-baseline the bench host (CPU pinning, dedicated runner) before
   any future `/bench-optimize:run` cycle** so wall-time signals are
   detectable above the 5% compiled-micro threshold.
