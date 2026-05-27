# Security Gap Analysis

Application-security findings for the Geode timeseries-storage library, consolidated from Phase 2
(static security scanner) and Phase 3 (adversarial security review).

This document is **scoped to additional findings beyond `GAP_ANALYSIS.md`**. Where a finding
overlaps an existing tracked gap (GAP-0001 TDE, GAP-0002 SeriesId catalog, GAP-0005 fail-closed WAL),
the cross-reference is called out at the top of the entry.

GitLab issue creation is intentionally **deferred** for this audit run. Each finding records the
platform-issue placeholder for traceability; a follow-up run with write token access will publish
them. Findings whose evidence would be useful to an attacker (full exploit chains, forged-file
layouts, OOM triggers) must be filed as **Confidential** when promoted.

## Run Summary

- **Date:** 2026-05-26 (initial audit)
- **Audit phase:** Phase 2 (security-scanner) + Phase 3 (security-reviewer, adversarial)
- **Mode:** DOCS-ONLY (no GitLab issues created)
- **Findings:** 14 new (SEC-001 through SEC-014)
- **Severity counts:** 1 Critical, 6 High, 6 Medium, 1 Low
- **Exploit chains identified:** 6 (Chain A through Chain F)

## Gap-Closure Session Summary (2026-05-26)

- **Session:** 32 commits; security findings addressed in Phases B through E.
- **Security findings closed:** 9 of 14
- **Security findings partial:** 2 (SEC-006, SEC-014)
- **Security findings deferred:** 2 (SEC-007, SEC-008) -- blocked on GAP-0002 tenant catalog
- **Security findings won't-do:** 1 (SEC-013) -- upstream maintainer action
- **Platform issues:** token write access unavailable; all GitLab actions deferred.

### Closure Map

| Finding | Status | Commit |
|---------|--------|--------|
| SEC-001 | Closed | `b23af0a` |
| SEC-002 | Closed | `73926b5` |
| SEC-003 | Closed | `73926b5` |
| SEC-004 | Closed | `088b2f1` |
| SEC-005 | Closed | `b23af0a` |
| SEC-006 | Partial (WAL only) | `38a944b` |
| SEC-007 | Deferred | depends on GAP-0002 |
| SEC-008 | Deferred | depends on GAP-0002 |
| SEC-009 | Closed | `b23af0a` |
| SEC-010 | Closed | `97a37ad` |
| SEC-011 | Closed | `b23af0a` |
| SEC-012 | Closed | `b23af0a` |
| SEC-013 | Won't Do | upstream maintainer action |
| SEC-014 | Partial (structured callback added; full audit trail pending) | `4d4dff5` |

### Status Legend

- **Closed (`<sha>`)** -- implemented and verified.
- **Partial** -- partially addressed; remaining work noted inline.
- **Deferred** -- not addressed; blocked on a dependency or XL design work.
- **Won't Do** -- explicitly decided not to fix; reason documented inline.

### Stack-Ranked Findings (by Risk Score)

| Rank | ID | Severity | Risk | Finding | Component | CWE | Chain | Status |
|------|----|----------|------|---------|-----------|-----|-------|--------|
| 1 | SEC-007 | Critical | 100 | No tenant scoping on append/query (BOLA) | engine.zig | CWE-862, CWE-284 | C | **Deferred** (blocked on GAP-0002) |
| 2 | SEC-001 | High | 64 | No batch-size guard in `appendPoints` allocation | engine.zig | CWE-770 | -- | **Closed** (`b23af0a`) |
| 2 | SEC-002 | High | 64 | WAL `readFrom` silently discards corrupt records | wal_manager.zig | CWE-354, CWE-390 | E | **Closed** (`73926b5`) |
| 2 | SEC-003 | High | 64 | `forEachFromStrict` defined but never called | wal_manager.zig | CWE-354 | E | **Closed** (`73926b5`) |
| 2 | SEC-004 | High | 64 | Segments: magic-only check, no per-block CRC/HMAC | segment.zig | CWE-345 | A | **Closed** (`088b2f1`) |
| 2 | SEC-005 | High | 64 | `BlockHeader.data_len` (u32) unchecked, allows 4 GiB alloc | segment.zig | CWE-770 | A | **Closed** (`b23af0a`) |
| 7 | SEC-006 | High | 48 | WAL `encryption_key` slot exists; never wired (plaintext on disk) | engine.zig, wal_manager.zig | CWE-311 | D | **Partial** (`38a944b` -- WAL only) |
| 7 | SEC-008 | Medium | 48 | Raw `u128` SeriesId persisted; enumerable/leaky | segment.zig, engine.zig | CWE-330, CWE-311 | C, D | **Deferred** (blocked on GAP-0002) |
| 7 | SEC-011 | Medium | 48 | Manifest reader allocates `@intCast(file_len)` without cap | manifest.zig | CWE-770 | B | **Closed** (`b23af0a`) |
| 7 | SEC-014 | Medium | 48 | `debug.print` for background errors; silent recovery failures | engine.zig, wal_manager.zig | CWE-778, CWE-223 | E | **Partial** (`4d4dff5` -- callback added; audit trail pending) |
| 11 | SEC-009 | Medium | 36 | GorillaEncoder bitset doubles capacity with no cap | encoding/gorilla.zig | CWE-770 | -- | **Closed** (`b23af0a`) |
| 11 | SEC-012 | Medium | 36 | `cwd().createFile/openFile` with caller-supplied `data_dir` | segment.zig, manifest.zig | CWE-22 | -- | **Closed** (`b23af0a`) |
| 13 | SEC-013 | Medium | 32 | Supply-chain: 3 deps all on one org (gitlab.com/devnw); no signing | build.zig.zon | CWE-1357, CWE-829 | F | **Won't Do** (upstream maintainer action) |
| 14 | SEC-010 | Low | 8 | `@ptrCast(@alignCast(ctx))` for thread callbacks (latent) | engine.zig, iterator.zig | CWE-704 | -- | **Closed** (`97a37ad`) |

