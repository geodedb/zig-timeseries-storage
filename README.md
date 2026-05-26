# timeseries-storage

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0+-orange.svg)](https://ziglang.org/)

An embedded LSM-style time-series storage engine written in Zig. Points
are first written to a crash-safe WAL and an in-memory memtable, then
flushed to immutable on-disk segment files; background compaction merges
level-0 segments into larger level-1 segments to keep read amplification
bounded. Per-block payloads are encoded with Gorilla (delta-of-delta on
timestamps, XOR on values) for compact storage and fast scans.

## Features

- **Library + CLI**: ships as both a Zig module and a standalone binary
- **Crash-safe WAL** with CRC32C-protected records and per-flush checkpoints
- **Gorilla-encoded segments** (delta-of-delta + XOR) for compact storage
- **Background flush and compaction** on a shared thread pool
- **Cross-platform**: Linux, macOS, Windows
- **Well tested**: unit, integration, and stress test suites

## Dependencies

This engine builds on three small Zig libraries pinned in
`build.zig.zon`; they are fetched automatically by the Zig package
manager during the first build.

| Dependency | Role |
| ---------- | ---- |
| [`wal`](https://gitlab.com/devnw/zig/wal) | Append-only write-ahead log with CRC-protected framing, used as the durability primitive for every mutation. |
| [`uuid`](https://gitlab.com/devnw/zig/uuid) | Generates the per-store time-series UUID stamped into the manifest so WAL segments cannot be cross-mounted between stores. |
| [`thread_pool`](https://gitlab.com/devnw/zig/thread-pool) | Bounded worker pool that runs background flush and compaction jobs without blocking the appender thread. |

## Installation

### Using the Zig package manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .timeseries_storage = .{
        .url = "https://gitlab.com/devnw/zig/timeseries-storage/-/archive/v0.1.0/timeseries-storage-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const timeseries_storage = b.dependency("timeseries_storage", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("timeseries_storage", timeseries_storage.module("timeseries_storage"));
```

## Quick Start

```zig
const std = @import("std");
const timeseries_storage = @import("timeseries_storage");
const thread_pool = @import("thread_pool");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The engine submits background flush and compaction work to a
    // caller-owned thread pool so the appender thread is never blocked
    // by I/O. Sharing one pool across multiple engines is fine.
    var pool = try thread_pool.ThreadPool.init(allocator, .{ .max_threads = 2 });
    defer pool.deinit();

    var engine = try timeseries_storage.engine.Engine.init(
        allocator,
        .{ .data_dir = "/var/lib/myapp/ts", .max_memtable_points = 100_000 },
        &pool,
    );
    defer engine.deinit();

    const series_id: timeseries_storage.types.SeriesId = 0x0000_0000_0000_0000_0000_0000_0000_0001;
    const points = [_]timeseries_storage.types.Point{
        .{ .ts = 1_700_000_000_000, .value = 42 },
        .{ .ts = 1_700_000_000_100, .value = 43 },
    };
    try engine.appendPoints(series_id, &points);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = try engine.queryPoints(arena.allocator(), series_id, 1_700_000_000_000, 1_700_000_001_000);
    while (it.next()) |pt| {
        std.debug.print("{d} -> {d}\n", .{ pt.ts, pt.value });
    }
}
```

Build and run the CLI directly from the repo:

```bash
zig build run -- <args...>
```

## Requirements

- Zig 0.16.0 or later

## Building

```bash
make build         # library + CLI
make test          # unit + integration + stress
make example       # run examples/basic.zig
make run           # run the CLI
make dev           # quick fmt + check + unit tests
make ci            # full clean rebuild + test-all
```

`zig build -Dno-cli=true` produces a library-only build. `zig build
-Dtsan` rebuilds tests under ThreadSanitizer.

## Benchmarks

```bash
make bench           # default suite -> benchmarks/results/latest.json
make bench-compare   # diff against benchmarks/results/baseline.json
make bench-micro     # micro-benchmarks
make scale-bench     # larger grid
```

The benchmark framework lives in `benchmarks/framework.zig` and is
library-agnostic. See [`benchmarks/README.md`](benchmarks/README.md)
for the JSON schema, how to register a new scenario, and how the CI
regression gate is wired.

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability
reporting.

## License

This project is licensed under the Apache License 2.0 - see the
[LICENSE](LICENSE) file for details.
