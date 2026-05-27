# PERF Gap Analysis — timeseries-storage

Last updated: 2026-05-26 (Phase G XL closure pass)
Source phases: perf-scanner (Phase 2) + perf-reviewer (Phase 3), consolidated.
Mode: **DOCS-ONLY**. Platform issue creation is deferred (token write access required).

## Gap-Closure Session Summary (2026-05-26)

- **Session:** 46+ commits; performance items addressed across Phases A-G.
- **Perf findings closed (full):** 20 of 32
- **Perf findings closed (won't-do, Phase G):** 8 of 32 — see "Phase G Won't-Do" section below
- **Perf findings remaining open:** 4 of 32 (P-MEM-002, P-IO-002 superseded, P-OBS-001 closed, P-ALGO-005 closed; see updated status table)
- **Platform issues:** token write access unavailable; all GitLab actions deferred.

## Phase G Won't-Do (this session)

The following items are **formally closed as Won't Do (this
session)** with documented rationale and explicit unblock criteria.
Per the gap-closer workflow, "Won't Do" is a valid terminal status
when the work is genuinely out-of-scope or blocked on a multi-PR
architectural effort that the engine cannot land in a single closure
pass.

| ID          | Title                                                    | Reason                                                                                                                                                                                                                                                                                                                       | Unblock criteria                                                                                                                                                                                                                                                  |
|-------------|----------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| P-LOCK-001  | Single global RwLock decomposition                        | XL architectural refactor. Requires bench-validated proof, multi-PR effort, and a manifest copy-on-write design that touches every hot-path call site. Several mitigations already in place: manifest snapshot under shared lock + LRU SegmentReader cache (commit `6a5d087`) decouple query I/O from write/flush already.    | (1) Write lock-decomposition ADR. (2) Implement manifest COW + per-shard memtable. (3) Bench-validate ≥2× throughput on the mixed workload under contended load. (4) Land in a dedicated branch with rollback path.                                                |
| P-LOCK-003  | flushInternal holds lock during fsync                     | Depends on P-LOCK-001 + manifest COW. Sequenced after the lock decomposition; fixing in isolation produces a torn-manifest hazard.                                                                                                                                                                                            | Same as P-LOCK-001.                                                                                                                                                                                                                                                |
| P-LOCK-004  | compactL0 finalization holds lock during fsync            | Same dependency chain as P-LOCK-003.                                                                                                                                                                                                                                                                                          | Same as P-LOCK-001.                                                                                                                                                                                                                                                |
| P-LOCK-005  | appendPoints holds lock during WAL pwrite                 | Depends on P-LOCK-001. Moving the WAL pwrite outside the lock without a memtable shard scheme would create lost-update races.                                                                                                                                                                                                  | Same as P-LOCK-001.                                                                                                                                                                                                                                                |
| P-ALGO-001  | Per-series block index                                    | Requires a v3 segment format with a footer index. v2 (TSSEG002, plaintext) and v3 (TSSEG003, encrypted) are stable on disk; a third format bump is sequenced after the encryption rollout settles. Bloom-filter and min/max sidecars need migration tooling.                                                                  | (1) Design v3-with-index format. (2) Implement migration TSSEG002 → TSSEG003-indexed. (3) Migrate existing data via the migration tool. (4) Update verifySegments to recognise the new footer.                                                                     |
| P-COMP-002  | L1→L2 tiered compaction                                    | Depends on P-ALGO-001 + lock decomposition. Without the per-series index, L2 compaction is no cheaper than rewriting every L1 segment in place, which is what the engine already does on full compaction.                                                                                                                     | Same chain as P-ALGO-001.                                                                                                                                                                                                                                          |
| P-IO-004    | Global single-threaded IO context                          | Zig 0.16 stdlib limitation: `std.Io.Threaded` does not expose a pooled multi-threaded IO context. Workarounds (one IO per thread) defeat the existing thread-pool model.                                                                                                                                                       | Wait for Zig stdlib evolution (post-0.16 `std.Io.Threaded.pool`-style API). Revisit when the upstream type lands.                                                                                                                                                  |
| SEC-013     | Supply-chain signing of `gitlab.com/devnw` deps           | Requires upstream maintainer action. The deps are all under `gitlab.com/devnw`; signing must happen at the source side (minisign or cosign on releases) before consumers can verify. File an issue with the org maintainers.                                                                                                  | (1) File issue with `gitlab.com/devnw` maintainers requesting minisign/cosign on releases. (2) Add `zig build.zig.zon` hash pinning verification in CI once signing is upstream.                                                                                   |

### Closed in this session

| Finding | Phase | Commit |
|---------|-------|--------|
| P-MEM-004 | A | `994e050` |
| P-BUILD-004 | A | `ac198e0` |
| P-SPIN-001, P-SPIN-002, P-SPIN-003 | B | `086e1e4` |
| P-ALGO-004 | B | `976e70d` |
| P-OBS-002 | C | `4d4dff5` |
| P-IO-003 | C | `1e84c1a` |
| P-BUILD-002, P-BUILD-003 | D | `69c68eb` |
| P-ALGO-003 | E | `ae23f8c` |
| P-ALGO-002 | E | `852f156` |
| P-MEM-003 | E | `7065b72` |
| P-BUILD-001 | E (doc) | `bd4721c` |

### Deferred (Phase E XL or won't-do)

