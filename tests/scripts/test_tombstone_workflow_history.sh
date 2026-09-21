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

grep -Fq './scripts/run-sensors.sh --gate ci' "$WORKFLOW" \
  || fail "harness-smoke must execute applicable history acceptance"
SENSOR=tests/scripts/test_install_harness_tombstone_history.sh
for mode in relevant release; do
  args=(--gate release)
  [ "$mode" != relevant ] || args=(--gate pre-pr scripts/install-harness.tombstones)
  selected="$("$ROOT/scripts/validation/affected-sensors.sh" "${args[@]}")"
  grep -Fxq "$SENSOR" <<<"$selected" || fail "$mode omitted tombstone history"
done
# shellcheck disable=SC2016 # Assert the shipped checker invocation literally.
grep -Fq '"$CHECKER" "$ROOT"' "$ROOT/$SENSOR" \
  || fail "selected history sensor must execute the real checker"
release_checkout="$(grep -A4 'uses: actions/checkout@' "$ROOT/.github/workflows/release.yml")"
grep -Eq '^[[:space:]]+fetch-depth:[[:space:]]+0([[:space:]]|$)' <<<"$release_checkout" \
  || fail "release acceptance must retain full history"
if grep -Fq 'run: ./scripts/check-install-harness-tombstones.sh' "$WORKFLOW"; then
  fail "CI duplicated history validation outside applicable selection"
fi

printf 'tombstone workflow full-history contract honored\n'
