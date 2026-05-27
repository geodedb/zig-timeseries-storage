# Bench-optimize audit — `merge_iter_k4/k16/k64`

**Date:** 2026-05-27
**Slug:** `mergeiter-presize`
**Targets:** `merge_iter_k4`, `merge_iter_k16`, `merge_iter_k64`
**Repo:** /home/benji/src/devnw/zig/timeseries-storage
**Language:** Zig 0.16.0

---

## 1. Target benchmark(s)

| Bench id | Native command | ops/iter | warmup | samples |
|---|---|---|---|---|
| `merge_iter_k4` | `zig build bench-micro-merge -- --filter merge_iter_k4` | 4000 | 2 | 10 |
| `merge_iter_k16` | `zig build bench-micro-merge -- --filter merge_iter_k16` | 16000 | 2 | 10 |
| `merge_iter_k64` | `zig build bench-micro-merge -- --filter merge_iter_k64` | 64000 | 2 | 10 |

All three live in `benchmarks/micro/merge.zig`. They share a single `runMerge(ctx, comptime K: u32)` body that builds K sorted slices of 1000 points each, constructs `MergeIterator`, calls `addIterator` K times, then drains via `next()` in a loop XORing into a sink.

---

## 2. Measured code path (file:line citations)

The measured surface is exclusively the `MergeIterator` API in `src/iterator.zig`.

| Operation | Symbol | File:line | Notes |
|---|---|---|---|
| Construction | `MergeIterator.init(allocator)` | `src/iterator.zig:199` | Returns an empty struct; `iters: ArrayListUnmanaged = .empty`, `heap: HeapType.empty`. **No capacity hint accepted.** |
| Add stream | `MergeIterator.addIterator(self, it)` | `src/iterator.zig:213-232` | `iters.ensureUnusedCapacity(allocator, 1)` then `heap.push(allocator, .{ .point = head, .iter_index = idx })`. **`heap.push` grows internal storage by doubling — K=64 calls produce ⌈log2(64)⌉ = 6 reallocs in the worst case.** |
| Drain | `MergeIterator.next(self)` | `src/iterator.zig:234-253` | Each call pops the heap min and re-pushes the next head from the same iter (`heap.push(...)`). For K=64 with full streams, this is 64,000 push calls — but the heap size stays bounded at K, so steady-state push does NOT reallocate. |
| Heap type | `HeapType = std.PriorityQueue(HeapEntry, void, compareHeap)` | `src/iterator.zig:197` | Backed by `std.ArrayList` internally; the relevant capacity method (Zig 0.16 stdlib) is `ensureTotalCapacity(allocator, n)` on the underlying list, exposed on `PriorityQueue` as the same name. |

**Other allocation sources during the scenario:**

- `iters.appendAssumeCapacity` after `ensureUnusedCapacity` — also doubles internally per K. Pre-sized via `ensureTotalCapacity(allocator, K)` would eliminate these.
- `MergeIterator.deinit` calls `iters.deinit(allocator)` + `heap.deinit(allocator)` — single free each.

---

## 3. Dominant metrics expected

Per `benchmarks/framework/scenario.zig` `ResultRow`, the following metrics are reported per scenario:

- `wall_ns_p50` — median per-iteration nanoseconds (full `runMerge` body)
- `throughput_ops_per_sec` — `ops_per_iteration / (wall_p50 / 1e9)` (each "op" is one point drained)
- `wall_ns_stddev` — population stddev across samples
- `alloc_count` — average per-iteration heap allocations under the `TrackingAllocator`
- `peak_live_bytes` — peak live bytes during the iteration

**Current baseline (commit `2723d3b`, znver2/linux/x86_64), `benchmarks/results/micro-merge.json`:**

| Bench | p50 ns/iter | throughput (ops/s) | allocs/iter | peak_live |
|---|---|---|---|---|
| `merge_iter_k4` | 122,162 | 32.74M | 6 | 64,336 |
| `merge_iter_k16` | 576,533 | 27.75M | 19 | 256,992 |
| `merge_iter_k64` | 3,947,139 | 16.21M | **71** | 1,027,464 |

`alloc_count` grows ~linearly with K (6 → 19 → 71). Theoretical lower bound for pre-sized: ~2 allocs/iter (one for `iters`, one for `heap`), regardless of K.

