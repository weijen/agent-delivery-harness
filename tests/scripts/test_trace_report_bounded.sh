#!/usr/bin/env bash
# test_trace_report_bounded.sh — regression sensor for issue #170:
# trace-report distinguishes traces bounded by a terminal close edge
# (finish or pr_merge) from truly open/unbounded runs without redefining
# finished or final_outcome.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
SCRATCH_ROOT="${ROOT}/.copilot-tracking/test-scratch"
TMP_DIR="${SCRATCH_ROOT}/test-trace-report-bounded-$$"
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
  || hard_fail "jq is required (the summary contract and this sensor are jq-driven)"
[ -f "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh not found (${REPORT_SH})"
[ -x "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh exists but is not executable (${REPORT_SH})"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

write_finish_and_pr_merge_trace() {
  local f="$1"
  {
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-08T10:00:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"preflight","harness.duration_ms":100}'
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-08T10:01:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"pr_merge","harness.duration_ms":200}'
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-08T10:02:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"finish","harness.outcome":"pass","harness.duration_ms":300}'
  } > "$f"
}

write_pr_merge_only_trace() {
  local f="$1"
  {
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-08T11:00:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"preflight","harness.duration_ms":100}'
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-08T11:01:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"pr_merge","harness.duration_ms":200}'
  } > "$f"
}

write_open_trace() {
  local f="$1"
  {
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-08T12:00:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"preflight","harness.duration_ms":100}'
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-08T12:01:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"feature_start","harness.feature_id":"bounded-vs-open-close-edge","harness.duration_ms":200}'
  } > "$f"
}

run_case() {
  local label="$1" writer="$2"
  local dir="${TMP_DIR}/${label}"
  mkdir -p "$dir"
  "$writer" "${dir}/trace.jsonl"
  local rc=0
  (
    cd "$TMP_DIR" || exit 9
    "$REPORT_SH" "${dir}/trace.jsonl"
  ) >"${dir}/out.md" 2>"${dir}/err.txt" || rc=$?
  [ "$rc" = "0" ] \
    || fail "${label}: expected trace-report.sh exit 0, got ${rc} (stderr: $(tr '\n' '|' < "${dir}/err.txt"))"
}

expect_summary() {
  local label="$1" filter="$2"
  local summary="${TMP_DIR}/${label}/trace-summary.json"
  if [ ! -f "$summary" ]; then
    fail "${label}: trace-report.sh must write ${summary}"
    return
  fi
  jq -e "$filter" "$summary" >/dev/null 2>&1 \
    || fail "${label}: trace-summary.json must satisfy ${filter} (got: $(jq -c '.' "$summary" 2>/dev/null | head -c 500))"
}

expect_markdown() {
  local label="$1" ere="$2" message="$3"
  grep -Eiq "$ere" "${TMP_DIR}/${label}/out.md" \
    || fail "${label}: ${message} (stdout was: $(tr '\n' '|' < "${TMP_DIR}/${label}/out.md"))"
}

reject_markdown() {
  local label="$1" fixed="$2" message="$3"
  if grep -Fqi "$fixed" "${TMP_DIR}/${label}/out.md"; then
    fail "${label}: ${message} (stdout was: $(tr '\n' '|' < "${TMP_DIR}/${label}/out.md"))"
  fi
}

run_case "finish-and-pr-merge" write_finish_and_pr_merge_trace
expect_summary "finish-and-pr-merge" '.finished == true'
expect_summary "finish-and-pr-merge" 'has("bounded") and .bounded == true'
expect_summary "finish-and-pr-merge" 'has("closed_by") and .closed_by == "finish"'
expect_summary "finish-and-pr-merge" '.final_outcome == "pass"'
expect_markdown "finish-and-pr-merge" 'Final outcome:[[:space:]]*pass' \
  "markdown must show the finish outcome as 'Final outcome: pass'"

run_case "pr-merge-only" write_pr_merge_only_trace
expect_summary "pr-merge-only" '.finished == false'
expect_summary "pr-merge-only" 'has("bounded") and .bounded == true'
expect_summary "pr-merge-only" 'has("closed_by") and .closed_by == "pr_merge"'
expect_summary "pr-merge-only" '.final_outcome == null'
reject_markdown "pr-merge-only" "unfinished run" \
  "pr_merge-bounded trace must not be called an unfinished run"
expect_markdown "pr-merge-only" 'attribution window.*bounded by.*pr_merge|bounded by.*pr_merge.*attribution window' \
  "markdown must say the attribution window is bounded by pr_merge"

run_case "open-unbounded" write_open_trace
expect_summary "open-unbounded" '.finished == false'
expect_summary "open-unbounded" 'has("bounded") and .bounded == false'
expect_summary "open-unbounded" 'has("closed_by") and .closed_by == null'
expect_summary "open-unbounded" '.final_outcome == null'
expect_markdown "open-unbounded" 'open|unbounded|not[- ]bounded' \
  "markdown must indicate an open/not-bounded run when no terminal close edge exists"

if [ "$fails" -ne 0 ]; then
  printf '\n%d bounded-vs-open-close-edge contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-report bounded/open close-edge contract honored\n'
