#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/harness-smoke.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

checkout_block="$(grep -A3 'uses: actions/checkout@' "$WORKFLOW")"
grep -Eq '^[[:space:]]+fetch-depth:[[:space:]]+0([[:space:]]|$)' <<<"$checkout_block" \
  || fail "harness-smoke checkout must fetch full history"

grep -Fq 'run: ./scripts/check-install-harness-tombstones.sh' "$WORKFLOW" \
  || fail "harness-smoke must invoke the dedicated tombstone checker"

printf 'tombstone workflow full-history contract honored\n'
