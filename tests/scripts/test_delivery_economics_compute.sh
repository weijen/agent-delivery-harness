#!/usr/bin/env bash
# test_delivery_economics_compute.sh — RED sensor for trace-derived delivery
# economics summary computation (issue #267, feature f1 economics-summary-compute).
#
# Contract under test:
#   source scripts/finish-lib.sh
#   compute_delivery_economics <trace_file> <feature_list_file_or_->
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_delivery_economics_compute.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE \
  REQUIRE_TRACE_CONSISTENCY REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true

run_compute() {
  local trace_file="$1" feature_list_file="$2"
  source "${ROOT}/scripts/finish-lib.sh"
  compute_delivery_economics "$trace_file" "$feature_list_file"
}

assert_line() {
  local label="$1" output="$2" expected="$3"
  printf '%s\n' "$output" | grep -Fx -- "$expected" >/dev/null \
    || fail "${label}: missing exact line: ${expected}; output was: $(printf '%s' "$output" | tr '\n' '|')"
}

assert_not_contains() {
  local label="$1" output="$2" needle="$3"
  if printf '%s\n' "$output" | grep -F -- "$needle" >/dev/null; then
    fail "${label}: output must not contain: ${needle}; output was: $(printf '%s' "$output" | tr '\n' '|')"
  fi
}

TRACE_FULL="${TMP_DIR}/trace-full.jsonl"
cat > "$TRACE_FULL" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T09:14:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":40}
{"schema_version":1,"timestamp":"2026-07-08T10:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"-","harness.outcome":"fail"}
{"schema_version":1,"timestamp":"2026-07-08T11:00:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x","gen_ai.usage.input_tokens":250,"gen_ai.usage.output_tokens":70}
{"schema_version":1,"timestamp":"2026-07-08T12:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"implementation-subagent","harness.lifecycle_step":"deviation","harness.feature_id":"f1","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-08T13:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"deviation","harness.feature_id":"f1","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-08T14:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"-","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-09T16:02:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x"}
JSONL

FEATURE_LIST="${TMP_DIR}/feature_list.json"
cat > "$FEATURE_LIST" <<'JSON'
{"features":[{"id":"f1","passes":true,"teeth_proof":{"kind":"red_first","evidence":"sensor failed before implementation"}},{"id":"f2","passes":true,"teeth_proof":{"kind":"negative_fixture","evidence":"fixture proves omit-never-fake"}},{"id":"f3","passes":true,"teeth_proof":null},{"id":"f4","passes":false}]}
JSON

# CASE A — full trace, partial token coverage, review/deviation counts, and features.
out="$(run_compute "$TRACE_FULL" "$FEATURE_LIST")"
assert_line "CASE A heading" "$out" "## Delivery economics (auto-stamped, trace-derived)"
assert_line "CASE A wall-clock" "$out" "- Wall-clock span: 2026-07-08T09:14:00Z → 2026-07-09T16:02:00Z (elapsed 30.8h)"
assert_line "CASE A tokens" "$out" "- Tokens: in 350 / out 110 (coverage: 2/3 runs)"
assert_line "CASE A review rounds" "$out" "- Review rounds: 2 (1 fail → 1 pass)"
assert_line "CASE A deviations" "$out" "- Deviations logged: 2"
assert_line "CASE A features" "$out" "- Features: 3/4 passes:true; teeth-proof coverage 2/4"

TRACE_NO_TOKENS="${TMP_DIR}/trace-no-tokens.jsonl"
cat > "$TRACE_NO_TOKENS" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T09:14:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x"}
{"schema_version":1,"timestamp":"2026-07-08T10:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"-","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-08T11:00:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x"}
JSONL

# CASE B — no model usage must degrade honestly, never fake zero-token totals.
out="$(run_compute "$TRACE_NO_TOKENS" "$FEATURE_LIST")"
assert_line "CASE B tokens n/a" "$out" "- Tokens: n/a (no run carried token data)"
assert_not_contains "CASE B tokens omit-never-fake" "$out" "in 0 / out 0"

# CASE C — no feature list available.
out="$(run_compute "$TRACE_FULL" -)"
assert_line "CASE C features absent" "$out" "- Features: n/a"

TRACE_SINGLE_TIMESTAMP="${TMP_DIR}/trace-single-timestamp.jsonl"
cat > "$TRACE_SINGLE_TIMESTAMP" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T09:14:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":40}
{"schema_version":1,"span":"agent","harness.issue":267,"harness.version":"0.7.0","harness.lifecycle_step":"deviation"}
JSONL

# CASE D — fewer than two timestamps cannot claim a wall-clock span.
out="$(run_compute "$TRACE_SINGLE_TIMESTAMP" "$FEATURE_LIST")"
assert_line "CASE D wall-clock n/a" "$out" "- Wall-clock span: n/a"

printf 'test_delivery_economics_compute: ok\n'
