#!/usr/bin/env bash
# Structural regression sensor for shared lifecycle runtime helpers (issue #423).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

LIB="scripts/lifecycle-runtime-lib.sh"
CALLERS=(
  scripts/start-issue.sh
  scripts/create-pr.sh
  scripts/merge-pr.sh
  scripts/finish-issue.sh
  scripts/review-gate.sh
)
fail=0

note() {
  printf 'FAIL: %s\n' "$*" >&2
  fail=1
}

[ -f "$LIB" ] || note "$LIB is missing"

if [ -f "$LIB" ]; then
  for fn in red green yellow bold lifecycle_runtime_trace_init; do
    grep -Eq "^${fn}[[:space:]]*\\(\\)" "$LIB" ||
      note "$LIB does not define ${fn}()"
  done
  grep -q 'trace-lib\.sh' "$LIB" ||
    note "$LIB does not own trace-lib.sh loading"
  grep -q 'TRACE_NOOP_WARNED' "$LIB" ||
    note "$LIB does not own the trace fallback"
fi

for caller in "${CALLERS[@]}"; do
  grep -q 'lifecycle-runtime-lib\.sh' "$caller" ||
    note "$caller does not source lifecycle-runtime-lib.sh"
  grep -q 'lifecycle_runtime_trace_init' "$caller" ||
    note "$caller does not initialize shared trace helpers"
  if grep -Eq '^(red|green|yellow|bold)[[:space:]]*\(\)' "$caller"; then
    note "$caller still defines terminal color helpers"
  fi
  if grep -q 'TRACE_NOOP_WARNED' "$caller"; then
    note "$caller still defines the trace fallback"
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'lifecycle runtime helpers have one owner\n'
