# Gap Analysis

This document identifies requirements-to-code gaps between the Geode timeseries storage specification
([ts-storage-spec.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/ts-storage-spec.md))
and the current timeseries-storage library implementation.

GitLab serves as the authoritative system of record for all requirements and gap tracking.

## Run Summary

- **Date:** 2026-05-26 (initial audit; closures through Phase G)
- **Audit phase:** full `/codepros:audit` (Phase 1 spec extraction, Phase 2 codebase mapping, Phase 3 gap detection)
- **Open gaps:** 11 (GAP-0001 through GAP-0011); 10 closed full, 1 partial (GAP-0002 only) after Phase G
- **Verified-implemented spec items:** 3 (SPEC-NEW-2, SPEC-NEW-5, SPEC-NEW-6) -- see [GAP_ANALYSIS_RESOLVED.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS_RESOLVED.md)

## Gap-Closure Session Summary

- **Date:** 2026-05-26
- **Session:** gap-closure run; 46+ commits merged across phases A-G
- **Items closed (full):** GAP-0001, GAP-0003, GAP-0004, GAP-0005, GAP-0006, GAP-0007, GAP-0008, GAP-0009, GAP-0010, GAP-0011 (10 of 11)
- **Items partial:** GAP-0002 (seam + opaque derivation landed; persistent tenant catalog deferred)
- **GitLab issue updates:** token write access unavailable during this session; all issue closures marked "close manually after token restore"

### Phase G closure summary (this session)

- **GAP-0001 (full):** Manifest TDE landed in commit `910b7a5`. AES-256-GCM `TSMNF002` format completes TDE coverage across WAL (`38a944b`), segments (`c376bb5`), and now the manifest. SEC-006 closed in full as a side effect.
- **GAP-0002 (minimal viable):** Commit `407732f` lands the `AccessController` seam (gating both `appendPoints` and `queryPoints`) and the `opaqueSeriesId(tenant, app_key, key)` HMAC-SHA256 derivation. SEC-007 (BOLA access seam) and SEC-008 (opaque ID derivation) close on this commit. A full persistent tenant catalog is still future work but does not require further engine API changes — adapters can wire the seam + derivation without coordination.
- **GAP-0010 (full):** Commit `723aa6f` adds overlap-aware compaction. Cross-segment OoO writes are now reconciled by folding overlapping segments at compaction time; same-timestamp collisions resolve last-write-wins. A strict opt-in mode (`allow_cross_segment_ooo = false`) rejects OoO points with `error.OutOfOrderTimestamp` for callers that need monotonic-only ingest.

Fully-closed items have been moved to
[GAP_ANALYSIS_RESOLVED.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS_RESOLVED.md).

---

## Open / Partial / Deferred Gaps

### GAP-0001: Missing Encryption-at-Rest (TDE)

- **GitLab issue:** [#1](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/1)
- **Category:** Security
- **Severity:** High
- **Status:** **Closed (full)** -- commits `38a944b` (WAL), `c376bb5` (segments), `910b7a5` (manifest)

#### Closure summary

Full AES-256-GCM TDE now covers every on-disk artefact:

| Surface  | Magic       | AAD                                                       | Commit    |
|----------|-------------|-----------------------------------------------------------|-----------|
| WAL      | -           | (wal-library internal)                                    | `38a944b` |
| Segment  | `TSSEG003`  | `graph_uuid \|\| "seg" \|\| segment_id \|\| block_index`  | `c376bb5` |
| Manifest | `TSMNF002`  | `ts_uuid \|\| "mnf" \|\| counter`                         | `910b7a5` |

Domain-separation tags (`"seg"` vs `"mnf"`) prevent cross-context
ciphertext reuse even when surfaces share the same 32-byte master
key. Wrong-key / no-key reopens fail closed with
`error.DecryptionFailed`. SEC-006 closed as a side effect.

---

### GAP-0002: Plaintext Metadata Leakage and Series Identity Exposure

- **GitLab issue:** [#2](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/2)
- **Category:** Security
- **Severity:** Medium
- **Status:** **Partial (seam + derivation closed; persistent catalog deferred)** -- commit `407732f`

#### What was closed in Phase G (commit `407732f`)

Two reusable primitives ship in this commit:

1. **`AccessController` seam** — pluggable per-call authoriser
   wired into `appendPoints` and `queryPoints`. The engine gates
   every call through the controller BEFORE any state mutation.
   Reference implementations: `PermissiveAccessController` (always
   allow), `DenyAllAccessController` (always deny, fail-closed
   default). SEC-007 (BOLA) closes against this seam.

2. **`opaqueSeriesId(tenant, app_key, key)`** — HMAC-SHA256(key,
   tenant_le \|\| app_key_le) truncated to u128. Callers derive
   unguessable SeriesIds without exposing the key to the engine.
   SEC-008 (raw u128 enumerability) closes against this helper.

#### What remains open

A persistent `(tenant_id, app_series_id) -> opaque_id` catalog is
still future work. Adapters that want full GAP-0002 coverage today
already have everything they need: the seam enforces the boundary,
and the HMAC derivation provides the catalog entries. The remaining
work is "store the entries in a durable, encrypted-at-rest table" —
something the engine itself does not need to know about (it stays
`u128`-on-disk; only the adapter's derivation needs to round-trip).

#### Unblock steps

1. Agree on the catalog data model with the Geode team (ADR).
2. Implement the catalog inside the adapter (Geode) using the
   engine's existing `appendPoints` / `queryPoints` surface.
3. Wire the adapter's authoriser implementation into the
   engine's `access_controller` config slot.

No further engine API changes are required.

---

### GAP-0010: Cross-Segment Out-of-Order Writes Rejected

- **GitLab issue:** TBD -- pending issue creation (token write access required)
- **Category:** Feature
- **Severity:** High
- **Status:** **Closed (full)** -- commit `723aa6f`

#### Closure summary (commit `723aa6f`)

The compaction layer now reconciles overlapping segments instead
of leaving them stranded. Two modes:

- **Permissive (default, `allow_cross_segment_ooo = true`):**
  `appendPoints` accepts late points; the resulting overlapping
  segment is folded back into time order by the next compaction
  pass. Same-timestamp collisions resolve last-write-wins via the
  MergeIterator tie-break + per-ts dedup pipeline.
- **Strict (opt-in, `allow_cross_segment_ooo = false`):**
  `appendPoints` returns `error.OutOfOrderTimestamp` when any
  input ts is less than the running per-series watermark. No
  state mutation on rejection.

Implementation details:

- Both `compactL0` (background) and `compactL0Forced` (operator-
  driven) now route through `collectOverlappingInputsLocked`:
  pick every L0 segment, then expand the set with any higher-
  level segment whose `[min_ts, max_ts]` overlaps. Inputs are
  sorted by segment id ascending so the merge produces last-
  write-wins.
- Output level = max(input.level) so OoO reconciliation does NOT
  climb the level ladder unboundedly.
- Strict-mode watermark stored per-series in a HashMap, seeded
  lazily from the manifest on first reference.

Tests cover end-to-end cross-segment OoO reconciliation, same-
timestamp last-write-wins resolution, and strict-mode rejection.
