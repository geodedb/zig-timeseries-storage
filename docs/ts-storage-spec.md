# Optimizing Time-Series Storage for Geode

## Executive summary

### Best recommendation

Replace the current time-series persistence layer with a **segment-based, append-oriented engine** that uses **(a) a small WAL-protected “head”**, **(b) immutable, time-partitioned compressed segments with per-block statistics**, and **(c) background compaction/retention via manifest-driven file lifecycle**. Keep the **analytics algorithms** (DTW / matrix profile / feature extraction / invariants / etc.) in the extracted `zig/timeseries` library, but **do not keep the current `ChunkStorage` disk format** except as a read-only legacy import path. citeturn19view1turn24view2turn23view2turn46view3

### Why

The current “persistence” is effectively **best-effort snapshotting of entire in-memory series**, with **no crash-atomicity**, **no real retention deletion**, **no encryption-at-rest for time-series files**, **a high metadata leakage surface**, and **a startup model that must hydrate everything into memory**. That is fundamentally incompatible with the invariants you listed (durable recovery, TDE/FLE, backups, multi-tenant isolation) and will collapse under any sustained high-cardinality or long-retention workload. citeturn24view2turn23view2turn23view3turn19view1turn46view3

### Biggest risks

The hard risks are (1) **semantic drift** in as-of lookups and analytic functions if the new iterator/merge logic is wrong, (2) **migration** from the legacy format that likely contains duplicate series snapshots, and (3) **tight integration** with Geode’s security/backup/recovery expectations, which today are visibly GraphStore-centric in some modules. citeturn24view2turn23view2turn47view0turn47view1turn47view2

### Confidence level

**Medium** for the architectural direction (the current implementation’s limits are unambiguous in code), **lower** for the exact integration points with Geode’s transactional/backup machinery because several operational paths in the repository are explicitly **GraphStore-only**, and the graph-storage-backed path is not represented in the backup modules inspected. citeturn23view2turn24view2turn47view0turn47view2turn37view0

## Current-state architecture map

### Modules, ownership boundaries, and storage path

**Boundary verification (Geode vs extracted library).**
Geode’s `src/timeseries/timeseries.zig` and `src/timeseries/chunk_storage.zig` are thin wrappers that **re-export** the extracted `timeseries_lib` dependency, indicating the time-series engine logic is owned primarily by the external library rather than Geode core. citeturn12view2turn12view3turn12view0turn10view0

**How the per-graph store is created and where it lives on disk.**
The graph-storage adapter instantiates one `ts_mod.Store` per graph (`ManagedGraph.ts_store`). It passes the **graph directory** as `StoreConfig.data_dir`, and the extracted time-series library appends `"/timeseries"` internally, placing time-series files under:
`{GEODE_DATA_DIR}/graphs/{uuid_hex}/timeseries/…` citeturn19view0turn19view1

**Durability is optional and failure is soft.**
If `ts_mod.Store.initWithConfig` or `loadFromDisk()` fails, Geode logs warnings and continues; the graph remains usable without time-series persistence. That means the time-series store is not currently treated as a critical durability component in the server lifecycle. citeturn19view1

**Disk format and files created today.**
Inside `ChunkStorage.init`, the library ensures the directory exists and creates/opens an append-only `chunks.dat`. Chunk metadata is appended to `chunk_meta.dat`. Series-key metadata is stored separately in `series_meta.dat`. citeturn23view2turn23view3turn24view0turn22view3

### Current data flow from query to disk

**Query-level time-series functions.**
Geode’s `src/timeseries/gql_functions.zig` exposes a set of time-series functions (canary-tagged) including last/valueAt, sampleBy/timeBucket, interpolate/moving average/rate/derivative, plus higher-order analytics like change points, feature extraction, matrix profile, invariants, and DTW-family operations. citeturn43view0turn43view2turn43view3

**Where the functions read from.**
Helpers like `extractF64FromSeries()` read from `store.getSeries(key)` and directly iterate the **in-memory** `series.points.items`, then feed numeric arrays into analytics modules. This is important: many analytics functions operate on a fully materialized point slice, not a streaming iterator. citeturn13view0turn43view1

