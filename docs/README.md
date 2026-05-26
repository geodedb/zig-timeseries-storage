# timeseries-storage Documentation

## Overview

An embedded LSM-style time-series storage engine: WAL-backed appends,
in-memory memtable, immutable Gorilla-encoded segment files on disk,
and background level-0 to level-1 compaction. See the [top-level
README](../README.md) for the API surface and a Quick Start example.

## Table of Contents

- [On-disk format & engine spec](ts-storage-spec.md) — segment layout, WAL
  record framing, manifest contract, Gorilla encoding parameters.
- [Requirements](REQUIREMENTS.md) — durability, throughput, and
  correctness requirements the engine targets.
- [Gap analysis (open)](GAP_ANALYSIS.md) — currently tracked gaps and
  their acceptance criteria.
- [Gap analysis (resolved)](GAP_ANALYSIS_RESOLVED.md) — closed gaps and
  the commits that resolved them.
- [Performance gap analysis](PERF_GAP_ANALYSIS.md) — perf-track gaps.
- [Quality gap analysis](QUALITY_GAP_ANALYSIS.md) — code-quality-track
  gaps.
- [Security gap analysis](SECURITY_GAP_ANALYSIS.md) — security-track
  gaps.

## Quick Links

- [Installation](../README.md#installation)
- [Contributing](../CONTRIBUTING.md)
- [Security](../SECURITY.md)
- [Changelog](../CHANGELOG.md)
