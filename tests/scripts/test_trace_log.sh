#!/usr/bin/env bash
# test_trace_log.sh — regression sensor for scripts/trace-lib.sh core log
# emission (issue #219, feature trace-log-core-emit).
#
# scripts/trace-lib.sh is the single sourceable telemetry primitive. Alongside
# `trace_span` (the shape stream), this feature adds `trace_log`, the detail
# stream: `trace_log <level> <message> [key=value...]` appends exactly one
# schema-v1 log record per call to the MAIN-root-pinned, append-only
# .copilot-tracking/issues/issue-NN/log.jsonl — a sibling of trace.jsonl. The
# authoritative contract is docs/evaluation/log-schema.v1.json:
#
#   required_common: log_schema_version (JSON number ==1), timestamp (ISO-8601
#   UTC), level (info|warn|error), harness.issue (JSON number, unpadded),
#   message (string). Optional: span_id (stamped from TRACE_LAST_SPAN_ID when
#   set, omitted otherwise), plus caller key=value attributes that fold in.
#
# This sensor mirrors test_trace_lib.sh's fixture pattern: a throwaway git repo
# on a feature/issue-07-* branch so trace__resolve_issue + trace__main_root
# resolve, sourcing the copied library under strict mode, then asserting the
# core emit contract. Redaction (F3) and the HARNESS_LOG kill switch (F4) are
# separate features with their own sensors — this one is scoped to core emit.
#
# Exit codes: 0 emit contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
SCHEMA="${ROOT}/docs/evaluation/log-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# jq drives log-record validation, so hard-require it the way the sibling
# sensors do.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace-lib log emission"

[ -f "$SCHEMA" ] \
  || fail "log schema contract not found at docs/evaluation/log-schema.v1.json (${SCHEMA})"

# RED gate: the library under test must exist before anything can be sourced.
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — the trace_log emitter for feature trace-log-core-emit (issue #219) is not implemented yet"

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }

nth_line() { sed -n "${2}p" "$1"; }

# --- Fixture: throwaway git repo faking an issue-07 worktree -------------------
REPO="${TMP_DIR}/myrepo"
mkdir -p "${REPO}/scripts"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
cd "$REPO"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf 'fixture\n' > README.md
git add README.md scripts/trace-lib.sh
git commit -q -m initial
git checkout -q -b feature/issue-07-trace-log-fixture

# The fixture must control issue resolution and span correlation: no ambient
# overrides leaking in from the developer's environment.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_LAST_SPAN_ID 2>/dev/null || true

LOG_FILE="${REPO}/.copilot-tracking/issues/issue-07/log.jsonl"

# --- 1. Sourcing works under strict mode and defines trace_log -----------------
# This script already runs under set -euo pipefail; a library that trips -e/-u
# on source would abort here. In the RED state trace_log does not exist yet, so
# the declare -F guard below is the expected point of failure.
# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh" \
  || fail "sourcing scripts/trace-lib.sh failed under set -euo pipefail"
declare -F trace_log >/dev/null \
  || fail "sourcing scripts/trace-lib.sh did not define a trace_log function (feature trace-log-core-emit is not implemented yet)"

# --- 2. First write creates dir + file with exactly one line -------------------
trace_log info "hello" \
  || fail "trace_log info \"hello\" returned non-zero"
[ -f "$LOG_FILE" ] \
  || fail "first trace_log call did not create the main-root-pinned .copilot-tracking/issues/issue-07/log.jsonl"
[ "$(line_count "$LOG_FILE")" = "1" ] \
  || fail "first trace_log call must append exactly one line (got $(line_count "$LOG_FILE"))"

# --- 3. That line is a valid record carrying every required common field -------
first_line="$(nth_line "$LOG_FILE" 1)"
printf '%s\n' "$first_line" | jq -e '
    (type == "object")
    and (.log_schema_version == 1)
    and (.level == "info")
    and ((.["harness.issue"] | type) == "number")
    and (.["harness.issue"] == 7)
    and (.message == "hello")
  ' >/dev/null \
  || fail "log record missing/incorrect required fields (need log_schema_version=1, level=\"info\", numeric harness.issue=7, message=\"hello\"): ${first_line}"
ts="$(printf '%s\n' "$first_line" | jq -r '.timestamp')"
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "timestamp is not ISO-8601 UTC (date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ), got '${ts}'"

# --- 4. Append-only: a second call appends without rewriting the first ---------
trace_log warn "second" \
  || fail "trace_log warn \"second\" returned non-zero"
[ "$(line_count "$LOG_FILE")" = "2" ] \
  || fail "log.jsonl must be append-only: expected 2 lines after a second trace_log call, got $(line_count "$LOG_FILE")"
[ "$(nth_line "$LOG_FILE" 1)" = "$first_line" ] \
  || fail "append truncated or rewrote existing lines: line 1 changed after a later trace_log call"
printf '%s\n' "$(nth_line "$LOG_FILE" 2)" \
  | jq -e '.level == "warn" and .message == "second"' >/dev/null \
  || fail "second record must carry level=\"warn\" and message=\"second\""

# --- 5. Unknown level is dropped (no new line) and returns 0 -------------------
trace_log bogus "x" \
  || fail "trace_log with an unknown level must return 0 (warn-and-drop, not hard-fail)"
[ "$(line_count "$LOG_FILE")" = "2" ] \
  || fail "unknown level 'bogus' must be dropped: no new line may be written (got $(line_count "$LOG_FILE") lines)"

# --- 6. Extra key=value folds into the record as an attribute -----------------
trace_log info "m" harness.stage=demo \
  || fail "trace_log info \"m\" harness.stage=demo returned non-zero"
[ "$(line_count "$LOG_FILE")" = "3" ] \
  || fail "key=value call must append exactly one line (got $(line_count "$LOG_FILE"))"
printf '%s\n' "$(nth_line "$LOG_FILE" 3)" \
  | jq -e '.["harness.stage"] == "demo" and .level == "info" and .message == "m"' >/dev/null \
  || fail "extra key=value (harness.stage=demo) must fold into the record as an attribute"

# --- 7. span_id correlation from TRACE_LAST_SPAN_ID (omit-never-fake) ----------
(
  export TRACE_LAST_SPAN_ID="deadbeef"
  trace_log info "m"
) || fail "trace_log under TRACE_LAST_SPAN_ID returned non-zero"
[ "$(line_count "$LOG_FILE")" = "4" ] \
  || fail "TRACE_LAST_SPAN_ID call must append exactly one line (got $(line_count "$LOG_FILE"))"
printf '%s\n' "$(nth_line "$LOG_FILE" 4)" \
  | jq -e '.span_id == "deadbeef"' >/dev/null \
  || fail "with TRACE_LAST_SPAN_ID=deadbeef exported, the record must carry span_id==\"deadbeef\""

# With TRACE_LAST_SPAN_ID unset, span_id must be ABSENT (omit, never fake).
unset TRACE_LAST_SPAN_ID 2>/dev/null || true
trace_log info "no-span" \
  || fail "trace_log without TRACE_LAST_SPAN_ID returned non-zero"
[ "$(line_count "$LOG_FILE")" = "5" ] \
  || fail "the span-less call must append exactly one line (got $(line_count "$LOG_FILE"))"
printf '%s\n' "$(nth_line "$LOG_FILE" 5)" \
  | jq -e 'has("span_id") | not' >/dev/null \
  || fail "with TRACE_LAST_SPAN_ID unset, the span_id key must be ABSENT (omit-never-fake), not empty or null"

printf 'trace-lib core log emission contract honored\n'
