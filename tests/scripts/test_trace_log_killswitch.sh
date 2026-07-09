#!/usr/bin/env bash
# test_trace_log_killswitch.sh — regression sensor for the HARNESS_LOG kill
# switch on scripts/trace-lib.sh trace_log (issue #219, feature
# trace-log-killswitch).
#
# trace_log is the detail stream: `trace_log <level> <message> [key=value...]`
# normally appends exactly one schema-v1 record per call to the
# MAIN-root-pinned .copilot-tracking/issues/issue-NN/log.jsonl. This feature
# adds an operator kill switch so log capture can be suppressed entirely:
#
#   HARNESS_LOG=0            → capture OFF. trace_log is a NOOP: it returns 0 and
#                             writes NO file and NO line (nothing appended even
#                             if a prior capture already created log.jsonl).
#   HARNESS_LOG unset        → capture ON (default). A line is written.
#   HARNESS_LOG=<non-zero>   → capture ON (e.g. HARNESS_LOG=1). A line is
#                             written.
#
# Only the literal value "0" disables capture; any other value (or unset) leaves
# capture on. The OFF path is proved with a negative assertion: a fresh dir
# yields no file, and an existing file's line count is unchanged.
#
# This sensor mirrors test_trace_log.sh's fixture pattern: a throwaway git repo
# on a feature/issue-07-* branch so trace__resolve_issue + trace__main_root
# resolve, sourcing the copied library under strict mode, then asserting the
# kill-switch contract.
#
# Exit codes: 0 kill-switch contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# jq drives log emission, so hard-require it the way the sibling sensors do.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to exercise trace-lib log emission"

# RED gate: the library under test must exist before anything can be sourced.
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — the trace_log emitter is not implemented yet"

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }

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
git checkout -q -b feature/issue-07-trace-log-killswitch-fixture

# The fixture must control issue resolution and span correlation: no ambient
# overrides leaking in from the developer's environment.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_LAST_SPAN_ID 2>/dev/null || true

LOG_FILE="${REPO}/.copilot-tracking/issues/issue-07/log.jsonl"

# --- Sourcing works under strict mode and defines trace_log --------------------
# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh" \
  || fail "sourcing scripts/trace-lib.sh failed under set -euo pipefail"
declare -F trace_log >/dev/null \
  || fail "sourcing scripts/trace-lib.sh did not define a trace_log function"

# --- 1. HARNESS_LOG=0 on a FRESH dir: NOOP — returns 0, writes no file ----------
[ ! -e "$LOG_FILE" ] \
  || fail "precondition: log.jsonl must not exist before the first capture"
HARNESS_LOG=0 trace_log info "hello" \
  || fail "with HARNESS_LOG=0, trace_log info \"hello\" must return 0 (kill switch is a NOOP, not a hard-fail)"
[ ! -e "$LOG_FILE" ] \
  || fail "with HARNESS_LOG=0 on a fresh dir, no log.jsonl may be created (kill switch must suppress all capture)"

# --- 2. HARNESS_LOG unset (default): capture ON — file created with one line ----
trace_log info "hello" \
  || fail "with HARNESS_LOG unset, trace_log info \"hello\" returned non-zero"
[ -f "$LOG_FILE" ] \
  || fail "with HARNESS_LOG unset (default), capture must be ON: log.jsonl was not created"
[ "$(line_count "$LOG_FILE")" = "1" ] \
  || fail "default capture must append exactly one line (got $(line_count "$LOG_FILE"))"

# --- 3. HARNESS_LOG=0 on an EXISTING file: line count unchanged (no append) -----
before="$(line_count "$LOG_FILE")"
HARNESS_LOG=0 trace_log warn "suppressed" \
  || fail "with HARNESS_LOG=0, trace_log must still return 0 even when log.jsonl already exists"
[ "$(line_count "$LOG_FILE")" = "$before" ] \
  || fail "with HARNESS_LOG=0, no new line may be appended to an existing log.jsonl (was ${before}, now $(line_count "$LOG_FILE"))"

# --- 4. HARNESS_LOG=1 (explicit non-zero): capture ON — a line is written -------
HARNESS_LOG=1 trace_log info "explicit" \
  || fail "with HARNESS_LOG=1, trace_log returned non-zero"
[ "$(line_count "$LOG_FILE")" = "$((before + 1))" ] \
  || fail "with HARNESS_LOG=1 (non-zero), capture must be ON: expected $((before + 1)) lines, got $(line_count "$LOG_FILE")"

printf 'trace_log HARNESS_LOG kill-switch contract honored\n'