**Ingestion/write path in the extracted library.**
The extracted `Store.insertMany()` appends points to an in-memory `ArrayList`, checks whether it can fast-path append, otherwise sorts the *entire series array* with `std.sort.pdq`. When persistence is enabled, it tracks an unflushed counter and—when a threshold is hit—**flushes by writing all points in the series** to `ChunkStorage.writePoints()`. `sync()` repeats the same full-series write for any series with unflushed data. citeturn24view2turn21view0turn22view3

### Where durability, encryption, backup, and recovery responsibilities live

**Graph WAL/recovery exists, but time-series is not part of it.**
Geode’s `src/wal.zig` wraps an external WAL library and defines record types exclusively for graph mutations (create node/edge, set/remove properties, labels, deletes). There is no time-series record type in that WAL schema, and no code path shown that emits time-series writes into the WAL. citeturn17view0

**Geode’s documented crash recovery relies on WAL + checkpoint phases.**
The recovery documentation describes a restart sequence including WAL analysis, redo of committed transactions, undo of uncommitted transactions, and checkpointing. That model aligns with the graph WAL design but does not mention time-series state. citeturn42view1

**TDE utility exists, but time-series files do not use it today.**
Geode provides file-level AES-256-GCM utilities (`tde_file_encryption.zig`) and explicitly frames TDE as applying to persistent storage files (indexes, catalogs, backups, raft state). The time-series library’s `ChunkStorage` opens plain files with mode `0o600` but does not use TDE encryption or authenticated integrity framing for `chunks.dat` / `chunk_meta.dat` / `series_meta.dat`. citeturn46view3turn23view2turn23view3turn24view0

**Backup/restore modules seen are GraphStore-only.**
`src/storage/backup.zig`, `src/server/backup_manager.zig`, and `src/storage/s3_backup.zig` are explicitly described as “GraphStore-only” snapshot/backup managers. The snapshot pipeline module shown is also GraphStore-centric (`GraphStore snapshot maintenance pipeline`). This strongly suggests that, as of the inspected code paths, time-series persisted under per-graph directories is **not covered** by these backup facilities. citeturn46view2turn47view0turn47view1turn47view2turn47view3

## Alternatives analysis

### Evaluation weights

Weights reflect Geode’s likely mixed workload: high ingest bursts, query-time analytics, strict security expectations, and operational requirements (backup/recovery). Sum = 100.

| Criterion | Weight |
|---|---:|
| Ingest throughput | 15 |
| Out-of-order write cost | 8 |
| Point lookup / as-of latency | 8 |
| Aggregation latency (sampleBy/bucket) | 8 |
| Startup / hydration time | 8 |
| Compression ratio / bytes per point | 7 |
| Flush/compaction cost | 6 |
| WAL / recovery cost | 4 |
| Backup/restore efficiency | 6 |
| Retention/prune cost | 4 |
| Corruption blast radius | 4 |
| Metadata leakage risk | 4 |
| Implementation complexity / refactor risk | 6 |
| Migration difficulty | 4 |
| Fit for future distribution/sharding | 8 |

### Decision matrix comparing required architectures

Scoring: 1 (poor) → 5 (excellent). Scores are justified directly by the current implementation’s properties and what each option structurally enables.

| Option | Summary | Weighted outcome |
|---|---|---|
| A. Keep current design as-is | In-memory arrays + full-series snapshot chunks + best-effort load | **Eliminate** |
| B. Keep wrapper/external design, tune only | Patch obvious hotspots but keep same format and hydration model | **Eliminate** unless scope is tiny |
| C. Append-only time-partitioned chunk segments + manifest + compaction | Immutable segments, time partitioning, manifest index | Strong |
| D. Per-series/per-partition chunk files + explicit catalogs | Simpler per-series isolation, but file explosion | Medium |
| E. LSM-style segments for OoO + tombstones | Good OoO writes and deletes, needs compaction | Strong |
| F. Columnar chunks + min/max stats + late materialization | Makes aggregations fast without full decompression | Strong (needs a write model) |
| G. Share page/WAL/checkpoint primitives with graph-storage | Best for TDE/backups/recovery alignment, higher complexity | Strong but risky |
| H. Hybrid (C+E+F) with selective sharing (G where needed) | Best overall trade-offs | **Best** |