### Top-4 Priorities (Immediate Action)

1. **SEC-007 — BOLA / no tenant scoping (Critical, R=100).** Engine accepts arbitrary `SeriesId` from any caller with no identity, ACL, or namespace. Any compromised or malicious caller can read/write any other tenant's series. Fixing this requires an API change (tenant context parameter + scoped catalog) and partially overlaps `GAP-0002`.
2. **SEC-006 — WAL/segment/manifest plaintext on disk (High, R=48).** The `encryption_key` slot is wired into `WalConfig` but `Engine.init` always passes `.{}`. Cold-disk read = full plaintext disclosure. Tracks `GAP-0001`. Combined with SEC-008, this is **Chain D**.
3. **SEC-002 + SEC-003 — Silent WAL corruption tolerance (both High, R=64 each).** The strict reader exists at `wal_manager.zig:136` (`forEachFromStrict`) but the actual recovery path at `wal_manager.zig:100` swallows checksum mismatches with `catch continue`. Engine recovery is fail-open with no audit trail. Tracks `GAP-0005`. This is **Chain E** -- silent data loss invisible to operators.
4. **Chain D (cold disk) — composite priority.** Combination of SEC-006 (no encryption) + SEC-008 (plaintext SeriesId) + SEC-014 (no detection of disk tampering) means an attacker with disk read access obtains full plaintext: segments, WAL, manifest, block stats, series enumeration. Highest data-loss blast radius even though individual scores are below SEC-007.

---

## Findings

### SEC-007: No Tenant Scoping on `appendPoints` / `queryPoints` (BOLA)

- **Severity:** Critical
- **Risk Score:** 100 (Impact 5 × Likelihood 5 × 4)
- **Status:** Deferred -- blocked on GAP-0002 (tenant catalog) and API-breaking `TenantContext` parameter change requiring Geode coordination. Would be marked Confidential when issued.
- **Confidence:** confirmed
- **CWE:** CWE-862 (Missing Authorization), CWE-284 (Improper Access Control)
- **OWASP:** API1:2023 -- Broken Object Level Authorization (BOLA)
- **Exploit surface:** Library API -- exposure depends on calling app, but library contract has zero scoping
- **Exploit chain:** Chain C
- **Overlap with existing GAP:** Partially overlaps **GAP-0002** (SeriesId catalog), but GAP-0002 covers identifier opacity, not authorization. The authorization gap is **new** and stronger.
- **Platform issue:** TBD (would be marked **Confidential**; token write access required)

**Evidence:**

- [src/engine.zig:101](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L101) -- `appendPoints(self: *Engine, series_id: SeriesId, points: []const Point)` accepts any `u128` with no caller identity, namespace, or ACL check.
- [src/engine.zig:365](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L365) -- `queryPoints(self: *Engine, series_id: SeriesId, ...)` symmetric on the read side. Any caller can request any series.

**Impact:** Cross-tenant breach. Any caller (or any party that compromises the calling layer) can write to or read from any other tenant's series by guessing or enumerating `SeriesId`. Combined with SEC-008 (deterministic / enumerable `u128`), enumeration is trivial.

**Likelihood:** Pre-auth, remote, trivial. Library exposes no boundary at all -- the entire question of authorization is punted to the caller, and the caller has no contract to enforce.

**Attack scenario:** Multi-tenant deployment where tenants share an engine instance. Tenant A's series IDs are derived deterministically (or simply enumerable u128 values). Tenant B (or an attacker who compromises any tenant-side surface) calls `appendPoints` / `queryPoints` against Tenant A's IDs and succeeds. No authorization signal is ever evaluated.

**Recommended fix:**

- Introduce a `TenantContext` (tenant_id + optional capability token) parameter to both `appendPoints` and `queryPoints`.
- Implement a tenant-scoped catalog (ties into GAP-0002): `(tenant_id, app_series_id) → opaque_series_id`.
- Reject any operation whose `tenant_id` does not match the catalog entry for the requested series.
- Add a per-tenant capability check at the engine boundary, before WAL append.

**Acceptance criteria:**

- `appendPoints` and `queryPoints` require a tenant context parameter; calls without it do not compile.
- Negative-test: tenant A's context cannot read or write tenant B's series; result is `error.Unauthorized`.
- Audit log records every cross-tenant access attempt.

---

### SEC-001: No Batch-Size Guard Before Allocation in `appendPoints`

- **Severity:** High
- **Risk Score:** 64 (Impact 4 × Likelihood 4 × 4)
- **Status:** Closed (`b23af0a`) -- `MAX_APPEND_BATCH_POINTS` cap added; `error.BatchTooLarge` returned before any allocation.
- **Confidence:** confirmed
- **CWE:** CWE-770 (Allocation of Resources Without Limits)
- **OWASP:** A06:2021 -- Vulnerable and Outdated Components / resource exhaustion
- **Exploit surface:** Library API -- caller-controlled
- **Exploit chain:** Standalone DoS
- **Overlap with existing GAP:** None.
- **Platform issue:** TBD (would be marked **Confidential** because the OOM trigger is a specific payload-size value)

**Evidence:**

- [src/engine.zig:104-105](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L104-L105) -- `appendPoints` calls `allocator.alloc(u8, 16 + points.len * 16)` with no upper bound on `points.len`.
- `MAX_WAL_PAYLOAD` exists but is only enforced on the **deserialize** path (read), not on the **write/append** path. A 4 GiB `points` slice will allocate 4 GiB at write time before the deserialize check ever sees it.

**Impact:** Process-wide OOM / crash. In a multi-tenant deployment a single caller can take down the engine and any co-located graph stores.

**Likelihood:** Trivial. No authentication is enforced at the library boundary (see SEC-007), so a malicious or buggy caller can pass an arbitrary `points` slice.

**Attack scenario:** Caller invokes `appendPoints(series_id, very_large_points_slice)`. Engine performs `allocator.alloc(16 + N*16)` for N points; with N = 256M, that's a 4 GiB allocation. Allocator either fails (caller-visible crash) or succeeds and pushes the host into swap.

