// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");

fn importedModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    thread_pool_module: *std.Build.Module,
    crypto_backend_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "timeseries_storage", .module = module },
            .{ .name = "thread_pool", .module = thread_pool_module },
            .{ .name = "crypto_backend", .module = crypto_backend_mod },
        },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // ------------------------------------------------------------------
    // Optimize-mode policy (P-BUILD-001).
    //
    // `standardOptimizeOption` defaults to `.Debug` and lets callers
    // override via `-Doptimize=ReleaseFast` (etc.). We intentionally
    // KEEP Debug as the default because:
    //
    //   * `zig build test` is the correctness gate. Debug enables
    //     runtime bounds checks, unreachable-code traps, and panic
    //     paths that surface UB the optimiser would silently fold
    //     away. Tests run fast enough (well under 1s in unit; <10s
    //     even with stress) that ReleaseFast offers no usability
    //     win and would mask real bugs.
    //   * `zig build` (library + CLI) honours the user override; CI
    //     can ship ReleaseSafe / ReleaseFast as policy without code
    //     changes.
    //   * `zig build bench` / `zig build scale-bench` etc. FORCE
    //     `.ReleaseFast` inside `benchModule` regardless of the
    //     top-level `-Doptimize` choice — bench numbers must be
    //     comparable across casual invocations.
    //   * `zig build test-stress` overrides to ReleaseFast when TSan
    //     is OFF (see below) — stress only proves throughput when
    //     the optimiser is on. With `-Dtsan=true` we drop back to
    //     Debug so the sanitizer can see real races instead of
    //     having them optimised away.
    //
    // Callers can override the unit-test optimize mode via
    // `zig build test -Doptimize=ReleaseSafe` if they want a faster
    // run; the framework supports it and CI matrices use it.
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer on test artifacts") orelse false;
    const no_cli = b.option(bool, "no-cli", "Skip building the CLI executable (library-only build)") orelse false;

    // -------------------------------------------------------------------------
    // FIPS-140-3 seam (GAP-0020-safe: exactly ONE build_options instance for
    // THIS repo's fips flag — the wal/uuid/thread_pool deps carry their OWN
    // private build_options, resolved separately as dependency modules).
    // Off by default with zero overhead; -Dfips=true routes security crypto
    // through the linked OpenSSL FIPS provider via the lazy `fips` dep.
    // -------------------------------------------------------------------------
    const fips = b.option(bool, "fips", "Route security crypto through the linked FIPS-140-3 provider (off by default; zero overhead when off)") orelse false;
    const openssl_path = b.option([]const u8, "openssl_path", "OpenSSL install prefix for non-standard installs (e.g. /usr/local/ssl)");
    const link = @import("src/link.zig");

    const build_options = b.addOptions();
    build_options.addOption(bool, "fips", fips);
    build_options.addOption([]const u8, "package_name", "timeseries-storage");
    const build_options_mod = build_options.createModule();

    const crypto_backend_mod = b.addModule("crypto_backend", .{
        .root_source_file = b.path("src/crypto_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options_mod }},
    });
    const std_shim_mod = b.addModule("std_shim", .{
        .root_source_file = b.path("src/std_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_backend_mod.addImport("std_shim", std_shim_mod);
    if (fips) {
        if (b.lazyDependency("fips", .{ .target = target, .optimize = optimize, .openssl_path = openssl_path orelse "/usr/local/ssl" })) |fips_dep| {
            const fips_mod = fips_dep.module("fips");
            crypto_backend_mod.addImport("fips", fips_mod);
            link.linkOpenssl(b, fips_mod, openssl_path);
        }
    }

    // ------------------------------------------------------------------
    // Library module — primary public surface for downstream consumers.
    // ------------------------------------------------------------------
    const wal = b.dependency("wal", .{
        .target = target,
        .optimize = optimize,
    }).module("wal");

    const uuid = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    }).module("uuid");

    const thread_pool = b.dependency("thread_pool", .{
        .target = target,
        .optimize = optimize,
    }).module("thread_pool");

    const module = b.addModule("timeseries_storage", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wal", .module = wal },
            .{ .name = "uuid", .module = uuid },
            .{ .name = "thread_pool", .module = thread_pool },
            .{ .name = "crypto_backend", .module = crypto_backend_mod },
        },
    });

    const static_lib = b.addLibrary(.{
        .name = "timeseries-storage",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(static_lib);

    const build_step = b.step("build", "Build the standalone library and CLI");
    build_step.dependOn(&static_lib.step);

    // ------------------------------------------------------------------
    // CLI executable — links against the library module.
    // Disable with `-Dno-cli` for pure-library builds.
    // ------------------------------------------------------------------
    if (!no_cli) {
        const cli_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "timeseries_storage", .module = module },
                .{ .name = "thread_pool", .module = thread_pool },
                .{ .name = "crypto_backend", .module = crypto_backend_mod },
            },
        });
        const cli_exe = b.addExecutable(.{
            .name = "timeseries-storage",
            .root_module = cli_module,
        });
        b.installArtifact(cli_exe);
        build_step.dependOn(&cli_exe.step);

        const run_cli = b.addRunArtifact(cli_exe);
        if (b.args) |args| run_cli.addArgs(args);
        const run_step = b.step("run", "Run the CLI (forwards trailing args after `--`)");
        run_step.dependOn(&run_cli.step);

        // CLI parser / argument tests — run with `zig build test-cli`.
        // These are pure parser tests (no engine I/O) so we keep them
        // off the default unit suite to avoid pulling main.zig into
        // every `zig build test` invocation.
        const cli_tests = b.addTest(.{ .root_module = cli_module });
        cli_tests.root_module.link_libc = true;
        const cli_test_step = b.step("test-cli", "Run CLI argument-parser tests");
        cli_test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    }

    // ------------------------------------------------------------------
    // Check step — fast IDE feedback. Compiles unit tests without
    // running them.
    // ------------------------------------------------------------------
    const check_step = b.step("check", "Compile the library and tests without running them");
    const check_tests = b.addTest(.{
        .root_module = module,
    });
    check_tests.root_module.link_libc = true;
    check_step.dependOn(&check_tests.step);

    // ------------------------------------------------------------------
    // Test suites.
    // ------------------------------------------------------------------
    const unit_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = module,
    });
    unit_tests.root_module.link_libc = true;
    if (tsan) unit_tests.root_module.sanitize_thread = true;
    unit_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/integration.zig", target, optimize, module, thread_pool, crypto_backend_mod),
    });
    integration_tests.root_module.link_libc = true;
    if (tsan) integration_tests.root_module.sanitize_thread = true;
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // Stress runs Debug under TSan so races aren't optimised away.
    const stress_optimize: std.builtin.OptimizeMode = if (tsan) .Debug else .ReleaseFast;
    const stress_step = b.step("test-stress", "Run stress and load tests");
    const stress_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/stress.zig", target, stress_optimize, module, thread_pool, crypto_backend_mod),
    });
    stress_tests.root_module.link_libc = true;
    if (tsan) stress_tests.root_module.sanitize_thread = true;
    stress_step.dependOn(&b.addRunArtifact(stress_tests).step);

    // Engine end-to-end tests (large input volumes; lifted out of the
    // default unit suite so `zig build test` stays fast).
    const e2e_step = b.step("test-engine-e2e", "Run engine end-to-end tests");
    const e2e_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/engine_e2e.zig", target, optimize, module, thread_pool, crypto_backend_mod),
    });
    e2e_tests.root_module.link_libc = true;
    if (tsan) e2e_tests.root_module.sanitize_thread = true;
    e2e_step.dependOn(&b.addRunArtifact(e2e_tests).step);

    // WAL recovery regression tests — exercise the strict and salvage
    // policies under `Engine.init`. Closes GAP-0005 / SEC-002 / SEC-003.
    const wal_recovery_step = b.step("test-wal-recovery", "Run WAL recovery regression tests");
    const wal_recovery_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/wal_recovery.zig", target, optimize, module, thread_pool, crypto_backend_mod),
    });
    wal_recovery_tests.root_module.link_libc = true;
    if (tsan) wal_recovery_tests.root_module.sanitize_thread = true;
    wal_recovery_step.dependOn(&b.addRunArtifact(wal_recovery_tests).step);

    const all_tests_step = b.step("test-all", "Run unit, integration, stress, and e2e suites");
    all_tests_step.dependOn(&b.addRunArtifact(unit_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(integration_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(stress_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(e2e_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(wal_recovery_tests).step);

    // ------------------------------------------------------------------
    // Example — demonstrates library usage end-to-end.
    // ------------------------------------------------------------------
    const example_step = b.step("example", "Build and run the basic example");
    const example_exe = b.addExecutable(.{
        .name = "timeseries-storage-basic",
        .root_module = importedModule(b, "examples/basic.zig", target, optimize, module, thread_pool, crypto_backend_mod),
    });
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

    // ------------------------------------------------------------------
    // Benchmarks — see benchmarks/README.md.
    //
    // The benchmark framework (benchmarks/framework.zig) is library-
    // agnostic and depends only on the Zig stdlib. We expose it as its
    // own module so any bench source — including files in subdirectories
    // like benchmarks/micro/ — can `@import("framework")` it. Each suite
    // is then a standalone exe whose root module imports both the
    // framework and the project library. ReleaseFast is forced for all
    // benchmark exes so casual `zig build bench` invocations still
    // produce comparable numbers regardless of the top-level optimize
    // option.
    // ------------------------------------------------------------------

    const framework_module = b.addModule("framework", .{
        .root_source_file = b.path("benchmarks/framework.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_exe = b.addExecutable(.{
        .name = "timeseries-storage-bench",
        .root_module = benchModule(b, "benchmarks/bench.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the default benchmark suite");
    bench_step.dependOn(&run_bench.step);

    const scale_bench_exe = b.addExecutable(.{
        .name = "timeseries-storage-scale-bench",
        .root_module = benchModule(b, "benchmarks/scale.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    b.installArtifact(scale_bench_exe);
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| run_scale_bench.addArgs(args);
    const scale_bench_step = b.step("scale-bench", "Run the larger / longer benchmark grid");
    scale_bench_step.dependOn(&run_scale_bench.step);

    const compare_bench_exe = b.addExecutable(.{
        .name = "timeseries-storage-compare-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "framework", .module = framework_module },
            },
        }),
    });
    b.installArtifact(compare_bench_exe);
    const run_compare = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| run_compare.addArgs(args);
    const compare_step = b.step("compare-bench", "Diff two benchmark result files and gate on regressions");
    compare_step.dependOn(&run_compare.step);

    const micro_example_exe = b.addExecutable(.{
        .name = "timeseries-storage-micro-example",
        .root_module = benchModule(b, "benchmarks/micro/example.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_micro_example = b.addRunArtifact(micro_example_exe);
    if (b.args) |args| run_micro_example.addArgs(args);
    const micro_example_step = b.step("bench-micro-example", "Example micro-benchmark");
    micro_example_step.dependOn(&run_micro_example.step);

    // codec
    const micro_codec_exe = b.addExecutable(.{
        .name = "timeseries-storage-micro-codec",
        .root_module = benchModule(b, "benchmarks/micro/codec.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_micro_codec = b.addRunArtifact(micro_codec_exe);
    if (b.args) |args| run_micro_codec.addArgs(args);
    const micro_codec_step = b.step("bench-micro-codec", "Gorilla encode/decode micros");
    micro_codec_step.dependOn(&run_micro_codec.step);

    // segment read/write
    const micro_segment_rw_exe = b.addExecutable(.{
        .name = "timeseries-storage-micro-segment-rw",
        .root_module = benchModule(b, "benchmarks/micro/segment_rw.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_micro_segment_rw = b.addRunArtifact(micro_segment_rw_exe);
    if (b.args) |args| run_micro_segment_rw.addArgs(args);
    const micro_segment_rw_step = b.step("bench-micro-segment-rw", "Segment write/read block micros");
    micro_segment_rw_step.dependOn(&run_micro_segment_rw.step);

    // merge iterator
    const micro_merge_exe = b.addExecutable(.{
        .name = "timeseries-storage-micro-merge",
        .root_module = benchModule(b, "benchmarks/micro/merge.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_micro_merge = b.addRunArtifact(micro_merge_exe);
    if (b.args) |args| run_micro_merge.addArgs(args);
    const micro_merge_step = b.step("bench-micro-merge", "k-way merge iterator micros");
    micro_merge_step.dependOn(&run_micro_merge.step);

    // WAL I/O
    const micro_wal_exe = b.addExecutable(.{
        .name = "timeseries-storage-micro-wal",
        .root_module = benchModule(b, "benchmarks/micro/wal_io.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_micro_wal = b.addRunArtifact(micro_wal_exe);
    if (b.args) |args| run_micro_wal.addArgs(args);
    const micro_wal_step = b.step("bench-micro-wal", "WAL append micro");
    micro_wal_step.dependOn(&run_micro_wal.step);

    // Manifest I/O
    const micro_manifest_exe = b.addExecutable(.{
        .name = "timeseries-storage-micro-manifest",
        .root_module = benchModule(b, "benchmarks/micro/manifest_io.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_micro_manifest = b.addRunArtifact(micro_manifest_exe);
    if (b.args) |args| run_micro_manifest.addArgs(args);
    const micro_manifest_step = b.step("bench-micro-manifest", "Manifest write/read micro");
    micro_manifest_step.dependOn(&run_micro_manifest.step);

    // Memtable
    const micro_memtable_exe = b.addExecutable(.{
        .name = "timeseries-storage-micro-memtable",
        .root_module = benchModule(b, "benchmarks/micro/memtable.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_micro_memtable = b.addRunArtifact(micro_memtable_exe);
    if (b.args) |args| run_micro_memtable.addArgs(args);
    const micro_memtable_step = b.step("bench-micro-memtable", "Memtable insert (sorted/ooo) micros");
    micro_memtable_step.dependOn(&run_micro_memtable.step);

    // Integration benches (concurrent, ooo, recovery)
    const bench_integration_exe = b.addExecutable(.{
        .name = "timeseries-storage-bench-integration",
        .root_module = benchModule(b, "benchmarks/bench_integration.zig", target, module, framework_module, thread_pool, crypto_backend_mod),
    });
    const run_bench_integration = b.addRunArtifact(bench_integration_exe);
    if (b.args) |args| run_bench_integration.addArgs(args);
    const bench_integration_step = b.step("bench-integration", "Integration benches: concurrent, ooo, recovery");
    bench_integration_step.dependOn(&run_bench_integration.step);

    const micro_all_step = b.step("bench-micro", "Run all micro-benchmarks");
    micro_all_step.dependOn(&run_micro_example.step);
    micro_all_step.dependOn(&run_micro_codec.step);
    micro_all_step.dependOn(&run_micro_segment_rw.step);
    micro_all_step.dependOn(&run_micro_merge.step);
    micro_all_step.dependOn(&run_micro_wal.step);
    micro_all_step.dependOn(&run_micro_manifest.step);
    micro_all_step.dependOn(&run_micro_memtable.step);

    // bench-ci: fast CI bench = bench + bench-micro
    const bench_ci_step = b.step("bench-ci", "Fast CI bench: bench + bench-micro");
    bench_ci_step.dependOn(&run_bench.step);
    bench_ci_step.dependOn(&run_micro_example.step);
    bench_ci_step.dependOn(&run_micro_codec.step);
    bench_ci_step.dependOn(&run_micro_segment_rw.step);
    bench_ci_step.dependOn(&run_micro_merge.step);
    bench_ci_step.dependOn(&run_micro_wal.step);
    bench_ci_step.dependOn(&run_micro_manifest.step);
    bench_ci_step.dependOn(&run_micro_memtable.step);

    // bench-smoke: cross-platform liveness. Caller passes `-- --samples 1 --quiet`.
    const bench_smoke_step = b.step("bench-smoke", "Cross-platform liveness smoke (pass --samples 1)");
    bench_smoke_step.dependOn(bench_ci_step);

    // bench-ab: orchestrator script
    const bench_ab_run = b.addSystemCommand(&.{ "bash", "benchmarks/scripts/bench_ab.sh" });
    if (b.args) |args| bench_ab_run.addArgs(args);
    const bench_ab_step = b.step("bench-ab", "Run A/B bench between two refs");
    bench_ab_step.dependOn(&bench_ab_run.step);

    const tools_step = b.step("tools", "Build benchmark tooling artifacts");
    tools_step.dependOn(&bench_exe.step);
    tools_step.dependOn(&scale_bench_exe.step);
    tools_step.dependOn(&compare_bench_exe.step);
    tools_step.dependOn(&micro_example_exe.step);
    tools_step.dependOn(&micro_codec_exe.step);
    tools_step.dependOn(&micro_segment_rw_exe.step);
    tools_step.dependOn(&micro_merge_exe.step);
    tools_step.dependOn(&micro_wal_exe.step);
    tools_step.dependOn(&micro_manifest_exe.step);
    tools_step.dependOn(&micro_memtable_exe.step);
    tools_step.dependOn(&bench_integration_exe.step);
}

fn benchModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    lib_module: *std.Build.Module,
    framework_module: *std.Build.Module,
    thread_pool_module: *std.Build.Module,
    crypto_backend_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "timeseries_storage", .module = lib_module },
            .{ .name = "framework", .module = framework_module },
            .{ .name = "thread_pool", .module = thread_pool_module },
            .{ .name = "crypto_backend", .module = crypto_backend_mod },
        },
    });
}