#### Why A is not viable

The extracted `Store` sorts whole series on overlap/unordered input, and persistence flush writes the full series repeatedly, which is unbounded write amplification. citeturn24view2turn23view2
`ChunkStorage.queryRange()` must decompress entire chunks and filter point-by-point; there is no per-block pruning beyond chunk start/end timestamps. citeturn23view2
Retention only rebuilds in-memory metadata and does not reclaim `chunks.dat` space, so backups and disk usage will grow without bound. citeturn23view3
Time-series state is not integrated with Geode’s WAL/recovery model and does not use the provided TDE framing. citeturn17view0turn46view3turn23view2

#### Why B is still weak

Even if you “optimize” the current chunk format, as long as the design requires full hydration into memory (`loadFromDisk()` reinserts points into in-memory series) it will still break at scale. citeturn22view3turn19view1turn43view1
Also, the GraphStore-focused backup modules indicate operational gaps that “tuning only” won’t solve for the invariants. citeturn47view0turn47view2

## Recommended design

### Target architecture: hybrid segment-LSM with columnar blocks and manifest-driven lifecycle

The recommendation is a **rebuild of the time-series persistence layer** inside `zig/timeseries`, while keeping the analytic computation modules (DTW/matrix profile/features/etc.) intact and invoked from Geode’s `src/timeseries/gql_functions.zig`. citeturn43view0turn22view2

#### On-disk layout

Under `{graph_dir}/timeseries/` (same top-level directory used today to avoid changing Geode’s per-graph directory semantics): citeturn19view1turn22view3

- `manifest/ts.manifest`
  Versioned manifest containing:
  - format version, manifest UUID, monotonic epoch
  - per-segment index (segment id → file path, time partition, block index offsets)
  - per-series catalog (series_id → encrypted logical key reference or graph-attached mapping key)
  - compaction levels and active L0/L1 segment lists
  - checksums for every manifest record (fail-closed start-up)

- `wal/ts.wal`
  A time-series WAL, used only for the “head” / memtable and for exactly-once segment publication semantics. Encrypt using the same operational keying model as Geode WAL/TDE (e.g., `GEODE_TDE_KEY`-derived), but introduce a dedicated env var precedence similar to `GEODE_WAL_KEY`. citeturn17view0turn46view3

- `segments/p{partition}/seg-{ulid}.tsseg`
  Immutable segment files partitioned by time (e.g., day or hour partitions) so retention is mostly file deletion. Each file contains multiple **blocks**, each block representing `(series_id, start_ts..end_ts)`.

- `tmp/`
  Crash-safe temp files used only for atomic rename during compaction.

This replaces today’s `chunks.dat` + `chunk_meta.dat` + `series_meta.dat` model, which is not crash-atomic and leaks series identity. citeturn23view2turn23view3turn24view0

#### Block format and compression

Each block stores columnar data:

- Timestamp column: delta-of-delta encoding (you already implement it inside Gorilla timestamp path today). citeturn22view0turn23view1
- Value column: Gorilla XOR encoding (already implemented for `i64` values). citeturn22view0turn23view1
- Optional: a small “skip index” every N points for in-block binary search (to accelerate `valueAt/valueBefore` without full decode).

Per-block statistics persisted in the block header:

- `min_ts/max_ts`
- `count`
- `min_value/max_value`
- `sum` (for avg/sum)
- `first_value/last_value` (for first/last)
These stats allow `sampleBy` / `timeBucketAvg` to skip decoding value payloads for many buckets. The current implementation always iterates all points when aggregating. citeturn22view3turn23view2

