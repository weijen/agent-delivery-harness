#!/usr/bin/env bash
# Regression sensor for issue #320, feature count-review-events.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="${ROOT}/.copilot-tracking/test-runs/test_delivery_economics_review_events.$$"
trap 'rm -rf "${SCRATCH}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SCRATCH"

write_complete_trace() {
  cat > "$1" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f3","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"repair","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"repair","harness.feature_id":"f2","harness.outcome":"pass"}
JSONL
}

run_markdown() {
  local library="$1" trace="$2"
  (
    # shellcheck source=scripts/finish-lib.sh
    source "$library"
    compute_delivery_economics "$trace" -
  )
}

run_numeric() {
  local library="$1" trace="$2"
  (
    # shellcheck source=scripts/finish-lib.sh
    source "$library"
    economics_numeric_aggregates "$trace" -
  )
}

assert_complete_contract() {
  local library="$1" trace="$2" markdown numeric markdown_rounds numeric_rounds
  markdown="$(run_markdown "$library" "$trace")"
  numeric="$(run_numeric "$library" "$trace")"

  grep -Fx -- '- Review rounds: 3 (1 fail → 2 pass)' <<< "$markdown" >/dev/null \
    || fail "7 per-feature verdict spans must aggregate to 3 events with mixed outcomes"
  grep -Fx -- 'harness.economics.review_rounds=3' <<< "$numeric" >/dev/null \
    || fail "numeric economics must count the same 3 review events"
  grep -Fx -- 'harness.economics.review_identity_covered=7' <<< "$numeric" >/dev/null \
    || fail "numeric economics must report seven identified verdict spans"
  grep -Fx -- 'harness.economics.review_identity_total=7' <<< "$numeric" >/dev/null \
    || fail "numeric economics must report seven total verdict spans"

  markdown_rounds="$(sed -n 's/^- Review rounds: \([0-9][0-9]*\).*/\1/p' <<< "$markdown")"
  numeric_rounds="$(sed -n 's/^harness\.economics\.review_rounds=//p' <<< "$numeric")"
  [ "$markdown_rounds" = "$numeric_rounds" ] \
    || fail "Markdown and machine-readable review-round counts must match"
}

COMPLETE="${SCRATCH}/complete.jsonl"
write_complete_trace "$COMPLETE"
assert_complete_contract "${ROOT}/scripts/finish-lib.sh" "$COMPLETE"

MISSING="${SCRATCH}/missing.jsonl"
cat > "$MISSING" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"quick","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_mode":"repair","harness.outcome":"pass"}
JSONL
markdown="$(run_markdown "${ROOT}/scripts/finish-lib.sh" "$MISSING")"
numeric="$(run_numeric "${ROOT}/scripts/finish-lib.sh" "$MISSING")"
grep -Fx -- '- Review rounds: n/a (event identity coverage: 1/3 verdict spans; missing/invalid reviewed_sha or review_mode)' <<< "$markdown" >/dev/null \
  || fail "incomplete review identity must render n/a with coverage"
if grep -Fq -- 'harness.economics.review_rounds=' <<< "$numeric"; then
  fail "numeric review_rounds must be omitted when any event identity is missing"
fi
grep -Fx -- 'harness.economics.review_identity_covered=1' <<< "$numeric" >/dev/null \
  || fail "numeric economics must explain incomplete identity coverage"
grep -Fx -- 'harness.economics.review_identity_total=3' <<< "$numeric" >/dev/null \
  || fail "numeric economics must expose the review identity denominator"

NONE="${SCRATCH}/none.jsonl"
printf '{"span":"agent","harness.lifecycle_step":"deviation"}\n' > "$NONE"
grep -Fx -- '- Review rounds: 0' <<< "$(run_markdown "${ROOT}/scripts/finish-lib.sh" "$NONE")" >/dev/null \
  || fail "no review verdict spans must remain a measured zero"
grep -Fx -- 'harness.economics.review_rounds=0' <<< "$(run_numeric "${ROOT}/scripts/finish-lib.sh" "$NONE")" >/dev/null \
  || fail "numeric economics must report zero when there are no review verdict spans"

# Mutation proof: dropping review_mode from the temporary key must collapse the
# full and repair reviews at sha-b, and this sensor must reject that result.
MUTATED="${SCRATCH}/finish-lib-mutated.sh"
# shellcheck disable=SC2016 # jq variable names are the literal mutation target.
sed 's/\[$sha, $mode\]/[$sha]/' "${ROOT}/scripts/finish-lib.sh" > "$MUTATED"
if cmp -s "${ROOT}/scripts/finish-lib.sh" "$MUTATED"; then
  fail "mutation setup did not alter the review-event key"
fi
if (
  assert_complete_contract "$MUTATED" "$COMPLETE"
) >/dev/null 2>&1; then
  fail "sensor survived a mutation that removed review_mode from the event key"
fi

printf 'delivery economics review-event aggregation contract honored\n'
