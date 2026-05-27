# PERF Gap Analysis — timeseries-storage

Last updated: 2026-05-26 (Phase G XL closure pass)
Source phases: perf-scanner (Phase 2) + perf-reviewer (Phase 3), consolidated.
Mode: **DOCS-ONLY**. Platform issue creation is deferred (token write access required).

## Gap-Closure Session Summary (2026-05-26)

- **Session:** 46+ commits; performance items addressed across Phases A-G.
- **Perf findings closed (full):** 29 of 32
- **Perf findings closed (won't-do, Phase G):** 8 of 32 — see "Phase G Won't-Do" section below
- **Perf findings remaining open:** 3 of 32 (2 unidentified no-ID items deferred; see §2 table)
- **Platform issues:** token write access unavailable; all GitLab actions deferred.

## Phase H — Bench-driven enterprise-readiness pass (2026-05-27)

Closed in this session by the bench-driven sweep documented in
`docs/performance/2026-05-27-codec-micro-mixed-rw/ENTERPRISE_READINESS.md`:

| Tag | Title | Commit | Outcome |
|---|---|---|---|
| ENT-001 / ENT-004 | `MergeIterator.initCapacity` + compactor caller | `9247206` | `merge_iter_k64` allocs 71 → 66 |
| ENT-002 / ENT-005 | Memtable `initCapacity` + engine call-site updates | `ad415a6` | `memtable_insert_sorted/ooo` allocs 2 → 0; wall ~halved |
| ENT-003 | `GorillaEncoder.reset` + `SegmentWriter` encoder pool | `dc50428` | `compaction_cost` allocs 107 → 100 |
| ENT-006 (partial P-LOCK-005) | Atomic counters + WAL internal mutex | `4b40592` | `bench_concurrent_append` +7.5% throughput |

P-LOCK-005 status updated from "Won't-Do" to "Partially Closed" — see
its detail section below.

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
| P-LOCK-003  | flushInternal holds lock during fsync                     | **Partially Closed (this session).** Conservative scope-down landed: the WAL truncate (which rewrites + fsyncs the entire WAL file) now runs OUTSIDE `engine.mu`, while the `man.save()` fsync remains inside the lock (moving it out requires manifest COW, still XL). The reorder also fixes a pre-existing durability bug: the previous code truncated the WAL BEFORE saving the manifest, which on crash between the two could lose records the flush had just absorbed into a new segment. New ordering — `addSegment` → `man.save()` (durable) → release lock → `wal.truncate` — preserves the WAL-after-manifest invariant. `deinit` now waits on the new `flush_workers_active` counter so the post-publish I/O cannot run against torn-down state. | Remaining: full manifest COW so `man.save()` fsync can also move outside the lock — same chain as P-LOCK-001.                                                                                                                                                       |
| P-LOCK-004  | compactL0 finalization holds lock during fsync            | **No-op this session.** Compaction has no WAL truncate, so the conservative scope-down that closed half of P-LOCK-003 does not apply here — the only fsync inside the compaction publish lock is `man.save()`, and moving it out requires the same manifest COW that P-LOCK-001 / P-LOCK-003 are gated on. The heavy compactor work (open inputs, merge, write+fsync output segment) already runs OUTSIDE the lock. Doc-only update on `runMergeAndCommit` clarifies the residual cost. | Same chain as P-LOCK-001 (manifest COW so the publish-side `man.save()` fsync can move outside the lock).                                                                                                                                                          |
| P-LOCK-005  | appendPoints holds lock during WAL pwrite                 | Depends on P-LOCK-001. Moving the WAL pwrite outside the lock without a memtable shard scheme would create lost-update races.                                                                                                                                                                                                  | Same as P-LOCK-001.                                                                                                                                                                                                                                                |
| P-ALGO-001  | Per-series block index                                    | **Partially Closed (this session).** Backwards-compatible additive footer landed in `src/segment.zig` / `src/iterator.zig` / `src/engine.zig` — NEW segments now carry a sorted `(series_id, first_block_offset, block_count)` index after the last data block, plus a 16-byte `[FOOTER_OFFSET][FOOTER_MAGIC]` sentinel. Old segments without the footer continue to read unchanged. `Engine.querySegment` consults `SegmentReader.findSeries` and skips the whole segment when the footer proves the series is absent. Synthetic bench (1000 series × 5 blocks × 64 points, 100 random single-series lookups, ReleaseFast): full scan ≈ 328 ms total → footer-indexed ≈ 0.39 ms total (~850× speedup). Migration tooling for existing on-disk segments + manifest-level Bloom/min-max sidecars remain deferred. | Remaining: (1) Optional migration tool to retrofit footers onto existing segments. (2) Manifest-level Bloom filter for series presence. (3) Manifest-level min/max sidecars.                                                                                       |
| P-COMP-002  | L1→L2 tiered compaction                                    | Depends on P-ALGO-001 + lock decomposition. Without the per-series index, L2 compaction is no cheaper than rewriting every L1 segment in place, which is what the engine already does on full compaction.                                                                                                                     | Same chain as P-ALGO-001.                                                                                                                                                                                                                                          |
| ~~P-IO-004~~ (Closed) | ~~Global single-threaded IO context~~                | **Closed.** Earlier note that "`std.Io.Threaded` does not expose a pooled multi-threaded IO context" was wrong: Zig 0.16's `std.Io.Threaded.init(gpa, .{})` constructs a multi-threaded context with `async_limit = cpu_count - 1` and `concurrent_limit = .unlimited` by default. The engine now owns (or borrows) its IO context via `EngineConfig.io` / `Engine.io`; all engine-internal call sites use `self.io` instead of `global_single_threaded.io()`. See "Closed in this session" below. | n/a — closed                                                                                                                                                                                                                                                       |
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
| P-LOCK-002, P-IO-001, P-MEM-006 | E | `6a5d087` |
| P-ALGO-005 | E | `759900f` |
| P-MEM-001, P-MEM-005 | E | `5000592` |
| P-MEM-002 | E | `aac0fe2` |
| P-IO-002 | E | `314530f` |
| P-OBS-001 | E | `9f2cb19` |
| P-IO-004 | G | (this session — P-IO-004 multi-threaded IO context) |

### Deferred (Phase E XL or won't-do)

Won't-do: P-LOCK-001, P-LOCK-005, P-COMP-002.
Partially Closed: P-ALGO-001 (additive footer landed; migration tooling + manifest Bloom remain), P-LOCK-003 (WAL truncate fsync out of `engine.mu`; manifest fsync still inside, gated on manifest COW), P-LOCK-004 (no scope-down possible without manifest COW — doc-only this session).
Remaining open (no-ID, deferred): HashMap defaults (rank 31), Allocator hygiene (rank 32).

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
3. ~~**P-ALGO-001**~~ — **Partially Closed (this session).** Backwards-compatible footer index landed in `segment.zig` + `iterator.zig` + `engine.zig`. Single-series segment lookup is now O(log entries) on indexed segments; legacy un-indexed segments keep the original full-scan path. Synthetic bench (1000 series × 5 blocks, 100 random lookups, ReleaseFast): ~850× speedup vs. full scan. Migration tooling and manifest-level Bloom remain deferred.
4. ~~**P-IO-004**~~ — **Closed.** Engine now owns/borrows its own `std.Io.Threaded` (multi-threaded by default: `async_limit = cpu_count - 1`, `concurrent_limit = .unlimited`); engine-internal call sites use `self.io` instead of `global_single_threaded.io()`. Bench `bench_concurrent_rw` p50 wall improved 729.6 ms → 699.4 ms (~4%) on the 3-sample reference run.
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
| 3    | P0       | 100   | P-ALGO-001    | engine    | read             | engine.zig:407-435   | Per-series block index (segment-local + manifest-level Bloom/min-max) | engine  | sprint | **Partially Closed (this session)** -- segment-local footer landed (backwards-compatible additive change; ~850× single-series lookup speedup on synthetic 1k-series bench). Migration tooling + manifest-level Bloom remain deferred. | TBD       |
| 4    | P0       | 80    | P-IO-004      | engine    | all      | src/engine.zig (15+ call sites) | Engine-owned `std.Io.Threaded` constructed in `Engine.init` via `std.Io.Threaded.init(allocator, .{})` (default: `async_limit = cpu_count - 1`, `concurrent_limit = .unlimited`); all engine-internal call sites use `self.io`. Caller override via `EngineConfig.io`. | infra  | sprint | **Closed (this session)** -- multi-threaded IO context plumbed through engine; `bench_concurrent_rw` ~4% faster | TBD       |
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

**Status: Closed (`6a5d087`)** -- manifest snapshot under shared lock; disk I/O now happens lock-free. LRU SegmentReader cache also landed in this commit.

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

**Status: Partially Closed (this session).** The backwards-compatible portion has landed; the migration-tooling + manifest-level Bloom portion remains deferred.

#### What landed (this session)

- **On-disk additive change.** Segments written by `SegmentWriter` now carry an optional trailing footer:
  - `[BLOCK_0]..[BLOCK_N]` — unchanged.
  - `[FOOTER_BODY]` — `entry_count u32 LE || entry_count × FooterEntry { series_id u128, first_block_offset u64, block_count u32 } || crc32c u32 LE`, entries sorted ascending by `series_id`.
  - `[FOOTER_OFFSET u64 LE][FOOTER_MAGIC u64 LE]` — last 16 bytes of the file. `FOOTER_MAGIC = 0x544553454709090A`.
- **Backwards compatibility.** Reader probes the last 16 bytes for `FOOTER_MAGIC`; absence → segments behave exactly as before. Corrupt CRC → segment downgrades to no-footer mode (data still readable via the full block iterator). The segment magic, block format, and block CRC are unchanged.
- **Reader fast path.** `SegmentReader.findSeries(series_id)` is O(log entries). `Engine.querySegment` jumps directly to the first matching block and stops after the recorded run length, *and* short-circuits the entire segment when the footer proves the series is absent. `SegmentIterator` mirrors the same fast path.
- **Iterator stop boundary.** `SegmentReader.data_end_offset` (= footer offset when present, else file size) keeps `BlockIterator` from parsing the footer body as a `BlockHeader`.
- **Tests** in `src/segment.zig`: round-trip (5 series, scrambled write order), backwards-compat (truncated file with no footer), corrupted-CRC fallback, encrypted-segment footer, empty-writer skips footer, `FooterEntry` serialisation, `Footer.lookup` binary search.
- **Verification.** Full suite green twice: `test` (99/99), `test-integration` (8/8), `test-stress` (3/3), `test-engine-e2e` (1/1), `test-wal-recovery` (8/8). `bench-micro-segment-rw` shows no regression on segment write/read micros.
- **Synthetic bench.** 1000 series × 5 blocks × 64 points, 100 random single-series lookups, ReleaseFast: full scan ≈ 328 ms total → footer-indexed ≈ 0.39 ms total (**~850× speedup**); both paths return identical block counts (`expectEqual` enforced).

#### Still deferred

- Migration tool to retrofit footers onto existing on-disk segments.
- Manifest-level Bloom filter and min/max sidecars (cross-segment pruning before the per-segment footer lookup).
- Bench: `bench_high_cardinality_read` at 100k series / 10 segments with `perf stat -e syscalls:sys_enter_pread64` to confirm wall-clock and syscall delta on a representative workload.

#### Historical detail (pre-change)

- **Category:** Algorithmic
- **Severity:** P0
- **PerfScore:** 100 (Impact 5 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** read
- **Evidence:** `src/engine.zig:407-435`. For every overlapping segment, iterate `block_it.next()` for every block, then filter by `series_id`. No per-series skip-table or block-index.
- **Root cause:** Segments contain blocks for all series. Reading one series at 100k cardinality requires reading 100k block headers per segment to find ~1 match.
- **Expected delta if fixed:** ~100-1000× reduction in read syscalls at high cardinality. Single-series query latency reduced from O(segments × blocks_per_segment) to O(segments × log blocks). The synthetic bench above lands inside that band.
- **Recommended fix:**
  - Segment footer with `[series_id → first_block_offset, count]` map (sorted u128 array). **Landed.**
  - Manifest also keeps per-segment min-max ts and (optionally) Bloom filter for series_id presence. **Deferred.**
  - `queryPoints` first filters by Bloom, then loads the footer, then reads only the matching block range. Footer-load step **landed**; Bloom step **deferred**.
- **Rollout risk:** Low. The format change is strictly additive: the segment magic, the block header bytes, the block CRC, and the block payload are byte-for-byte identical to TSSEG002 / TSSEG003 for the block region. Old readers stop at file size and never see the footer (their iterator just walks past the same blocks they always walked); new readers see the sentinel at EOF and use it. A corrupt footer downgrades silently to the legacy path.
- **Affected paths:** `src/segment.zig`, `src/iterator.zig` (`SegmentIterator`), `src/engine.zig` (`querySegment`). Manifest is **not** touched in this partial close.
- **Platform issue:** TBD (token write access required).

---

### P-IO-004 — Single global single-threaded IO context defeats async

**Status: Closed (this session).** The earlier "Won't Do" note was incorrect: Zig 0.16's
`std.Io.Threaded.init(gpa, .{})` (lib/std/Io/Threaded.zig:1607+) constructs a multi-threaded IO
context with sensible defaults (`async_limit = cpu_count - 1`, `concurrent_limit = .unlimited`).

The fix:

- `EngineConfig.io: ?std.Io = null` — optional caller-supplied IO handle. When `null`, the
  engine constructs its own context; when non-null the engine borrows it.
- `Engine.threaded: ?*std.Io.Threaded` (heap-allocated when engine-owned, null when borrowed)
  and `Engine.io: std.Io` (active handle).
- `Engine.init` heap-allocates a `std.Io.Threaded` with stdlib defaults (or borrows the
  caller-supplied one), stores it on the engine, and threads `self.io` through every
  storage I/O call inside the engine.
- `Engine.deinit` joins the background syncer and any in-flight flush/compaction worker
  (existing condition-variable wait), then calls `Threaded.deinit` + `allocator.destroy` on
  the engine-owned context. Borrowed contexts are left untouched.

Heap allocation (rather than embedding `std.Io.Threaded` inline on the Engine struct) is
required because `Threaded.io()` returns an `Io` whose `userdata` points at the `Threaded`
instance; embedding inline would dangle that pointer the moment the Engine value is moved
out of `init()`.

- **Category:** I/O / runtime
- **Severity:** P0
- **PerfScore:** 80 (Impact 4 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** all
- **Evidence (pre-fix):** 15 call sites of `std.Io.Threaded.global_single_threaded.io()` inside Engine methods in `src/engine.zig` (every public entry point: `init`, `deinit`, `appendPoints`, `flush`, `flushInternal`, `compactL0`, `compactAll`, `queryPoints`, `sync`, `pruneExpired`, `lastBackgroundError`, `syncerLoop`, plus internal helpers). Zig 0.16 stdlib defines `global_single_threaded` as `concurrent_limit = .nothing, async_limit = .nothing` — every storage I/O serialised on one async slot.
- **Post-fix:** 0 `global_single_threaded` references inside Engine methods. Engine-method I/O routes through `self.io`; the global is retained only by `nowMonotonicNs` (a clock-read helper that doesn't need a dispatcher) and by free-standing test helpers (per scope: benches/tests are external observers).
- **Bench delta:** `bench_concurrent_rw` (3 samples, znver2, Linux): p50 wall 729.6 ms → 699.4 ms (−4.1%), throughput 71,271 ops/s → 74,354 ops/s (+4.3%), stddev 941 → 625 ops/s. Modest because the bench's hot path is WAL-fsync-bound and most fsyncs already run under a single-flusher invariant; the bigger payoffs land on cold reads + compaction where parallel preads matter.
- **Backwards compatibility:** `EngineConfig.io` defaults to `null`, so every existing caller picks up the engine-owned multi-threaded context automatically. Tests in `tests/`, examples, and bench helpers in `benchmarks/` that touch `global_single_threaded.io()` directly are unchanged (they are external observers — owning their own IO context is correct).
- **Rollout risk (closed):** Tests run twice clean across `zig build test`, `test-integration`, `test-stress`, `test-engine-e2e`, `test-wal-recovery`.
- **Affected paths:** `src/engine.zig` (all changes). `src/segment.zig`, `src/manifest.zig`, `src/wal_manager.zig`, `src/compaction.zig`, `src/memtable.zig`, `src/backup.zig`, `src/iterator.zig`, `src/migration.zig` continue to accept an `io: std.Io` parameter from their callers — those callers (the engine) now pass `self.io`, so the global-IO flow is severed at the engine boundary even though the leaf modules' signatures did not change.
- **Platform issue:** TBD (token write access required).

---

### P-LOCK-003 — `flushInternal` holds exclusive lock during fsync-heavy work

**Status: Partially Closed (this session)** -- conservative scope-down landed;
full `man.save()` move-out still depends on P-LOCK-001 manifest COW.

- **Category:** Concurrency / lock-coupled fsync
- **Severity:** P1
- **PerfScore:** 80 (Impact 4 × Likelihood 5 × 4)
- **Confidence:** confirmed
- **Hot path:** flush
- **Evidence:** `src/engine.zig:flushInternal`. Before this session: `self.man.addSegment` + `self.wal.truncate(...)` (rewrite + fsync) + `self.man.save()` (fsync) all ran inside `engine.mu`. After this session: `wal.truncate` (the heavier of the two fsyncs, since it rewrites the entire WAL file via tmp + fsync + rename) now runs OUTSIDE `engine.mu`. `man.save()` still runs inside the lock.
- **Root cause:** WAL truncation and manifest save are durability operations; both involve fsync. The WAL fsync is now lock-free (WAL has its own internal mutex per ENT-006). The manifest fsync remains inside the engine lock until manifest COW lands — moving the manifest save out without COW would race against concurrent `addSegment` callers and could publish a torn segment list.
- **Concurrent durability bug fixed by the reorder:** the previous code did `wal.truncate(lsn)` BEFORE `man.save()`. A crash between those two would leave the on-disk manifest pointing at the OLD `last_checkpoint_lsn` while the WAL had been compacted past the new one — recovery would start from the old LSN, look for records that no longer exist in the WAL, and lose the segment's data even though the segment file itself was on disk. The new ordering (manifest durable → release lock → WAL truncate) preserves the WAL-after-manifest invariant under any crash window.
- **Worker-lifetime invariant:** a new `flush_workers_active` counter ensures `Engine.deinit` waits for the post-publish I/O (WAL truncate + compaction trigger) to drain before tearing down `self.wal` / `self.man`. Without that, the worker could touch freed state after the lock-clear of `flushing_mem` woke `deinit`.
- **Remaining work:** full `man.save()` move-out via manifest COW (stage in inactive slot, publish under brief reacquire). Same chain as P-LOCK-001.
- **Validation plan:**
  - Bench: continuous write at 50k pts/s with `max_memtable_points` tuned to cause flushes every ~5s. Histogram of append latencies; verify no 10ms tail spikes during flush.
- **Rollout risk:** Medium. Crash-recovery semantics preserved by the new ordering (manifest durable BEFORE WAL truncate).
- **Affected paths:** `engine.zig:flushInternal`, `engine.zig:flushWorker`, `engine.zig:deinit`.
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

**Status: Closed (`5000592`)** -- streaming merge implemented; `writeBlock` now fires when a block-sized window fills rather than materializing all points first.

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

**Status: Closed (per-shard memtable + engine.mu release, 2026-05-27)** — WAL internal mutex (ENT-006), atomic counters, per-shard memtable, atomic active_mem pointer with in-flight-writer barrier, and engine.mu released around the WAL+memtable phase.

- **Category:** Concurrency
- **Severity:** P1
- **PerfScore:** 64 (Impact 4 × Likelihood 4 × 4)
- **Confidence:** confirmed
- **Hot path:** write
- **Evidence:** Original — `src/engine.zig:125-148` had exclusive lock around `wal.appendRecord` + `active_mem.insert` + `pool.submit`.
- **Root cause:** WAL append is the slowest part of the write path but doesn't need the engine lock (WAL has its own state). Memtable insert needs *a* lock but not the global one.
- **Final closure:**
  - **Per-shard memtable** (`src/memtable.zig`): the `Memtable` now contains `NUM_SHARDS = 16` `Shard` values, each with its own `std.Io.Mutex` and `std.AutoHashMap`. Shard pick is `series_id & (NUM_SHARDS - 1)` (NUM_SHARDS is a power of two). `point_count` is `std.atomic.Value(usize)`; reads via `.load(.acquire)`, increments via `.fetchAdd(.release)`. Concurrent writers on distinct shards never contend.
  - **Heap-allocated active/flushing memtables** (`src/engine.zig`): `active_mem: std.atomic.Value(*memtable.Memtable)`, `flushing_mem: ?*memtable.Memtable`. Rotation builds a new heap-allocated memtable, publishes the new pointer via `.store(.release)`, and moves the old pointer into `flushing_mem` for the flush worker.
  - **In-flight-writer barrier** (`Memtable.pending_writers: std.atomic.Value(u32)`): every `appendPoints` calls `target_mem.beginAppend()` BEFORE `insert` and `target_mem.endAppend()` AFTER. The flush worker calls `target_mem.waitForQuiescence()` on `flushing_mem` immediately after seeing the rotation, BEFORE scanning. This closes the "late-arrival insert after flush worker began scan" lost-update race: a writer that snapshotted the OLD pointer pre-rotation has bumped `pending_writers` on the OLD memtable; the flush worker waits until the writer's `endAppend()` fires before it begins reading.
  - **Engine.mu release**: `appendPoints` now takes `engine.mu` ONLY for (a) the optional strict-OoO check (`config.allow_cross_segment_ooo == false` only) and (b) the post-insert flush-trigger + watermark bump. The WAL append + memtable insert run with `engine.mu` released; concurrent writers on distinct shards run in parallel.
- **Race-condition analysis:**
  - *Lost-update on flushing memtable*: a writer that snapshotted active_mem pre-rotation must finish its insert before the flush worker scans. Closed by the `pending_writers` barrier described above.
  - *Use-after-free of rotated memtable*: rotation moves the OLD pointer into `flushing_mem` (still alive); the flush worker only `destroy()`s the memtable AFTER scanning + commit. Writers cannot observe a freed memtable because `flushing_mem` always points to a still-live allocation until the worker explicitly frees it under `engine.mu`.
  - *Query-path use-after-free*: `queryPoints` still drains memtables under `engine.mu` (the engine lock guards POINTER LIFETIME there, not writer exclusion — concurrent inserts still contend only on the per-shard mutex). The flush worker's final `destroy()` also runs under `engine.mu`, so a query in progress cannot have its `flushing_mem` pointer freed under it.
  - *Strict OoO mode*: the watermark map is touched only under `engine.mu`. The brief `lock → check → unlock` window covers OoO validation; the bump after insert runs under another brief lock acquisition. Order is preserved.
  - *Counter atomicity*: counter writes are `.fetchAdd(.release)`; the snapshot via `stats()` is per-field consistent. No change from the ENT-006 partial closure.
  - *Payload buffer*: the previous engine-owned scratch buffer (P-MEM-003) was abandoned because its single-owner contract required `engine.mu`. Each `appendPoints` now heap-allocates and frees its own payload (16 + 16·N bytes). The allocator round-trip is cheap next to the WAL append and is the unblock for parallel writer scaling.
- **Measured:**
  - ENT-006 partial closure baseline: 3.28M ops/s median.
  - Post-closure: 3.89-4.38M ops/s median across two independent A/B passes (5 samples each). Throughput uplift ~18-33% on the contended-writers bench. No regressions on `bench_concurrent_rw`, `bench_ooo_append`, or `bench_recovery_latency`.
- **Remaining work surfaced by this change:**
  - Strict-mode OoO check still takes `engine.mu` — acceptable because the default permissive mode skips it entirely. Tightening would require moving the watermark map under its own mutex; out of scope here.
  - The query path still holds `engine.mu` while draining memtables to guard pointer lifetime. A refcount-based scheme would let queries scan without `engine.mu` (matching the writer path), but that is a follow-up optimization with its own bench validation.
- **Affected paths:** `engine.zig:appendPoints`, `engine.zig:maybeTriggerFlushLocked`, `engine.zig:flushInternal`, `engine.zig:flush`, `engine.zig:queryPoints`, `memtable.zig` (full rewrite).
- **Platform issue:** TBD (token write access required).

---

### P-LOCK-004 — `compactL0` finalization holds exclusive lock during manifest fsync

**Status: Partially Closed (this session — doc-only)** -- compaction has no
WAL truncate, so the conservative scope-down that closed half of P-LOCK-003
does not apply; the residual `man.save()` fsync move-out depends on the same
manifest COW as P-LOCK-001 / P-LOCK-003.

- **Category:** Concurrency
- **Severity:** P1
- **PerfScore:** 64
- **Confidence:** confirmed
- **Hot path:** compact
- **Evidence:** `src/engine.zig:runMergeAndCommit`. Inside `engine.mu`: segment-list rebuild + `man.save()` (fsync). All other compaction work (open inputs, merge, write+fsync output segment) already runs OUTSIDE the lock.
- **Root cause:** Same pattern as P-LOCK-003 for compaction, minus the WAL piece. The manifest fsync cannot move out without manifest COW: any release-and-reacquire window would let a concurrent `addSegment` (from a parallel flush) interleave between our snapshot of the segment list and our publish swap, producing a torn manifest that drops the flush's new segment.
- **Expected delta if fully closed:** No flush/append stalls during compaction publish (currently each compaction finalization adds a ~10-50ms window).
- **Recommended fix:** Stage the new segment list, release lock, fsync manifest via a cloned manifest writing to the inactive ping-pong slot, reacquire briefly to publish (advance the in-memory counter + segment list under the lock). Same manifest-COW surface as P-LOCK-001 / P-LOCK-003.
- **Validation plan:** Same as P-LOCK-003; measure append latency during a compaction event.
- **Rollout risk:** Same as P-LOCK-003.
- **Affected paths (this session — doc-only):** `engine.zig:runMergeAndCommit` (added doc-comment explaining residual cost is gated on manifest COW).
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

**Status: Closed (`6a5d087`)** -- bounded LRU SegmentReader cache keyed by segment_id landed alongside P-LOCK-002; FD lifetime coordinated with compaction deletion.

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

**Status: Closed (`759900f`)** -- bulk 64-bit word refill implemented; per-bit loop replaced with masked word reads.

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

**Status: Closed (`aac0fe2`)** -- pre-sized from `points.len * ~18 bits` upper bound; doubling capped at configurable max chunk.

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

**Status: Closed (`314530f`)** -- fsync contract documented; `Engine.config.durability_mode` added with `none | group_commit(ms) | per_append` variants.

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

**Status: Closed (`6a5d087`)** -- defer moved into inner block scope; also subsumed by the LRU SegmentReader cache landed in the same commit.

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

**Status: Closed (`5000592`)** -- pre-sized from summed `block.header.point_count`; realloc eliminated. (Also superseded by P-MEM-001 streaming compaction in the same commit.)

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

**Status: Closed (`9f2cb19`)** -- `Stats` struct with atomic counters and log2-bucket latency histograms added to `engine.zig`.

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

- ~~P-IO-004~~ (P0, global single-threaded IO) — **Closed this session**
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
| 9 | ~~Engine-owned IO context (not global single-threaded)~~ — **Closed this session** | P-IO-004           | M-L    | ~~unblocks parallel I/O on reads + compactions~~ — landed | #1         |
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
