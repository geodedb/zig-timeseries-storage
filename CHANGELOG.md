# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial project structure
- Core library implementation
- Unit and integration tests
- CI/CD pipeline
- Documentation

## [0.2.23] - 2026-11-15

### Fixed

- The batch-mode WAL syncer no longer fdatasyncs an unchanged `ts.wal`
  every `wal_sync_interval_ms` (about ten times a second at the default
  100 ms) (SONNY-6634). `WalManager.sync()` now skips the fdatasync when
  nothing was appended since the last successful one; the first sync
  after open still runs, and a failed sync is retried on the next tick.

### Added

- `WalManager.syncCount()`: the number of fdatasyncs issued against
  `ts.wal`.

## [0.2.22] - 2026-11-15

### Fixed

- `Engine` no longer leaks a descriptor on its data directory
  (SONNY-6623). `Engine.init` opened `data_dir` for the WAL and the wal
  library only borrows it; `Engine.deinit` now closes it after the WAL is
  torn down, and `Engine.init` closes it if it fails after the open.
  Embedders that closed `eng.wal.inner.dir` themselves must stop doing so.
- A WAL compaction that the wal library refuses after a flush
  (`WalEncryptionMismatch` / `WalAuthFailed` / `WalCorrupted`) is no longer
  reported as a flush background error or through `error_callback`
  (SONNY-6622). The flush is durable and the WAL file is unchanged and
  stays usable. The refusal is logged and counted.

### Added

- `StatsSnapshot.wal_compactions_refused` (default `0`): post-flush WAL
  compactions the wal library refused.

### Changed

- wal v0.1.24 (SONNY-6620). Its recovery and compaction fail closed with
  `WalEncryptionMismatch`, `WalAuthFailed` and `WalCorrupted` and leave the
  file untouched, and it adds opt-in `salvage_corrupt_records`. The
  pre-open check added in 0.2.21 (`src/wal_precheck.zig`) is removed in
  favour of the library's; behaviour, error names and
  `WalConfig.salvage_corrupt_records` are unchanged. `WalError` now unions
  `wal.RecoveryError`.
- thread_pool v0.2.11, the revision wal v0.1.24 and geode pin.

## [0.2.21] - 2026-11-15

### Fixed

- `Engine.init` no longer truncates `ts.wal` when it cannot read it
  (SONNY-6615). A plaintext WAL opened with an encryption key, an encrypted
  WAL opened without one, or an encrypted WAL opened with the wrong key
  used to be truncated to zero bytes, losing every point not yet flushed.
  The WAL is now checked read-only before the wal library opens it, and a
  failed open leaves the file byte-for-byte intact.
- A corrupt record in the middle of the WAL no longer silently drops the
  valid records after it. The default `wal_recovery = .fail_closed` refuses
  to open; `.salvage` cuts the log at the bad record, but only when a valid
  record precedes it.
- A genuine torn tail is still truncated, from the first bad record onward
  only.

### Added

- New `WalError` (and so `EngineError`) members:
  - `WalEncryptionMismatch`: the WAL was written in the other key mode.
  - `WalAuthFailed`: no WAL record authenticates under the configured key.
  - `WalCorrupted`: a corrupt record has valid records after it.
- `WalConfig.salvage_corrupt_records` (default `false`); the engine sets it
  from `wal_recovery = .salvage`.

### Changed

- Includes v0.2.19 (thread_pool v0.2.10) and v0.2.20 (wal v0.1.23), which
  were tagged from a release branch and had not been merged to `main`.

## [0.2.20] - 2026-11-12

### Changed

- Converge wal v0.1.23, which keeps the LSN anchor when compaction empties
  the log (SONNY-6424). Geode, graph-storage and raft pin the same wal
  revision.

## [0.2.19] - 2026-11-12

### Changed

- Converge thread_pool v0.2.10, which fixes data races in the pool's
  work-stealing queues (SONNY-6375). Geode shares `*ThreadPool` with this
  library, so both must pin the same thread_pool revision.

## [0.2.13] - 2026-09-15

### Changed

- Converge grpc_zig v0.1.10 (GAP-0838 diamond sync).

## [0.2.12] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5, config v0.1.13 (GAP-0838 diamond sync).

## [0.2.11] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.1.0] - YYYY-MM-DD

### Added

- Initial release
- Basic functionality
- Documentation and examples

[Unreleased]: https://gitlab.com/devnw/zig/timeseries_storage/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/timeseries_storage/-/releases/v0.1.0
