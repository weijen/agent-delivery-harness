#!/usr/bin/env bash
# test_trace_report_log_failures.sh — regression sensor for the additive
# log-derived gate-failure surface in `scripts/trace-report.sh` (issue #221,
# feature trace-report-log-failures, feature 2 of 4).
#
# Executable spec for the ONE additive behavior this feature adds: the report
# reads the sibling `log.jsonl` (same directory as the resolved `trace.jsonl`,
# the detail stream defined by docs/evaluation/log-schema.v1.json) and surfaces
# gate-failure counts on a NEW top-level summary key `log_failures`, plus a
# markdown rendering — without ever crashing (exit 0, silent stderr on every
# leg; the never-crash / reporting-is-not-gating contract of trace-report.sh).
#
# A log record (per log-schema.v1.json and scripts/trace-lib.sh `trace_log`) is
# a JSON object with FLAT DOTTED keys, e.g.:
#   {"log_schema_version":1,"timestamp":"2026-07-04T12:00:00Z","level":"error",
#    "harness.issue":221,"message":"push rejected","harness.stage":"push",
#    "harness.outcome":"fail"}
# The version key is log_schema_version (NOT the span schema's schema_version),
# level is one of info|warn|error, and harness.outcome is one of
# pass|fail|blocked. A gate FAILURE is a record where
#   level == "error"  AND  ."harness.outcome" == "fail"
# grouped by ."harness.stage".
#
# Metrics-honesty doctrine (shared with the robustness sensor — null = no data,
# 0 = a measured zero, {} = the detector ran and found nothing):
#
#   1. ABSENT (no sibling log.jsonl): log_failures is EXPLICIT null (absence,
#      NOT 0); the markdown states log detail is unavailable ("log evidence
#      unavailable" / "log detail unavailable") — never a fabricated 0.
#   2. PRESENT WITH FAILURES: log_failures ==
#        { "total": <int>, "by_stage": { "<harness.stage>": <int>, ... } }
#      counting only error+fail records, grouped by harness.stage; the markdown
#      renders the counts (total + per-stage).
#   3. PRESENT BUT NO FAILURES (only info/warn records): log_failures ==
#        { "total": 0, "by_stage": {} }
#      a MEASURED zero (the file was read and no failures were found), NOT null;
#      the markdown renders 0.
#
# Every leg also asserts the never-crash contract: exit 0 and silent stderr,
# with a parseable trace-summary.json written beside the trace.
#
# RED status at authoring time (documented honestly): the current
# scripts/trace-report.sh emits NO log_failures key, so `.log_failures` is
# absent (jq null) on every leg — the absent leg's markdown assertion and BOTH
# present legs' JSON assertions fail until the feature is implemented.
#
# Exit codes: 0 log-failure surface contract honored · 1 a contract obligation
# regressed.

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

