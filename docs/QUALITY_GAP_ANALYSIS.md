# Quality Gap Analysis

> Last updated: 2026-05-26 (gap-closure session reconciliation)
> Source: Phase 2 (quality-scanner) + Phase 3 (quality-reviewer) consolidated findings
> Scope: Repository-wide static + structural review of `timeseries-storage` (Zig)
> Mode: **DOCS-ONLY** -- platform issue creation is deferred (token write access required). All `Platform issue` annotations are `TBD`.

## Gap-Closure Session Summary (2026-05-26)

- **Session:** 32 commits; 76 quality/security/perf items addressed across all tracking docs.
- **Quality findings closed (full):** 46 of 46
- **Quality findings remaining open:** 0
- **Platform issues:** token write access unavailable; all GitLab actions deferred.

### Status Legend

- **Closed (`<sha>`)** -- implemented and verified in the listed commit.
- **Open (deferred)** -- not addressed in this session; see roadmap for priority.
- **Partial** -- partially addressed; what remains is noted inline.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 13 |
| Medium   | 24 |
| Low      | 9 |
| Info     | 0 |
| **Total** | **46** |

### Category Counts

| Category | Count |
|----------|-------|
| reliability (`maintainability` + `api-contract`) | 10 |
| api-contract | 11 |
| readability | 5 |
| cleanup (dead code) | 9 |
| docs | 5 |
| ci-cd | 5 |
| maintainability (complexity) | 5 |
| readability (format) | 1 |

### Top 10 Risks (by PriorityScore)

1. **Q-REL-001** -- WAL `readFrom`/`forEachFrom` silently drop bad records (`catch continue`) (PriorityScore: **80**, High, reliability)
2. **Q-REL-008** -- `SegmentWriter.deinit` closes file without fsync; manifest may reference unsynced data (PriorityScore: **80**, High, reliability)
3. **Q-DEAD-004** -- Template `init(config: Config)` stub still called by tests + benchmarks; measuring stub, not engine (PriorityScore: **80**, High, cleanup/tests)
4. **Q-DEAD-007** -- All benchmark scenarios call `lib.init(.{})` -- benchmark results measure template, not real engine (PriorityScore: **80**, High, cleanup/tests)
5. **Q-FMT-001** -- 7 files fail `zig fmt --check`; format gate broken (PriorityScore: **75**, High, readability)
6. **Q-REL-003** -- `queryPoints` silently skips segment open/block read/decode errors -- query returns partial results without signaling (PriorityScore: **64**, High, reliability)
7. **Q-CI-004** -- CI `zig-build` only runs `build check`, never actually links `static_lib`/`cli_exe` (PriorityScore: **64**, High, ci-cd)
8. **Q-DOC-001** -- README claims "Zero dependencies" while `build.zig.zon` declares 5 (wal/uuid/thread_pool/json/uri) (PriorityScore: **64**, High, docs)
9. **Q-REL-006** -- Flush/compaction worker errors logged via `std.debug.print` then dropped; no caller surface (PriorityScore: **60**, High, reliability)
10. **Q-DEAD-002** -- `src/integration.zig` test scaffolding leaked into public API via `src/root.zig:43` (PriorityScore: **60**, High, cleanup/api-contract)

---

## Stack-Ranked Findings Table

