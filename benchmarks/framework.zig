// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Library-agnostic benchmark framework — public re-export module.
//!
//! Define a list of `Scenario` records and call `runScenarios`. The
//! framework does the rest:
//!
//! * Runs each scenario `warmup_iterations + sample_iterations` times.
//! * Discards the warmup runs.
//! * Sorts the sampled wall times, reports median + p95 + p99 + min +
//!   max + stddev.
//! * Computes `throughput_ops_per_sec` from `ops_per_iteration`.
//! * Tracks allocations via an optional `TrackingAllocator` wrapper.
//! * Reads RSS from `/proc/self/status` on Linux (zero elsewhere).
//! * Captures git SHA, Zig version, OS, arch, and CPU model.
//! * Emits a stable JSON schema that `compare.zig` can diff.
//!
//! Internal layout (Q-CPLX-005 split):
//!
//!   framework/scenario.zig — public type contract + CLI parsing.
//!   framework/runner.zig   — run loop, timing, summary stats,
//!                            TrackingAllocator.
//!   framework/reporter.zig — JSON output, summary printer, env /
//!                            git SHA / RSS capture.
//!
//! This file re-exports the public surface so downstream bench
//! suites can keep `@import("framework").Scenario` and friends
//! unchanged.
//!
//! Has no dependency on the project library — it only uses the Zig
//! standard library — so it can be lifted into any Zig project by
//! copying `benchmarks/framework/` + `benchmarks/framework.zig` +
//! `benchmarks/compare.zig`.

const scenario_mod = @import("framework/scenario.zig");
const runner_mod = @import("framework/runner.zig");
const reporter_mod = @import("framework/reporter.zig");

// --- scenario / types ------------------------------------------------------

pub const RunFn = scenario_mod.RunFn;
pub const Scenario = scenario_mod.Scenario;
pub const Context = scenario_mod.Context;
pub const ResultRow = scenario_mod.ResultRow;
pub const ResultDocument = scenario_mod.ResultDocument;
pub const RunOptions = scenario_mod.RunOptions;
pub const ParseResult = scenario_mod.ParseResult;

pub const parseArgs = scenario_mod.parseArgs;
pub const printHelp = scenario_mod.printHelp;
pub const printScenarios = scenario_mod.printScenarios;

// --- runner ----------------------------------------------------------------

pub const TrackingAllocator = runner_mod.TrackingAllocator;
pub const runScenarios = runner_mod.runScenarios;