# The fixture must control everything: no ambient trace/log overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the report and this sensor are jq-driven)"
[ -f "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh not found (${REPORT_SH})"
[ -x "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh exists but is not executable (${REPORT_SH})"

OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"

# run_report <cmd...> → prints exit code; stdout/stderr land in $OUT/$ERR.
run_report() {
  local rc=0
  (
    cd "$TMP_DIR" || exit 9
    exec "$@"
  ) >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# expect_ok <label> <trace> — exit 0, silent stderr, parseable summary JSON
# written beside the trace (never-crash contract). Accumulates fails.
expect_ok() {
  local label="$1" trace="$2" rc
  rc="$(run_report "$REPORT_SH" "$trace")"
  if [ "$rc" != "0" ]; then
    fail "${label}: expected exit 0 (never crashes, reporting never gates), got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"
  fi
  if [ -s "$ERR" ]; then
    fail "${label}: stderr must stay silent on a successful report, got: $(tr '\n' '|' < "$ERR")"
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
  [ -f "$file" ] || { fail "${label}: summary JSON missing (${file})"; return; }
  jq -e "$filter" "$file" >/dev/null 2>&1 \
    || fail "${label}: summary must satisfy jq filter ${filter} (got: $(jq -c '.log_failures' "$file" 2>/dev/null | head -c 400))"
}

# A minimal FINISHED trace so the base report renders normally; the log-failure
# surface is orthogonal to span aggregation.
C='"schema_version":1,"harness.issue":221,"harness.version":"fix221"'
write_trace() {
  local f="$1"
  {
    printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:00:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"preflight\",\"harness.duration_ms\":50}"
    printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:05:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":10}"
  } > "$f"
}

# --- Leg 1: ABSENT — no sibling log.jsonl → log_failures null ------------------
ABSENT_DIR="${TMP_DIR}/absent"
mkdir -p "$ABSENT_DIR"
write_trace "${ABSENT_DIR}/trace.jsonl"
[ ! -e "${ABSENT_DIR}/log.jsonl" ] \
  || hard_fail "leg-absent fixture must NOT have a sibling log.jsonl"
expect_ok "absent log" "${ABSENT_DIR}/trace.jsonl"
S="${ABSENT_DIR}/trace-summary.json"
expect_json "absent: log_failures is EXPLICIT null (absence, not 0) and the key is present" \
  "$S" '.log_failures == null and has("log_failures")'
grep -Eiq 'log.*(unavailable|not available)' "$OUT" \
  || fail "absent markdown: must state log detail/evidence is unavailable (absence, never a fabricated 0), stdout was: $(tr '\n' '|' < "$OUT")"

# --- Leg 2: PRESENT WITH FAILURES — two error+fail records (one per stage) -----
FAIL_DIR="${TMP_DIR}/with-failures"
mkdir -p "$FAIL_DIR"
write_trace "${FAIL_DIR}/trace.jsonl"
{
  # push: an error+fail gate failure
  printf '%s\n' '{"log_schema_version":1,"timestamp":"2026-07-04T12:01:00Z","level":"error","harness.issue":221,"message":"push rejected by remote","harness.stage":"push","harness.outcome":"fail"}'
  # ci_checks: an error+fail gate failure
  printf '%s\n' '{"log_schema_version":1,"timestamp":"2026-07-04T12:02:00Z","level":"error","harness.issue":221,"message":"ci checks red","harness.stage":"ci_checks","harness.outcome":"fail"}'
  # info record — must NOT be counted as a failure
  printf '%s\n' '{"log_schema_version":1,"timestamp":"2026-07-04T12:03:00Z","level":"info","harness.issue":221,"message":"pushing branch","harness.stage":"push","harness.outcome":"pass"}'
} > "${FAIL_DIR}/log.jsonl"
expect_ok "present-with-failures log" "${FAIL_DIR}/trace.jsonl"
S="${FAIL_DIR}/trace-summary.json"
expect_json "with-failures: total counts only error+fail records (info excluded)" \
  "$S" '.log_failures.total == 2'
expect_json "with-failures: by_stage groups error+fail by harness.stage" \
  "$S" '.log_failures.by_stage == {"push": 1, "ci_checks": 1}'
grep -Eiq 'log[^0-9]*(failure|fail)[^0-9]*2([^0-9]|$)' "$OUT" \
  || fail "with-failures markdown: a log-failures line must render the failure total 2, stdout was: $(tr '\n' '|' < "$OUT")"
grep -Fq 'push' "$OUT" \
  || fail "with-failures markdown: must render the push stage count"
grep -Fq 'ci_checks' "$OUT" \
  || fail "with-failures markdown: must render the ci_checks stage count"

# --- Leg 3: PRESENT BUT NO FAILURES — only info/warn → measured zero ----------
NONE_DIR="${TMP_DIR}/present-none"
mkdir -p "$NONE_DIR"
write_trace "${NONE_DIR}/trace.jsonl"
{
  printf '%s\n' '{"log_schema_version":1,"timestamp":"2026-07-04T12:01:00Z","level":"info","harness.issue":221,"message":"pushing branch","harness.stage":"push","harness.outcome":"pass"}'
  printf '%s\n' '{"log_schema_version":1,"timestamp":"2026-07-04T12:02:00Z","level":"warn","harness.issue":221,"message":"rebase needed a retry","harness.stage":"rebase","harness.outcome":"pass"}'
} > "${NONE_DIR}/log.jsonl"
expect_ok "present-none log" "${NONE_DIR}/trace.jsonl"
S="${NONE_DIR}/trace-summary.json"
expect_json "present-none: total is a MEASURED zero (file read, no failures) — 0 not null" \
  "$S" '.log_failures.total == 0 and .log_failures != null'
expect_json "present-none: by_stage is empty object (detector ran, found nothing) — {} not null" \
  "$S" '.log_failures.by_stage == {}'
grep -Eiq 'log.*(failure|fail).*(^|[^0-9])0([^0-9]|$)|(^|[^0-9])0([^0-9]|$).*log.*(failure|fail)' "$OUT" \
  || grep -Eiq 'log (failures|fail)[^:]*:?[[:space:]]*0([^0-9]|$)' "$OUT" \
  || fail "present-none markdown: must render a measured 0 for log failures (not 'unavailable'), stdout was: $(tr '\n' '|' < "$OUT")"

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d log-failure surface contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-report log-failure surface contract honored\n'