### Flush / compaction / retention model

#### Ingestion model

- Writes go to an in-memory **memtable per series** (or per shard) plus a single append-only `ts.wal` record stream.
- When memtable reaches thresholds, flush to an immutable **L0 segment** in the appropriate time partition.
- “Publish” a segment by atomically appending its metadata to the manifest (with checksum).

This replaces the current model where reaching a threshold triggers `cs.writePoints(chunk_id, s.points.items)` with *the entire series*, i.e., full snapshot rewrites. citeturn24view2turn23view2

#### Out-of-order writes

- Accept OoO writes into the memtable regardless of partition.
- For OoO writes that target already-sealed time partitions, write into a small “late” L0 segment in that partition. This creates duplicates across levels but bounded.
- Compaction merges blocks for a series inside a partition, producing an L1 segment with:
  - sorted, de-duplicated points
  - explicit policy for duplicate timestamps (choose last-write-wins if you can define it; if current semantics are “timestamp is key” but duplicates exist, preserve stable ordering rules and document it)

This is structurally impossible to do efficiently in today’s implementation because `insertMany` sorts a monolithic in-memory array and persistence is full-series snapshotting. citeturn24view2turn23view2

#### Retention

Retention becomes:

- Delete whole partitions (directory `pYYYYMMDD/`) when fully older than cutoff.
- For partially-covered partitions, delete segments whose `max_ts < cutoff`.
- If a segment straddles cutoff, compact it and drop expired blocks.

Today’s `runRetention()` merely filters chunk metadata in memory and does not reclaim disk. citeturn23view3turn22view3

### Crash-recovery model

#### Goals

- No silent data loss
- Deterministic restart to last consistent manifest state
- Detection of partial writes and corruption (fail-closed)

#### Implementation outline

- WAL records are appended with checksums; on startup:
  1) Load manifest (verify checksums; reject if corrupted unless explicit “repair” mode).
  2) Replay WAL to rebuild memtables for any unpublished data.
  3) If a segment temp file exists without a matching manifest record, delete temp file.
  4) If manifest references a missing segment, fail closed (or go into repair workflow).

This aligns with Geode’s documented recovery model (analysis → redo/undo → checkpoint), but applies it to time-series state explicitly instead of leaving it out-of-band. citeturn42view1turn17view0

### Backup/restore model

#### Current gap to close

The backup manager and S3 backup code explicitly target “GraphStore only.” That is incompatible with time-series durability guarantees if time-series is persisted under per-graph directories. citeturn47view0turn47view2turn19view1

#### Recommended backup integration

Add a **per-graph backup manifest** that includes:

- graph-storage engine snapshot artifacts (whatever GraphEngine produces on checkpoint)
- time-series `timeseries/manifest` and `timeseries/segments`
- full-text index `fts/` (already per-graph) citeturn19view0
- audit log `audit.jsonl` if required for compliance restore semantics citeturn19view0

Backup process:

1) Acquire per-graph lock (reuse `ManagedGraph.rwlock` and extend it to cover both graph engine checkpoint and time-series checkpoint). citeturn19view1
2) Run `engine.checkpoint()` then `ts_store.syncCheckpoint()` (a new API that flushes memtable to L0 and fsyncs manifest/WAL as needed).
3) Copy/snapshot the graph directory into backup artifact (or stream it through an archive format).
4) Restore rehydrates graph engine + time-series manifest/segments as a consistent unit.

This is the minimum needed to meet the “backup/restore correctness” invariant.

### Security model

#### Series identity and metadata leakage

Today, `SeriesKey` is `(device_id, metric)` and the persistence layer appends that mapping into `series_meta.dat` (device_id + metric bytes). That leaks both high-level schema and workload shape through backups, filenames, and plain metadata. citeturn24view2turn24view0

Recommended changes:

