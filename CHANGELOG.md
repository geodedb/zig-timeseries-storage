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