**Throughput scaling observation:** K=4 → K=64 is 16× more streams and 16× more drained points, but per-point throughput drops 32.74M / 16.21M ≈ 2.02×. Expected `O(log K)`: log4 = 2, log64 = 6, ratio 3×. **Observed 2× is BETTER than log(K) prediction**, suggesting reallocation overhead from `heap.push` growth contributes; once pre-sized, per-point throughput should track log(K) more tightly OR improve further.

---

## 4. Related tests

These tests MUST keep passing after any optimization:

| File | Test name | Concern |
|---|---|---|
| `src/iterator.zig:319-354` | `MergeIterator with SliceIterators` | Basic 3-stream interleave; ordering correctness |
| `src/iterator.zig:356-387` | `MergeIterator: K=10 streams, correct ordering and tie-break (P-ALGO-002)` | K=10 fan-in; produces dense 0..(K*N)-1 sequence |
| `src/iterator.zig:389-414` | `MergeIterator: tie-break favours earliest-added iterator` | Critical for compactor dedup correctness |
| `src/iterator.zig:416-452` | `MergeIterator: empty and single-stream cases` | Edge cases |

Run command: `zig build test -Doptimize=Debug` and `-Doptimize=ReleaseFast`. Both must pass.

Plus integration tests that exercise the compactor (which is the production user of `MergeIterator`):

| File | Concern |
|---|---|
| `tests/integration.zig` | Compaction integration |
| `tests/stress.zig` | High-volume compaction stress |
| `tests/engine_e2e.zig` | End-to-end including compaction |

Run: `zig build test-integration`, `zig build test-stress`, `zig build test-engine-e2e`.

---

## 5. Likely confounders

- **`std.PriorityQueue` internal API changes between Zig 0.16 patch versions.** The method to pre-size is `ensureTotalCapacity(allocator, n)` based on the std.ArrayList contract, but verify the actual name on `PriorityQueue` in `zig version` 0.16.0 before relying on it.
- **`ReleaseFast` inlining** may already partly amortize allocation cost. The optimization may show different gains in Debug vs ReleaseFast.
- **`TrackingAllocator` is not thread-safe** (`tracking_allocator.zig:14`); `MergeIterator` is single-threaded by design, so this doesn't bite here but is worth noting.
- **Heap-as-ArrayList growth pattern**: each `push` may grow the underlying storage by `*2`. K=64 → 64 pushes during `addIterator`. The growth events at K-thresholds {2,4,8,16,32,64} produce 6 reallocs. Pre-sizing to K eliminates all of them.
- **Bench fixture cost is constant per scenario** (build K slices of 1000 Points × 16 bytes = K × 16KB). At K=64 = 1MB of fixture data per iteration — non-trivial but constant across baseline and candidate, so the delta is preserved.
- **CPU frequency scaling** — the bench runs on a machine without `cpufreq-set -g performance`; expect 5-15% noise in wall_ns_p50 even without code changes. The 15% noise floor in `compare.zig` covers this.
- **Allocator backing** — the runner wraps `ctx.allocator` with `TrackingAllocator`. Whatever backing allocator the runner uses (likely `ArenaAllocator` from `main`'s arena) affects raw allocation cost.

---

## 6. Known hot paths

The `MergeIterator` is exercised in production by `src/compaction.zig` (the K-way merge that folds L0 segments into L1). Calls per compaction = (segments per compaction × points per segment). In `bench_concurrent_rw` and `compaction_cost` integration scenarios, MergeIterator allocation cost is **part of the steady-state compaction wall time**.

| Caller | File:line | Fan-in (K) |
|---|---|---|
| `src/compaction.zig` (L0→L1 merge) | grep `MergeIterator` in `src/compaction.zig` for line numbers | typically K = `COMPACTION_L0_COUNT = 4` per `benchmarks/bench.zig:41`; higher in adversarial workloads |
| `src/engine.zig` (queryPoints multi-segment scan) | grep `MergeIterator` in `src/engine.zig` | K = number of overlapping segments per query series |

Allowed-paths in the bench-optimize session: `src/iterator.zig`, `src/compaction.zig`. The optimization may either:

1. Add a capacity hint parameter to `MergeIterator.init(allocator, hint)` and update callers in `src/compaction.zig` (and `engine.zig` if applicable — note `engine.zig` is NOT in allowed_paths, so any change there needs the allowed_paths to expand).

2. Add a separate `MergeIterator.initCapacity(allocator, K)` constructor leaving `init(allocator)` backwards-compatible (preferred — no caller churn).

The compaction call site is the realistic enterprise-database hot path; preserving its API is important.
