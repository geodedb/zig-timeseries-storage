# Requirements Directory

This document serves as a flatfile mirror of all requirements and gaps identified in the
timeseries-storage library, mapped to their corresponding authoritative GitLab tracking issues.

This file is a mirror of the platform issue tracker. The tracker is authoritative.

## Gap-Closure Session Status (2026-05-26)

32 commits were merged in the gap-closure session. See
[GAP_ANALYSIS_RESOLVED.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS_RESOLVED.md)
for fully-closed items (GAP-0003 through GAP-0008, GAP-0011).

---

## Open / Partial / Deferred Requirements

### High Priority

| Requirement ID | Summary | Status | GitLab Issue |
| -------------- | ------- | ------ | ------------ |
| **GAP-0001** | Transparent Data Encryption (TDE) for all data-at-rest | **Partial** -- WAL wired (`38a944b`); segments + manifest still plaintext | [#1](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/1) |
| **GAP-0010** | Cross-segment out-of-order writes must persist to the correct historical segment | **Deferred** -- XL design work; ADR needed | No GitLab issue yet -- token write access required |

### Medium Priority

| Requirement ID | Summary | Status | GitLab Issue |
| -------------- | ------- | ------ | ------------ |
| **GAP-0002** | Secure, tenant-scoped Series ID mapping catalog | **Deferred** -- API-breaking; blocked on Geode coordination | [#2](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/2) |
| **GAP-0009** | v1 -> v2 segment format migration path | **Partial** -- format bumped to `TSSEG002` (`088b2f1`); migration tool still needed | No GitLab issue yet -- token write access required |

---

## Closed Requirements

These were fully closed in the gap-closure session. GitLab issues should be closed manually
(token write access unavailable during closure session).

| Requirement ID | Summary | Closing Commit | GitLab Issue |
| -------------- | ------- | -------------- | ------------ |
| **GAP-0003** | Consistent Snapshots and Integrated Backup/Restore | `fe5bf9e` | [#3](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/3) |
| **GAP-0004** | Data Retention and Segment Pruning Engine | `28bac58` | [#4](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/4) |
| **GAP-0005** | Strict fail-closed recovery on WAL corruption | `73926b5` | [#5](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/5) |
| **GAP-0006** | Segment file existence/integrity verification on engine startup | `fe89463` | [#6](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/6) |
| **GAP-0007** | Comprehensive integration and stress testing suites | `6dfd585` | [#7](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/7) |
| **GAP-0008** | Standalone operational CLI commands and comprehensive examples | `be44f61` | [#8](https://gitlab.com/devnw/zig/timeseries-storage/-/issues/8) |
| **GAP-0011** | Benchmark harness bodies + CI regression gate | `69c68eb` | No issue yet -- create and close once token restored |

---

*This document is dynamically updated as new requirements are extracted and tracked. For detailed
evidence and current implementation state, see
[GAP_ANALYSIS.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS.md).
For verified-implemented spec items and resolved gaps, see
[GAP_ANALYSIS_RESOLVED.md](file:///home/benji/src/devnw/zig/timeseries-storage/docs/GAP_ANALYSIS_RESOLVED.md).*