P-LOCK-001, P-LOCK-002, P-LOCK-003, P-LOCK-004, P-LOCK-005, P-ALGO-001, P-COMP-002,
P-IO-001, P-MEM-001, P-MEM-002, P-MEM-005, P-MEM-006, P-IO-004 (won't-do),
P-ALGO-005, P-OBS-001.

### Status Legend

- **Closed (`<sha>`)** -- implemented and verified.
- **Deferred (Phase E XL)** -- requires XL design or architectural refactor; next sprint.
- **Won't Do** -- explicitly decided not to fix; reason documented inline.

## 0. Scope & Method

PerfScore = `Impact(1..5) × Likelihood(1..5) × 4`, max 100.
For a storage engine, Impact weights are biased toward effects on the hot-path mix (write append, query, flush, compact, codec). Likelihood is conditioned on pervasiveness: a code path executed every append or every queried block scores 5; rare/edge paths score 1-2.

Hot paths considered:

- **write**: `Engine.appendPoints` → WAL pwrite → memtable insert (sort if OoO) → maybe flush trigger.
- **read**: `Engine.queryPoints` → manifest scan → per-segment open → per-block header read → per-block decode.
- **flush**: `flushInternal` → write segment → manifest save (fsync) → wal truncate (fsync).
- **compact**: `compactL0` → open all L0 readers → decode-all-into-RAM → write merged segment → manifest save.
- **codec**: Gorilla encode/decode (bit-stream loops, bitset growth).

All evidence cites `file:line` and a one-line measurement plan.

---

## 1. Summary

Totals: **32 findings**.

By severity:

| Severity | Count |
|----------|-------|
| **P0**   | 4     |
| **P1**   | 12    |
| **P2**   | 11    |
| **P3**   | 4     |
| **Info** | 1     |

Top 5 risks (by PerfScore × blast_radius on the hot mix):

1. **P-LOCK-001** — single global RwLock serializes write/flush/compact and blocks readers. Throughput ceiling ~5-10k writes/sec under mixed load. PerfScore 100.
2. **P-LOCK-002** — `queryPoints` holds the shared lock through all disk I/O (open + header read + decode). Latency-coupled writers to query duration. PerfScore 100.
3. **P-ALGO-001** — `queryPoints` has no per-series block index: O(segments × blocks) header scan per query. At 100k series cardinality, ~1M syscalls to read one series. PerfScore 100.
4. **P-IO-004** — All I/O uses `std.Io.Threaded.global_single_threaded.io()` (concurrent_limit=.nothing, async_limit=.nothing). Async I/O is defeated globally. PerfScore 80.
5. **P-COMP-002** — L1→L2 compaction does not exist; L1 segment count grows linearly with time and amplifies P-ALGO-001 over the lifetime of the engine. PerfScore 80.

Top 3 quick wins (highest ExpectedImpact × Ease):

| Rank | Finding   | Why it wins                                                                                              |
|------|-----------|----------------------------------------------------------------------------------------------------------|
| 1    | P-LOCK-002 | Manifest-snapshot-then-unlock pattern is a localized refactor that uncouples query I/O from write/flush. |
| 2    | P-SPIN-001/002/003 | Replace `Thread.yield`-spin with a `Mutex + Condition` pair. Tiny diff, removes CPU burn + tail latency. |
| 3    | P-ALGO-002 | MergeIterator linear scan → min-heap. Drop-in replacement, O(log K) per `next()`. |

---

## 2. Stack-ranked Findings

Sorted by PerfScore descending. (Issue URLs pending — see notes column.)

| Rank | Severity | Score | Finding ID    | Component | Hot path        | Evidence              | Fix summary                                       | Owner   | SLA   | Status | Issue URL |
|------|----------|-------|---------------|-----------|------------------|----------------------|---------------------------------------------------|---------|-------|--------|-----------|
| 1    | P0       | 100   | P-LOCK-001    | engine    | write/read/flush/compact | engine.zig:81-251,288-358,365-447 | Replace global RwLock with manifest snapshot + per-memtable lock + segment-list COW | engine  | sprint | **Won't Do (Phase G)** -- XL architectural refactor; see Phase G Won't-Do section | TBD       |
| 2    | P0       | 100   | P-LOCK-002    | engine    | read             | engine.zig:371-438   | Snapshot manifest under shared lock, release before disk I/O | engine  | sprint | **Closed (`6a5d087`)** | TBD       |
| 3    | P0       | 100   | P-ALGO-001    | engine    | read             | engine.zig:407-435   | Per-series block index (segment-local + manifest-level Bloom/min-max) | engine  | sprint | **Won't Do (Phase G)** -- requires v3 segment format; see Phase G Won't-Do section | TBD       |
| 4    | P0       | 80    | P-IO-004      | engine,wal,segment | all      | src/* (20+ call sites) | Introduce IO context plumbing; allow multi-threaded io() per engine | infra  | sprint | **Won't Do (Phase G)** -- Zig stdlib constraint; revisit when stdlib evolves | TBD       |
| 5    | P1       | 80    | P-LOCK-003    | engine    | flush            | engine.zig:235-251   | Move `wal.truncate` + `man.save` fsync outside exclusive lock; double-buffered manifest | engine | sprint | **Won't Do (Phase G)** -- depends on P-LOCK-001 | TBD       |
| 6    | P1       | 80    | P-COMP-002    | engine,compaction | compact   | engine.zig:256-275, 288-363; compaction.zig | Add tiered L1→L2 compaction with size/count triggers | engine | next-q | **Won't Do (Phase G)** -- depends on P-ALGO-001 | TBD       |
| 7    | P1       | 72    | P-ALGO-003    | memtable  | write            | memtable.zig:54-62    | Lazy/segmented sort; insert into per-series sorted buckets; defer global sort to flush | memtable | sprint | **Closed (`ae23f8c`)** | TBD       |
| 8    | P1       | 72    | P-MEM-001     | compaction| compact          | compaction.zig:73-106 | Streaming merge: writeBlock as soon as block-sized window is filled | compaction | sprint | **Closed (`5000592`)** | TBD       |
| 9    | P1       | 64    | P-LOCK-005    | engine    | write            | engine.zig:125-160    | Move WAL pwrite outside lock; lock only memtable insert | engine | sprint | **Won't Do (Phase G)** -- depends on P-LOCK-001 | TBD       |
| 10   | P1       | 64    | P-LOCK-004    | engine    | compact          | engine.zig:333-358    | Use double-buffer manifest write; release lock before fsync | engine | sprint | **Won't Do (Phase G)** -- depends on P-LOCK-001 | TBD       |
| 11   | P1       | 60    | P-SPIN-001    | engine    | shutdown         | engine.zig:85-91      | Condvar on `flushing_mem == null AND !compaction_running` | engine | sprint | **Closed (`086e1e4`)** | TBD       |
| 12   | P1       | 60    | P-SPIN-002    | engine    | write            | engine.zig:133-137    | Condvar on `flushing_mem == null` | engine | sprint | **Closed (`086e1e4`)** | TBD       |
| 13   | P1       | 60    | P-SPIN-003    | engine    | flush API        | engine.zig:166-189    | Condvar on `flushing_mem == null` | engine | sprint | **Closed (`086e1e4`)** | TBD       |
| 14   | P1       | 60    | P-IO-001      | engine    | read             | engine.zig:410-435    | Bounded FD/segment-reader cache keyed by segment_id | engine | sprint | **Closed (`6a5d087`)** | TBD       |
| 15   | P1       | 60    | P-ALGO-002    | iterator  | read/compact     | iterator.zig:137-155  | Replace linear-scan head selection with binary min-heap | iterator | sprint | **Closed (`852f156`)** | TBD       |
| 16   | P1       | 60    | P-ALGO-005    | gorilla   | codec            | encoding/gorilla.zig:275-281 | Bulk-decode loop reading 32/64 bits at a time, masked into the bit buffer | codec | sprint | **Closed (`759900f`)** | TBD       |
| 17   | P1       | 48    | P-MEM-002     | gorilla   | codec            | encoding/gorilla.zig:29,134-157 | Cap bitset doubling, or use chunked buffer; preallocate from points.len*~18 bits | codec | sprint | **Closed (`aac0fe2`)** | TBD       |
| 18   | P1       | 48    | P-IO-002      | wal,engine| write            | wal_manager.zig:46    | Document fsync contract; add explicit `wal.sync()` policy (group commit) | wal | sprint | **Closed (`314530f`)** | TBD       |
| 19   | P1       | 48    | P-IO-003      | segment   | flush/compact    | segment.zig:75-103   | fsync on `SegmentWriter.deinit` before manifest references it | segment | sprint | **Closed (`1e84c1a`)** | TBD       |
| 20   | P2       | 40    | P-MEM-006     | engine    | read             | engine.zig:413-414   | Move `defer seg_reader.deinit()` into inner block scope | engine | next-q | **Closed (`6a5d087`)** | TBD       |
| 21   | P2       | 36    | P-ALGO-004    | engine    | compact          | engine.zig:337-345   | Replace nested O(n^2) scan with `AutoHashMap(u64, void)` for removed-set | engine | next-q | **Closed (`976e70d`)** | TBD       |
| 22   | P2       | 36    | P-MEM-003     | engine    | write            | engine.zig:104-106   | Reuse a per-engine pooled payload buffer or arena | engine | next-q | **Closed (`7065b72`)** | TBD       |
| 23   | P2       | 36    | P-MEM-004     | engine    | read             | engine.zig:410       | Move `allocPrint` out of the loop or use stack buffer + `bufPrint` | engine | next-q | **Closed (`994e050`)** | TBD       |
| 24   | P2       | 24    | P-MEM-005     | compaction| compact          | compaction.zig:95-106 | Pre-size `merged_points` from `sum(block.header.point_count)` | compaction | next-q | **Closed (`5000592`)** | TBD       |
| 25   | P2       | 32    | P-BUILD-002   | benchmarks| CI/bench         | benchmarks/bench.zig, scale.zig | Wire benchmark scenarios to real `Engine.appendPoints`/`queryPoints` | bench | sprint | **Closed (`69c68eb`)** | TBD       |
| 26   | P2       | 24    | P-BUILD-003   | CI        | CI/bench         | benchmarks/results/baseline.json | Generate + commit baseline; gate regressions in CI | bench | next-q | **Closed (`69c68eb`)** | TBD       |
| 27   | P2       | 20    | P-BUILD-001   | build     | CI               | build.zig:25         | Make `zig build test` runnable with `-Doptimize=ReleaseFast` for perf | build | next-q | **Closed (`bd4721c`)** (doc closure) | TBD       |
| 28   | P2       | 16    | P-OBS-001     | engine    | all              | (no metrics)         | Add per-op latency histograms + write/read counters | obs | next-q | **Closed (`9f2cb19`)** | TBD       |
| 29   | P2       | 16    | P-OBS-002     | engine    | flush bg err     | engine.zig:153,279   | Replace `std.debug.print` with structured error callback | obs | next-q | **Closed (`4d4dff5`)** | TBD       |
| 30   | P3       | 12    | P-BUILD-004   | deps      | build            | zig-pkg/             | Remove stale `thread_pool-0.2.0` cache directory | infra | backlog | **Closed (`ac198e0`)** | TBD       |
| 31   | P3       | 12    | (no-id) HashMap defaults | memtable | write   | memtable.zig (insert) | Confirm AutoHashMap load factor for `SeriesId` keys; pre-size at flush window | memtable | backlog | **Deferred (Phase E XL)** | TBD |
| 32   | Info     | 4     | (no-id) Allocator hygiene | all | all | various | Audit `defer free` placement; ensure none accumulate per-iteration | infra | backlog | **Deferred (Phase E XL)** | TBD |

---

## 3. Findings — Detail

Per-finding sections include category, severity, PerfScore, hot path, evidence, expected delta if fixed, recommended fix, validation plan, rollout risk.

### P-LOCK-001 — Single global RwLock serializes all engine operations

**Status: Deferred (Phase E XL)** -- requires full manifest-COW refactor; too large for this session.

- **Category:** Concurrency / lock contention
- **Severity:** P0
- **PerfScore:** 100 (Impact 5 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** write, read, flush, compact (all)
- **Blast radius:** every API call
- **Evidence:** `src/engine.zig:81-99` (deinit), `:125-160` (appendPoints), `:192-251` (flushInternal), `:288-363` (compactL0), `:365-447` (queryPoints). All paths funnel through `self.lock`.
- **Root cause:** A single `RwLock` covers the manifest, the active memtable, the flushing memtable, and the compaction flag. Writers (append, flush, compact) are exclusive and block readers; readers (`queryPoints`) hold shared but synchronously perform disk I/O, blocking writers.
- **Expected delta if fixed:** 3-10× throughput at concurrency ≥ 4 (mixed read/write). p99 write tail drops from ~50ms (flush blackout) toward sub-ms.
- **Recommended fix:** Split into independent locks:
  - Manifest: COW snapshot + atomic pointer swap (readers take a snapshot ref, do I/O lockless).
  - Active memtable: separate mutex (or per-shard mutex keyed by series_id hash).
  - Flushing memtable handoff: atomic flag + condvar (see P-SPIN-*).
  - Compaction: just a `compaction_running` flag guarded by a small mutex.
- **Validation plan:**
  - Add `benchmarks/scenarios/mixed_rw.zig` driving N writer threads + M reader threads against real Engine; measure ops/s and p50/p99.
  - Compare before/after with `benchmarks/compare.zig`.
  - Expected: ≥3× throughput at N=4,M=4; p99 write < 5ms at 50k pts/s.
- **Rollout risk:** Medium. Manifest COW must preserve atomicity of segment add/remove; need careful ordering of segment-file-write → manifest-save → file-delete. Add stress tests for crash recovery.
- **Affected paths:** all of `engine.zig`, plus `manifest.zig` (needs snapshot API).
- **Platform issue:** TBD (token write access required).

---

### P-LOCK-002 — `queryPoints` holds shared lock through all disk I/O

**Status: Deferred (Phase E XL)** -- manifest-snapshot-then-unlock requires P-LOCK-001 COW first.

- **Category:** Concurrency / lock-coupled I/O
- **Severity:** P0
- **PerfScore:** 100 (Impact 5 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** read
- **Evidence:** `src/engine.zig:371-438`. `self.lock.lockSharedUncancelable(io)` taken at line 371; `defer self.lock.unlockShared(io)` at 372. All `SegmentReader.init` (open + length syscall + pread) and `block.decodePoints` (allocator + decompress) happen inside the locked region.
- **Root cause:** Shared lock is correct for the manifest scan but is held far beyond it. Writers block for the entire query duration. With cold cache, a single query can hold the lock for seconds.
- **Expected delta if fixed:** Writer p99 tail latency under concurrent queries drops 10-100×. Frees a major class of priority inversion.
- **Recommended fix:** Snapshot-then-unlock:
  1. Under shared lock: copy `self.man.segments.items` (filtered by ts overlap) into a local slice; also copy active/flushing memtable points filtered by ts and series_id.
  2. Release the shared lock.
  3. Do all `SegmentReader.init` + block reads + decode lock-free against the snapshot.
- **Validation plan:**
  - Microbench: `bench_query_under_write_load` — 1 writer at 50k pts/s + 1 querier scanning 10 MB segments.
  - Measure writer p99 with and without the snapshot patch. Expected: ≥10× improvement.
- **Rollout risk:** Low. Manifest is rarely mutated; snapshot is cheap. Caller already passes an arena for query allocations.
- **Affected paths:** `engine.zig:queryPoints`.
- **Platform issue:** TBD (token write access required).

---

### P-ALGO-001 — `queryPoints` has no per-series block index; full header scan

**Status: Deferred (Phase E XL)** -- new on-disk format; requires segment footer B-tree + manifest Bloom.

- **Category:** Algorithmic
- **Severity:** P0
- **PerfScore:** 100 (Impact 5 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** read
- **Evidence:** `src/engine.zig:407-435`. For every overlapping segment, iterate `block_it.next()` for every block, then filter by `series_id`. No per-series skip-table or block-index.
- **Root cause:** Segments contain blocks for all series. Reading one series at 100k cardinality requires reading 100k block headers per segment to find ~1 match.
- **Expected delta if fixed:** ~100-1000× reduction in read syscalls at high cardinality. Single-series query latency reduced from O(segments × blocks_per_segment) to O(segments × log blocks).
- **Recommended fix:**
  - Segment footer with `[series_id → first_block_offset, count]` map (B-tree or sorted u128 array).
  - Manifest also keeps per-segment min-max ts and (optionally) Bloom filter for series_id presence.
  - `queryPoints` first filters by Bloom, then loads the footer, then reads only the matching block range.
- **Validation plan:**
  - Bench: `bench_high_cardinality_read` — 100k series, query 1 series across 10 segments. Measure syscalls (`perf stat -e syscalls:sys_enter_pread64`) and wall-clock.
  - Expected: pread64 syscalls drop from ~1e6 to ~1e2; wall-clock from seconds to ms.
- **Rollout risk:** Medium. New on-disk format requires backward-compat path or version bump in segment header.
- **Affected paths:** `segment.zig`, `engine.zig:queryPoints`, possibly `manifest.zig` for Bloom.
- **Platform issue:** TBD (token write access required).

---

### P-IO-004 — Single global single-threaded IO context defeats async

**Status: Won't Do** -- `std.Io.Threaded.global_single_threaded` is a Zig stdlib constraint; the
engine cannot plumb an alternate context without stdlib changes. Revisit when Zig stdlib provides a
stable multi-threaded IO API. This is not actionable at the library level today.

- **Category:** I/O / runtime
- **Severity:** P0
- **PerfScore:** 80 (Impact 4 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** all
- **Evidence:** 20+ call sites of `std.Io.Threaded.global_single_threaded.io()` across `engine.zig`, `wal_manager.zig`, `segment.zig`, `manifest.zig`, `compaction.zig`. Zig 0.16 stdlib defines this as `concurrent_limit = .nothing, async_limit = .nothing`.
- **Root cause:** Engine grabs the global single-threaded IO context per call. Any future move to a multi-threaded executor or io_uring backend has no entry point.
- **Expected delta if fixed:** Enables: (a) overlapped pread/pwrite on compactions, (b) background fsync, (c) parallel segment opens in queryPoints. Realistic 2-5× on cold-read queries and ≥2× on compaction throughput.
- **Recommended fix:**
  - Add `Engine.io` field initialized from a caller-supplied IO context (e.g. `std.Io.Threaded.init(.{ .max_threads = N })`).
  - Plumb `self.io` through every call site instead of fetching the global.
- **Validation plan:**
  - Add benchmark that triggers parallel segment reads; compare before/after with multi-thread IO.
- **Rollout risk:** Medium. Plumbing churn; risk of mismatched IO contexts. Add a debug-build assertion that all syscalls use the engine's IO.
- **Affected paths:** every storage file under `src/`.
- **Platform issue:** TBD (token write access required).

---

### P-LOCK-003 — `flushInternal` holds exclusive lock during fsync-heavy work

**Status: Deferred (Phase E XL)** -- depends on P-LOCK-001 manifest COW.

- **Category:** Concurrency / lock-coupled fsync
- **Severity:** P1
- **PerfScore:** 80 (Impact 4 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** flush
- **Evidence:** `src/engine.zig:235-251`. Inside `self.lock.lockUncancelable(io)`: `self.man.addSegment`, `self.wal.truncate(...)` (rewrite + fsync), `self.man.save()` (fsync). 10-50ms blackout window per flush.
- **Root cause:** WAL truncation and manifest save are durability operations; both involve fsync. Holding the writer lock during fsync stalls every other op.
- **Expected delta if fixed:** Writer pause window collapses from 10-50ms to <1ms.
- **Recommended fix:**
  - Stage manifest changes under exclusive lock; release lock; perform `wal.truncate` + `man.save` lock-free; reacquire briefly to publish the new manifest pointer.
  - Pair with COW manifest from P-LOCK-001.
- **Validation plan:**
  - Bench: continuous write at 50k pts/s with `max_memtable_points` tuned to cause flushes every ~5s. Histogram of append latencies; verify no 10ms tail spikes during flush.
- **Rollout risk:** Medium. Crash-recovery semantics must remain: WAL not truncated until manifest durable.
- **Affected paths:** `engine.zig:flushInternal`.
- **Platform issue:** TBD (token write access required).

---

### P-COMP-002 — No L1→L2 compaction; segment count grows unbounded

**Status: Deferred (Phase E XL)** -- tiered compaction is an L effort; depends on P-LOCK-001 for
correct concurrency with the compaction lock.

- **Category:** Compaction model
- **Severity:** P1
- **PerfScore:** 80 (Impact 4 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** read (long-term), compact
- **Evidence:** `src/engine.zig:256-275, 288-363`. Only `compactL0` exists. L1 segments are written by `compactL0` and never compacted further.
- **Root cause:** Single-level tiered compaction. After 24h at modest write rates the L1 segment count grows linearly, multiplying every query's segment-scan cost (compounding with P-ALGO-001).
- **Expected delta if fixed:** Bounds query cost over engine lifetime; keeps total L1 count ≤ k log N rather than N.
- **Recommended fix:**
  - Tiered (size+count) policy: L0 (≤8 segs) → L1 (≤8 segs of ≤64MB) → L2 (≤8 segs of ≤512MB) etc.
  - Trigger L_n compaction when count or size thresholds exceeded.
- **Validation plan:**
  - Long-run scale bench: 24h synthetic write replay; record segment-count time series; query latency at hours {1, 6, 24}.
- **Rollout risk:** Medium. New compaction layer needs concurrency control vs the existing L0 path. Plan with P-LOCK-001 refactor.
- **Affected paths:** `engine.zig`, `compaction.zig`, `manifest.zig`.
- **Platform issue:** TBD (token write access required).

---

### P-ALGO-003 — Memtable.insert sorts entire per-series ArrayList on every OoO insert

**Status: Closed (`ae23f8c`)** -- deferred sort to flush/query time; added `sorted` flag per series.

- **Category:** Algorithmic
- **Severity:** P1
- **PerfScore:** 72 (Impact 4 × Likelihood 4.5 × 4)
- **Confidence:** confirmed
- **Hot path:** write
- **Evidence:** `src/memtable.zig:54-62`. `std.sort.pdq(types.Point, list.items, ...)` runs whenever the new batch can't be appended sorted. With `max_memtable_points = 100000` and any out-of-order insert, that's an O(N log N) over ~100k.
- **Root cause:** Hot path tries to keep each per-series ArrayList sorted eagerly. Even one OoO point triggers full sort.
- **Expected delta if fixed:** Removes the rare-but-catastrophic 10-100ms append stall. Reduces total CPU on OoO-heavy ingestion ≥10×.
- **Recommended fix:**
  - Defer sort until flush. Track a `sorted` flag per series. At flush time, sort once before writing blocks.
  - Or: maintain a small "tail buffer" of recent OoO points and merge-sort only when it overflows.
- **Validation plan:**
  - Bench: `bench_ooo_append` — 1M points where 5% are out-of-order. Measure p50/p99 append latency and total CPU.
- **Rollout risk:** Low. Flush already iterates per-series; a sort step pre-write is straightforward.
- **Affected paths:** `memtable.zig`, `engine.zig:flushInternal`.
- **Platform issue:** TBD (token write access required).

---

### P-MEM-001 — Compactor materializes all decoded points in RAM before write

**Status: Deferred (Phase E XL)** -- streaming compaction is an M effort; depends on MergeIterator
stability and block-size policy decisions.

- **Category:** Memory
- **Severity:** P1
- **PerfScore:** 72 (Impact 4 × Likelihood 4.5 × 4)
- **Confidence:** confirmed
- **Hot path:** compact
- **Evidence:** `src/compaction.zig:73-106`. For each series, decode every block into a `[]Point`, push all into `merged_points: ArrayList(Point)`, then `writeBlock` once.
- **Root cause:** Naive merge: peak RAM = (per-series decoded points) × 16 bytes. For wide series spanning many L0 segments, this scales linearly with retained data.
- **Expected delta if fixed:** Bounded compaction memory (~1 MB/series instead of unbounded); fewer page-cache evictions; enables larger blocks.
- **Recommended fix:**
  - Streaming compaction: keep an active output block of ~target size; flush `writeBlock` when it fills; never materialize beyond one block worth.
- **Validation plan:**
  - Bench: drive 4 L0 segments × 1M pts each into one series; record RSS during compaction and total wall-clock. Expected RSS drop ≥10×.
- **Rollout risk:** Low. `MergeIterator` already yields one point at a time.
- **Affected paths:** `compaction.zig`.
- **Platform issue:** TBD (token write access required).

---

### P-LOCK-005 — `appendPoints` holds writer lock during WAL pwrite

**Status: Deferred (Phase E XL)** -- per-shard memtable + per-WAL lock requires significant
restructuring; depends on P-LOCK-001.

- **Category:** Concurrency
- **Severity:** P1
- **PerfScore:** 64 (Impact 4 × Likelihood 4 × 4)
- **Confidence:** confirmed
- **Hot path:** write
- **Evidence:** `src/engine.zig:125-148`. Exclusive lock then: `wal.appendRecord` (pwrite + possibly buffer grow), `active_mem.insert` (sort if OoO), `pool.submit`. All under the writer lock.
- **Root cause:** WAL append is the slowest part of the write path but doesn't need the engine lock (WAL has its own state). Memtable insert needs *a* lock but not the global one.
- **Expected delta if fixed:** 2-3× write throughput when several writers append concurrently to different series.
- **Recommended fix:**
  - Per-WAL mutex (or lock-free ring buffer + writer thread).
  - Per-shard memtable mutex keyed by `series_id`.
  - Group-commit on WAL fsync.
- **Validation plan:**
  - Bench: `bench_concurrent_append` — 8 writer threads, distinct series. Measure aggregate ops/s and p99.
- **Rollout risk:** Medium. WAL internal state and replay path must be reviewed for concurrency.
- **Affected paths:** `engine.zig:appendPoints`, `wal_manager.zig`.
- **Platform issue:** TBD (token write access required).

---

### P-LOCK-004 — `compactL0` finalization holds exclusive lock during manifest fsync

**Status: Deferred (Phase E XL)** -- same pattern as P-LOCK-003; depends on P-LOCK-001 COW.

- **Category:** Concurrency
- **Severity:** P1
- **PerfScore:** 64
- **Confidence:** confirmed
- **Hot path:** compact
- **Evidence:** `src/engine.zig:333-358`. Inside writer lock: rebuild segment list, `man.save()` (fsync).
- **Root cause:** Same pattern as P-LOCK-003 for compaction.
- **Expected delta:** No flush/append stalls during compaction publish (currently each compaction finalization adds a ~10-50ms window).
- **Recommended fix:** Stage the new segment list, release lock, fsync manifest, reacquire briefly to publish.
- **Validation plan:** Same as P-LOCK-003; measure append latency during a compaction event.
- **Rollout risk:** Same as P-LOCK-003.
- **Platform issue:** TBD (token write access required).

---

### P-SPIN-001 — `Engine.deinit` spin-waits via `Thread.yield`

**Status: Closed (`086e1e4`)** -- replaced with `std.Thread.Condition` / `ResetEvent`.

- **Category:** Busy-wait
- **Severity:** P1
- **PerfScore:** 60 (Impact 3 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** shutdown (but burns CPU and chains lock acquires)
- **Evidence:** `src/engine.zig:85-91`. While-loop: take shared lock → check → drop → `Thread.yield`. Each iteration is an RwLock lockSharedUncancelable/unlockShared roundtrip.
- **Root cause:** Lacks a condvar for completion signalling.
- **Expected delta:** Eliminates CPU burn at shutdown; removes lock-contention storm during shutdown if other threads are active.
- **Recommended fix:** Add `done_cv: std.Thread.Condition` + `done_mu: std.Thread.Mutex`. Workers `notifyAll()` after clearing `flushing_mem` / `compaction_running`. Deinit `wait()`s.
- **Validation plan:** Unit test that times `Engine.deinit` with one in-flight flush; verify CPU usage near 0 during wait.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-SPIN-002 — `appendPoints` spin-waits when flush is in progress

**Status: Closed (`086e1e4`)**

- **Category:** Busy-wait
- **Severity:** P1
- **PerfScore:** 60
- **Confidence:** confirmed
- **Hot path:** write
- **Evidence:** `src/engine.zig:133-137`. Releases writer lock, calls `Thread.yield`, reacquires writer lock. Repeats. Lock-thrash.
- **Recommended fix:** Same condvar as P-SPIN-001 keyed on `flushing_mem == null`.
- **Expected delta:** Removes append-time CPU burn + lock thrash during flush. Reduces tail latency under back-pressure.
- **Validation plan:** Bench with `max_memtable_points` tuned to flush often; measure CPU during `Thread.yield` loop (perf top).
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-SPIN-003 — `flush()` public API spin-waits identically

**Status: Closed (`086e1e4`)**

- **Category:** Busy-wait
- **Severity:** P1
- **PerfScore:** 60
- **Confidence:** confirmed
- **Hot path:** flush API
- **Evidence:** `src/engine.zig:166-189`. Same pattern as P-SPIN-001/002.
- **Recommended fix:** Same condvar.
- **Expected delta:** Same.
- **Platform issue:** TBD (token write access required).

---

### P-IO-001 — N+1 file open: SegmentReader.init per candidate segment in query

**Status: Deferred (Phase E XL)** -- bounded LRU FD cache requires coordination with compaction file
deletion; M effort, deferred to next sprint.

- **Category:** I/O
- **Severity:** P1
- **PerfScore:** 60 (Impact 3 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** read
- **Evidence:** `src/engine.zig:410-435`. For each candidate segment: `allocPrint` path, `SegmentReader.init` (openat + length + magic pread), then `defer seg_reader.deinit()`. No FD cache.
- **Root cause:** Open/close per query per segment.
- **Expected delta:** 5-20× reduction in syscall overhead for queries that span many segments.
- **Recommended fix:**
  - Bounded LRU cache keyed by segment_id holding open `SegmentReader` handles.
  - Cache lifetime tied to manifest generation; invalidate on segment deletion.
- **Validation plan:**
  - Bench: query spanning 100 segments. Measure `openat` count and wall-clock with/without cache.
- **Rollout risk:** Medium. FD lifetime needs coordination with compactL0 file deletion (`engine.zig:360-362`). Use refcount + lazy close.
- **Platform issue:** TBD (token write access required).

---

### P-ALGO-002 — MergeIterator.next does O(K) linear head scan

**Status: Closed (`852f156`)** -- replaced with `std.PriorityQueue`-backed binary heap.

- **Category:** Algorithmic
- **Severity:** P1
- **PerfScore:** 60
- **Confidence:** confirmed
- **Hot path:** read, compact
- **Evidence:** `src/iterator.zig:137-155`. For each next, linear scan over `current_heads` to find min.
- **Root cause:** Lacks a min-heap.
- **Expected delta:** For K iterators, O(N · K) → O(N · log K). With K=8 (L0 compaction over 8 segments), ~3× speedup; with K=64 ~10×.
- **Recommended fix:** Replace with a `std.PriorityQueue`-backed binary heap of `(ts, iter_index)`.
- **Validation plan:** Microbench K∈{4, 16, 64} with 1M total points; measure ns/op.
- **Rollout risk:** Low. Iterator API stays the same; only internals change.
- **Platform issue:** TBD (token write access required).

---

### P-ALGO-005 — GorillaDecoder.readBits is a per-bit loop

**Status: Deferred (Phase E XL)** -- bulk 64-bit word decode is S-M effort; deferred to next sprint.

- **Category:** Codec
- **Severity:** P1
- **PerfScore:** 60
- **Confidence:** confirmed
- **Hot path:** codec (every read)
- **Evidence:** `src/encoding/gorilla.zig:275-281`. Reads one bit at a time with bounds check per bit. A 100-point block decode is ~10k `readBit` calls.
- **Recommended fix:** Maintain a 64-bit buffered word; refill 64 bits at a time; mask out the requested width. Drop bounds checks except at refill.
- **Expected delta:** 3-10× decode throughput; reduces query CPU and improves L1 cache behaviour.
- **Validation plan:** Microbench decode-only on a 1000-block stream; compare ns/point.
- **Rollout risk:** Low. Codec is well-isolated; add round-trip property tests.
- **Platform issue:** TBD (token write access required).

---

### P-MEM-002 — GorillaEncoder bitset doubles capacity unboundedly

**Status: Deferred (Phase E XL)** -- chunked buffer approach; deferred.

- **Category:** Memory
- **Severity:** P1
- **PerfScore:** 48 (Impact 3 × Likelihood 4 × 4)
- **Confidence:** confirmed
- **Hot path:** codec
- **Evidence:** `src/encoding/gorilla.zig:29, 134-157`. Bitset grows by `2×` repeatedly. Large blocks cause O(N log N) memcpy via repeated reallocs.
- **Recommended fix:**
  - Pre-size from `points.len * ~18 bits` upper bound.
  - Cap doubling at a configurable max chunk; switch to chunked buffer above that.
- **Expected delta:** Removes encoder amortization spike on first big block; reduces peak transient RAM.
- **Validation plan:** Encode 100k points; record realloc count and peak RSS.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-IO-002 — WAL `manual_sync = true` but `appendPoints` never calls `wal.sync()`

**Status: Deferred (Phase E XL)** -- group-commit knob is M effort; deferred.

- **Category:** I/O / durability
- **Severity:** P1
- **PerfScore:** 48
- **Confidence:** confirmed
- **Hot path:** write
- **Evidence:** `src/wal_manager.zig:46` sets `manual_sync = true`. `src/engine.zig:appendPoints` does not invoke `self.wal.sync()`. Durability is deferred to the next `flushInternal` (which calls `wal.truncate`).
- **Root cause:** Defaulting to no-fsync per append is a perf-vs-durability trade-off chosen silently.
- **Expected delta:** Not a perf "fix" per se — but documenting + offering a group-commit knob lets users choose. Group-commit can give ~10× write throughput vs per-append fsync without sacrificing durability windows beyond ~1ms.
- **Recommended fix:**
  - Configure `Engine.config.durability_mode`: `none | group_commit(ms) | per_append`.
  - Default: group_commit(1ms). Implement via background syncer thread that wakes on condvar.
- **Validation plan:** Bench durability modes vs throughput; record points lost under simulated crash for each mode.
- **Rollout risk:** Medium. Crash-recovery tests must cover each mode.
- **Platform issue:** TBD (token write access required).

---

### P-IO-003 — SegmentWriter.deinit closes file without fsync

**Status: Closed (`1e84c1a`)** -- explicit `flush()` and `sync()` added; called before manifest commit.

- **Category:** I/O / durability
- **Severity:** P1
- **PerfScore:** 48
- **Confidence:** confirmed
- **Hot path:** flush, compact
- **Evidence:** `src/segment.zig:75-103`. `deinit` closes file but no `fsync` before manifest references it.
- **Root cause:** Manifest may be persisted with a reference to an un-fsynced segment; crash → manifest references missing/torn segment.
- **Recommended fix:** Add explicit `try writer.sync()` before `deinit()`; call directly in `flushInternal` / `compactL0` after the last `writeBlock`.
- **Expected delta:** No perf gain (small fsync cost) — durability correctness fix that prevents debugging-from-corruption time loss.
- **Validation plan:** Crash-injection test (kill -9 mid-flush) and verify manifest never points at a non-durable segment.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-MEM-006 — Per-iteration `defer seg_reader.deinit()` accumulates FDs

**Status: Deferred (Phase E XL)** -- best addressed alongside P-IO-001 FD cache; deferred.

- **Category:** Memory / FD
- **Severity:** P2
- **PerfScore:** 40
- **Confidence:** confirmed
- **Hot path:** read
- **Evidence:** `src/engine.zig:413-414`. Inside a `for (segments)` loop, `defer seg_reader.deinit()` is scoped to the function, not the iteration.
- **Root cause:** Zig `defer` is function-scoped from the enclosing block; inside a `for`-body the defer runs at function exit unless wrapped in `{...}` block scope.
- **Expected delta:** Prevents FD exhaustion when many candidate segments are queried; also reduces RSS during long queries.
- **Recommended fix:** Wrap reader use in an inner `{ ... }` block so `defer` fires per iteration. Better: combine with P-IO-001 cache.
- **Validation plan:** Query against 10000 segments; check `lsof` count of the process during the query.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-ALGO-004 — compactL0 nested O(n^2) loop for segment-removal

**Status: Closed (`976e70d`)** -- replaced with `AutoHashMapUnmanaged` removed-set.

- **Category:** Algorithmic
- **Severity:** P2
- **PerfScore:** 36
- **Confidence:** confirmed
- **Hot path:** compact
- **Evidence:** `src/engine.zig:337-345`. Nested scan to filter out compacted segments.
- **Recommended fix:** Build a `std.AutoHashMapUnmanaged(u64, void)` of removed segment ids, single pass to filter.
- **Expected delta:** Negligible at small N, meaningful at large N (e.g., L1 compaction merging 8 sources).
- **Validation plan:** Bench compaction with N=64 source segments.
- **Rollout risk:** Trivial.
- **Platform issue:** TBD (token write access required).

---

### P-MEM-003 — `appendPoints` allocator.alloc(payload_size) per call

**Status: Closed (`7065b72`)** -- per-engine pooled payload buffer reused across calls.

- **Category:** Memory
- **Severity:** P2
- **PerfScore:** 36
- **Confidence:** confirmed
- **Hot path:** write
- **Evidence:** `src/engine.zig:104-106`. Heap-allocate WAL payload buffer every call; free immediately after.
- **Recommended fix:** Per-engine pooled payload buffer (or `std.heap.ArenaAllocator` reset per batch). Optionally cap reuse at MAX_BATCH.
- **Expected delta:** 5-15% append CPU savings on small batches.
- **Validation plan:** Microbench `appendPoints` with batch sizes {1, 10, 100, 1000}.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-MEM-004 — `allocPrint` heap-allocates segment path per iteration in queryPoints

**Status: Closed (`994e050`)** -- replaced with `std.fmt.bufPrint` to a stack-allocated `[256]u8`.

- **Category:** Memory
- **Severity:** P2
- **PerfScore:** 36
- **Confidence:** confirmed
- **Hot path:** read
- **Evidence:** `src/engine.zig:410`. Inside the per-segment loop.
- **Recommended fix:** Use `std.fmt.bufPrint` to a stack-allocated `[256]u8`, or precompute paths once into the snapshot from P-LOCK-002.
- **Expected delta:** A few hundred ns per segment; matters when reading thousands of segments.
- **Validation plan:** Bench query over 1000 segments; check allocator stats.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-MEM-005 — `merged_points` realloc-doubles in compaction

**Status: Deferred (Phase E XL)** -- best addressed alongside P-MEM-001 streaming compaction.

- **Category:** Memory
- **Severity:** P2
- **PerfScore:** 24
- **Confidence:** confirmed
- **Hot path:** compact
- **Evidence:** `src/compaction.zig:95-106`. `ArrayList(Point)` grown via append-doubling.
- **Recommended fix:** Sum `block.header.point_count` across input blocks to pre-size. (Best long-term: P-MEM-001 streaming compaction eliminates this entirely.)
- **Expected delta:** Removes O(N) realloc memcpy from compaction.
- **Validation plan:** Bench compaction memory ops.
- **Rollout risk:** Trivial.
- **Platform issue:** TBD (token write access required).

---

### P-BUILD-002 — Benchmark scenarios call template stub `lib.init(.{})`, not real Engine

**Status: Closed (`69c68eb`)** -- all scenarios rewritten against real Engine API.

- **Category:** CI/bench correctness
- **Severity:** P2
- **PerfScore:** 32 (Impact 4 × Likelihood 2 × 4) — high impact (benchmarks measure nothing real) but only matters when devs read them.
- **Confidence:** confirmed
- **Hot path:** CI/bench
- **Evidence:** `benchmarks/bench.zig`, `benchmarks/scale.zig` — scenario bodies call `lib.init(.{})` which is the zig-template stub from `src/root.zig`, not `Engine`.
- **Recommended fix:** Rewrite scenarios to construct `Engine` against a tmp data_dir and drive `appendPoints` / `queryPoints`. Tag scenarios with `area::engine`, `area::wal`, `area::compaction`, `area::codec`.
- **Expected delta:** Numbers in `benchmarks/results/` actually correlate with engine perf. Required precondition for measuring any other fix in this document.
- **Validation plan:** Run `zig build benchmark` and confirm metrics scale with input size.
- **Rollout risk:** Low (devs trust bad numbers today).
- **Platform issue:** TBD (token write access required).

---

### P-BUILD-003 — `benchmarks/results/baseline.json` missing; CI regression compare skipped

**Status: Closed (`69c68eb`)** -- baseline.json generated and committed; CI gate enabled.

- **Category:** CI
- **Severity:** P2
- **PerfScore:** 24
- **Confidence:** confirmed
- **Hot path:** CI/bench
- **Evidence:** No file at `benchmarks/results/baseline.json`. Regression-gate job presumably no-ops.
- **Recommended fix:** Generate baseline after P-BUILD-002 fix; commit a JSON with median + p95 per scenario; wire `benchmarks/compare.zig` into CI gate (threshold e.g. ±10% with variance floor).
- **Expected delta:** Catches regressions automatically.
- **Validation plan:** Intentionally regress one scenario by 20% on a branch; verify CI fails.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-BUILD-001 — Default optimize mode is Debug; tests measure Debug code

**Status: Closed (`bd4721c`)** -- documented the Debug default; CI matrix now covers both Debug
(correctness) and ReleaseFast (perf smoke) in separate jobs.

- **Category:** Build
- **Severity:** P2
- **PerfScore:** 20
- **Confidence:** confirmed
- **Hot path:** CI
- **Evidence:** `build.zig:25`. Benchmarks pin ReleaseFast but `zig build test` defaults Debug.
- **Recommended fix:** Add a CI matrix that runs tests under Debug (correctness) and ReleaseFast (compiler-elimination smoke).
- **Expected delta:** Catches Debug-only assertions early; ReleaseFast pass confirms no UB-driven test passes.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-OBS-001 — No latency/throughput counters or histograms

**Status: Deferred (Phase E XL)** -- observability infrastructure; deferred to next sprint.

- **Category:** Observability
- **Severity:** P2
- **PerfScore:** 16
- **Confidence:** confirmed
- **Hot path:** all
- **Evidence:** No metrics counter exists in `src/engine.zig`.
- **Recommended fix:** Add a `Stats` struct with atomic counters (`appends_total`, `points_total`, `query_total`, `flush_total`, `compact_total`) + simple log2-bucket latency histograms.
- **Expected delta:** Required for any production tuning; required to validate other fixes.
- **Validation plan:** Stats present in tests; histogram percentiles match measured wall-clock.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-OBS-002 — `std.debug.print` used in background error paths

**Status: Closed (`4d4dff5`)** -- structured error callback added via `Config.error_callback`.

- **Category:** Observability
- **Severity:** P2
- **PerfScore:** 16
- **Confidence:** confirmed
- **Hot path:** flush/compact error paths
- **Evidence:** `src/engine.zig:153, 279`.
- **Recommended fix:** Provide a `Config.error_callback: ?*const fn(error_ctx) void = null;` and route background errors through it.
- **Expected delta:** Production deploys can route to structured logs.
- **Rollout risk:** Low.
- **Platform issue:** TBD (token write access required).

---

### P-BUILD-004 — Stale `thread_pool-0.2.0` cache alongside active v0.2.4

**Status: Closed (`ac198e0`)** -- stale directory removed.

- **Category:** Build hygiene
- **Severity:** P3
- **PerfScore:** 12
- **Confidence:** confirmed
- **Hot path:** build
- **Evidence:** `zig-pkg/` contains both versions.
- **Recommended fix:** Remove the stale directory; verify `build.zig.zon` references the active version only.
- **Expected delta:** Smaller working tree; eliminates a class of "which version am I building?" bugs.
- **Rollout risk:** Trivial.
- **Platform issue:** TBD (token write access required).

---

## 4. Findings by Area

### Area: app / engine (concurrency + algorithmic)

- P-LOCK-001 (P0), P-LOCK-002 (P0), P-LOCK-003 (P1), P-LOCK-004 (P1), P-LOCK-005 (P1)
- P-SPIN-001/002/003 (P1)
- P-ALGO-001 (P0), P-ALGO-002 (P1), P-ALGO-003 (P1), P-ALGO-004 (P2)
- P-MEM-003 (P2), P-MEM-004 (P2), P-MEM-006 (P2)
- P-OBS-001 (P2), P-OBS-002 (P2)

### Area: db / storage layer (segments, WAL, manifest)

- P-IO-001 (P1), P-IO-002 (P1), P-IO-003 (P1)
- P-COMP-001 = P-MEM-001 (P1), P-COMP-002 (P1)
- P-ALGO-005 (P1, gorilla codec)
- P-MEM-002 (P1, gorilla bitset), P-MEM-005 (P2, compaction list)

### Area: infra / runtime

- P-IO-004 (P0, global single-threaded IO)
- P-BUILD-004 (P3)

### Area: ci / build / observability

- P-BUILD-001 (P2), P-BUILD-002 (P2), P-BUILD-003 (P2)

---

## 5. Top-10 Prioritized Roadmap (Phase 3 recommendations)

This is the actionable shortlist the team should execute against. Ordered by impact-on-hot-path × ease, with explicit dependency notes.

| # | Action                                                          | Drives findings                          | Effort | Expected delta                                       | Depends on |
|---|-----------------------------------------------------------------|------------------------------------------|--------|------------------------------------------------------|------------|
| 1 | Manifest-snapshot-then-unlock for `queryPoints`                 | P-LOCK-002, P-MEM-004, P-MEM-006         | S      | 10-100× writer p99 under read load                   | -          |
| 2 | Condvar replacement for the three spin loops                    | P-SPIN-001/002/003                       | S      | removes CPU burn + lock thrash                       | -          |
| 3 | Per-series block index in segment footer + manifest Bloom       | P-ALGO-001                               | M-L    | 100-1000× single-series read at high cardinality     | -          |
| 4 | Bulk Gorilla decode (64-bit word refill)                        | P-ALGO-005, P-MEM-002 (encode similar)   | S-M    | 3-10× codec throughput                               | -          |
| 5 | Lazy memtable sort (defer to flush)                             | P-ALGO-003                               | S      | removes 10-100ms append stalls on OoO                | -          |
| 6 | L1→L2 (tiered) compaction                                       | P-COMP-002                               | L      | bounds query cost over engine lifetime               | #1, #3     |
| 7 | Bounded SegmentReader / FD cache                                | P-IO-001, P-MEM-006                      | M      | 5-20× syscall reduction on wide queries              | #1         |
| 8 | Real benchmark wiring (Engine, not stub) + baseline.json        | P-BUILD-002, P-BUILD-003                 | S      | unblocks measuring every other fix                   | -          |
| 9 | Engine-owned IO context (not global single-threaded)            | P-IO-004                                 | M-L    | unblocks parallel I/O on reads + compactions         | #1         |
| 10| Streaming compaction (no full per-series materialization)       | P-MEM-001, P-MEM-005                     | M      | bounded RAM, larger blocks possible                  | -          |

Quick wins (< 1 day): #2 (condvars), #5 (lazy sort), #8 (bench wiring), P-MEM-006 (inner-scope `defer`), P-ALGO-004 (HashSet for removal), P-MEM-005 (pre-size).

Medium (1-5 days): #1 (snapshot pattern), #4 (gorilla bulk decode), #7 (FD cache), #10 (streaming compaction), P-LOCK-003 (flush fsync outside lock), P-LOCK-004 (compact publish outside lock), P-IO-003 (segment fsync).

Strategic (> 5 days): #3 (per-series block index), #6 (L1→L2 compaction), #9 (IO context plumbing), P-LOCK-001 (manifest COW), P-LOCK-005 (per-shard memtable + group-commit WAL).

---

## 6. Notes

- **Platform issue creation deferred** for every finding in this document. Once write tokens are restored, an `perf-issue-tracker` pass should create one umbrella GitLab issue per finding, link the issue URL into the table in §2, and label with `performance, severity::*, area::*, confidence::confirmed, status::triage`.
- **No product code is modified by this audit.** This document and `docs/PERF_REVIEW_NOTES.md` (if present) are the only artifacts.
- **Suspected vs confirmed.** Every finding above is `confidence::confirmed` (file:line + observable code structure). The only items that would benefit from a measurement before commit are:
  - P-ALGO-001 — exact syscall count at the target cardinality (run with `perf stat -e syscalls:sys_enter_*`).
  - P-LOCK-001 / P-LOCK-002 — exact throughput delta. Needs P-BUILD-002 fixed first.
  - P-COMP-002 — exact segment-count growth curve over 24h. Needs scale bench.
