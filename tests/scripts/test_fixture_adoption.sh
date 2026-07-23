#!/usr/bin/env bash
# Structural adoption guard for the issue #373 surviving fixture families.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

SENSORS=(
  tests/scripts/test_log_handback.sh
  tests/scripts/test_review_gate.sh
  tests/scripts/test_review_gate_patch_id_store.sh
  tests/scripts/test_review_gate_ci_coverage.sh
  tests/scripts/test_create_pr_failure.sh
  tests/scripts/test_finish_issue_conclusion.sh
  tests/scripts/test_trace_lib.sh
  tests/scripts/test_trace_lib_redaction.sh
)

for sensor in "${SENSORS[@]}"; do
  path="${ROOT}/${sensor}"
  [ -f "$path" ] || fail "adoption target is missing: ${sensor}"
  grep -qF 'tests/scripts/lib/fixture.sh' "$path" \
    || fail "${sensor} does not source the shared fixture helper"
  grep -qE '(^|[[:space:]])fixture_repo([[:space:]]|$)' "$path" \
    || fail "${sensor} does not call fixture_repo"
  if grep -qE 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+init([[:space:]]|$)' "$path"; then
    fail "${sensor} still hand-rolls git init"
  fi
done

printf 'shared fixture adoption contract honored for %d sensors\n' "${#SENSORS[@]}"