**Recommended fix:**

- Define `MAX_APPEND_BATCH_POINTS` (e.g., 16,384 to match `max_points_per_block * 4`).
- Reject any call where `points.len > MAX_APPEND_BATCH_POINTS` with `error.BatchTooLarge` before any allocation.
- Mirror the deserialize-side `MAX_WAL_PAYLOAD` cap on the serialize/write side as a defense-in-depth check.

**Acceptance criteria:**

- Unit test: `appendPoints(id, oversize_slice)` returns `error.BatchTooLarge` without allocating.
- Defense-in-depth: even if cap is bypassed, deserialize-side `MAX_WAL_PAYLOAD` rejects.

---

### SEC-002: WAL `readFrom` Silently Discards Corrupt Records

- **Severity:** High
- **Risk Score:** 64 (Impact 4 × Likelihood 4 × 4)
- **Status:** Closed (`73926b5`) -- `Engine.init` now uses `forEachFromStrict` as default; `readFrom` restricted to explicit salvage mode.
- **Confidence:** confirmed
- **CWE:** CWE-354 (Improper Validation of Integrity Check Value), CWE-390 (Detection of Error Condition Without Action)
- **OWASP:** A04:2021 -- Insecure Design
- **Exploit surface:** Local disk / pre-replay
- **Exploit chain:** Chain E (with SEC-003, SEC-014)
- **Overlap with existing GAP:** Tracks **GAP-0005**. SEC-002 is the active-code half (silent skip); SEC-003 is the unwired-strict-mode half. Both should be resolved together.
- **Platform issue:** TBD (Confidential)

**Evidence:**