- Introduce an internal `series_id` that is **not derived from plaintext identifiers in a reversible way** (avoid today’s `chunkSeriesId(hk)` truncation). citeturn24view0
- Store the `(tenant_id, device_id, metric)` → `series_id` mapping inside an encrypted catalog:
  - either in the graph store as an encrypted property (leveraging existing security mechanisms)
  - or in the time-series manifest with TDE framing + authenticated integrity (AES-GCM with AAD binding to graph UUID)

#### Encryption-at-rest and integrity

Use Geode’s AES-256-GCM framing concepts (or a streaming-compatible extension) for:

- manifest
- WAL
- segment files (block-level or file-level)
and bind AAD to `{graph_uuid, file_type, segment_id}` to prevent cross-file substitution attacks. The current `tde_file_encryption` module defines a file framing magic and authenticated decryption failure handling expectations. citeturn46view3

### Migration model

Support **two formats in parallel**:

- **Legacy reader** for `{timeseries}/chunks.dat + chunk_meta.dat + series_meta.dat` to enable in-place upgrade. citeturn23view2turn23view3turn24view0
- **New writer** outputs the segment-based format alongside, under e.g. `{timeseries}/v2/…`.

Migration steps:

1) On startup, if legacy exists and v2 absent: create v2 manifest and begin background migration.
2) For each legacy `series_id`:
   - read all legacy chunks, merge-sort, de-duplicate by timestamp per defined semantics
   - write into v2 segments partitioned by time
3) Once all series are migrated and validated (counts/checksums), mark v2 as active in manifest and optionally archive old files.

This is necessary because the legacy system may have repeated full-series flushes; migration must assume duplicates are present even if current tests do not exercise that path. citeturn24view2turn23view2

## Security review

### Confidentiality

- **Current risk:** Unencrypted time-series data and unencrypted `series_meta.dat` leak device IDs and metric names. citeturn24view0turn23view2turn19view1
- **Fix:** Encrypt manifest/WAL/segments; store or derive series identity without plaintext leakage; avoid plaintext identifiers in filenames.

### Integrity and tamper resistance

- **Current risk:** `chunks.dat` payload and `chunk_meta.dat` are written independently with no atomic commit protocol and no authenticated integrity check. Partial writes can yield silent truncation or metadata/payload mismatch (queryRange skips if reads don’t match sizes). citeturn23view2turn23view3
- **Fix:** Manifest-driven atomic publication + per-record checksums + authenticated encryption; fail-closed startup if manifest/segment mismatch.

### Retention deletes: auditable and fail-closed

- **Current risk:** Retention rebuilds in-memory metadata but doesn’t remove on-disk data. This is not compliant with “delete means delete” expectations and will leak through backups. citeturn23view3turn47view2
- **Fix:** Time-partitioned segment deletion + manifest tombstones + compaction for partial partitions; log deletions into audit stream.

### Cross-tenant confusion

- **Current risk:** `chunkSeriesId` truncates a u128 hash to u64 which is collision-prone at scale, and `series_meta.dat` uses that id as lookup key. Collision would merge two tenants/series into one storage identity. citeturn24view0turn22view3
- **Fix:** Use full-width ids (u128) or randomly assigned ids stored in encrypted catalog; include tenant scope in mapping.

## Implementation and validation plan

### Code impact map

#### Geode repository changes

- `src/storage/graph_storage_adapter.zig`
  - Replace `ts_mod.Store.initWithConfig(...).loadFromDisk()` with new APIs:
    - `initWithConfig` + `openOrCreate` + `replayWal` + `loadManifestIndex` (names illustrative)
  - Activate hard-failure vs soft-failure depending on config (time-series durability mode). citeturn19view1
- `src/timeseries/gql_functions.zig`
  - Replace any direct materialization assumptions with iterator-based extraction paths where feasible (but preserve semantics). citeturn43view1turn13view0
- Backup integration
  - Current modules are GraphStore-only (`src/storage/backup.zig`, `src/server/backup_manager.zig`, `src/storage/s3_backup.zig`). A new backup path must include per-graph time-series directories. citeturn47view0turn47view2turn46view2
