#!/usr/bin/env bash
# test_trace_report_summary_json.sh — regression sensor for the versioned
# summary JSON emission (issue #98, feature trace-report-summary-json, plan
# Phase 2).
#
# Executable spec for the machine-readable half of `scripts/trace-report.sh`:
# the versioned trace-summary.v1 contract that #104 (cross-run scorecard)
# consumes. Pinned conventions (this sensor IS the spec — plan D2/D5/D6):
#
#   1. Contract doc  docs/evaluation/trace-summary.v1.json  exists, parses
#      with jq, and — mirroring the trace-schema.v1.json precedent — declares
#      `"summary_schema_version": 1` (a JSON number) plus its field
#      vocabulary: a `required_top_level` array naming every mandatory
#      top-level key of the emitted summary. Pinned members: it must include
#      at least  summary_schema_version, trace_file, issue, harness_versions,
#      finished, final_outcome, span_counts, wall_clock, stages, tools,
#      tokens.
#   2. Running trace-report.sh writes  <trace dir>/trace-summary.json
#      (conductor-resolved delivery point) while markdown still goes to
#      stdout. Emitted values pinned against the core fixture:
#        * summary_schema_version == 1 and is a NUMBER;
#        * harness_versions: unique harness.version STRINGS carried through
#          from the trace's spans (fixture plants fix1234 + fix5678 →
#          exactly ["fix1234","fix5678"] sorted) — never invented locally;
#        * issue == 98 (number, from the spans' harness.issue);
#        * finished == true, final_outcome == "pass" (finish span);
#        * span_counts: total 15, invalid_lines 2,
#          by_type {agent 2, lifecycle 6, tool 7};
#        * stages: pr_merge {spans 2, duration_ms 1000};
#        * tools: git calls 3; typedrift-tool calls 1 (type-violating but
#          parseable span still aggregates — plan D1);
#        * wall_clock.elapsed_seconds == 630;
#        * tokens == null (fixture has no model spans — absence is null,
#          plan D5).
#   3. Null-vs-zero (plan D5): the red_handback stage (agent span, no
#      harness.duration_ms) reports  duration_ms: null  — never 0. A second
#      fixture with a span measuring  harness.duration_ms: 0  reports
#      duration_ms: 0 — a measured zero is preserved, never nulled.
#   4. Markdown/JSON agreement (plan D2 — one set of numbers): stdout and
#      trace-summary.json agree on elapsed 630, git calls 3, and
#      invalid lines 2.
#   5. Idempotent overwrite: a second run leaves exactly ONE JSON document
#      in trace-summary.json (jq slurp length 1) with the same numbers —
#      overwritten, never appended.
#
# Exit codes: 0 summary-JSON contract honored · 1 a contract obligation
# regressed (RED today: the emission seam is a no-op and the contract doc
# does not exist).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
CONTRACT_DOC="${ROOT}/docs/evaluation/trace-summary.v1.json"
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

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the summary contract and this sensor are jq-driven)"
[ -f "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh not found (${REPORT_SH}) — feature trace-report-core must land before its summary emission can be specified"
[ -x "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh exists but is not executable (${REPORT_SH})"

# --- 1. The trace-summary.v1 contract doc (plan D6, #104's authority) ------------
if [ ! -f "$CONTRACT_DOC" ]; then
  fail "contract doc docs/evaluation/trace-summary.v1.json not found (${CONTRACT_DOC}) — feature trace-report-summary-json (issue #98 Phase 2) must document the #104 input contract"
else
  jq empty "$CONTRACT_DOC" >/dev/null 2>&1 \
    || fail "contract doc must parse as JSON (mirror the trace-schema.v1.json precedent)"
  jq -e '.summary_schema_version == 1' "$CONTRACT_DOC" >/dev/null 2>&1 \
    || fail "contract doc must declare summary_schema_version 1 as a JSON number"
  jq -e '
    (.required_top_level // []) as $r
    | ["summary_schema_version","trace_file","issue","harness_versions",
       "finished","final_outcome","span_counts","wall_clock","stages",
       "tools","tokens"]
    | all(.[]; . as $k | $r | index($k) != null)
  ' "$CONTRACT_DOC" >/dev/null 2>&1 \
    || fail "contract doc must declare a required_top_level vocabulary covering summary_schema_version, trace_file, issue, harness_versions, finished, final_outcome, span_counts, wall_clock, stages, tools, tokens"
fi

# --- Fixture: the core fixture's exact numbers + a second harness.version --------
# Identical shape/counts to test_trace_report_core.sh (15 aggregatable lines,
# 2 planted invalid lines, elapsed 630 s), except the SECOND pr_merge span
# carries harness.version fix5678 — proving harness_versions is carried
# through from the spans on disk, not invented.
write_fixture_trace() {
  local f="$1"
  : > "$f"
  local ln
  for ln in \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"preflight","harness.exit_status":0,"harness.duration_ms":1200}' \
    'GARBAGE_LINE_a17c this is not JSON {{{' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:05Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"feature_start","harness.feature_id":"trace-report-core","harness.duration_ms":300}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:10Z","span":"agent","harness.issue":98,"harness.version":"fix1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"trace-report-core","harness.outcome":"pass"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:01:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"check-feature-list","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":10}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:02:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"check-feature-list","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":20}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:03:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":5}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:03:10Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":5}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:03:20Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":5}' \
    '"SCALAR_LINE_b42e — valid JSON, not an object"' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:04:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"review-gate.check","harness.outcome":"pass","harness.duration_ms":40}' \
    '{"schema_version":"1","timestamp":"2026-07-04T10:05:00Z","span":"tool","harness.issue":"98","harness.version":"fix1234","gen_ai.tool.name":"typedrift-tool","harness.duration_ms":7}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:05:30Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"skill","harness.skill.name":"find-over-design","harness.outcome":"pass"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:06:00Z","span":"agent","harness.issue":98,"harness.version":"fix1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:07:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"pr_create","harness.duration_ms":2500}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:08:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"pr_merge","harness.duration_ms":400}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:09:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix5678","harness.lifecycle_step":"pr_merge","harness.duration_ms":600}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:10:30Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"finish","harness.outcome":"pass","harness.duration_ms":150}' \
    ; do
    printf '%s\n' "$ln" >> "$f"
  done
}

TRACE_DIR="${TMP_DIR}/trace-home"
mkdir -p "$TRACE_DIR"
TRACE="${TRACE_DIR}/trace.jsonl"
write_fixture_trace "$TRACE"
SUMMARY="${TRACE_DIR}/trace-summary.json"

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

# jq assertion against the emitted summary file.
expect_summary() {
  local label="$1" filter="$2"
  jq -e "$filter" "$SUMMARY" >/dev/null 2>&1 \
    || fail "${label}: trace-summary.json must satisfy jq filter ${filter} (got: $(jq -c '.' "$SUMMARY" 2>/dev/null | head -c 400))"
}

# --- 2. Emission: <trace dir>/trace-summary.json, exact fixture numbers ----------
rc="$(run_report "$REPORT_SH" "$TRACE")"
[ "$rc" = "0" ] \
  || fail "path mode: expected exit 0, got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"

if [ ! -f "$SUMMARY" ]; then
  fail "running trace-report.sh must write the summary JSON beside the trace at <trace dir>/trace-summary.json (${SUMMARY}) — the emission seam is still a no-op"
else
  expect_summary "versioned"            '.summary_schema_version == 1 and (.summary_schema_version | type) == "number"'
  expect_summary "harness_versions carried through from the spans (strings, unique, sorted)" \
    '(.harness_versions | sort) == ["fix1234","fix5678"] and all(.harness_versions[]; type == "string")'
  expect_summary "issue number"         '.issue == 98 and (.issue | type) == "number"'
  expect_summary "finished flag"        '.finished == true'
  expect_summary "final outcome"        '.final_outcome == "pass"'
  expect_summary "bounded close edge"   '.bounded == true and .closed_by == "finish"'
  expect_summary "span_counts totals"   '.span_counts.total == 16 and .span_counts.invalid_lines == 2'
  expect_summary "span_counts by_type"  '.span_counts.by_type == {"agent":2,"lifecycle":6,"tool":8}'
  expect_summary "skills aggregate (#139: find-over-design, 1 call, 0 fail)" \
    '(.skills[] | select(.name == "find-over-design")) | .calls == 1 and .fail_calls == 0'
  expect_summary "coverage flags (#131: tool spans present, no model spans)" \
    '.coverage.has_tool_spans == true and .coverage.has_model_spans == false'
  expect_summary "stage pr_merge (2 spans, 400+600=1000 ms)" \
    '(.stages[] | select(.step == "pr_merge")) | .spans == 2 and .duration_ms == 1000'
  expect_summary "tool git (3 calls)" \
    '(.tools[] | select(.name == "git")) | .calls == 3'
  expect_summary "type-violating-but-parseable span aggregates (plan D1)" \
    '(.tools[] | select(.name == "typedrift-tool")) | .calls == 1'
  expect_summary "wall clock elapsed"   '.wall_clock.elapsed_seconds == 630'
  expect_summary "tokens null when no model spans (absence is null, plan D5)" \
    '.tokens == null and has("tokens")'

  # --- 3a. Null-vs-zero: absent duration is null, never 0 ------------------------
  expect_summary "red_handback stage duration is null (agent span carries no harness.duration_ms)" \
    '(.stages[] | select(.step == "red_handback")) | .spans == 1 and .duration_ms == null'

  # --- 4. Markdown/JSON agreement (plan D2 — one set of numbers) ------------------
  grep -Eq '(^|[^0-9])630([^0-9]|$)' "$OUT" \
    || fail "agreement: markdown must carry the same elapsed 630 the JSON reports"
  grep -Eq '[|][[:space:]]*git[[:space:]]*[|][[:space:]]*3[[:space:]]*[|]' "$OUT" \
    || fail "agreement: markdown must carry the same git calls=3 the JSON reports"
  grep -Eiq 'invalid lines: 2' "$OUT" \
    || fail "agreement: markdown must carry the same invalid_lines=2 the JSON reports"

  # --- 5. Idempotent overwrite (re-run: one document, same numbers) ---------------
  rc="$(run_report "$REPORT_SH" "$TRACE")"
  [ "$rc" = "0" ] \
    || fail "re-run: expected exit 0, got ${rc}"
  jq -es 'length == 1' "$SUMMARY" >/dev/null 2>&1 \
    || fail "re-run: trace-summary.json must hold exactly ONE JSON document (overwrite, never append)"
  expect_summary "re-run keeps the same numbers" \
    '.span_counts.total == 16 and .wall_clock.elapsed_seconds == 630'
fi

# --- 3b. Measured zero is preserved as 0, never nulled ----------------------------
ZERO_DIR="${TMP_DIR}/zero-home"
mkdir -p "$ZERO_DIR"
ZERO_TRACE="${ZERO_DIR}/trace.jsonl"
{
  printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T11:00:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"preflight","harness.duration_ms":0}'
  printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T11:00:01Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"zero-tool","harness.outcome":"pass","harness.duration_ms":0}'
  printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T11:00:02Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"finish","harness.outcome":"pass","harness.duration_ms":5}'
} > "$ZERO_TRACE"
rc="$(run_report "$REPORT_SH" "$ZERO_TRACE")"
[ "$rc" = "0" ] \
  || fail "zero fixture: expected exit 0, got ${rc}"
ZERO_SUMMARY="${ZERO_DIR}/trace-summary.json"
if [ ! -f "$ZERO_SUMMARY" ]; then
  fail "zero fixture: trace-summary.json not written beside ${ZERO_TRACE}"
else
  jq -e '(.stages[] | select(.step == "preflight")) | .duration_ms == 0' \
    "$ZERO_SUMMARY" >/dev/null 2>&1 \
    || fail "zero fixture: a MEASURED duration_ms of 0 must stay 0 in the stage table (0 = measured zero, null = no data — plan D5)"
  jq -e '(.tools[] | select(.name == "zero-tool")) | .duration_ms == 0' \
    "$ZERO_SUMMARY" >/dev/null 2>&1 \
    || fail "zero fixture: a MEASURED duration_ms of 0 must stay 0 in the tool table"
fi

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-summary.v1 contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-report summary-json contract honored\n'
