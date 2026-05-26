# Benchmarks

This directory contains the benchmark suite for timeseries-storage.
The framework is library-agnostic — copy `framework.zig` and
`compare.zig` into any other project and the rest of this README still
applies.

## Layout

| File | Purpose |
| --- | --- |
| `framework.zig` | Iteration loop, statistics, JSON emit, RSS + alloc tracking. No dependency on the project library. |
| `bench.zig` | Default suite invoked by `zig build bench`. Replace the placeholder scenarios with real workloads. |
| `scale.zig` | Larger / longer-running grid invoked by `zig build scale-bench`. Gated to schedule/manual in CI. |
| `compare.zig` | Diffs two result documents and exits non-zero on regression. Used by `zig build compare-bench` and the CI gate. |
| `micro/` | One file per narrowly-scoped micro-benchmark. Each is a standalone exe wired in `build.zig`. |
| `results/` | JSON output. `baseline.json` is committed; `latest.json` and friends are gitignored. |

## Quick start

```bash
zig build bench                                  # run the default suite
zig build bench -- --output results/latest.json  # save to disk
zig build bench -- --filter init                 # subset by substring
zig build bench -- --list                        # list registered scenarios
zig build bench -- --warmup 3 --samples 10       # override iterations
zig build bench -- --no-track                    # skip alloc tracking

zig build compare-bench -- \
    --baseline benchmarks/results/baseline.json \
    --current benchmarks/results/latest.json
```

Make targets wrap the same commands:

```bash
make bench            # writes benchmarks/results/latest.json
make bench-compare    # diff latest.json against baseline.json
make bench-micro      # all micro-benchmarks
make scale-bench      # larger grid
```

## Adding a new scenario

1. Open `benchmarks/bench.zig` (or write a new `benchmarks/<file>.zig`
   for an isolated suite).
2. Define a body function with the framework's signature:

   ```zig
   fn benchMyThing(ctx: *framework.Context) anyerror!void {
       var i: u64 = 0;
       while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
           // ... do one unit of work, e.g. call a public library function ...
           std.mem.doNotOptimizeAway(result);
       }
   }
   ```

   `std.mem.doNotOptimizeAway` is important when the body's result is
   discarded — without it the optimizer may delete the call entirely
   and your timings drop to "memory access" rather than "real work".

3. Add a `framework.Scenario` entry to the `scenarios` array:

   ```zig
   .{
       .name = "my_thing",
       .ops_per_iteration = 100_000,
       .warmup_iterations = 1,
       .sample_iterations = 6,
       .run = benchMyThing,
   },
   ```

4. Run `zig build bench -- --filter my_thing` to iterate locally.

## Adding a new micro-benchmark

1. Copy `benchmarks/micro/example.zig` to `benchmarks/micro/<name>.zig`.
2. Replace the scenario body and name.
3. In `build.zig`, register a new exe + step modeled on the existing
   `micro_example_exe` block, and add it to `micro_all_step.dependOn(...)`.

## Result schema

Every run emits a `ResultDocument`:

```jsonc
{
  "generated_at_unix_s": 1777123451,
  "rows": [
    {
      "git_sha": "...",
      "run_timestamp_unix_s": 1777123451,
      "zig_version": "0.16.0",
      "os": "linux", "arch": "x86_64", "cpu": "broadwell",
      "scenario_name": "init_default_config",
      "ops_per_iteration": 10000,
      "sample_count": 6,
      "wall_ns_min": 38, "wall_ns_p50": 38,
      "wall_ns_p95": 40, "wall_ns_p99": 40, "wall_ns_max": 42,
      "wall_ns_stddev": 1.87,
      "throughput_ops_per_sec": 263157894736.84,
      "throughput_stddev_ops_per_sec": 11879938094.87,
      "alloc_count": 0, "alloc_bytes": 0, "peak_live_bytes": 0,
      "rss_current_bytes": 1241088, "rss_peak_bytes": 1241088
    }
  ]
}
```

Stable fields. Adding new fields is backwards-compatible (the comparer
uses `.ignore_unknown_fields = true` when parsing).

## Methodology

* Every scenario runs `warmup_iterations + sample_iterations` times.
* Warmup runs are discarded.
* Sampled wall times are sorted; median is reported alongside p95, p99,
  min, max, and stddev.
* Throughput = `ops_per_iteration / wall_seconds` per sample, then
  median + stddev across samples.
* Allocation totals are averaged across sampled iterations.
* RSS is read once per scenario after the run loop completes (Linux
  only — zero on macOS / Windows).

## Regression gating

`compare-bench` matches rows by `scenario_name` and computes percent
change in throughput against the baseline. A regression fires when
`-throughput_change` exceeds the noise gate, defined as
`max(--floor (default 15%), 3 * baseline_stddev_pct)`.

The CI job `benchmark-regression` runs the suite on the default branch
and on schedule and writes `benchmarks/results/ci-current.json` as an
artifact. It only enforces the gate when `benchmarks/results/baseline.json`
exists; until then it logs and passes. Drop `allow_failure: true` from
the job once the baseline is established.

To refresh the baseline locally:

```bash
make bench
cp benchmarks/results/latest.json benchmarks/results/baseline.json
git add benchmarks/results/baseline.json
git commit -m "perf(bench): refresh baseline after <change>"
```
