#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cd "$ROOT"

check_snapshot() {
  local path="$1"
  local expected_hash="$2"
  local stripped
  stripped="${TMP_DIR}/$(basename "$path")"

  grep -qF '<!-- snapshot-retirement:start -->' "$path" \
    || { echo "journey-retirement: notice start missing from ${path}"; exit 1; }
  grep -qF 'point-in-time snapshot' "$path" \
    || { echo "journey-retirement: snapshot warning missing from ${path}"; exit 1; }
  # shellcheck disable=SC2016  # backticks are literal Markdown, not shell syntax
  grep -qF 'export scripts and `trace_tools` examples no longer run' "$path" \
    || { echo "journey-retirement: retired examples missing from ${path}"; exit 1; }
  grep -qF '#352' "$path" \
    || { echo "journey-retirement: topology retirement missing from ${path}"; exit 1; }
  grep -qF '#394' "$path" \
    || { echo "journey-retirement: current contract transition missing from ${path}"; exit 1; }
  # shellcheck disable=SC2016  # backticks are literal Markdown, not shell syntax
  grep -qF '[`docs/harness-contract.yml`](harness-contract.yml)' "$path" \
    || { echo "journey-retirement: current doctrine link missing from ${path}"; exit 1; }

  awk '
    /<!-- snapshot-retirement:start -->/ { skip = 1; next }
    /<!-- snapshot-retirement:end -->/ { skip = 0; next }
    !skip
  ' "$path" >"$stripped"
  [ "$(shasum -a 256 "$stripped" | awk '{print $1}')" = "$expected_hash" ] \
    || { echo "journey-retirement: historical body changed in ${path}"; exit 1; }
}

check_snapshot docs/observability-journey.md \
  c376b120012a5dc31c298433ac0080116c7d0bb0447fd3c7c9f077b74d76c238
check_snapshot docs/deep-tracing-journey.md \
  7d694e36e0ed583572a2c1e44f2486e60f0b823fc8659881068bad255660023c

printf 'journey retirement checks passed\n'
