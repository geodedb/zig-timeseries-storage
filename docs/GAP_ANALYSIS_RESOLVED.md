# Resolved Gaps

This document tracks all previously identified requirements-to-code gaps that have been
successfully resolved and verified, as well as architectural items from the specification
that the gap-detector confirmed are already implemented.

To maintain GitLab as the single source of truth, all resolved items listed here must
correspond to closed GitLab issues. Items with the **Verified-Implemented** marker were
checked against the current code during an audit and never required a tracking issue.

## Resolved Gaps Lifecycle

When a gap identified in [GAP_ANALYSIS.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS.md) is resolved:

1. The corresponding GitLab issue is verified and closed.
2. The gap entry is moved out of `docs/GAP_ANALYSIS.md` and appended to this document.
3. The resolution evidence (commit SHA, files changed, test names) is cited.

---

## Verified-Implemented Spec Items (2026-05-26 audit)

These spec features were exercised during the Phase 3 gap detector and confirmed already present
in the codebase. They are recorded here as architectural baseline so future audits do not
re-open them as gaps.

### SPEC-NEW-2: Per-Block Statistics for Query Pruning [VERIFIED-IMPLEMENTED]

- **GitLab issue:** none (never tracked as a gap)
- **Category:** Feature
- **Resolution:** Block-level statistics (min/max timestamp and value) are emitted by the Gorilla
  encoder and consumed by the engine to skip blocks during query planning.
- **Evidence:**
  - `src/encoding/gorilla.zig:4-13` -- `BlockStats` struct defines per-block summary fields.
  - `src/engine.zig:419-421` -- query path consults block stats to prune non-overlapping ranges
    before decoding.
- **Verified date:** 2026-05-26

### SPEC-NEW-5: Iterator-Based Query API with Merge Across Sources [VERIFIED-IMPLEMENTED]

- **GitLab issue:** none (never tracked as a gap)
- **Category:** Feature
- **Resolution:** `Engine.query` returns a `MergeIterator` that streams points from memtable +
  segments in timestamp order, satisfying the spec's iterator contract.
- **Evidence:**
  - `src/engine.zig:365` -- `query()` constructs and returns a `MergeIterator` over active sources.
  - `src/iterator.zig` -- `MergeIterator` implementation.
- **Verified date:** 2026-05-26

### SPEC-NEW-6: Atomic Manifest Updates with Dual-File CRC [VERIFIED-IMPLEMENTED]

- **GitLab issue:** none (never tracked as a gap)
- **Category:** Bug
- **Resolution:** Manifest writes use the `.tmp` + rename pattern for atomicity, and persistence
  is dual-file with a CRC32 checksum so corruption of either file is detectable on load.
- **Evidence:**
  - `src/manifest.zig:147-162` -- `writeToFile` writes to a `.tmp` path then atomically renames.
  - `src/manifest.zig:182` -- dual-file CRC32 verification on load.
- **Verified date:** 2026-05-26

---

## Resolved Gaps (gap-closure session 2026-05-26)

The following gaps were fully closed in the gap-closure session (32 commits).
All items below have been removed from `GAP_ANALYSIS.md`.

GitLab issue closure note: token write access was unavailable during this session.
All GitLab issues for the items below should be closed manually once token access is restored.
Evidence summaries suitable for the closing comment are included in each entry.

---

### GAP-0003: Missing Integrated Backup and Restore Capabilities [CLOSED]

