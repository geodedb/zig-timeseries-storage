#!/usr/bin/env bash
# A/B orchestrator for the timeseries-storage bench suite.
# Usage:
#   benchmarks/scripts/bench_ab.sh [--ref-a SHA_OR_REF] [--ref-b SHA_OR_REF] [--out DIR]
# Defaults: --ref-a main, --ref-b HEAD, --out docs/performance/2026-05-27-codec-micro-mixed-rw/runs/<timestamp>
#
# Captures bench (default suite), bench-micro (all micro scenarios), and
# bench-integration (concurrent + OoO + recovery) results for both refs.
# Writes machine-readable host-state-*.json files for downstream diffing.

set -euo pipefail

REF_A="main"
REF_B="HEAD"
OUT_BASE="docs/performance/2026-05-27-codec-micro-mixed-rw/runs"

while [ $# -gt 0 ]; do
  case "$1" in
    --ref-a) REF_A="$2"; shift 2 ;;
    --ref-b) REF_B="$2"; shift 2 ;;
    --out)   OUT_BASE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

TS="$(date -u +%Y-%m-%dT%H%M%SZ)"
SHA_A="$(git rev-parse --verify "$REF_A")"
SHA_B="$(git rev-parse --verify "$REF_B")"
OUT_DIR="${OUT_BASE}/${TS}-${SHA_A:0:7}-vs-${SHA_B:0:7}"
mkdir -p "$OUT_DIR" "$OUT_DIR/raw"

echo "ref_a=$REF_A ($SHA_A)"
echo "ref_b=$REF_B ($SHA_B)"
echo "out=$OUT_DIR"

# JSON-shaped host-state capture so downstream tools can diff key=value.
host_state_json() {
  local out_path="$1"
  local uname_str
  local zig_ver
  local date_iso
  local cpu_model
  local mem_total_kb
  uname_str="$(uname -a)"
  zig_ver="$(zig version)"
  date_iso="$(date -u --iso-8601=seconds)"
  cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo unknown)"
  mem_total_kb="$(grep -m1 'MemTotal' /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)"
  cat > "$out_path" <<EOF
{
  "uname": "${uname_str//\"/\\\"}",
  "zig_version": "${zig_ver//\"/\\\"}",
  "date": "${date_iso}",
  "cpu_model": "${cpu_model//\"/\\\"}",
  "mem_total_kb": ${mem_total_kb}
}
EOF
}

host_state_json "$OUT_DIR/host-state-before.json"

# Remember the starting ref so we can return.
START_REF="$(git rev-parse --abbrev-ref HEAD)"
if [ "$START_REF" = "HEAD" ]; then
  START_REF="$(git rev-parse HEAD)"
fi

# Stash any local changes for safety.
STASH_OUT="$(git stash push --include-untracked -m "bench-ab pre-run" 2>&1 || true)"
STASHED=0
if echo "$STASH_OUT" | grep -q "Saved working directory"; then
  STASHED=1
fi

cleanup() {
  set +e
  git checkout "$START_REF" >/dev/null 2>&1
  if [ "$STASHED" = 1 ]; then
    git stash pop --quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Run one ref end-to-end: bench + bench-micro + bench-integration.
# Writes raw JSON for each suite into raw/<ref>_<suite>.json.
run_ref () {
  local label="$1"
  local sha="$2"
  echo "=== Building and running ref_${label} ($sha) ==="
  git checkout --detach "$sha" >/dev/null
  zig build bench             -- --output "$OUT_DIR/raw/${label}_bench.json"             --quiet
  zig build bench-micro       -- --output "$OUT_DIR/raw/${label}_micro.json"             --quiet || true
  zig build bench-integration -- --output "$OUT_DIR/raw/${label}_integration.json"       --quiet || true
}

run_ref a "$SHA_A"
run_ref b "$SHA_B"

# Canonical inputs to compare-bench remain the default-suite JSON files
# (so the existing CI gate format is unchanged).
cp "$OUT_DIR/raw/a_bench.json" "$OUT_DIR/ref_a.json"
cp "$OUT_DIR/raw/b_bench.json" "$OUT_DIR/ref_b.json"

host_state_json "$OUT_DIR/host-state-after.json"

# Compare default-suite results (the CI gate). Micro and integration
# diffing is a follow-up step (the raw/ JSONs are preserved for it).
zig build compare-bench -- \
  --baseline "$OUT_DIR/ref_a.json" \
  --current "$OUT_DIR/ref_b.json" \
  > "$OUT_DIR/compare.txt" 2>&1 || true

echo "Wrote $OUT_DIR"
cat "$OUT_DIR/compare.txt"
