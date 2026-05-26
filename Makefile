# timeseries-storage - Zig Library + CLI Makefile
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2026 CodePros

ZIG ?= $(if $(wildcard ./zig-0.16.0/zig),./zig-0.16.0/zig,zig)
BASELINE ?= benchmarks/results/baseline.json
CURRENT ?= benchmarks/results/latest.json

.PHONY: all build check fmt test test-unit test-integration test-stress test-all
.PHONY: test-release-safe test-release-fast test-release-small clean dev ci
.PHONY: example run install help
.PHONY: pre-commit-install pre-commit pre-commit-run
.PHONY: bench bench-save bench-compare bench-micro scale-bench tools

all: build test-unit

build:
	$(ZIG) build build

check:
	$(ZIG) build check

fmt:
	$(ZIG) fmt src tests examples benchmarks build.zig

test: test-unit test-integration test-stress

test-unit:
	$(ZIG) build test --summary all

test-integration:
	$(ZIG) build test-integration --summary all

test-stress:
	$(ZIG) build test-stress --summary all

test-all:
	$(ZIG) build test-all --summary all

test-release-safe:
	$(ZIG) build test -Doptimize=ReleaseSafe --summary all

test-release-fast:
	$(ZIG) build test -Doptimize=ReleaseFast --summary all

test-release-small:
	$(ZIG) build test -Doptimize=ReleaseSmall --summary all

example:
	$(ZIG) build example

run:
	$(ZIG) build run

install:
	$(ZIG) build --prefix $(or $(PREFIX),zig-out)

bench:
	mkdir -p benchmarks/results
	$(ZIG) build bench -- --output $(CURRENT)

bench-save:
	mkdir -p benchmarks/results
	$(ZIG) build bench -- --output $(CURRENT)

bench-compare:
	$(ZIG) build compare-bench -- --baseline $(BASELINE) --current $(CURRENT)

bench-micro:
	$(ZIG) build bench-micro

scale-bench:
	mkdir -p benchmarks/results
	$(ZIG) build scale-bench -- --output benchmarks/results/scale-latest.json

tools:
	$(ZIG) build tools

dev: fmt check test-unit

ci: clean check test-all

clean:
	rm -rf .zig-cache zig-cache zig-out

# Pre-commit hook management
pre-commit-install:
	pre-commit install
	pre-commit install --hook-type commit-msg
	pre-commit install --hook-type pre-push

pre-commit:
	pre-commit run --all-files

pre-commit-run: pre-commit

help:
	@echo "timeseries-storage - Zig Library + CLI"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Development:"
	@echo "  all                  Build and run unit tests (default)"
	@echo "  build                Build the library and CLI"
	@echo "  install              Install artifacts to PREFIX (default zig-out)"
	@echo "  run                  Build and run the CLI"
	@echo "  example              Build and run the basic example"
	@echo "  dev                  Quick iteration: fmt + check + test-unit"
	@echo "  ci                   Full CI: clean + check + test-all"
	@echo ""
	@echo "Testing:"
	@echo "  test                 Run unit + integration + stress tests"
	@echo "  test-unit            Run unit tests"
	@echo "  test-integration     Run integration tests"
	@echo "  test-stress          Run stress tests"
	@echo "  test-all             Run all suites in one build"
	@echo "  test-release-safe    Run tests with ReleaseSafe"
	@echo "  test-release-fast    Run tests with ReleaseFast"
	@echo "  test-release-small   Run tests with ReleaseSmall"
	@echo ""
	@echo "Code Quality:"
	@echo "  fmt                  Format source code (zig fmt)"
	@echo "  check                Check for compilation errors"
	@echo "  pre-commit           Run pre-commit hooks across the repo"
	@echo "  pre-commit-install   Install git hooks"
	@echo ""
	@echo "Benchmarks:"
	@echo "  bench                Run default suite, write \$$(CURRENT)"
	@echo "  bench-save           Alias for bench"
	@echo "  bench-compare        Diff \$$(CURRENT) against \$$(BASELINE)"
	@echo "  bench-micro          Run all micro-benchmarks"
	@echo "  scale-bench          Run scale benchmark suite"
	@echo "  tools                Build benchmark tooling artifacts"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean                Remove build artifacts"
	@echo "  help                 Show this help message"