- [src/wal_manager.zig:100](file:///home/benji/src/devnw/zig/timeseries-storage/src/wal_manager.zig#L100) -- `WalRecord.deserialize(allocator, entry.payload) catch continue;` silently skips records that fail deserialization. Checksum mismatches are never surfaced.
- Engine.init uses `wal.readFrom` (not the strict variant). Recovery is **fail-open** by default.

**Impact:** Silent data loss. An attacker who can corrupt or selectively truncate WAL records causes those points to silently disappear from the recovered state. No audit signal, no metric, no error.

**Likelihood:** Any disk corruption (bitrot, partial write, attacker tampering, FS bug) triggers the silent path. Pre-replay surface (no auth needed beyond disk write access).

**Attack scenario:** Attacker with WAL write access flips a single bit in a checksum or truncates a record mid-payload. On next restart, `Engine.init` silently drops the record. Combined with SEC-014 (no logging), there is no audit trail and the operator never knows. Combined with **SEC-003**, the safer code path that would have failed exists but is unreachable.

**Recommended fix:**

- Replace `wal.readFrom` in `Engine.init` with `wal.forEachFromStrict` (already exists at wal_manager.zig:136 -- see SEC-003).
- Surface checksum/deserialize errors as `error.WalCorrupted`.
- Provide an **explicit** `--salvage` / `repair` mode that opts into the lossy path with a loud warning and a metric.
- Increment a `wal.recovery.records_dropped` counter on every silent skip in salvage mode.

**Acceptance criteria:**

- Default `Engine.init` fails closed on any checksum or deserialize error.
- Regression test injects a corrupt WAL record and asserts startup fails with `error.WalCorrupted`.
- Salvage mode is an explicit, documented opt-in.

---

### SEC-003: `forEachFromStrict` Defined But Never Called

- **Severity:** High
- **Risk Score:** 64 (Impact 4 × Likelihood 4 × 4)
- **Status:** Closed (`73926b5`) -- `forEachFromStrict` is now the default recovery reader.
- **Confidence:** confirmed
- **CWE:** CWE-354 (Improper Validation of Integrity Check Value)
- **OWASP:** A04:2021 -- Insecure Design
- **Exploit surface:** Local disk / pre-replay
- **Exploit chain:** Chain E (with SEC-002, SEC-014)
- **Overlap with existing GAP:** Tracks **GAP-0005**. Sister finding to SEC-002.
- **Platform issue:** TBD (Confidential)

**Evidence:**

- [src/wal_manager.zig:136](file:///home/benji/src/devnw/zig/timeseries-storage/src/wal_manager.zig#L136) -- `forEachFromStrict` is implemented and propagates checksum/deserialize errors.
- `grep -r forEachFromStrict src/` returns the definition only -- no caller.

**Impact:** The safer recovery path was written but never wired. Operators reading the code may believe checksum verification is active when it is not.

**Likelihood:** Always (every recovery path bypasses the strict reader).

**Recommended fix:** Same as SEC-002 -- swap the call site in `Engine.init`.

**Acceptance criteria:** `forEachFromStrict` is the default recovery reader; `readFrom` is reserved for an explicit salvage code path with a comment block explaining when (never in normal startup) it is used.

---

### SEC-004: Segments Have Only Magic-Bytes Check, No Per-Block Integrity

- **Severity:** High
- **Risk Score:** 64 (Impact 4 × Likelihood 4 × 4)
- **Status:** Closed (`088b2f1`) -- per-block CRC32C integrity field added to block header; segment format bumped to TSSEG002. CRC verified before any data_len-based allocation.
- **Confidence:** confirmed
- **CWE:** CWE-345 (Insufficient Verification of Data Authenticity)
- **OWASP:** A08:2021 -- Software and Data Integrity Failures
- **Exploit surface:** Local disk (segment files)
- **Exploit chain:** Chain A (with SEC-005)
- **Overlap with existing GAP:** Adjacent to **GAP-0001** (TDE). TDE provides authenticated framing as a side effect; without TDE, an explicit per-block integrity field is required.
- **Platform issue:** TBD (Confidential -- forgery details)

**Evidence:**

- [src/segment.zig:11](file:///home/benji/src/devnw/zig/timeseries-storage/src/segment.zig#L11) -- segment header magic bytes only.
- [src/segment.zig:122](file:///home/benji/src/devnw/zig/timeseries-storage/src/segment.zig#L122) -- read-side check verifies the magic but no per-block CRC/HMAC.
- `Block.decodePoints` allocates `self.header.data_len` without any verification of the header.

**Impact:** Segment files are forgeable. An attacker with disk write access can swap, corrupt, or fabricate blocks; the engine accepts them as long as the file-level magic survives.

**Likelihood:** Disk write access required, but no per-block defense once the attacker has it.

**Attack scenario:** Attacker writes a forged segment file with valid magic bytes and a block header whose `data_len` is `0xFFFFFFFF` (see SEC-005). Engine reads the magic, opens the block, performs a 4 GiB allocation, OOMs. Forms **Chain A**.

**Recommended fix:**

- Add a CRC32C (or BLAKE3-128) integrity field to each block header.
- For tenant-isolated trust models, switch to an HMAC keyed by the per-tenant TDE key (ties to GAP-0001 / SEC-006).
- Verify the integrity tag **before** any allocation from `data_len`.

**Acceptance criteria:**

- Flipping any byte in a block payload causes `Engine.init` (or first query touching the block) to fail with `error.BlockIntegrityFailed`.
- Forged segment file with valid magic but bad block tag is rejected without performing the suspicious allocation.

---

### SEC-005: `BlockHeader.data_len` (u32) Unchecked -- Allows 4 GiB Allocation

- **Severity:** High
- **Risk Score:** 64 (Impact 4 × Likelihood 4 × 4)
- **Status:** Closed (`b23af0a`) -- `MAX_BLOCK_DATA_LEN` cap added; blocks with oversized `data_len` rejected before allocation.
- **Confidence:** confirmed
- **CWE:** CWE-770 (Allocation of Resources Without Limits)
- **OWASP:** A04:2021 -- Insecure Design
- **Exploit surface:** Local disk (segment files)
- **Exploit chain:** Chain A (with SEC-004)
- **Overlap with existing GAP:** None directly; related to GAP-0001 (encryption would cover this) and GAP-0006 (segment verification on startup).
- **Platform issue:** TBD (Confidential -- specific OOM trigger value)

**Evidence:**

- [src/segment.zig:179](file:///home/benji/src/devnw/zig/timeseries-storage/src/segment.zig#L179) -- `BlockHeader.data_len` is a `u32` read from disk. No bound check before allocation.

**Impact:** A forged or corrupted block header with `data_len = 0xFFFFFFFF` causes a 4 GiB allocation per block. Multiplied by N blocks per segment, easily exceeds host memory.

**Likelihood:** Trivial once attacker has segment-write access (or in combination with SEC-004 / SEC-013).

**Attack scenario:** See Chain A in the chain narratives.

**Recommended fix:**

- Define `MAX_BLOCK_DATA_LEN` (e.g., 4 MiB, matching expected `max_points_per_block`).
- Reject any block whose `data_len > MAX_BLOCK_DATA_LEN` with `error.InvalidBlockHeader` before allocating.
- Cross-check `data_len` against remaining file size; reject if it would exceed the file length.

**Acceptance criteria:**

- Forged block with `data_len = u32_max` is rejected; no large allocation is performed.
- Unit test asserts the cap with a fixture file.

---

### SEC-006: WAL `encryption_key` Field Exists But Is Always Empty (Plaintext on Disk)

- **Severity:** High
- **Risk Score:** 48 (Impact 4 × Likelihood 3 × 4)
- **Status:** Partial (`38a944b`) -- WAL encryption key now wired through `EngineConfig` to `WalManager`. Segments and manifest remain plaintext. Full TDE (segments + manifest) tracked under GAP-0001.
- **Confidence:** confirmed
- **CWE:** CWE-311 (Missing Encryption of Sensitive Data)
- **OWASP:** A02:2021 -- Cryptographic Failures
- **Exploit surface:** Cold disk read / backup theft / physical
- **Exploit chain:** Chain D (with SEC-008, SEC-014)
- **Overlap with existing GAP:** **Direct overlap with GAP-0001 (TDE).** This SEC entry restates the issue from the security-review lens (highlighting the always-empty `.{}` config init at `engine.zig:37`) and links it into Chain D. Remediation tracks GAP-0001.
- **Platform issue:** TBD (Confidential)

**Evidence:**

- [src/wal_manager.zig:13](file:///home/benji/src/devnw/zig/timeseries-storage/src/wal_manager.zig#L13) -- `WalConfig.encryption_key` field exists.
- [src/engine.zig:37](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L37) -- `Engine.init` always constructs `WalManager` with empty `.{}` config; `encryption_key` is never populated. AES-256-GCM scaffolding is unused.

**Impact:** All WAL records (and by spec, segments and manifest as well) are written plaintext. Cold-disk read = full data disclosure: timestamps, values, series IDs, tenant workload shape.

**Likelihood:** Requires disk read access (backup theft, physical access, FS misconfig, container volume exposure). Common enough to score L=3.

**Attack scenario:** See Chain D.

**Recommended fix:** Track resolution under **GAP-0001**:

- Wire `WalConfig.encryption_key` from `EngineConfig`.
- Implement AES-256-GCM framing in `SegmentWriter` and `Manifest.writeToFile` / `readFromFile`.
- Bind AAD to `{graph_uuid, file_type, segment_id}` to defeat cross-file substitution.

**Acceptance criteria:**

- Files on disk are not readable without the key.
- Unit test confirms `Engine.init` with a wrong key fails to decrypt and refuses to start.

---

### SEC-008: Raw `u128` SeriesId Persisted; Enumerable and Leaky

- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 × Likelihood 4 × 4)
- **Status:** Deferred -- blocked on GAP-0002 (tenant-scoped encrypted catalog). Raw u128 remains on disk. Would be marked Confidential when issued.
- **Confidence:** confirmed for plaintext-on-disk; suspected for derivation-determinism (depends on caller)
- **CWE:** CWE-330 (Use of Insufficiently Random Values -- suspected), CWE-311 (Missing Encryption -- confirmed)
- **OWASP:** A04:2021 -- Insecure Design / A02 Cryptographic Failures
- **Exploit surface:** Cold disk + library API
- **Exploit chain:** Chain C (with SEC-007), Chain D (with SEC-006)
- **Overlap with existing GAP:** **Direct overlap with GAP-0002** (SeriesId catalog). SEC-008 adds the exploit-chain framing (enumerability for BOLA + plaintext disclosure on disk).
- **Platform issue:** TBD (Confidential)

**Evidence:**

- [src/types.zig:19](file:///home/benji/src/devnw/zig/timeseries-storage/src/types.zig#L19) -- `SeriesId` is a raw `u128`.
- [src/segment.zig:23](file:///home/benji/src/devnw/zig/timeseries-storage/src/segment.zig#L23) -- `BlockHeader` serializes `series_id` as raw LE `u128`.
- [src/engine.zig:108](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L108) -- `appendPoints` writes the raw `SeriesId` directly into the WAL payload.

**Impact:** Two-fold:

1. **Enumeration enables BOLA (Chain C):** if a caller derives `SeriesId` deterministically from `(tenant, metric)` -- common pattern -- IDs are guessable; combined with SEC-007, this is a full cross-tenant breach.
2. **Disclosure on cold disk (Chain D):** workload shape (tenant + metric names if derivable, cardinality, write volume) leaks through file contents.

**Likelihood:** L=4. Enumeration is trivial in the deterministic-derivation case; even random u128s are leaked through file layout.

**Recommended fix:** Track resolution under **GAP-0002**:

- Replace the raw `u128` with an opaque, randomly assigned identifier from an encrypted catalog.
- Catalog maps `(tenant_id, app_series_key) → opaque_series_id`.
- Persist only the opaque ID in WAL and segments.

**Acceptance criteria:**

- No plaintext tenant or metric information appears in WAL, segment, or manifest files (verified by hex-dump fixture test).
- IDs are not enumerable: knowing one valid ID gives no information about other valid IDs in the same tenant.

---

### SEC-011: Manifest Reader Allocates `@intCast(file_len)` Without Cap

- **Severity:** Medium
- **Risk Score:** 48 (Impact 4 × Likelihood 3 × 4)
- **Status:** Closed (`b23af0a`) -- `MAX_MANIFEST_SIZE` cap added; oversized manifest rejected before allocation.
- **Confidence:** confirmed
- **CWE:** CWE-770 (Allocation of Resources Without Limits)
- **OWASP:** A04:2021 -- Insecure Design
- **Exploit surface:** Local disk (manifest file)
- **Exploit chain:** Chain B
- **Overlap with existing GAP:** Adjacent to GAP-0001 (TDE would authenticate manifest size) and GAP-0006 (manifest/segment verification on startup).
- **Platform issue:** TBD (Confidential)

**Evidence:**

- [src/manifest.zig:172-174](file:///home/benji/src/devnw/zig/timeseries-storage/src/manifest.zig#L172-L174) -- manifest reader allocates `@intCast(file_len)` after only checking `file_len < SERIALIZED_SIZE + 4`. The upper-bound check is missing.

**Impact:** Forged manifest with `file_len = 1 GiB+` causes a 1+ GiB allocation at startup. Engine OOMs before it can serve any traffic.

**Likelihood:** Requires manifest write access (disk corruption, attacker, FS bug).

**Attack scenario:** See Chain B.

**Recommended fix:**

- Define `MAX_MANIFEST_SIZE` (e.g., 16 MiB, generous for plausible segment counts).
- Reject any manifest where `file_len > MAX_MANIFEST_SIZE` with `error.ManifestTooLarge`.
- Add a manifest-level checksum (or authenticated framing under GAP-0001) so size tampering is detected before allocation.

**Acceptance criteria:**

- Forged manifest with oversized `file_len` is rejected without large allocation.
- Regression test fixture exercises the rejection path.

---

### SEC-014: `std.debug.print` for Background Errors; No Structured Logging or Fail-Closed Mode

- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 × Likelihood 4 × 4)
- **Status:** Partial (`4d4dff5`) -- structured `Config.error_callback` introduced; `std.debug.print` in background workers replaced. Full audit trail (metrics counters for `wal.recovery.records_dropped`, `segment.integrity_failed`) and `fail_closed_on_corruption` config flag are not yet implemented.
- **Confidence:** confirmed
- **CWE:** CWE-778 (Insufficient Logging), CWE-223 (Omission of Security-relevant Information)
- **OWASP:** A09:2021 -- Security Logging and Monitoring Failures
- **Exploit surface:** Operational / observability
- **Exploit chain:** Chain E (magnifier -- makes attacks invisible)
- **Overlap with existing GAP:** None directly; magnifies GAP-0005 (silent corruption tolerance) and SEC-002 / SEC-003.
- **Platform issue:** TBD

**Evidence:**

- [src/engine.zig:153](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L153), [src/engine.zig:280](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L280) -- `std.debug.print` is the only error reporter for background threads.
- [src/wal_manager.zig:100](file:///home/benji/src/devnw/zig/timeseries-storage/src/wal_manager.zig#L100), [src/wal_manager.zig:127](file:///home/benji/src/devnw/zig/timeseries-storage/src/wal_manager.zig#L127) -- silent failures.
- [src/engine.zig:413](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L413), [engine.zig:417](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L417), [engine.zig:422](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L422), [engine.zig:426](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L426) -- silent error swallows.
- `Engine.init` has no fail-closed mode; no metric for dropped-on-replay records.

**Impact:** Attacks via Chain E (silent WAL corruption) are entirely invisible. No operator-facing signal that recovery dropped records, that a checksum failed, or that a background thread errored. Audit trail is absent.

**Likelihood:** L=4 -- this is the current default behavior on every run.

**Recommended fix:**

- Introduce a logging interface (callback or `std.log` adapter) injected via `EngineConfig`.
- Replace `std.debug.print` with structured logs containing event type, error code, file/segment ID, LSN.
- Add metrics counters: `wal.recovery.records_dropped`, `wal.recovery.checksum_mismatch`, `segment.integrity_failed`, `manifest.read_failed`.
- Add a `fail_closed_on_corruption: bool` config flag (default true).

**Acceptance criteria:**

- All silent `catch continue` / `catch {}` paths either fail closed or emit a structured log + metric.
- Regression test asserts that a corrupt-record scenario produces a log line and a counter increment.

---

### SEC-009: GorillaEncoder Bitset Doubles With No Upper Bound

- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 × Likelihood 3 × 4)
- **Status:** Closed (`b23af0a`) -- `max_points_per_block` enforced inside `GorillaEncoder`; `error.EncoderInputTooLarge` returned before any doubling growth.
- **Confidence:** confirmed
- **CWE:** CWE-770 (Allocation of Resources Without Limits)
- **OWASP:** A04:2021 -- Insecure Design
- **Exploit surface:** Library API -- caller-controlled
- **Exploit chain:** Standalone DoS
- **Overlap with existing GAP:** None.
- **Platform issue:** TBD

**Evidence:**

- [src/encoding/gorilla.zig:134-157](file:///home/benji/src/devnw/zig/timeseries-storage/src/encoding/gorilla.zig#L134-L157) -- encoder bitset doubles capacity with no upper bound check.
- `StoreConfig.max_points_per_block = 4096` is set at the engine level but **not enforced inside the encoder**.

**Impact:** Caller can pass an oversize batch that bypasses the engine-level cap (or reach the encoder via a path that does not enforce `max_points_per_block`) and exhaust memory through doubling growth.

**Likelihood:** L=3 -- requires reaching the encoder with a large input; combined with SEC-001 (no batch cap), trivial.

**Recommended fix:**

- Enforce `max_points_per_block` as a hard cap inside `GorillaEncoder` (defense in depth, in addition to engine-level caps).
- Add an `error.EncoderInputTooLarge` and return it before any doubling that would exceed the cap.
- Add a fuzz test for the encoder with adversarial input sizes.

**Acceptance criteria:**

- Encoder rejects input exceeding the configured cap without growing its bitset.
- Fuzz test runs for N iterations with no OOM.

---

### SEC-012: `cwd().createFile/openFile` With Caller-Supplied `data_dir` (Path Traversal Risk)

- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 × Likelihood 3 × 4)
- **Status:** Closed (`b23af0a`) -- `Engine.init` now rejects relative or traversal `data_dir` with `error.InvalidDataDir`; directory opened once via `std.fs.openDirAbsolute` and all file ops use the resulting handle.
- **Confidence:** suspected (depends on caller sanitization)
- **CWE:** CWE-22 (Path Traversal)
- **OWASP:** A01:2021 -- Broken Access Control
- **Exploit surface:** Library API -- caller-controlled
- **Exploit chain:** Standalone (file overwrite or escape)
- **Overlap with existing GAP:** None.
- **Platform issue:** TBD (Confidential if a specific traversal payload is included)

**Evidence:**

- [src/segment.zig:60](file:///home/benji/src/devnw/zig/timeseries-storage/src/segment.zig#L60), [src/segment.zig:115](file:///home/benji/src/devnw/zig/timeseries-storage/src/segment.zig#L115) -- `cwd().createFile` / `openFile` with paths built from caller-supplied `data_dir`.
- [src/manifest.zig:155](file:///home/benji/src/devnw/zig/timeseries-storage/src/manifest.zig#L155), [manifest.zig:161](file:///home/benji/src/devnw/zig/timeseries-storage/src/manifest.zig#L161), [manifest.zig:166](file:///home/benji/src/devnw/zig/timeseries-storage/src/manifest.zig#L166) -- same pattern in manifest writer.
- [src/engine.zig:36](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L36) -- `data_dir` flows directly from `EngineConfig` to filesystem calls with no normalization, `..` rejection, or absolute-path requirement.

**Impact:** A caller passing an adversarial `data_dir` (e.g., `../../etc/`) writes engine files outside the intended directory. Severity depends entirely on the calling application's input validation -- the library performs none.

**Likelihood:** L=3 -- common library users pass through user input without normalization.

**Recommended fix:**

- Reject any `data_dir` that is not absolute.
- Reject any `data_dir` containing `..` segments after resolution.
- Open the data directory once (`std.fs.openDirAbsolute`) and use `dir.createFile` for relative paths inside that directory -- no `cwd()` calls.
- Add a regression test with adversarial `data_dir` inputs.

**Acceptance criteria:**

- `Engine.init` returns `error.InvalidDataDir` for relative or traversal paths.
- All file operations happen under a single opened directory handle.

---

### SEC-013: Supply Chain -- Three Deps All on `gitlab.com/devnw`, No Signing

- **Severity:** Medium
- **Risk Score:** 32 (Impact 4 × Likelihood 2 × 4)
- **Status:** Won't Do -- upstream signing (`minisign`/`cosign`) requires action by the `devnw` org maintainer, not by this library. The library cannot unilaterally add upstream signing verification without corresponding maintainer participation. This item is tracked as an upstream request; if the `devnw` org adds signing, this library can add verification in `build.zig`.
- **Confidence:** confirmed
- **CWE:** CWE-1357 (Reliance on Untrusted Component), CWE-829 (Inclusion of Functionality from Untrusted Control Sphere)
- **OWASP:** A06:2021 -- Vulnerable and Outdated Components / A08 Integrity Failures
- **Exploit surface:** Build pipeline (CI + developer workstations)
- **Exploit chain:** Chain F
- **Overlap with existing GAP:** None.
- **Platform issue:** TBD

**Evidence:**

- `build.zig.zon` -- three dependencies (`wal`, `uuid`, `thread_pool`) all hosted at `gitlab.com/devnw`. Single-org trust boundary.
- `zig-pkg/` -- contains a stale `thread_pool-0.2.0` cache.
- Content hashes are pinned, but no upstream signing (no `minisign` / `cosign` / Sigstore).

**Impact:** Compromise of any `gitlab.com/devnw` account, CI token, or repository propagates instantly to all downstream consumers via pinned-hash-but-trusted-source updates. No out-of-band integrity check.

**Likelihood:** L=2 -- rare but plausible (account takeover, CI token leak, malicious maintainer).

**Recommended fix:**

- Add upstream signing for `devnw` releases (minisign keypair, distribute public key out-of-band).
- Verify signatures at build time (`build.zig` step that runs before package fetch resolves).
- Diversify trust: when feasible, mirror critical deps to a second host (GitHub, Codeberg) with independent signing.
- Purge stale `zig-pkg/thread_pool-0.2.0` cache; assert in CI that no stale package cache exists outside the pinned set.

**Acceptance criteria:**

- Build fails if a dependency's signature does not match the pinned public key.
- CI run verifies the absence of stale package directories.

---

### SEC-010: `@ptrCast(@alignCast(ctx))` for Thread Callbacks (Latent Type Confusion)

- **Severity:** Low
- **Risk Score:** 8 (Impact 2 × Likelihood 1 × 4)
- **Status:** Closed (`97a37ad`) -- tagged-context magic added to all callback context structs; debug-build assertion verifies the tag before each cast.
- **Confidence:** confirmed
- **CWE:** CWE-704 (Incorrect Type Conversion or Cast)
- **OWASP:** -- (hardening / defense-in-depth)
- **Exploit surface:** Internal callbacks only
- **Exploit chain:** Standalone, latent
- **Overlap with existing GAP:** None.
- **Platform issue:** TBD

**Evidence:**

- [src/engine.zig:151](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L151), [src/engine.zig:278](file:///home/benji/src/devnw/zig/timeseries-storage/src/engine.zig#L278) -- `@ptrCast(@alignCast(ctx))` for thread callbacks.
- [src/iterator.zig:36](file:///home/benji/src/devnw/zig/timeseries-storage/src/iterator.zig#L36), [src/iterator.zig:106](file:///home/benji/src/devnw/zig/timeseries-storage/src/iterator.zig#L106), [src/iterator.zig:163](file:///home/benji/src/devnw/zig/timeseries-storage/src/iterator.zig#L163) -- same pattern.

**Impact:** Latent. If a refactor ever passes the wrong context pointer to one of these callbacks, the cast succeeds silently and the code reads garbage memory as the wrong type. Type confusion -> UB.

**Likelihood:** L=1 -- requires a bug introduced in a refactor; not exploitable today.

**Recommended fix:**

- Wrap each callback's context in a tagged struct with a `magic: u32 = COMPILE_TIME_TAG` field; assert the tag matches before casting.
- Or: use a generic `Context(comptime T: type)` wrapper that pins the type at compile time and exposes only typed accessors.
- Add a debug-build assertion at every cast site.

**Acceptance criteria:**

- All callback sites assert a runtime tag (in debug builds) and use a typed wrapper in release builds.
- Refactor regression: deliberately passing a wrong context type to a callback triggers an assertion in debug mode.

---

## Exploit Chain Narratives

The following chains combine multiple findings to produce a higher-impact attack than any single finding alone. Chains are the reason SEC-006, SEC-008, and SEC-014 are scored higher than their isolated impact would suggest, and why SEC-007 is the top priority despite being a single finding.

### Chain A -- Forged Segment Triggers 4 GiB Allocation Per Block

- **Components:** SEC-004 (segments: magic-only check) + SEC-005 (`data_len` is unchecked u32).
- **Pre-conditions:** Attacker has disk write access (compromised volume, restored backup tampered offline, FS misconfiguration).
- **Steps:**
  1. Attacker crafts a segment file with the legitimate magic header (passes SEC-004 surface check).
  2. Each block header sets `data_len = 0xFFFFFFFF`.
  3. On next `Engine.init` or first query, `Block.decodePoints` allocates `data_len` bytes per block -- 4 GiB each.
  4. Process OOMs or pushes the host into swap. With N blocks, the multiplier compounds.
- **Detection:** None today (SEC-014 -- no metric, no log).
- **Mitigation:** Per-block CRC/HMAC (SEC-004) **and** `data_len` cap (SEC-005). Either one alone is insufficient -- the integrity tag prevents undetected forgery; the size cap prevents OOM even when the integrity check is missing.

### Chain B -- Forged Manifest Triggers Startup OOM

- **Components:** SEC-011 (manifest `@intCast(file_len)` without cap).
- **Pre-conditions:** Attacker has manifest write access.
- **Steps:**
  1. Attacker writes a manifest file with `file_len = 1 GiB+` (only the bottom-bound check `file_len < SERIALIZED_SIZE + 4` is enforced).
  2. Engine startup allocates `file_len` bytes for the manifest buffer.
  3. Engine OOMs before serving any traffic -- denial of service that persists across restart attempts until the attacker's manifest is removed.
- **Detection:** None today.
- **Mitigation:** Upper-bound cap (SEC-011) + authenticated framing (GAP-0001 / SEC-006).

### Chain C -- Cross-Tenant BOLA via SeriesId Guessing or Enumeration

- **Components:** SEC-007 (no tenant scoping) + SEC-008 (raw u128 SeriesId, enumerable).
- **Pre-conditions:** Multi-tenant deployment; attacker is any tenant or any process with library API access.
- **Steps:**
  1. Attacker enumerates `SeriesId` values -- either by guessing (if derivation is deterministic) or by reading cold disk (Chain D).
  2. Attacker calls `appendPoints(victim_series_id, malicious_points)` -- engine writes to victim's series with no authorization check (SEC-007).
  3. Symmetrically, attacker calls `queryPoints(victim_series_id, range)` and reads victim's data.
- **Detection:** None (SEC-014 -- no audit log of cross-tenant calls).
- **Mitigation:** **Both** are required: tenant scoping (SEC-007) to enforce the boundary, opaque catalog IDs (SEC-008 / GAP-0002) to make enumeration impossible.

### Chain D -- Cold Disk Read = Full Plaintext Disclosure

- **Components:** SEC-006 (no TDE) + SEC-008 (plaintext SeriesId) + SEC-014 (no tampering detection).
- **Pre-conditions:** Attacker has read access to disk (stolen backup, snapshot of container volume, retired SSD, physical theft).
- **Steps:**
  1. Attacker reads WAL, segment, and manifest files directly.
  2. SEC-006: files are plaintext -- AES-256-GCM scaffolding (`WalConfig.encryption_key`) was never wired.
  3. SEC-008: `SeriesId` values are raw `u128` -- tenant/metric workload shape inferable (especially if caller-side derivation is deterministic).
  4. Attacker reconstructs full timeseries: timestamps, values, tenant cardinality, ingest cadence.
  5. SEC-014: no signal that the disk was read or modified.
- **Detection:** None.
- **Mitigation:** TDE (GAP-0001 / SEC-006) **and** opaque catalog IDs (GAP-0002 / SEC-008) **and** integrity logging (SEC-014). Each layer alone is insufficient; combined they reduce cold-disk impact to ciphertext that's also opaque about workload shape.

### Chain E -- WAL Corruption = Silent Data Loss, No Audit Trail

- **Components:** SEC-002 (`readFrom` swallows corruption) + SEC-003 (`forEachFromStrict` unwired) + SEC-014 (no logging / metrics).
- **Pre-conditions:** Attacker has WAL write access, OR ordinary disk corruption.
- **Steps:**
  1. Attacker (or bitrot) corrupts a WAL record's checksum or truncates a payload.
  2. On restart, `Engine.init` -> `readFrom` hits the bad record, executes `catch continue`, silently skips it (SEC-002).
  3. The strict reader (`forEachFromStrict`, SEC-003) that would have failed closed is never called.
  4. No log, no metric, no operator-facing signal (SEC-014).
  5. Recovered state is missing the dropped records; queries return incomplete results indefinitely.
- **Detection:** None today.
- **Mitigation:** Wire `forEachFromStrict` as the default recovery path (SEC-003) **and** emit structured logs/metrics on every dropped record (SEC-014). Track resolution under **GAP-0005**.

### Chain F -- Single-Org Supply Chain Compromise

- **Components:** SEC-013 (all deps on `gitlab.com/devnw`, no signing).
- **Pre-conditions:** Attacker compromises a single `gitlab.com/devnw` account or CI token.
- **Steps:**
  1. Attacker pushes a malicious release of `wal`, `uuid`, or `thread_pool` to `gitlab.com/devnw`.
  2. Downstream consumers (any timeseries-storage user) update their pin to the new hash.
  3. Malicious code executes inside every downstream `Engine.init` -- with full filesystem and network access.
- **Detection:** Pinned hashes provide tampering detection only **after** a pin update. Operators relying on automatic pin refreshes have no out-of-band integrity signal.
- **Mitigation:** Upstream signing (`minisign` / `cosign`); CI verification of signatures; mirror critical deps to a second-host repo (GitHub / Codeberg) with independent signing.

---

## Cross-Reference With Existing Gaps

| New SEC entry | Existing gap | Relationship | Resolution path |
|---------------|--------------|--------------|-----------------|
| SEC-006 | **GAP-0001** (Missing TDE) | Direct overlap | Track under GAP-0001 |
| SEC-007 | GAP-0002 (SeriesId catalog) | Partial overlap (catalog yes, ACL no) | New work item beyond GAP-0002 |
| SEC-008 | **GAP-0002** (SeriesId catalog) | Direct overlap | Track under GAP-0002 |
| SEC-002 | **GAP-0005** (Silent WAL corruption) | Direct overlap | Track under GAP-0005 |
| SEC-003 | **GAP-0005** (Silent WAL corruption) | Direct overlap | Track under GAP-0005 |
| SEC-004 | GAP-0001 / GAP-0006 | Adjacent | New work item (per-block integrity) |
| SEC-011 | GAP-0001 / GAP-0006 | Adjacent | New work item (size cap) |
| SEC-001, SEC-005, SEC-009, SEC-010, SEC-012, SEC-013, SEC-014 | -- | Net-new | New work items |

---

## Roadmap

### Quick wins (less than 1 day each)

- **SEC-001** -- add `MAX_APPEND_BATCH_POINTS` cap in `appendPoints`.
- **SEC-005** -- add `MAX_BLOCK_DATA_LEN` cap in segment block parsing.
- **SEC-011** -- add `MAX_MANIFEST_SIZE` cap in manifest reader.
- **SEC-003** -- swap `readFrom` for `forEachFromStrict` in `Engine.init`.
- **SEC-009** -- enforce `max_points_per_block` inside `GorillaEncoder`.
- **SEC-012** -- reject relative / traversal `data_dir` and open the data directory once.

### Medium (1-5 days each)

- **SEC-002 + SEC-014** -- wire fail-closed recovery, add structured logging hooks, add counters for dropped/corrupt records.
- **SEC-004** -- per-block CRC32C integrity tag (interim, before HMAC under TDE).
- **SEC-010** -- tagged context wrapper for thread callbacks.
- **SEC-013** -- minisign signing of `devnw` deps + CI verification.

### Strategic (more than 5 days each)

- **SEC-007** -- tenant context API + scoped catalog (joint work with GAP-0002).
- **SEC-006 + SEC-008** -- full TDE (AES-256-GCM with AAD binding) for WAL, segments, and manifest (GAP-0001 + GAP-0002 alignment).

---

## Immediate Actions (Operational)

- **None of the findings indicate a leaked secret in the repository today.** No credential rotation is required from this audit. The `WalConfig.encryption_key` is a *slot*, not a leaked key.
- The library is **not production-safe for multi-tenant deployment** until SEC-007 (tenant scoping) and SEC-006 (TDE) are resolved.
- Engine startup is **not safe against malicious disk content** until SEC-004, SEC-005, and SEC-011 are resolved -- a tampered or corrupted disk can OOM the process.
- WAL recovery is **silently lossy** today (SEC-002 + SEC-003). Any deployment that depends on durable replay should not rely on the current default until GAP-0005 is closed.

---

**Last updated:** 2026-05-26 (gap-closure session reconciliation)
