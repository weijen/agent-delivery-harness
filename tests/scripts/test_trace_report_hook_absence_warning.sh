#!/usr/bin/env bash
# test_trace_report_hook_absence_warning.sh — RED sensor for feature
# `hook-absence-warning` (issue #121).
#
# Contract under spec:
#   scripts/trace-report.sh must emit an explicit WARNING when a FINISHED
#   trace (has a `finish` lifecycle span, at least one lifecycle span, and at
#   least one agent span) contains ZERO `tool` spans. Zero tool spans in a
#   finished run means the Copilot hooks adapter was NOT installed, so
#   tool-call spans were never captured. Today the report renders an empty
#   Tool-calls table with no rows — a reader could misread that silence as
#   "the agent called no tools." The warning must reframe the silence as
#   *tracing-not-wired* (name the missing hooks adapter / unavailable tool
#   spans), NEVER let it read as a legitimate empty tool table.
#
#   When at least one `tool` span DOES exist, the warning must NOT fire.
#
# THE CONTRACT (what the implementer must satisfy):
#   * On a FINISHED trace with lifecycle+agent spans but zero tool spans,
#     trace-report.sh emits a line matching (case-insensitive):
#         warning .* (hook|adapter) .* tool
#     i.e. a line carrying the word WARNING, naming the hooks/adapter, and
#     tying it to tool spans. This sensor asserts the ERE:
#         warning
#       AND on the same warning line:  hook|adapter   AND   tool
#   * On a trace that HAS a tool span, no such WARNING line appears.
#
# RED today: the feature is unimplemented, so the warning is absent and the
# first assertion fails LOUDLY. That failure proves the sensor has teeth.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
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

# The fixture must control everything: no ambient trace overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the report and this sensor are jq-driven)"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB}) — trace-report.sh depends on it"
[ -f "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh not found (${REPORT_SH})"
[ -x "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh exists but is not executable (${REPORT_SH})"

# --- Fixture A: FINISHED trace, lifecycle + agent spans, ZERO tool spans --------
# This is the hooks-adapter-not-installed shape: the lifecycle ran to `finish`
# and an agent span exists, but no `tool` span was ever recorded.
write_no_tool_trace() {
  local f="$1"
  : > "$f"
  local ln
  for ln in \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":121,"harness.version":"fix1234","harness.lifecycle_step":"preflight","harness.exit_status":0,"harness.duration_ms":1200}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:05Z","span":"lifecycle","harness.issue":121,"harness.version":"fix1234","harness.lifecycle_step":"feature_start","harness.feature_id":"hook-absence-warning","harness.duration_ms":300}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:06:00Z","span":"agent","harness.issue":121,"harness.version":"fix1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:10:30Z","span":"lifecycle","harness.issue":121,"harness.version":"fix1234","harness.lifecycle_step":"finish","harness.outcome":"pass","harness.duration_ms":150}' \
    ; do
    printf '%s\n' "$ln" >> "$f"
  done
}

# --- Fixture B: FINISHED trace that DOES contain a tool span --------------------
# Same lifecycle+agent shape, plus one `tool` span → hooks adapter present,
# tool spans available → the warning must NOT fire.
write_with_tool_trace() {
  local f="$1"
  : > "$f"
  local ln
  for ln in \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":121,"harness.version":"fix1234","harness.lifecycle_step":"preflight","harness.exit_status":0,"harness.duration_ms":1200}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:05Z","span":"lifecycle","harness.issue":121,"harness.version":"fix1234","harness.lifecycle_step":"feature_start","harness.feature_id":"hook-absence-warning","harness.duration_ms":300}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:03:00Z","span":"tool","harness.issue":121,"harness.version":"fix1234","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":5}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:06:00Z","span":"agent","harness.issue":121,"harness.version":"fix1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:10:30Z","span":"lifecycle","harness.issue":121,"harness.version":"fix1234","harness.lifecycle_step":"finish","harness.outcome":"pass","harness.duration_ms":150}' \
    ; do
    printf '%s\n' "$ln" >> "$f"
  done
}

TRACE_NO_TOOL="${TMP_DIR}/trace-no-tool.jsonl"
TRACE_WITH_TOOL="${TMP_DIR}/trace-with-tool.jsonl"
write_no_tool_trace "$TRACE_NO_TOOL"
write_with_tool_trace "$TRACE_WITH_TOOL"

# --- Fixture self-checks: the planted shapes must actually be on disk -----------
# Fixture A: finish span present, agent span present, ZERO tool spans.
jq -e 'select(.["harness.lifecycle_step"] == "finish")' "$TRACE_NO_TOOL" >/dev/null 2>&1 \
  || hard_fail "fixture A must contain a finish lifecycle span"
jq -e 'select(.span == "agent")' "$TRACE_NO_TOOL" >/dev/null 2>&1 \
  || hard_fail "fixture A must contain an agent span"
if jq -e 'select(.span == "tool")' "$TRACE_NO_TOOL" >/dev/null 2>&1; then
  hard_fail "fixture A was supposed to contain ZERO tool spans"
fi
# Fixture B: finish span present AND at least one tool span present.
jq -e 'select(.["harness.lifecycle_step"] == "finish")' "$TRACE_WITH_TOOL" >/dev/null 2>&1 \
  || hard_fail "fixture B must contain a finish lifecycle span"
jq -e 'select(.span == "tool")' "$TRACE_WITH_TOOL" >/dev/null 2>&1 \
  || hard_fail "fixture B was supposed to contain at least one tool span"

# --- Run helper -----------------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_report() {
  local rc=0
  "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# grep the combined stdout+stderr for the warning line: a single line carrying
# WARNING that names the hooks/adapter AND ties it to tool spans.
warning_line() {
  grep -Ei 'warning' "$OUT" "$ERR" 2>/dev/null \
    | grep -Ei 'hook|adapter' \
    | grep -Ei 'tool' \
    | head -n 1
}

# --- Assertion 1 (RED today): warning FIRES on the zero-tool finished trace -----
rc="$(run_report "$REPORT_SH" "$TRACE_NO_TOOL")"
[ "$rc" = "0" ] \
  || fail "zero-tool trace: expected exit 0 (a report was producible — the warning is advisory, not gating), got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"

wline="$(warning_line || true)"
if [ -z "$wline" ]; then
  fail "MISSING WARNING (this is the RED state): a FINISHED trace with lifecycle+agent spans but ZERO tool spans must emit a WARNING line matching /warning/i AND /hook|adapter/i AND /tool/i on the same line — naming the missing Copilot hooks adapter / unavailable tool spans so the empty Tool-calls table is NOT misread as 'the agent called no tools'. No such line was found. stdout+stderr was: $(cat "$OUT" "$ERR" | tr '\n' '|')"
fi

# --- Assertion 2: warning is ABSENT when a tool span exists ---------------------
rc="$(run_report "$REPORT_SH" "$TRACE_WITH_TOOL")"
[ "$rc" = "0" ] \
  || fail "with-tool trace: expected exit 0, got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"

wline_present="$(warning_line || true)"
if [ -n "$wline_present" ]; then
  fail "FALSE POSITIVE: a trace that DOES contain a tool span must NOT emit the hook-absence WARNING, but one was found: ${wline_present}"
fi

# --- Result ---------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d hook-absence-warning contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'hook-absence-warning contract honored\n'