- **GitLab issue:** [#3](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/3) -- **close manually after token restore**
- **Category:** Feature | **Severity:** High
- **Resolved date:** 2026-05-26
- **Closing commit:** `fe5bf9e`
- **Resolution summary:** Implemented `ts_store.checkpoint()` API (flush memtable, fsync
  manifest/WAL, lock directory), `ts_store.snapshot()` for consistent directory capture, and
  `ts_store.restore()` for rehydrating an engine from a backup directory. CLI `backup` and
  `restore` subcommands were also added.
- **Evidence:**
  - `src/engine.zig` -- `Engine.checkpoint`, `Engine.snapshot`, `Engine.restore` methods.
  - `src/main.zig` -- `backup` and `restore` CLI subcommands.
  - Integration test in `tests/integration.zig` covers checkpoint-then-restore round-trip.

---

### GAP-0004: Lack of Retention Engine and Pruning Mechanisms [CLOSED]

- **GitLab issue:** [#4](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/4) -- **close manually after token restore**
- **Category:** Feature | **Severity:** High
- **Resolved date:** 2026-05-26
- **Closing commit:** `28bac58`
- **Resolution summary:** Added age-based segment pruning engine. `EngineConfig` now accepts a
  `max_retention_age_ns` field. A retention runner iterates the segment manifest and deletes
  segments whose `max_ts < (now - retention)`. Partial segments straddling the cutoff are
  identified for rewrite during the next compaction pass.
- **Evidence:**
  - `src/engine.zig` -- `Engine.pruneSegments` method and retention config integration.
  - `src/manifest.zig` -- manifest exposes `max_ts` per segment entry for cutoff comparison.
  - Unit tests assert segments outside the retention window are removed after prune.

---

### GAP-0005: Silent WAL Corruption Tolerance During Recovery [CLOSED]

- **GitLab issue:** [#5](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/5) -- **close manually after token restore**
- **Category:** Bug | **Severity:** High
- **Resolved date:** 2026-05-26
- **Closing commit:** `73926b5`
- **Resolution summary:** `Engine.init` now uses `wal.forEachFromStrict` (which propagates
  checksum/deserialize errors) as the default recovery path. The silent-skip `readFrom` path
  is restricted to an explicit salvage mode. An injected-corruption regression test asserts
  `Engine.init` returns `error.WalCorrupted` on a bad payload.
- **Evidence:**
  - `src/engine.zig` -- recovery call site uses `forEachFromStrict`.
  - `src/wal_manager.zig` -- `readFrom` annotated as salvage-only path.
  - Regression test in `tests/integration.zig` exercises corrupt-WAL startup failure.

---

### GAP-0006: Missing Segment File Verification on Startup [CLOSED]

- **GitLab issue:** [#6](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/6) -- **close manually after token restore**
- **Category:** Bug | **Severity:** Medium
- **Resolved date:** 2026-05-26
- **Closing commit:** `fe89463`
- **Resolution summary:** `Engine.init` now scans the data directory and verifies that every
  segment ID listed in the manifest exists on disk and has a valid magic header. A missing or
  unreadable segment causes startup to fail with `error.SegmentFileMissing`.
- **Evidence:**
  - `src/engine.zig` -- startup verification loop over `man.segments`.
  - Test: deleting a manifest-referenced segment file causes `Engine.init` to fail with a
    clear error.

---

### GAP-0007: Placeholder Test Suites in tests/ Directory [CLOSED]

- **GitLab issue:** [#7](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/7) -- **close manually after token restore**
- **Category:** Test | **Severity:** Medium
- **Resolved date:** 2026-05-26
- **Closing commit:** `6dfd585`
- **Resolution summary:** `tests/integration.zig` and `tests/stress.zig` were rewritten with
  real Engine lifecycle scenarios. Integration tests cover append+query round-trips, flush
  persistence, WAL recovery, and reopen-after-close. Stress tests cover concurrent writers
  and high-cardinality ingestion loads.
- **Evidence:**
  - `tests/integration.zig` -- real Engine flows; all stubs replaced.
  - `tests/stress.zig` -- concurrent writer and high-cardinality variants.
  - `zig build test-integration` and `zig build test-stress` both pass.

---

### GAP-0008: Placeholder Command-Line Interface and Examples [CLOSED]

- **GitLab issue:** [#8](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/8) -- **close manually after token restore**
- **Category:** Enhancement | **Severity:** Low
- **Resolved date:** 2026-05-26
- **Closing commit:** `be44f61`
- **Resolution summary:** `src/main.zig` now dispatches `status`, `append`, `query`, `flush`,
  `compact`, `verify`, `backup`, and `restore` subcommands. `examples/basic.zig` was rewritten
  to demonstrate a full write-flush-query flow. Help menu is available via `--help`.
- **Evidence:**
  - `src/main.zig` -- subcommand dispatch table.
  - `examples/basic.zig` -- end-to-end usage example.
  - `zig build run -- --help` prints subcommand list.

---

### GAP-0011: Benchmark Harness Bodies Are Stubs (No Regression Gate) [CLOSED]

- **GitLab issue:** TBD -- pending issue creation (token write access required; close once created)
- **Category:** Performance | **Severity:** Medium
- **Resolved date:** 2026-05-26
- **Closing commit:** `69c68eb`
- **Resolution summary:** All benchmark scenario bodies were rewritten against the real
  `Engine.appendPoints` / `queryPoints` API. A `benchmarks/results/baseline.json` was generated
  and committed. The CI `benchmark-regression` job was flipped from `allow_failure: true` to
  `allow_failure: false`, establishing an active regression gate.
- **Evidence:**
  - `benchmarks/bench.zig`, `benchmarks/scale.zig` -- real Engine workloads.
  - `benchmarks/results/baseline.json` -- committed baseline metrics.
  - `.gitlab-ci.yml` -- `allow_failure: false` on the regression job.
  - `zig build bench` produces deterministic measurements.