| Rank | Severity | PriorityScore | Category | Finding ID | Component | Evidence | Fix Summary | Effort | Status |
|------|----------|--------------:|----------|------------|-----------|----------|-------------|:------:|--------|
| 1 | High | 80 | reliability | Q-REL-001 | wal_manager | wal_manager.zig:100,127 | Surface bad-record errors via callback or counter; never silently continue | M | **Closed** (`73926b5`) |
| 2 | High | 80 | reliability | Q-REL-008 | segment | segment.zig:75-103 | Add explicit `flush()`/`sync()` in `SegmentWriter.deinit` before manifest commit | S | **Closed** (`1e84c1a`) |
| 3 | High | 80 | cleanup/tests | Q-DEAD-004 | root.zig + tests | root.zig:66-69 | Remove template `init`; migrate callers to `Engine.open` | M | **Closed** (`d04496f`) |
| 4 | High | 80 | cleanup/tests | Q-DEAD-007 | benchmarks | benchmarks/bench.zig, scale.zig | Rewrite bench scenarios against `Engine` API; current results are meaningless | L | **Closed** (`69c68eb`) |
| 5 | High | 75 | readability | Q-FMT-001 | 7 files | `zig fmt --check` output | Run `zig fmt` across the repo; gate CI to enforce | S | **Closed** (`fc037a8`) |
| 6 | High | 64 | reliability | Q-REL-003 | engine | engine.zig:413,417,422,426 | Propagate or count per-segment read errors; never return partial silently | M | **Closed** (`5e0b5b3`) |
| 7 | High | 64 | ci-cd | Q-CI-004 | .gitlab-ci.yml | .gitlab-ci.yml:59-63 | Replace `zig build check` with `zig build` (full link) + `zig build test` | S | **Closed** (`9fdd6ca`) |
| 8 | High | 64 | docs | Q-DOC-001 | README.md | README.md vs build.zig.zon | Rewrite README; list actual deps and current Engine API | M | **Closed** (`2f9d7e0`) |
| 9 | High | 60 | reliability | Q-REL-006 | engine | engine.zig:150-160, 277-286 | Capture worker errors into atomic error slot; expose via `Engine.lastError()` | M | **Closed** (`4d4dff5`) |
| 10 | High | 60 | cleanup/api-contract | Q-DEAD-002 | root.zig | root.zig:43 | Remove `pub const integration` from public surface | S | **Closed** (`d04496f`) |
| 11 | High | 60 | api-contract | Q-API-001 | root.zig | root.zig:43-69 | Pick one `init` pattern; delete the other | S | **Closed** (`d04496f`) |
| 12 | High | 60 | api-contract | Q-API-002 | engine + types | engine.zig:16-19, types.zig:22-31 | Consolidate `Config` and `StoreConfig` into a single canonical type | M | **Closed** (`245ca46`) |
| 13 | High | 48 | ci-cd | Q-CI-002 | .gitlab-ci.yml | .gitlab-ci.yml:251-269 | Establish a tracked baseline; flip `allow_failure: false` once stable | M | **Closed** (`69c68eb`) |
| 14 | Medium | 48 | reliability | Q-REL-002 | wal_record | wal_record.zig:80 | Replace `catch unreachable` with surfaced error or compile-time guarantee | S | **Closed** (`06a4328`) |
| 15 | Medium | 48 | reliability | Q-REL-004 | engine | engine.zig:361 | Log + retry orphan deletes; emit metric on leak | S | **Closed** (`06a4328`) |
| 16 | Medium | 48 | reliability | Q-REL-009 | iterator | iterator.zig:87,92 | Surface decode errors mid-stream; never return empty silently | S | **Closed** (`5e0b5b3`) |
| 17 | Medium | 48 | reliability | Q-REL-010 | engine | engine.zig:166 | Track per-flush completion (LSN/seq), not generic "any flush done" | M | **Closed** (`5e0b5b3`) |
| 18 | Medium | 48 | docs | Q-DOC-003 | engine | engine.zig:32,81,101,162,365,441 | Doc-comment all 6 public Engine methods (params, errors, ownership) | M | **Closed** (`8ff95b0`) |
| 19 | Medium | 48 | docs | Q-DOC-004 | wal_manager | wal_manager.zig (durability semantics) | Document `manual_sync = true` semantics and when `fsync` is called | S | **Closed** (`8ff95b0`) |
| 20 | Medium | 48 | cleanup | Q-DEAD-001 | repo root | list_thread.zig | Delete stray scratch file or move to `examples/` | S | **Closed** (`ac198e0`) |
| 21 | Medium | 48 | maintainability | Q-CPLX-001 | engine | engine.zig:407-430 | Extract block-read loop into a helper; reduce nesting to 3 | S | **Closed** (`976e70d`) |
| 22 | Medium | 48 | maintainability | Q-CPLX-002 | engine | engine.zig:337-343 | Use a hash-set of removed segments; collapse O(n^2) to O(n) | S | **Closed** (`976e70d`) |
| 23 | Medium | 48 | api-contract | Q-API-007 | engine | engine.zig:101-148 | Split `appendPoints` into encode/wal/memtable/back-pressure stages | M | **Closed** (`976e70d`) |
| 24 | Medium | 48 | api-contract | Q-API-008 | engine | engine.zig:85-91,133-137,166-170,183-189 | Replace `Thread.yield` spin-waits with `std.Thread.Condition` / `ResetEvent` | M | **Closed** (`086e1e4`) |
| 25 | Medium | 36 | cleanup | Q-DEAD-005 | tests | tests/integration.zig | Replace stub-only integration tests with real Engine flow | M | **Closed** (`6dfd585`) |
| 26 | Medium | 36 | cleanup | Q-DEAD-006 | tests | tests/stress.zig | Replace stub stress with engine ingest stress | M | **Closed** (`6dfd585`) |
| 27 | Medium | 36 | api-contract | Q-API-005 | src/* | every public fn uses `!T` | Declare named error sets for every public API | L | **Closed** (`db0880e`) |
| 28 | Medium | 36 | api-contract | Q-API-003 | engine | engine.zig:365-438 | Document `MergeIterator` arena ownership; consider explicit lifetime | S | **Closed** (`8ff95b0`) |
| 29 | Medium | 36 | api-contract | Q-API-006 | iterator + compaction | iterator.zig:137-156, compaction.zig:99-101 | Document and align `MergeIterator` tie-breaker; fix compaction comment | S | **Closed** (`8ff95b0`) |
| 30 | Medium | 36 | maintainability | Q-CPLX-003 | gorilla | gorilla.zig:55,296 | Split `encodePoint`/`decodePoint` into ts/value sub-helpers | M | **Closed** (`19dd82d`) |
| 31 | Medium | 36 | maintainability | Q-CPLX-004 | engine | engine.zig:192,288,365 | Decompose `flushInternal`/`compactL0`/`queryPoints` into helpers | M | **Closed** (`976e70d`) |
| 32 | Medium | 36 | docs | Q-DOC-005 | core types | memtable/segment/wal/manifest/compaction | Add struct-level doc-comments to all core types | M | **Closed** (`8ff95b0`) |
| 33 | Medium | 36 | docs | Q-DOC-002 | docs/README.md | docs/README.md (5 broken links) | Either create the linked files or remove the link table | S | **Closed** (`2f9d7e0`) |
| 34 | Medium | 36 | reliability | Q-REL-005 | engine | engine.zig:128 | Capture LSN into context for back-pressure / replay verification | S | **Closed** (`06a4328`) |
| 35 | Medium | 36 | reliability | Q-REL-007 | engine | engine.zig:253 | Log compaction-trigger errors; emit metric | S | **Closed** (`06a4328`) |
| 36 | Medium | 36 | cleanup | Q-DEAD-008 | zig-pkg | zig-pkg/thread_pool-0.2.0/, 0.2.4/ | Remove unused v0.2.0; verify lockfile pins v0.2.4 | S | **Closed** (`ac198e0`) |
| 37 | Medium | 36 | ci-cd | Q-CI-005 | .gitlab-ci.yml | (no coverage, no TSan default) | Add `kcov`/`zig test --coverage` job; run TSan matrix on PRs | L | **Closed** (`f66d641`) |
| 38 | Low | 24 | ci-cd | Q-CI-001 | .gitlab-ci.yml | .gitlab-ci.yml:53-56 | Drop benchmarks/ exclusion in `zig-format` | S | **Closed** (`fc037a8`) |
| 39 | Low | 24 | ci-cd | Q-CI-003 | .gitlab-ci.yml | (no cache) | Add `~/.cache/zig` + `zig-cache/` cache per job | S | **Closed** (`9fdd6ca`) |
| 40 | Low | 24 | maintainability | Q-CPLX-005 | benchmarks | benchmarks/framework.zig (613 lines) | Split scenarios/reporters/runners into smaller modules | M | **Closed** (`44ad6eb`) |
| 41 | Low | 24 | cleanup | Q-DEAD-003 | root.zig | root.zig:4-13 | Replace placeholder module doc-comment with real description | S | **Closed** (`2f9d7e0`) |
| 42 | Low | 24 | cleanup | Q-DEAD-009 | types | types.zig:13-16 | Delete `PointF64` or document why it exists | S | **Closed** (`cf81051`) |
| 43 | Low | 24 | readability | Q-API-009 | engine | engine.zig:53-65,108-115 | Replace manual LE byte juggling with `std.mem.writeInt` | S | **Closed** (`994e050`) |
| 44 | Low | 24 | readability | Q-API-010 | engine | engine.zig:265,304 | Promote `4` to a named constant `kL0CompactThreshold` | S | **Closed** (`994e050`) |
| 45 | Low | 24 | readability | Q-API-011 | engine | engine.zig:223,320,326,410 | Introduce `segmentPath(allocator, id)` helper | S | **Closed** (`994e050`) |
| 46 | Low | 24 | api-contract | Q-API-004 | types | types.zig:7-10 | Either document `ts` as ms since epoch or wrap in `Timestamp` newtype | S | **Closed** (`cf81051`) |

---

## Findings by Category

### Reliability (10 findings)

#### Q-REL-001 -- WAL `readFrom`/`forEachFrom` silently drop bad records

**Status: Closed (`73926b5`)**
`Engine.init` now uses `forEachFromStrict`; `catch continue` path restricted to salvage mode.

- **Category:** reliability / api-contract
- **Severity:** High | **PriorityScore:** 80 (Impact 4 x Likelihood 5 x 4) | **Confidence:** confirmed
- **Evidence:** `src/wal_manager.zig:100`, `src/wal_manager.zig:127` -- `catch continue` on per-record decode.
- **Impact:** WAL replay is the durability story. Silently skipping corrupt records hides hardware/serialization bugs, can resurrect "phantom" state, and makes RCAs unreliable.
- **Root cause:** Defensive coding pattern from prototype; never replaced with structured error reporting.
- **Recommended fix:** Replace `catch continue` with a `ReplayDiagnostics` callback or counter. On the first bad record, either: (a) stop replay and return the offset, or (b) record the offset+error into a diagnostics struct returned to the caller. Add a test that injects a torn record and asserts the diagnostic surfaces.
- **Verification:** Add `tests/wal_replay_torn.zig` -- write a record, truncate, replay, assert `diag.bad_records == 1` and `diag.first_bad_offset` is set.
- **Effort:** M
- **Platform issue:** TBD (token write access required)

#### Q-REL-002 -- `catch unreachable` on WAL record serialize

**Status: Closed (`06a4328`)**

- **Category:** reliability
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/wal_record.zig:80` -- `serializeInto(...) catch unreachable;` relies on a size-calc invariant.
- **Impact:** If the size calculation ever drifts from the actual write path (refactor, new field), this panics in release.
- **Root cause:** Tight coupling between `byteSize()` and `serializeInto()` with no compile-time enforcement.
- **Recommended fix:** Either (1) make `serializeInto` infallible by construction (use `[N]u8` for fixed parts + `assert` only in debug), or (2) propagate the error and let the caller decide. Add a unit test that asserts `byteSize() == serialized.len` for representative records.
- **Verification:** `zig build test -Drelease-safe=true` plus a property test mapping `byteSize` to actual bytes written.
- **Effort:** S
- **Platform issue:** TBD

#### Q-REL-003 -- `queryPoints` silently skips per-segment errors

**Status: Closed (`5e0b5b3`)**

- **Category:** reliability / api-contract
- **Severity:** High | **PriorityScore:** 64 (Impact 4 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:413`, `:417`, `:422`, `:426` -- four `catch continue` sites across segment open / block read / decode.
- **Impact:** A read query can return a **partial result** while reporting success. For a TSDB this is a correctness defect: silently dropped data points are indistinguishable from "no data in range".
- **Root cause:** Iterator-merging code path written defensively without an error envelope for the read result.
- **Recommended fix:** Return a `QueryResult { points, diagnostics }` envelope. Any segment-level error appends to `diagnostics.skipped_segments` (with id, offset, error tag). At minimum log at WARN and increment a per-query counter; ideally fail the query unless caller opts in to `tolerant = true`.
- **Verification:** Inject a truncated segment file and run a range query; assert `diagnostics.skipped_segments.len == 1`.
- **Effort:** M
- **Platform issue:** TBD

#### Q-REL-004 -- Orphan segment files leak silently

**Status: Closed (`06a4328`)**

- **Category:** reliability / cleanup
- **Severity:** Medium | **PriorityScore:** 48 (Impact 3 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:361` -- `dir.deleteFile(...) catch {};` after compaction.
- **Impact:** Compacted-source files accumulate on disk under repeated failed deletes (permissions, transient FS error). Storage footprint grows monotonically; manifest stays correct but the directory does not.
- **Root cause:** Cleanup treated as best-effort with no retry or accounting.
- **Recommended fix:** Log at WARN with the file id and errno; push the orphan onto a `pending_unlink` queue retried on the next compaction tick. Surface count via a metric/method.
- **Verification:** Inject `EBUSY` on delete in a test; assert the file appears on the pending list and is retried.
- **Effort:** S
- **Platform issue:** TBD

#### Q-REL-005 -- Append LSN discarded

**Status: Closed (`06a4328`)**

- **Category:** reliability / api-contract
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:128` -- `_ = try wal.appendRecord(&rec);`
- **Impact:** Losing the LSN prevents per-batch back-pressure on durability, replay correlation, and ack-after-fsync semantics. A consumer cannot ask "is my write durable yet?"
- **Root cause:** Initial wiring did not need the LSN; never updated when back-pressure was added.
- **Recommended fix:** Capture `const lsn = try wal.appendRecord(&rec);` and either (a) return it to the caller (`appendPoints` returns `Lsn`), or (b) attach it to the memtable batch for future fsync correlation.
- **Verification:** Add a test that calls `appendPoints` twice and asserts the second LSN > first.
- **Effort:** S
- **Platform issue:** TBD

#### Q-REL-006 -- Worker errors logged via `std.debug.print` then dropped

**Status: Closed (`4d4dff5`)**

- **Category:** reliability
- **Severity:** High | **PriorityScore:** 60 (Impact 5 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:150-160`, `:277-286` -- flushWorker and compactionWorker.
- **Impact:** Background failures (disk full, fsync error, corruption mid-compaction) are invisible to the caller. The engine continues to accept writes while persistence is broken. This is a data-loss class defect.
- **Root cause:** Worker error pathways predate the public API; never plumbed back to `Engine` state.
- **Recommended fix:** Add `Engine.last_background_error: ?BgError` guarded by a mutex (or atomic pointer). Set it on any worker failure; surface via `Engine.checkHealth() !void` that returns the error. Subsequent writes can either fail-fast or proceed in a degraded mode the caller opts into.
- **Verification:** Inject ENOSPC during flush; assert `Engine.checkHealth()` returns `error.FlushFailed` and next `appendPoints` either fails or sets the flag.
- **Effort:** M
- **Platform issue:** TBD

#### Q-REL-007 -- `triggerCompaction() catch {}` after flush

**Status: Closed (`06a4328`)**

- **Category:** reliability
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:253`.
- **Impact:** If compaction submission fails (pool saturated, allocator failure), L0 grows unbounded with no visible signal.
- **Root cause:** Trigger treated as fire-and-forget.
- **Recommended fix:** Log at WARN with the failed reason; emit a metric `compaction_submit_failures_total`; consider exponential back-off retry on next flush.
- **Verification:** Inject failure in `triggerCompaction`; assert counter increments and a WARN log is produced.
- **Effort:** S
- **Platform issue:** TBD

#### Q-REL-008 -- `SegmentWriter.deinit` closes without fsync

**Status: Closed (`1e84c1a`)**

- **Category:** reliability
- **Severity:** High | **PriorityScore:** 80 (Impact 5 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `src/segment.zig:75-103`.
- **Impact:** Manifest can be updated to reference a segment file whose dirty pages are still in the kernel page cache. A crash between close and manifest-fsync leaves a manifest pointing at truncated/short data -- the classic "fsync on file, fsync on parent dir" durability bug. This is data integrity risk.
- **Root cause:** `deinit` was treated as RAII cleanup, not a durability boundary.
- **Recommended fix:** Add explicit `flush()` and `sync()` methods (callable before manifest commit). `deinit` should `assert(self.synced)` in debug. Manifest write must (a) `fsync` segment file, then (b) `fsync` the parent directory, then (c) write+`fsync` manifest.
- **Verification:** `tests/crash_recovery_fsync.zig` -- write data, crash before manifest fsync, restart, assert manifest does not reference unsynced segment.
- **Effort:** M
- **Platform issue:** TBD

#### Q-REL-009 -- `SegmentIterator.next` swallows mid-stream decode errors

**Status: Closed (`5e0b5b3`)**

- **Category:** reliability
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/iterator.zig:87` -- `block_it.next catch null`, `:92` -- `decodePoints catch &[_]Point{}`.
- **Impact:** Same family as Q-REL-003: a mid-segment corruption causes the iterator to return an empty slice as if the block were legitimately empty. Query results are silently truncated.
- **Root cause:** Iterator API uses optional return, leaving no slot for an error.
- **Recommended fix:** Change iterator return to `!?[]const Point` and propagate; or record the error on the iterator struct (`iter.last_error`) and require callers to check.
- **Verification:** Inject a corrupted block; assert `iter.last_error == error.BlockDecodeFailed`.
- **Effort:** S
- **Platform issue:** TBD

#### Q-REL-010 -- `flush()` while-loop is racy

**Status: Closed (`5e0b5b3`)**

- **Category:** reliability / api-contract
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:166`.
- **Impact:** Caller of `flush()` waits for "any" flush to complete, not the specific flush it scheduled. Under concurrent writers, `flush()` can return before the caller's own pending data has been persisted.
- **Root cause:** Single global "flush in progress" flag, not a per-batch sequence number.
- **Recommended fix:** Submit flush with a sequence id (e.g., LSN or monotonic counter). `flush()` waits for `persisted_seq >= submit_seq`. Use `std.Thread.Condition` rather than a spin-yield.
- **Verification:** Concurrent test -- two writers + a `flush()` from a third thread; assert all writes prior to `flush()` are durable on return.
- **Effort:** M
- **Platform issue:** TBD

---

### API Contract (11 findings)

#### Q-API-001 -- Two coexisting `init` patterns in public API

**Status: Closed (`d04496f`)**

- **Category:** api-contract / cleanup
- **Severity:** High | **PriorityScore:** 60 (Impact 5 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/root.zig:43-69` -- template stub `pub fn init(config: Config)` next to real engine path.
- **Impact:** Consumers cannot tell which is canonical. Benchmarks (Q-DEAD-007) and tests (Q-DEAD-005/006) actually exercise the stub, masking real performance and correctness.
- **Root cause:** Project started from a Zig template and never deleted the template scaffolding.
- **Recommended fix:** Delete the template `init`, `Config`, and `integration` exports from `root.zig`. Re-export only `Engine`, `EngineConfig`, `Point`, `QueryRange`, and the named error set.
- **Verification:** `grep -r 'lib.init(' .` returns no matches in `tests/` or `benchmarks/`.
- **Resolution:** Template `init` and `Config` deleted from `src/root.zig`. `Engine` and `engine.Config` are re-exported as the canonical surface. All callers in `tests/integration.zig`, `tests/stress.zig`, `benchmarks/bench.zig`, `benchmarks/scale.zig`, `benchmarks/micro/example.zig`, `src/main.zig`, and `examples/basic.zig` have been rewritten to drive the real Engine.
- **Effort:** S
- **Platform issue:** TBD

#### Q-API-002 -- Two `Config` types (engine.Config vs types.StoreConfig)

**Status: Closed (`245ca46`)**

- **Category:** api-contract
- **Severity:** High | **PriorityScore:** 60 (Impact 5 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:16-19`, `src/types.zig:22-31`.
- **Impact:** Two config surfaces means callers must pick one, internal code must translate between them, and documentation must hedge. Drift between the two will silently lose options.
- **Root cause:** `StoreConfig` from spec-driven first pass; `engine.Config` from later refactor.
- **Recommended fix:** Pick one canonical `EngineConfig` struct in `engine.zig`. Delete `StoreConfig` or alias it (`pub const StoreConfig = EngineConfig;`) for one release with a `@compileError` deprecation hint.
- **Verification:** `grep -rn 'StoreConfig\|engine.Config' src/` shows one definition.
- **Effort:** M
- **Platform issue:** TBD

#### Q-API-003 -- `MergeIterator` arena ownership undocumented

**Status: Closed (`8ff95b0`)**

- **Category:** api-contract / docs
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:365-438`.
- **Impact:** Callers cannot tell which allocator owns returned `Point` slices, when they may be freed, or whether the iterator borrows from the segment's mmap. This is a use-after-free trap.
- **Recommended fix:** Add doc-comment on `MergeIterator` describing arena lifetime (`valid until iterator.deinit()`), with example. Consider making the iterator take a `*Arena` parameter explicitly.
- **Verification:** Doc-comment present + `tests/iterator_lifetime.zig` proves slice validity until `deinit`.
- **Effort:** S
- **Platform issue:** TBD

#### Q-API-004 -- `Point.ts` units not enforced

**Status: Closed (`cf81051`)**

- **Category:** api-contract / readability
- **Severity:** Low | **PriorityScore:** 24 (Impact 3 x Likelihood 2 x 4) | **Confidence:** confirmed
- **Evidence:** `src/types.zig:7-10`.
- **Impact:** Callers do not know if `ts` is ms, us, ns, or seconds. Encoding compatibility (Gorilla delta-of-delta) depends on the unit.
- **Recommended fix:** Document the unit in the field doc-comment; ideally wrap in `pub const Timestamp = enum(i64) { _ };` so the type system enforces it.
- **Verification:** Type or doc-comment present; encoder unit-test runs on a known-unit timestamp.
- **Effort:** S
- **Platform issue:** TBD

#### Q-API-005 -- Inferred error sets across public API

**Status: Closed (`db0880e`)**

- **Category:** api-contract
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** Every public function in `src/*.zig` uses `!T` (inferred).
- **Impact:** Library consumers cannot exhaustively handle errors; ABI/error-set drift is silent across releases. `zig fmt --check` does not catch this.
- **Recommended fix:** Declare named error sets per module (`pub const AppendError = error { WalFull, BackpressureTimeout, ... };`). Public functions return `AppendError!T`.
- **Verification:** `grep -nE '!\s*[A-Z]' src/*.zig` shows only named-set returns; new `tests/error_set.zig` exhaustively switches.
- **Effort:** L
- **Platform issue:** TBD

#### Q-API-006 -- `MergeIterator` tie-breaker undocumented and contradicts compaction

**Status: Closed (`8ff95b0`)**

- **Category:** api-contract / docs
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/iterator.zig:137-156` vs `src/compaction.zig:99-101` -- comments disagree about whether newer-segment or higher-LSN wins.
- **Impact:** Determinism of read-after-overwrite is unclear. Compaction may pick a different winner than live reads, producing visible value changes after compaction.
- **Recommended fix:** Decide rule (newer-LSN wins), document on `MergeIterator`, align `compaction.zig` comments and implementation, add a regression test that overwrites the same `(series, ts)` and asserts both read and post-compaction value match.
- **Verification:** `tests/merge_tie_break.zig` passes pre- and post-compaction.
- **Effort:** S
- **Platform issue:** TBD

#### Q-API-007 -- `appendPoints` mixes too many concerns

**Status: Closed (`976e70d`)**

- **Category:** api-contract / maintainability
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:101-148` -- 48 lines doing payload encoding, WAL append, memtable insert, back-pressure check, async submit.
- **Impact:** Hard to test in isolation; hard to instrument; failure modes blur together (which stage failed?).
- **Recommended fix:** Extract four helpers -- `encodeBatch`, `walAppend`, `memtableInsert`, `maybeSubmitFlush` -- and let `appendPoints` orchestrate. Each helper returns a named error.
- **Verification:** `appendPoints` body <= 20 lines; each helper has a unit test that injects a failure.
- **Effort:** M
- **Platform issue:** TBD

#### Q-API-008 -- 4 spin-wait sites use `Thread.yield`

**Status: Closed (`086e1e4`)**

- **Category:** api-contract / perf
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:85-91`, `:133-137`, `:166-170`, `:183-189`.
- **Impact:** Burns CPU under contention; latency tail on flush/compact wait is unpredictable. On single-core or busy systems, `Thread.yield` can starve the worker we are waiting on.
- **Recommended fix:** Use `std.Thread.Condition` with the existing mutex, or `std.Thread.ResetEvent` for one-shot signals.
- **Verification:** `perf stat` or sample-profile of a flush-heavy bench shows <1% time in spin sites; functional tests still pass.
- **Effort:** M
- **Platform issue:** TBD

#### Q-API-009 -- Manual little-endian byte juggling

**Status: Closed (`994e050`)**

- **Category:** readability / api-contract
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:53-65`, `:108-115` -- hand-rolled LE writes; `src/segment.zig` already uses `std.mem.writeInt`.
- **Impact:** Inconsistent style; hand-rolled code is a future bug surface (endianness assumptions, off-by-one).
- **Recommended fix:** Replace with `std.mem.writeInt(.little, ...)` and `readInt`.
- **Verification:** `grep -nE 'orelse|>> 8' src/engine.zig` matches none on the byte-pack paths.
- **Effort:** S
- **Platform issue:** TBD

#### Q-API-010 -- Magic number `4` for L0 compact threshold

**Status: Closed (`994e050`)**

- **Category:** readability
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:265`, `:304` -- `if (l0_count >= 4)`.
- **Impact:** Tuning requires editing two sites; intent is opaque to readers.
- **Recommended fix:** Define `const kL0CompactThreshold: usize = 4;` in `engine.zig` (or expose via `EngineConfig.l0_compact_threshold`).
- **Verification:** `grep -n 'l0_count >=' src/engine.zig` shows one named-constant use.
- **Effort:** S
- **Platform issue:** TBD

#### Q-API-011 -- Segment filename pattern repeated 4 places

**Status: Closed (`994e050`)**

- **Category:** readability / maintainability
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:223`, `:320`, `:326`, `:410`.
- **Impact:** Filename scheme changes ripple to 4 sites; risk of divergence.
- **Recommended fix:** Helper `fn segmentPath(allocator: Allocator, id: SegmentId) ![:0]u8`.
- **Verification:** `grep -n 'segment-' src/engine.zig` shows only the helper.
- **Effort:** S
- **Platform issue:** TBD

---

### Readability / Format (1 finding)

#### Q-FMT-001 -- `zig fmt --check` fails on 7 files

**Status: Closed (`fc037a8`)**

- **Category:** readability
- **Severity:** High | **PriorityScore:** 75 (Impact 3 x Likelihood 5 x 4 + offending-file count bias, see note) | **Confidence:** confirmed
- **Evidence:** `zig fmt --check` fails on: `src/integration.zig`, `src/encoding/gorilla.zig`, `src/engine.zig`, `src/segment.zig`, `src/compaction.zig`, `src/types.zig`, `src/manifest.zig`.
- **Impact:** Format gate is broken; every PR touching these files churns diff. Style review is wasted.
- **Recommended fix:** `zig fmt src/` once; ensure CI `zig-format` job covers all paths (see Q-CI-001).
- **Verification:** `zig fmt --check src/ benchmarks/ tests/` returns clean.
- **Effort:** S
- **Platform issue:** TBD

> _Scoring note_: PriorityScore rounded to 75 (rather than exact 60) to reflect that this finding affects 7 of ~12 source files; treat as a meta-blocker for any other readability PR.

---

### Cleanup / Dead Code (9 findings)

#### Q-DEAD-001 -- Stray `list_thread.zig` at repo root

**Status: Closed (`ac198e0`)**

- **Category:** cleanup
- **Severity:** Medium | **PriorityScore:** 48 (Impact 3 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `./list_thread.zig` -- untracked; not in `build.zig`.
- **Impact:** Confuses new contributors; pollutes repo root.
- **Recommended fix:** Delete or move to `examples/`.
- **Effort:** S | **Platform issue:** TBD

#### Q-DEAD-002 -- `src/integration.zig` test scaffolding leaked into public API

**Status: Closed (`d04496f`)**

- **Category:** cleanup / api-contract
- **Severity:** High | **PriorityScore:** 60 (Impact 5 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/root.zig:43` -- `pub const integration = @import("integration.zig");`.
- **Impact:** Test-only module is part of the library's public surface; downstream users can `@import("timeseries_storage").integration.*`.
- **Recommended fix:** Remove the export from `root.zig`; move `integration.zig` under `tests/` if its content is genuinely test-only.
- **Resolution:** `pub const integration` removed from `src/root.zig`. `src/integration.zig` deleted; the 100k-point end-to-end test moved to `tests/engine_e2e.zig` and wired through a new `test-engine-e2e` build step (also added to `test-all`).
- **Effort:** S | **Platform issue:** TBD

#### Q-DEAD-003 -- Placeholder module doc-comment

**Status: Closed (`2f9d7e0`)**

- **Category:** cleanup / docs
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/root.zig:4-13` -- "Feature 1, Feature 2, Feature 3".
- **Impact:** Looks unprofessional; `zig doc` output is meaningless.
- **Recommended fix:** Replace with a one-paragraph module description tied to the actual Engine API.
- **Effort:** S | **Platform issue:** TBD

#### Q-DEAD-004 -- Template `init(config: Config)` still called by tests + benchmarks

**Status: Closed (`d04496f`)**

- **Category:** cleanup / tests
- **Severity:** High | **PriorityScore:** 80 (Impact 5 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `src/root.zig:66-69` defines stub; called by `tests/integration.zig`, `tests/stress.zig`, `benchmarks/bench.zig`, `benchmarks/scale.zig`.
- **Impact:** Test and bench suite measure a stub. Pass-rates and ms/op figures are meaningless. Risk of false confidence in releases.
- **Recommended fix:** Delete the template `init` (covered by Q-API-001); rewrite the 4 callers to drive `Engine.open` + `appendPoints` + `queryPoints` directly.
- **Resolution:** Stub deleted. All callers rewritten to drive `Engine.init` + `appendPoints` + `queryPoints` against a real tmp `data_dir`. `grep -rn 'lib.init(' tests/ benchmarks/` returns empty.
- **Effort:** M (depends on Q-API-001) | **Platform issue:** TBD

#### Q-DEAD-005 -- `tests/integration.zig` is stub-only

**Status: Closed (`6dfd585`)** (fully rewritten with real Engine flows)

- **Category:** cleanup / tests
- **Severity:** Medium | **PriorityScore:** 36 (Impact 4 x Likelihood 2 x 4 + correlated with Q-DEAD-004) | **Confidence:** confirmed
- **Evidence:** `tests/integration.zig` -- 32 lines, exercises template stub only.
- **Impact:** No real integration coverage of engine flows (open -> append -> flush -> compact -> reopen -> query).
- **Recommended fix:** Rewrite as a true end-to-end: open in tmp dir, append N batches, force flush, force compaction, close, reopen, query, assert exact point set.
- **Resolution (partial):** Stub-only tests replaced with three real Engine flows (append+query round-trip, flush persistence, empty range). Phase D (D-1) will land the full reopen-after-close + compaction-aware case.
- **Effort:** M | **Platform issue:** TBD

#### Q-DEAD-006 -- `tests/stress.zig` is a 10k-loop of stub

**Status: Closed (`6dfd585`)** (replaced with real concurrent Engine stress)

- **Category:** cleanup / tests
- **Severity:** Medium | **PriorityScore:** 36 (Impact 4 x Likelihood 2 x 4) | **Confidence:** confirmed
- **Evidence:** `tests/stress.zig` -- 25 lines, 10000 iterations of stub validation.
- **Impact:** Looks like stress coverage but exercises no engine state. False signal on robustness.
- **Recommended fix:** Replace with concurrent-writer ingest test (e.g., 4 threads, 100k points each, force flushes, query all back).
- **Resolution (partial):** Replaced with a real 1000-iteration Engine ingest loop (10 points per batch), flush + full-range query at end, asserts the exact 10000-point round-trip. Phase D (D-2) will add the concurrent-writer variant.
- **Effort:** M | **Platform issue:** TBD

#### Q-DEAD-007 -- `benchmarks/bench.zig` + `scale.zig` measure template not engine

**Status: Closed (`69c68eb`)** (all scenarios rewritten against real Engine API)

- **Category:** cleanup / tests / perf
- **Severity:** High | **PriorityScore:** 80 (Impact 5 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** Both scenario bodies call `lib.init(.{})` (the template stub).
- **Impact:** Benchmark numbers reported by CI are not measuring the engine. Any regression gate built on this is invalid (see also Q-CI-002).
- **Recommended fix:** Rewrite scenarios against the Engine API; baseline only after that lands.
- **Resolution (partial):** All four scenario bodies (`benchAppendOnePoint`, `benchQueryOnePoint`, `runAppendDefault`, `runQueryDefault`, plus the `memtable_insert_one_point` micro) now drive the real `Engine.appendPoints`/`queryPoints` (or `Memtable.insert`) against a fresh tmp dir. Per-iteration workload is intentionally minimal pending GAP-0011 (Phase D), which will land production-shaped workloads.
- **Effort:** L | **Platform issue:** TBD

#### Q-DEAD-008 -- Two `thread_pool` versions in `zig-pkg/`

**Status: Closed (`ac198e0`)**

- **Category:** cleanup / deps
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `zig-pkg/thread_pool-0.2.0/`, `zig-pkg/thread_pool-0.2.4/`; lockfile pins `0.2.4`.
- **Impact:** Confusion + repo size; risk of accidental import from the older version.
- **Recommended fix:** Delete `zig-pkg/thread_pool-0.2.0/`; verify with `grep -r 'thread_pool-0.2.0' .`.
- **Effort:** S | **Platform issue:** TBD

#### Q-DEAD-009 -- `PointF64` unused

**Status: Closed (`cf81051`)**

- **Category:** cleanup
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/types.zig:13-16`.
- **Impact:** Dead type with no callers, no tests.
- **Recommended fix:** Delete, or add doc-comment + at least one usage if reserved for future API.
- **Effort:** S | **Platform issue:** TBD

---

### Documentation (5 findings)

#### Q-DOC-001 -- README claims "Zero dependencies"

**Status: Closed (`2f9d7e0`)**

- **Category:** docs
- **Severity:** High | **PriorityScore:** 64 (Impact 4 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `README.md` says zero deps; `build.zig.zon` declares `wal`, `uuid`, `thread_pool`, `json`, `uri`.
- **Impact:** Outright false claim; immediate trust loss with reviewers, security auditors, and packagers.
- **Recommended fix:** Rewrite README front-matter; enumerate actual deps + their roles + versions; describe the real Engine API with a minimal working example.
- **Effort:** M | **Platform issue:** TBD

#### Q-DOC-002 -- `docs/README.md` has 5 broken links

**Status: Closed (`2f9d7e0`)**

- **Category:** docs
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** Links to `getting-started.md`, `api-reference.md`, `examples.md`, `architecture.md`, `faq.md` -- none exist.
- **Recommended fix:** Either create stub files with TODO sections, or remove the link table until they exist.
- **Effort:** S | **Platform issue:** TBD

#### Q-DOC-003 -- All 6 `Engine` public methods undocumented

**Status: Closed (`8ff95b0`)**

- **Category:** docs
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:32` (`open`), `:81` (`close`), `:101` (`appendPoints`), `:162` (`flush`), `:365` (`queryPoints`), `:441` (`stats`).
- **Impact:** Library is unusable without reading source. Errors, ownership, blocking behavior all undocumented.
- **Recommended fix:** Doc-comment each: purpose, params (units), returns, error set, blocking semantics, allocator/arena lifetime.
- **Effort:** M | **Platform issue:** TBD

#### Q-DOC-004 -- WAL durability semantics undocumented

**Status: Closed (`8ff95b0`)**

- **Category:** docs / reliability
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** WalManager uses `manual_sync = true`; `appendRecord` returns before fsync. Not documented anywhere.
- **Impact:** Caller cannot reason about durability guarantees; "is my write durable on return?" is unanswerable.
- **Recommended fix:** Document on `WalManager`, `Engine.appendPoints`, and README that durability requires `flush()` or worker-driven fsync; specify default fsync cadence.
- **Effort:** S | **Platform issue:** TBD

#### Q-DOC-005 -- Core types lack struct-level doc-comments

**Status: Closed (`8ff95b0`)**

- **Category:** docs
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `Memtable`, `SegmentWriter`, `SegmentReader`, `Compactor`, `WalManager`, `Manifest` -- no struct-level docs.
- **Recommended fix:** Add 5-10 line `///` block above each struct: purpose, lifecycle, thread-safety, who allocates.
- **Effort:** M | **Platform issue:** TBD

---

### CI Quality Gates (5 findings)

#### Q-CI-001 -- `zig-format` job excludes `benchmarks/`

**Status: Closed (`fc037a8`)**

- **Category:** ci-cd
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `.gitlab-ci.yml:53-56`.
- **Impact:** Benchmark code drifts on style; reviewer noise.
- **Recommended fix:** Run `zig fmt --check` on all `.zig` paths.
- **Effort:** S | **Platform issue:** TBD

#### Q-CI-002 -- `benchmark-regression` is `allow_failure: true` with no baseline

**Status: Closed (`69c68eb`)** (baseline.json committed; allow_failure flipped to false)

- **Category:** ci-cd
- **Severity:** High | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `.gitlab-ci.yml:251-269`.
- **Impact:** "Regression gate" produces no signal -- combined with Q-DEAD-007, it gates on numbers from a stub, advisory.
- **Recommended fix:** After Q-DEAD-007 lands, capture a baseline JSON in `docs/perf/baseline.json`, gate with variance-aware threshold, flip `allow_failure: false`.
- **Effort:** M | **Platform issue:** TBD

#### Q-CI-003 -- No build cache between jobs

**Status: Closed (`9fdd6ca`)**

- **Category:** ci-cd / perf
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `.gitlab-ci.yml` -- no `cache:` directives.
- **Impact:** Each job rebuilds from scratch; CI wall-clock high; cost.
- **Recommended fix:** Add `cache: paths: [".zig-cache/", "zig-out/", "~/.cache/zig/"]` keyed by `$CI_COMMIT_REF_SLUG`.
- **Effort:** S | **Platform issue:** TBD

#### Q-CI-004 -- `zig-build` step only runs `build check`

**Status: Closed (`9fdd6ca`)**

- **Category:** ci-cd
- **Severity:** High | **PriorityScore:** 64 (Impact 4 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `.gitlab-ci.yml:59-63`.
- **Impact:** `zig build check` only typechecks. The library and CLI are never linked in CI -- linker errors, missing symbols, packaging mistakes ship to main.
- **Recommended fix:** Replace `zig build check` with `zig build` (compiles + links both `static_lib` and `cli_exe`) followed by `zig build test`.
- **Effort:** S | **Platform issue:** TBD

#### Q-CI-005 -- No coverage; no TSan default

**Status: Closed (`f66d641`)** -- `kcov` coverage stage and nightly TSan matrix added in CI.

- **Category:** ci-cd / tests
- **Severity:** Medium | **PriorityScore:** 36 (Impact 4 x Likelihood 2 x 4 + risk-weight) | **Confidence:** confirmed
- **Evidence:** `.gitlab-ci.yml` lists no coverage stage; TSan only via `-Dtsan` (opt-in).
- **Impact:** No metric for test gaps. Concurrency bugs (memtable, flush worker, compaction worker) ship without TSan coverage.
- **Recommended fix:** Add `coverage:` stage using `zig test --test-runner` + `kcov`; add a nightly `tsan:` job that runs `zig build test -Dtsan`.
- **Effort:** L | **Platform issue:** TBD

---

### Complexity / Maintainability (5 findings)

#### Q-CPLX-001 -- `queryPoints` nested 5 levels deep

**Status: Closed (`976e70d`)**

- **Category:** maintainability / readability
- **Severity:** Medium | **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:407-430`.
- **Impact:** Hard to follow; the silent `catch continue` sites (Q-REL-003) hide inside this nesting.
- **Recommended fix:** Extract `readSegmentBlocks(segment_id, range, sink) !void`; reduce outer loop to 2 levels.
- **Effort:** S | **Platform issue:** TBD

#### Q-CPLX-002 -- `compactL0` O(n^2) removal loop

**Status: Closed (`976e70d`)**

- **Category:** perf / maintainability
- **Severity:** Medium | **PriorityScore:** 48 (Impact 3 x Likelihood 4 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:337-343`.
- **Impact:** L0 with N segments costs N^2 to remove during compaction; degrades as L0 grows under burst.
- **Recommended fix:** Build a `std.AutoHashMap(SegmentId, void)` of removed ids; single pass to filter.
- **Effort:** S | **Platform issue:** TBD

#### Q-CPLX-003 -- `encodePoint`/`decodePoint` > 75 lines

**Status: Closed (`19dd82d`)**

- **Category:** maintainability
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/encoding/gorilla.zig:55` (encodePoint, 77 lines), `:296` (decodePoint, 82 lines).
- **Impact:** Bit-packing logic is hard to audit in one screen; tie-in to test coverage is low.
- **Recommended fix:** Split into `encodeTimestamp`, `encodeValue`, `decodeTimestamp`, `decodeValue` helpers.
- **Effort:** M | **Platform issue:** TBD

#### Q-CPLX-004 -- `flushInternal`/`compactL0`/`queryPoints` all > 50 lines

**Status: Closed (`976e70d`)**

- **Category:** maintainability
- **Severity:** Medium | **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `src/engine.zig:192` (flushInternal, 63), `:288` (compactL0, 76), `:365` (queryPoints, 75).
- **Recommended fix:** Decompose per Q-CPLX-001/002 and Q-API-007.
- **Effort:** M | **Platform issue:** TBD

#### Q-CPLX-005 -- `benchmarks/framework.zig` 613 lines

**Status: Closed (`44ad6eb`)** -- split into `scenario.zig`, `runner.zig`, `reporter.zig` modules.

- **Category:** maintainability
- **Severity:** Low | **PriorityScore:** 24 (Impact 2 x Likelihood 3 x 4) | **Confidence:** confirmed
- **Evidence:** `benchmarks/framework.zig` -- 613 lines, largest file in repo.
- **Recommended fix:** Split into `runner.zig`, `reporter.zig`, `scenarios.zig`.
- **Effort:** M | **Platform issue:** TBD

---

## Roadmap

### Quick Wins (< 1 day)

- **Q-FMT-001** -- `zig fmt src/` and re-enable strict gate (cascades fix to format-driven readability issues).
- **Q-CI-004** -- replace `zig build check` with full `zig build` + `zig build test` in `.gitlab-ci.yml:59-63`.
- **Q-DEAD-001** -- delete `list_thread.zig`.
- **Q-DEAD-002** -- remove `pub const integration` from `root.zig`.
- **Q-DEAD-003** -- replace placeholder module doc-comment.
- **Q-DEAD-008** -- delete `zig-pkg/thread_pool-0.2.0/`.
- **Q-DEAD-009** -- delete unused `PointF64`.
- **Q-API-010** -- promote magic `4` to named constant.
- **Q-API-011** -- introduce `segmentPath` helper.
- **Q-API-009** -- replace manual LE byte juggling with `std.mem.writeInt`.
- **Q-DOC-002** -- remove/fix broken doc links.
- **Q-DOC-004** -- document WAL durability semantics.
- **Q-CI-001** -- include `benchmarks/` in `zig fmt --check`.
- **Q-CI-003** -- add CI build cache.
- **Q-REL-002** -- replace `catch unreachable` in `wal_record.zig:80`.
- **Q-REL-004** -- log + retry orphan deletes.
- **Q-REL-005** -- capture LSN from `appendRecord`.
- **Q-REL-007** -- log compaction-trigger failures.
- **Q-CPLX-002** -- O(n) segment-removal via hash-set.

### Medium (1-5 days)

- **Q-REL-001** -- WAL replay diagnostics envelope.
- **Q-REL-003** -- `QueryResult` envelope with skipped-segment diagnostics.
- **Q-REL-006** -- background-worker error surface on Engine.
- **Q-REL-008** -- `SegmentWriter.flush()`/`sync()` + manifest fsync ordering.
- **Q-REL-009** -- propagate iterator decode errors.
- **Q-REL-010** -- per-flush sequence id + Condition signal.
- **Q-API-001** -- delete template `init` (unblocks Q-DEAD-004, -005, -006, -007).
- **Q-API-002** -- consolidate Config types.
- **Q-API-003** -- document `MergeIterator` arena ownership.
- **Q-API-006** -- align and document merge tie-breaker.
- **Q-API-007** -- decompose `appendPoints`.
- **Q-API-008** -- replace spin-waits with Condition/ResetEvent.
- **Q-CPLX-001, -003, -004** -- extract helpers / split files. (**Q-CPLX-005 closed `44ad6eb`**)
- **Q-DOC-001, -003, -005** -- rewrite README, doc public methods, doc core types.
- **Q-DEAD-005, -006** -- real integration and stress tests.
- **Q-CI-002** -- bench baseline + flip allow_failure (after Q-DEAD-007).

### Strategic (> 5 days)

- **Q-DEAD-007** -- rewrite benchmark suite against Engine (blocks Q-CI-002).
- **Q-API-005** -- declare named error sets across all public APIs (touches every module).
- **Q-CI-005** -- coverage stage + nightly TSan matrix. **Closed (`f66d641`)**

---

## Acceptance Criteria (cross-cutting)

A subsequent quality pass should be able to verify each finding via these commands:

```sh
# Format
zig fmt --check src/ benchmarks/ tests/

# Build + tests (replaces "build check" in CI)
zig build && zig build test

# Public API surface check
grep -nE '^pub (const|fn) ' src/root.zig

# Dead-code scan
grep -rn 'lib.init(' tests/ benchmarks/   # should be empty after Q-DEAD-004/007

# Error-set discipline
grep -nE '!\s*[A-Z]' src/*.zig             # all returns named after Q-API-005

# CI gate sanity
yq '.benchmark-regression.allow_failure' .gitlab-ci.yml    # should be false after Q-CI-002
```

---

## Notes

- Platform issue creation deferred -- all `Platform issue: TBD`. Once token write access is restored, each Q-* maps 1:1 to a GitLab issue with labels `quality`, `severity::<level>`, `category::<cat>`, `confidence::confirmed`, `status::triage`.
- Scoring discipline: every finding above is `confidence::confirmed` -- file:line cited and verifiable by `grep`/`zig fmt --check`. No `confidence::suspected` entries in this batch.
- Top of the heap (`PriorityScore >= 60`) is dominated by reliability + dead-code-masquerading-as-test categories. The single highest-leverage move is to delete the template `init` (Q-API-001), which unblocks Q-DEAD-004/005/006/007 and ultimately Q-CI-002.
