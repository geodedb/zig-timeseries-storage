# graph-storage → timeseries-storage Parity Audit (2026-07-09)

Cross-repo audit of every graph-storage improvement from 2026-06-19 →
2026-07-09 (v0.2.5 → v0.3.2), mapped onto this LSM engine. Six defect
classes transferred and were fixed (see the tasks in
`docs/superpowers/plans/2026-07-09-graph-storage-parity-hardening.md`);
the rest were audited and found not applicable. This file records the
NOT-APPLICABLE findings so they are not re-audited.

## Fixed here (see plan + git history)

| graph-storage fix | this repo |
|---|---|
| 2dcc678 checked offset arithmetic on hostile input | manifest segment-table exact-length gate |
| CWE-770 unbounded alloc class | block decode point-count cap + Gorilla reserve clamp |
| 49d85dc downgrade gate / 22b801c upgrade path | manifest format_version gate + v1→v2 upgrade |
| af37079 stale manifest stats + 2e0d3a4-F5 no-silent-default | manifest v2 per-segment point_count, derived total |
| 2291ecc recovery re-derives from replayed WAL tail | strict-OoO watermarks seeded from recovered memtable |
| close-durability cluster (0a0f9f0/557a62d) | final WAL fsync in Engine.deinit |

## Operational note: no downgrade after upgrade

Once a binary at this version saves, the store carries a manifest v2
(33-byte segment entries). Previously released binaries have no
version gate and no length gate; the manifest CRC covers the body
regardless of stride, so an old binary silently misparses a v2
manifest: with 1 segment it opens cleanly and its next save silently
rewrites v1 (dropping per-segment counts); with ≥2 segments it reads
25-byte strides over 33-byte entries and derives garbage segment ids
— under the default fail-closed verification that is a confusing
open failure, and under `wal_recovery = .salvage` it prunes every
"missing" segment and clobbers the store on the next save.

Therefore: do NOT run a pre-v2 binary against a data dir that a v2
binary has saved. Take a backup before upgrading if a rollback path
is required.

## Audited — no action needed (with reasons)

- **Buffer-pool fixes** (dirty-eviction race e8b784a, lock-free pin
  0e5a2a0, pin deadlock/lost-wakeup ad34882, O(1) CLOCK b2d0951,
  lazy anon-mmap backing df33faa, pool re-create hardening 4a5beb4):
  this engine has NO buffer pool. Reads copy decoded blocks into a
  per-query arena; the only shared cache is the SegmentReaderCache
  (FD/reader LRU), which is refcounted and mutex-guarded with
  deferred close for borrowed entries.
- **Pager checked arithmetic** (2dcc678 mechanism): no pager. Segment
  block iteration computes `offset = data_offset + data_len` in
  u64+u32 (cannot wrap); corrupt lengths yield short positional reads
  → `error.UnexpectedEOF`; `data_len` is capped at
  `MAX_BLOCK_DATA_LEN` before any allocation. The *class* was still
  found (and fixed) at two decode sites — see the fixed table.
- **Iterator/scan races** (LabelIndex scan-vs-add 27a6ef0, DESC
  cursor OOB a6d5a13): `queryPoints` copies memtable points out
  under the shard mutex and decodes segment blocks into an arena at
  call time; the returned iterator owns all its data. Segments
  compacted away mid-query are protected by reader-cache refcounts.
  No live-structure iteration exists to race.
- **WAL under-logging** (1c72e46, 6420221): every unsealed-data
  mutation (`appendPoints`) is WAL-logged before apply. Flush,
  compaction, and retention mutate only sealed state whose source of
  truth is the manifest, which is fsync'd atomically (tmp+rename,
  dual-slot) BEFORE the WAL is truncated. There is no delete/update
  path that could under-log. Verified ordering:
  segment fsync → manifest publish → WAL truncate.
- **Free-space map trusts checkpoint-era bitmap** (d05942d): no
  free-space map. Segment files are immutable and append-created;
  ids are allocated from `next_segment_id`, which only advances at
  publish time and is persisted in the same fsync'd manifest write.
- **Derived-index durability "Path B"** (be40df5, 605e266, 8d27f60,
  f6a325d, 557a62d): the only persisted derived structure is the
  segment footer sparse index, which lives INSIDE the immutable
  fsync'd segment file (CRC-protected, falls back to a full block
  scan when absent/corrupt). It cannot drift from primary data
  across a crash, so no epoch/covered-LSN reload contract is needed.
- **Counter re-derivation for id allocators** (2291ecc/84ea73c
  mechanism): `next_segment_id` advances only at flush/compaction
  publish and travels in the same atomic manifest write as the
  segment list — a replayed WAL tail never allocates segment ids, so
  the manifest value cannot be stale relative to the tail. (The
  watermark leg of 2291ecc DID transfer — see fixed table.)
- **Slab packing** (prop/var/adjacency/edge-prop trains): the analog
  amplification here is one block header (92 B plaintext / 120 B
  encrypted) per series per flush for wide-cardinality sparse
  workloads. Gorilla blocks already pack points; L0→L1 compaction
  re-chunks to ~256-point blocks and amortizes the header. A
  flush-time coalescer would only help pre-compaction L0 reads —
  noted as potential future work, not a defect.
- **Early-ready / lazy / parallel open** (211586b, 4ecc1d7, a6ba76e):
  open cost is already O(num_segments) 8-byte magic probes +
  O(WAL tail) replay. Footers, reader FDs, and caches are lazy.
  Nothing eager to defer; no shards to parallelize.