- Security integration
  - Use `src/storage/tde_file_encryption.zig` framing or extend it to streaming/block framing for segments/WAL. citeturn46view3

#### Extracted `zig/timeseries` library changes

- Replace/retire `src/chunk_storage.zig` format for write path; keep as legacy reader. citeturn23view2turn23view3
- Replace persistence logic in `src/store.zig`:
  - remove full-series flush behavior (`cs.writePoints(chunk_id, s.points.items)`) citeturn24view2
  - implement memtable + WAL + segment writer + manifest manager
  - implement query iterators that stream blocks rather than loading everything
- Add corruption tests and format versioning in `src/root.zig` (entrypoint) as needed. citeturn22view2

### Testing plan

#### Unit tests

- Segment encoding/decoding round-trips (timestamps + values), similar in spirit to existing Gorilla round-trip tests. citeturn23view3turn22view0
- Manifest atomicity tests: interrupted publish, missing segment, bad checksum → fail-closed.
- Series identity mapping tests: tenant-scoped ids, collision resistance (no u64 truncation).

#### Integration tests (Geode + library)

- Preserve semantics of:
  - `last`, `valueBefore`, `valueAt` (binary search correctness across merged segments) citeturn24view2
  - `sampleBy`, `timeBucketAvg` (bucket boundaries, null handling) citeturn22view3
  - interpolation/moving average/rate/derivative and array-based analytics (DTW family, matrix profile, invariants) citeturn43view0turn43view2turn43view3turn22view1
- Multi-graph isolation: verify `{data_dir}/graphs/{uuid}/timeseries` separation. citeturn19view1

#### Fault-injection tests

- Crash during:
  - WAL append
  - segment write before manifest publish
  - manifest publish (partial write)
- Corrupt:
  - manifest block checksum
  - segment block checksum/tag
  - missing segment file referenced by manifest

#### Migration tests

- Write legacy data with multiple flush cycles (forcing full-series snapshot duplication), then migrate and verify:
  - dedup + stable ordering
  - range queries match legacy semantics

#### Backup/restore tests

- Extend beyond GraphStore-only backup tests to include per-graph timeseries directories. Current backup systems are labeled GraphStore-only, so the new tests must cover the new integrated backup artifact semantics. citeturn47view0turn47view2

### Benchmark plan

To be implementable, build a harness that measures:

- ingest throughput (points/sec)
- latency p50/p95/p99 for point lookups and bucket queries
- bytes written per point (including WAL + segment + manifest overhead)
- compaction amplification (bytes rewritten / bytes ingested)
- startup time (manifest load + WAL replay)
- recovery time after injected crash
- memory footprint (RSS) and open file descriptors

Bench matrix (each row is a benchmark scenario):

| Scenario | Workload pattern | Dataset shape | Success metrics | Failure conditions | Instrumentation | Expected trade-offs |
|---|---|---|---|---|---|---|
| Hot dense ordered | streaming append in-order | 1 series, 100M points | >X pts/s; low write amp | WAL stalls; segment publish stalls | WAL bytes, segment bytes, fsync time | Best-case for append segments |
| Hot dense heavy OoO | random timestamps in recent window | 1 series, 100M points, 30% OoO | bounded compaction; stable p99 | compaction runaway | per-level segment counts, compaction queue | LSM needed |
| Many sparse high-cardinality | many series, few points | 10M series × 10 points | startup does not OOM | hydration OOM | manifest size, fd count | requires sparse indexes |
| Mixed hot/cold + retention | rolling window deletes | partitioned by day | retention deletes reclaim disk | disk never shrinks | deleted segment count, backup delta | partition deletion is key |
| Batch ingest vs streaming | large insertMany batches | variable | stable ordering, no resort storms | CPU spikes from sorting | CPU profile, comparator counters | avoid full re-sorts |
| Read-heavy as-of | repeated valueBefore/last | mixed series | p99 lookup low | scans too many blocks | block seek counters | needs per-series index |
| Aggregation-heavy | sampleBy/timeBucket queries | 1k series × 10M pts | near-linear at blocks, not points | decompress everything | decoded points count, stats hit-rate | columnar + stats wins |
| Analytics-heavy | DTW/matrix profile | medium series windows | correctness preserved, bounded alloc | allocator blowups | alloc counters, safety caps | iterator extraction must be cheap |
| Startup hydration | restart with 1–10 TB | many series | startup bounded (manifest+WAL) | full-load behavior | time-to-ready, manifest scan bytes | remove full hydration |
| Crash during flush/compaction | kill -9 at phases | any | recovery deterministic | silent loss | WAL replay logs, manifest verification | fail-closed |
| Corrupt metadata/chunk | mutate bytes | any | detected + isolated | returns garbage | checksum/tags | must not degrade integrity |
| Backup/inc backup/restore | periodic backups | large dataset | efficient deltas | time-series missing | backup contents audit | integrate ts dirs |
| TDE on/off | enable key env var | same | small overhead | large regression | encrypt/decrypt CPU, IO | choose block size |
| Multi-tenant isolation | tenant mix | shared graph or per-graph | no cross-reads | id collision merges | per-tenant series_id stats | avoid u64 truncation |
| Distributed/sharded (future) | shard by series_id | simulated | stable partitioning | hotspot shards | shard histogram | design for hashing |

