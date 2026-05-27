# Baseline Decision — `mergeiter-presize`

**Date:** 2026-05-27
**Verdict:** STOP per `/bench-optimize:run` variance policy

## Variance measurement

Two independent baseline runs of 1 warmup + 10 measured rounds against
`merge_iter_k4/k16/k64`:

| Bench | Baseline (unpinned) p50_stddev_pct | Baseline (taskset -c 0 pinned) p50_stddev_pct | Policy threshold |
|---|---|---|---|
| `merge_iter_k4` | 7.7% | 12.1% | 5% (compiled micro) |
| `merge_iter_k16` | 11.9% | 16.5% | 5% |
| `merge_iter_k64` | 8.7% | 9.8% | 5% |

CPU pinning did not reduce variance. Likely uncontrollable noise sources
on the host (ondemand governor, background processes, thermal throttle).

Raw data: `baseline/raw/`, `baseline-pinned/raw/`.

## Why this matters

The proposed optimization (`MergeIterator` pre-sized PriorityQueue) has
predicted wall-time impact ≤1% because:

- Allocation cost is a small fraction of `next()` per-point cost
- Heap doubling on push has cumulative copy work ≈4KB across log2(K) grows; ~4µs at K=64
- Total predicted savings: ≤30µs out of 3680µs measured (0.8% at K=64)

At a 9-16% measured noise floor, a 0.8% gain is **undetectable**. The
`/bench-optimize:run` decision rule
(`max(+5%, 3*stddev_pct)`) would require a 24-50% gain to declare a win.
The optimization is correct but **not validatable on this hardware via
this workflow**.

## Recommendation

1. **Defer the MergeIterator pre-size optimization** until either:
   - Bench host noise drops to <1% via dedicated runner + performance
     governor + cpufreq pinning, OR
   - The optimization is bundled with another change targeting the same
     code path (e.g., reuse a single heap across compactions), increasing
     aggregate signal.
2. **Switch evaluation to alloc_count secondary metric** for this class of
   optimization. The result schema's `alloc_count` field already exposes
   this; the validator would need to gate on alloc_count instead of
   throughput.
3. **Pursue the dominant enterprise-readiness gap (P-LOCK-001 family)
   outside the `/bench-optimize:run` workflow** — it is explicitly an XL
   architectural refactor, not a single-hypothesis change.

## Evidence preserved

- `audit-notes.md` — full audit
- `baseline/` — unpinned 10-round baseline + raw JSONs + host state
- `baseline-pinned/` — taskset -c 0 10-round baseline
- `.bench-optimize/session.json` — session state with both baselines

The bench infrastructure (commit `2723d3b`) remains valuable for:

- Validating other optimizations that produce larger wall-time deltas
- Detecting regressions in `MergeIterator` allocation count (alloc_count
  is already reported per-scenario)
- Providing the bench evidence needed for the P-LOCK-001 ADR
