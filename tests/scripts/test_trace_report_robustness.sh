#!/usr/bin/env bash
# test_trace_report_robustness.sh — regression sensor for robustness +
# absent-data honesty (issue #98, feature trace-report-robustness-honesty,
# plan Phase 4).
#
# Executable spec for the never-crash / never-fabricate half of
# `scripts/trace-report.sh`. Pinned conventions (plan D5 metrics-honesty
# doctrine — null = no data, 0 = measured zero, [] = detector ran and found
# nothing):
#
#   1. NEVER CRASHES (all legs exit 0, summary JSON parseable, stderr
#      silent — no jq errors under set -euo pipefail):
#        * empty trace file → markdown says "spans aggregated: 0"
#          (measured zero: the file was read), summary has total 0,
#          invalid_lines 0, stages/tools/loop_indicators/red_reentry [],
#          deviations count 0, wall_clock null, finished false,
#          final_outcome null, tokens null;
#        * garbage-only file (3 unparseable lines) → invalid_lines 3,
#          total 0, everything else null/empty as above;
#        * parseable spans with NO timestamps → wall_clock null in JSON,
#          elapsed n/a in markdown, no error text on stderr (the report is
#          not a validator — a missing required field never crashes it);
#        * an enormous (~2 MB) span line → still aggregates (its tool
#          appears with 1 call), exit 0.
#   2. TOKEN HONESTY BOTH WAYS (conductor-resolved: span-own attribution —
#      the model span's OWN gen_ai.agent.name / harness.feature_id fields,
#      no parent-chain reconstruction in v1; unresolvable buckets go under
#      "unattributed", never silently dropped or zeroed):
#        * tokens are computed from MODEL spans ONLY. gen_ai.usage.* on an
#          AGENT span is handback passthrough metadata, not a measurement
#          source — it must neither create a tokens object nor inflate one
#          (double-count guard).
#        * WITH model spans, the pinned JSON shape is EXACTLY
#            { "input_tokens":  <sum over model spans>,
#              "output_tokens": <sum over model spans>,
#              "by_role":    { "<gen_ai.agent.name>": {"input_tokens": N, "output_tokens": N},
#                              "unattributed": {...} },
#              "by_feature": { "<harness.feature_id>": {"input_tokens": N, "output_tokens": N},
#                              "unattributed": {...} } }
#          and the markdown carries a token section with the measured total.
#        * WITHOUT model spans, tokens == null — not {}, not zeros — even
#          when agent spans carry gen_ai.usage.* passthrough. Markdown must
#          not show token numbers: any line mentioning tokens must say the
#          data is unavailable (n/a, "no token data", or "unavailable").
#   3. UNFINISHED RUN: no finish lifecycle step → finished false,
#      final_outcome null (never fabricated), markdown states the run is
#      unfinished / in progress (pinned loosely).
#
# RED status at authoring time (documented honestly): the crash-safety legs
# (empty/garbage/no-timestamp/huge-line) and the unfinished-run leg are
# expected to already hold on the current implementation; the RED legs are
# the token ones — tokens is hardcoded null, so the WITH-model shape pin
# and its markdown section fail, and the model-only sourcing rule is
# unproven until implemented.
#
# Exit codes: 0 robustness/honesty contract honored · 1 a contract
# obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the report and this sensor are jq-driven)"
[ -f "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh not found (${REPORT_SH}) — earlier #98 features must land before robustness can be specified"
[ -x "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh exists but is not executable (${REPORT_SH})"

OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_report() {
  local rc=0
  (
    cd "$TMP_DIR" || exit 9
    exec "$@"
  ) >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# expect_ok <label> <trace> — exit 0, silent stderr, parseable summary JSON
# written beside the trace. Echoes nothing; accumulates fails.
expect_ok() {
  local label="$1" trace="$2" rc
  rc="$(run_report "$REPORT_SH" "$trace")"
  if [ "$rc" != "0" ]; then
    fail "${label}: expected exit 0 (never crashes, reporting never gates), got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"
  fi
  if [ -s "$ERR" ]; then
    fail "${label}: stderr must stay silent on a successful report (no jq errors under set -euo pipefail), got: $(tr '\n' '|' < "$ERR")"
  fi
  local summary
  summary="$(dirname "$trace")/trace-summary.json"
  if [ ! -f "$summary" ]; then
    fail "${label}: summary JSON must still be written beside the trace (${summary})"
  elif ! jq empty "$summary" >/dev/null 2>&1; then
    fail "${label}: summary JSON must parse (${summary})"
  fi
}

expect_json() {
  local label="$1" file="$2" filter="$3"
  jq -e "$filter" "$file" >/dev/null 2>&1 \
    || fail "${label}: summary must satisfy jq filter ${filter} (got: $(jq -c '.' "$file" 2>/dev/null | head -c 400))"
}

C='"schema_version":1,"harness.issue":98,"harness.version":"fix1234"'

# --- 1a. Empty trace file -----------------------------------------------------
EMPTY_DIR="${TMP_DIR}/empty"
mkdir -p "$EMPTY_DIR"
: > "${EMPTY_DIR}/trace.jsonl"
expect_ok "empty trace" "${EMPTY_DIR}/trace.jsonl"
grep -Eq 'spans aggregated: 0' "$OUT" \
  || fail "empty trace: markdown must report 'spans aggregated: 0' (a measured zero — the file was read)"
S="${EMPTY_DIR}/trace-summary.json"
if [ -f "$S" ]; then
  expect_json "empty trace: measured zeros"        "$S" '.span_counts.total == 0 and .span_counts.invalid_lines == 0'
  expect_json "empty trace: empty aggregates"      "$S" '.stages == [] and .tools == [] and .loop_indicators == [] and .red_reentry == []'
  expect_json "empty trace: deviations zero"       "$S" '.deviations.count == 0 and .deviations.feature_ids == []'
  expect_json "empty trace: nulls where no data"   "$S" '.wall_clock == null and .final_outcome == null and .tokens == null'
  expect_json "empty trace: not finished"          "$S" '.finished == false'
fi

# --- 1b. Garbage-only file ------------------------------------------------------
GARB_DIR="${TMP_DIR}/garbage"
mkdir -p "$GARB_DIR"
{
  printf '%s\n' 'GARBAGE_ONE not json {{{'
  printf '%s\n' '<<< GARBAGE_TWO >>>'
  printf '%s\n' '"GARBAGE_THREE — parses as JSON but is not an object"'
} > "${GARB_DIR}/trace.jsonl"
expect_ok "garbage-only trace" "${GARB_DIR}/trace.jsonl"
S="${GARB_DIR}/trace-summary.json"
if [ -f "$S" ]; then
  expect_json "garbage-only: skip-and-count"  "$S" '.span_counts.total == 0 and .span_counts.invalid_lines == 3'
  expect_json "garbage-only: nothing invented" "$S" '.wall_clock == null and .tokens == null and .stages == [] and .tools == [] and .finished == false and .final_outcome == null'
fi
grep -Eiq 'invalid lines: 3' "$OUT" \
  || fail "garbage-only: markdown must count all 3 invalid lines"

# --- 1c. Parseable spans with no timestamps --------------------------------------
NOTS_DIR="${TMP_DIR}/no-timestamps"
mkdir -p "$NOTS_DIR"
{
  printf '%s\n' "{${C},\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"preflight\",\"harness.duration_ms\":100}"
  printf '%s\n' "{${C},\"span\":\"tool\",\"gen_ai.tool.name\":\"git\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":4}"
} > "${NOTS_DIR}/trace.jsonl"
expect_ok "no-timestamp spans (missing required field never crashes the report — it is not a validator)" \
  "${NOTS_DIR}/trace.jsonl"
S="${NOTS_DIR}/trace-summary.json"
if [ -f "$S" ]; then
  expect_json "no timestamps: wall_clock null (no data, never a fabricated elapsed)" \
    "$S" '.wall_clock == null and .span_counts.total == 2'
fi
grep -Ei 'first-to-last' "$OUT" | grep -Eiq 'n/a' \
  || fail "no timestamps: markdown elapsed line must say n/a"

# --- 1d. Enormous (~2 MB) span line ------------------------------------------------
BIG_DIR="${TMP_DIR}/big"
mkdir -p "$BIG_DIR"
{
  jq -nc '{schema_version: 1, timestamp: "2026-07-04T14:00:00Z", span: "tool",
           "harness.issue": 98, "harness.version": "fix1234",
           "gen_ai.tool.name": "big-tool", "harness.duration_ms": 1,
           "harness.note": ("x" * 2097152)}'
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T14:01:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":5}"
} > "${BIG_DIR}/trace.jsonl"
[ "$(wc -c < "${BIG_DIR}/trace.jsonl" | tr -d '[:space:]')" -gt 2000000 ] \
  || hard_fail "big-line fixture failed to reach ~2MB"
expect_ok "2MB span line" "${BIG_DIR}/trace.jsonl"
S="${BIG_DIR}/trace-summary.json"
if [ -f "$S" ]; then
  expect_json "2MB line still aggregates" "$S" \
    '(.tools[] | select(.name == "big-tool")) | .calls == 1'
fi

# --- 2a. Tokens WITH model spans: measured sums + span-own attribution --------------
TOK_DIR="${TMP_DIR}/with-model"
mkdir -p "$TOK_DIR"
{
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T15:00:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"preflight\",\"harness.duration_ms\":50}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T15:01:00Z\",\"span\":\"model\",\"gen_ai.request.model\":\"example-model\",\"gen_ai.usage.input_tokens\":100,\"gen_ai.usage.output_tokens\":10,\"gen_ai.agent.name\":\"planner\",\"harness.feature_id\":\"feat-x\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T15:02:00Z\",\"span\":\"model\",\"gen_ai.request.model\":\"example-model\",\"gen_ai.usage.input_tokens\":200,\"gen_ai.usage.output_tokens\":20,\"gen_ai.agent.name\":\"planner\",\"harness.feature_id\":\"feat-y\"}"
  # no agent name, no feature id → both buckets fall back to "unattributed"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T15:03:00Z\",\"span\":\"model\",\"gen_ai.request.model\":\"example-model\",\"gen_ai.usage.input_tokens\":400,\"gen_ai.usage.output_tokens\":40}"
  # double-count guard: agent-span usage passthrough must NOT add to totals
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T15:04:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"green_handback\",\"harness.feature_id\":\"feat-x\",\"harness.outcome\":\"pass\",\"gen_ai.usage.input_tokens\":9999,\"gen_ai.usage.output_tokens\":9999}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T15:05:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":5}"
} > "${TOK_DIR}/trace.jsonl"
expect_ok "with-model-spans trace" "${TOK_DIR}/trace.jsonl"
S="${TOK_DIR}/trace-summary.json"
if [ -f "$S" ]; then
  expect_json "tokens: EXACT pinned shape (model spans only; span-own attribution; unattributed fallback; agent passthrough excluded)" "$S" '
    .tokens == {
      "input_tokens": 700,
      "output_tokens": 70,
      "by_role": {
        "planner":      {"input_tokens": 300, "output_tokens": 30},
        "unattributed": {"input_tokens": 400, "output_tokens": 40}
      },
      "by_feature": {
        "feat-x":       {"input_tokens": 100, "output_tokens": 10},
        "feat-y":       {"input_tokens": 200, "output_tokens": 20},
        "unattributed": {"input_tokens": 400, "output_tokens": 40}
      }
    }'