## Risk register and rollout decision

### Technical risks

- **Semantic compatibility risk:** iterator merge/dedup logic must preserve `valueBefore/valueAt` semantics defined by today’s binary search on sorted in-memory arrays. citeturn24view2
- **Compaction complexity:** LSM-style compaction is easy to get wrong (amplification, starvation).
- **Large analytics workloads:** existing GQL functions extract arrays from full series slices; iterator-based extraction needs careful bounded allocation policies. citeturn43view1turn22view1

### Security risks

- **Current leakage:** `series_meta.dat` stores `device_id` and `metric` in a recoverable mapping. Must be removed or encrypted. citeturn24view0
- **Key management:** introducing TS-WAL encryption requires consistent key scope with `GEODE_TDE_KEY` and the WAL precedence model used in `wal.zig`. citeturn17view0turn46view3

### Operational risks

- **Backup gap:** existing backup/S3 backup paths are GraphStore-only, so time-series durability is operationally unsafe until integrated backup is implemented. citeturn47view0turn47view2
- **Upgrade/migration time:** migrating legacy stores may be slow and must be resumable.

### Migration risks

- **Legacy duplication:** current flush behavior can write full-series snapshots repeatedly; migration must deduplicate. citeturn24view2turn23view2
- **Rollback:** must be able to fall back to legacy reader if v2 fails.

### Final recommendation

**Go**, but only as a **phased rollout**:

1) **Phase 0: lock down invariants and observability**
   - Add instrumentation around current `insertMany/sync/loadFromDisk/queryRange` to quantify write amp and hydration cost in real deployments. citeturn24view2turn23view2turn22view3

2) **Phase 1: build the new persistence layer behind a feature flag**
   - Implement v2 manifest + segment writer + WAL replay in `zig/timeseries`.
   - Keep current analytics APIs intact (operate on extracted arrays), but switch extraction to stream from segments where possible.

3) **Phase 2: integrate backup/restore + TDE**
   - Treat time-series as first-class in backup artifacts; do not ship “durable” time-series until this is done, because current backup is GraphStore-only. citeturn47view0turn47view2turn46view3

4) **Phase 3: migration**
   - Provide an offline migration tool and an online resumable migrator; validate by checksum + query equivalence.

**Rollback plan**

- Keep legacy reader and keep writing legacy format optionally until v2 is validated.
- If v2 manifest verification fails at startup, drop back to legacy mode (read-only) and require operator action for repair/migration continuation.

**What to prototype first**

- A minimal v2 segment + manifest + WAL that supports:
  - ordered ingest
  - `last`, `valueBefore`, `valueAt`
  - `sampleBy` using block stats
This closes the highest-risk performance path while validating correctness early. citeturn24view2turn22view3turn43view0
