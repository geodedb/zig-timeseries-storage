# Gap Analysis

This document identifies requirements-to-code gaps between the Geode timeseries storage specification
([ts-storage-spec.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/ts-storage-spec.md))
and the current timeseries-storage library implementation.

GitLab serves as the authoritative system of record for all requirements and gap tracking.

## Run Summary

- **Date:** 2026-05-26 (initial audit)
- **Audit phase:** full `/codepros:audit` (Phase 1 spec extraction, Phase 2 codebase mapping, Phase 3 gap detection)
- **Open gaps:** 11 (GAP-0001 through GAP-0011)
- **Verified-implemented spec items:** 3 (SPEC-NEW-2, SPEC-NEW-5, SPEC-NEW-6) -- see [GAP_ANALYSIS_RESOLVED.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS_RESOLVED.md)

## Gap-Closure Session Summary

- **Date:** 2026-05-26
- **Session:** gap-closure run; 32 commits merged
- **Items closed (full):** GAP-0003, GAP-0004, GAP-0005, GAP-0006, GAP-0007, GAP-0008, GAP-0011 (7 of 11)
- **Items partial:** GAP-0001, GAP-0009 (2 of 11)
- **Items deferred:** GAP-0002, GAP-0010 (2 of 11)
- **GitLab issue updates:** token write access unavailable during this session; all issue closures marked "close manually after token restore"

Fully-closed items (GAP-0003 through GAP-0011 where complete) have been moved to
[GAP_ANALYSIS_RESOLVED.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS_RESOLVED.md).

---

## Open / Partial / Deferred Gaps

### GAP-0001: Missing Encryption-at-Rest (TDE)

- **GitLab issue:** [#1](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/1)
- **Category:** Security
- **Severity:** High
- **Status:** Partial (WAL wired; segments + manifest still plaintext)

#### What was closed (commit `38a944b`)

`WalConfig.encryption_key` is now wired through `EngineConfig` and propagated to `WalManager` on
`Engine.init`. The AES-256-GCM key slot is populated when a key is provided in config.

#### What remains open

- `SegmentWriter` still writes blocks in plaintext (`src/segment.zig:60-63`).
- `Manifest.writeToFile` still serializes plaintext (`src/manifest.zig:147-159`).
- No AES-256-GCM framing is implemented for either file type.
- AAD binding to `{graph_uuid, file_type, segment_id}` not implemented.

#### Recommended next steps

1. Implement AES-256-GCM framing in `SegmentWriter` and `Manifest.writeToFile`/`readFromFile`.
2. Bind AAD to `{graph_uuid, file_type, segment_id}` to prevent cross-file substitution attacks.
3. Unit tests: reading a segment or manifest without the key must fail.

#### GitLab issue action

Would be moved to "In Progress" (partially closed) -- token unavailable, update manually.

---

### GAP-0002: Plaintext Metadata Leakage and Series Identity Exposure

- **GitLab issue:** [#2](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/2)
- **Category:** Security
- **Severity:** Medium
- **Status:** Deferred -- API-breaking change; blocked on Geode coordination

#### Reason for deferral

Implementing a tenant-scoped `SeriesId` catalog requires an API-breaking change to both
`appendPoints` and `queryPoints` (adding a `TenantContext` parameter). This touches the Geode
integration contract and cannot be landed without coordination with the Geode team's public API
surface. The dependent `SEC-007` (BOLA) and `SEC-008` (raw u128) findings also remain open.

#### Unblock steps

1. Agree on the `TenantContext` parameter shape with the Geode team.
2. Draft an ADR covering the encrypted catalog design.
3. Implement the catalog, then update the API signature.
4. Migrate all existing callers in Geode before merging.

#### GitLab issue action

Would remain Open with a "Deferred" label and a comment explaining the blocker -- token
unavailable, update manually.

---

### GAP-0009: Missing v1 -> v2 Segment Format Migration Path

- **GitLab issue:** TBD -- pending issue creation (token write access required)
- **Category:** Feature
- **Severity:** Medium
- **Status:** Partial -- format version bumped to `TSSEG002` in commit `088b2f1`; migration tool still needed

#### What was closed (commit `088b2f1`)

The segment header format version has been bumped to `TSSEG002` and a per-block CRC32C integrity
field was added. The new format is the sole written format going forward.

#### What remains open

- No `migrateSegments(from, to)` helper exists.
- Engine startup does not detect a v1 (`TSSEG001`) segment and fail with a clear message.
- No CLI `tsdb migrate` subcommand.
- A v1-fixture unit test and migration round-trip test are still missing.

#### Recommended next steps

1. Add detection of `TSSEG001` magic on `SegmentReader.init`; return `error.SegmentVersionTooOld`.
2. Implement `migrateSegments` helper: rewrite each v1 segment via temp + rename.
3. Expose `zig build migrate` / `tsdb migrate <dir>` CLI subcommand.
4. Add a unit test: write v1 fixture, run migration, reopen engine, assert all points readable.

#### GitLab issue action

Would be created as a new issue once token write access is restored. Assign label
`feature`, `severity::medium`, `status::partial`.

---

### GAP-0010: Cross-Segment Out-of-Order Writes Rejected

- **GitLab issue:** TBD -- pending issue creation (token write access required)
- **Category:** Feature
- **Severity:** High
- **Status:** Deferred -- XL design work required

#### Reason for deferral

Cross-segment OoO write handling is an XL design item requiring a sidecar-memtable or
eager-rewrite approach. The design must be consistent with the manifest's `(min_ts, max_ts)` per
segment invariants and the new CRC32C integrity tagging added in `088b2f1`. The implementation
risk is high enough to require a dedicated sprint and an ADR.

#### Current state

- In-memory OoO within the active memtable is handled correctly (`src/memtable.zig`).
- Writes for timestamps earlier than the max of any closed segment are currently either silently
  dropped or held in the active memtable without merging into the correct historical segment.

#### Unblock steps

1. Write an ADR covering the sidecar-memtable vs. eager-rewrite trade-offs.
2. Implement chosen approach with tests covering: late points in a closed segment, compaction
   folding of buffered OoO points, manifest invariant preservation.
3. Add `ooo_writes_total` and `ooo_target_segment` counters.

#### GitLab issue action

Would be created as a new issue once token write access is restored. Assign label
`feature`, `severity::high`, `status::deferred`, `effort::xl`.