fi
grep -Ei 'token' "$OUT" | grep -Eq '(^|[^0-9])700([^0-9]|$)' \
  || fail "tokens markdown: a token section must carry the measured input total 700"

# --- 2b. Tokens WITHOUT model spans: null, not {} / zeros ----------------------------
NOTOK_DIR="${TMP_DIR}/without-model"
mkdir -p "$NOTOK_DIR"
{
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T16:00:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"preflight\",\"harness.duration_ms\":50}"
  # agent passthrough usage present — STILL no token measurement source
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T16:01:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"red_handback\",\"harness.feature_id\":\"feat-x\",\"harness.outcome\":\"pass\",\"gen_ai.usage.input_tokens\":18000,\"gen_ai.usage.output_tokens\":4000}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T16:02:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":5}"
} > "${NOTOK_DIR}/trace.jsonl"
expect_ok "no-model-spans trace" "${NOTOK_DIR}/trace.jsonl"
S="${NOTOK_DIR}/trace-summary.json"
if [ -f "$S" ]; then
  expect_json "tokens absent => null (not {}, not zeros), even with agent passthrough usage on disk" \
    "$S" '.tokens == null and has("tokens")'
fi
# Markdown honesty: no fabricated token figures. Any token-mentioning line
# must declare the data unavailable.
while IFS= read -r tline; do
  printf '%s\n' "$tline" | grep -Eiq 'unavailable|no token data|n/a' \
    || fail "no-model markdown: a line mentioning tokens must declare the data unavailable, got: ${tline}"
done < <(grep -Ei 'token' "$OUT" || true)

# --- 3. Unfinished run ------------------------------------------------------------
UNFIN_DIR="${TMP_DIR}/unfinished"
mkdir -p "$UNFIN_DIR"
{
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T17:00:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"preflight\",\"harness.duration_ms\":50}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T17:01:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"feature_start\",\"harness.feature_id\":\"feat-x\",\"harness.duration_ms\":10}"
} > "${UNFIN_DIR}/trace.jsonl"
expect_ok "unfinished run (truncated mid-feature)" "${UNFIN_DIR}/trace.jsonl"
S="${UNFIN_DIR}/trace-summary.json"
if [ -f "$S" ]; then
  expect_json "unfinished: finished false, final_outcome null (never fabricated)" \
    "$S" '.finished == false and .final_outcome == null'
fi
grep -Eiq 'unfinished|in progress|in-flight' "$OUT" \
  || fail "unfinished markdown: report must state the run is unfinished / in progress"

# --- Result --------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d robustness/honesty contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-report robustness/honesty contract honored\n'
