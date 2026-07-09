#!/usr/bin/env bash
# test_trace_log_failure_capture.sh — regression sensor for the trace_log
# gate/sensor FAILURE-CAPTURE capability (issue #219, feature
# trace-log-failure-capture).
#
# trace_log (scripts/trace-lib.sh) is the detail stream (log.jsonl), a sibling
# of trace.jsonl. Prior features landed its `error` level, the redact-then-cap
# `payload=` attribute (bounded to HARNESS_LOG_PAYLOAD_CAP), and arbitrary
# harness.* attribute folding. This feature is a CAPABILITY PROOF: it shows that
# when a gate/sensor FAILS, trace_log can capture the full (bounded, redacted)
# failure output at `error` level with harness.outcome=fail and the output in
# `payload`, while a PASSING gate writes NO error line. Issue #221 will wire this
# into real gates; #219 proves it with a self-contained FIXTURE gate — no
# review-gate.sh wiring here.
#
# The sensor mirrors test_trace_log.sh's fixture pattern (a throwaway git repo on
# a feature/issue-07-* branch so trace__resolve_issue + trace__main_root
# resolve) and defines two fixture "gate" functions:
#
#   * a FAILING gate — returns non-zero and emits multi-line output longer than a
#     deliberately small HARNESS_LOG_PAYLOAD_CAP; a wrapper captures that output
#     and, only on failure, calls
#       trace_log error "gate <name> failed" \
#         harness.outcome=fail harness.stage=<gate> payload="$gate_output"
#   * a PASSING gate — returns 0 and, on the success path, calls trace_log NOT
#     AT ALL.
#
# It asserts, on log.jsonl:
#   1. Exactly one error-level line: level=="error", harness.outcome=="fail",
#      harness.stage set, message mentions the gate, non-empty payload present.
#   2. The stored payload is BOUNDED: byte length <= HARNESS_LOG_PAYLOAD_CAP.
#   3. That line is valid JSON.
#   4. The PASSING gate writes NO error line (negative assertion: zero
#      error-level lines from the success path — proves the failure mode, not
#      just the happy path).
#   5. Redaction still holds: a synthetic ghp_-shaped secret in the failure
#      output never reaches disk; [REDACTED] stands in.
#
# Exit codes: 0 the failure-capture capability holds · 1 a contract obligation
# regressed (or a planted secret reached disk).

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

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace_log failure capture"

[ -f "$SCHEMA" ] \
  || fail "log schema contract not found at docs/evaluation/log-schema.v1.json (${SCHEMA})"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — the trace_log emitter is not available"

# --- Helpers -------------------------------------------------------------------
byte_len() { printf '%s' "$1" | wc -c | tr -d '[:space:]'; }

# error-level line count that is safe when the log file does not exist yet.
error_line_count() {
  [ -f "$LOG_FILE" ] || { printf '0'; return 0; }
  jq -c 'select(.level == "error")' "$LOG_FILE" 2>/dev/null | grep -c . || true
}

# Bounded payload cap the fixture gate output must overflow.
CAP=128

# --- Planted SYNTHETIC secret (never real; dataset-governance.md) --------------
# ghp_ + 36 word chars (redactor needs >=20). Placed at the START of the failure
# output so redaction (redact-before-cap) keeps the [REDACTED] marker inside the
# small cap window — proving redaction, not mere truncation.
GHP_SECRET='ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

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
git checkout -q -b feature/issue-07-trace-log-failure-capture-fixture

# The fixture must control issue resolution + span correlation: no ambient leak.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_LAST_SPAN_ID 2>/dev/null || true

LOG_FILE="${REPO}/.copilot-tracking/issues/issue-07/log.jsonl"

# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh" \
  || fail "sourcing scripts/trace-lib.sh failed under set -euo pipefail"
declare -F trace_log >/dev/null \
  || fail "scripts/trace-lib.sh did not define a trace_log function"

# --- Fixture gates -------------------------------------------------------------
# A PASSING gate: succeeds and does NOT log on the success path.
passing_gate() {
  printf 'all checks green\n'
  return 0
}

# A FAILING gate: emits multi-line output longer than CAP, then fails. The first
# line carries the synthetic secret so redaction is exercised.
failing_gate() {
  printf 'boom: authenticating with %s\n' "$GHP_SECRET"
  local i
  for i in $(seq 1 40); do
    printf 'stack frame %02d: deep in the failing gate machinery\n' "$i"
  done
  return 1
}

# Wrapper that mirrors the issue-#221 pattern: run a gate, capture combined
# output, and ONLY on failure emit the bounded error record.
run_gate() {
  local name="$1"
  local out rc
  if out="$("$name" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    HARNESS_LOG_PAYLOAD_CAP="$CAP" \
      trace_log error "gate ${name} failed" \
        harness.outcome=fail harness.stage="$name" payload="$out" \
      || fail "trace_log error failure-capture call returned non-zero for ${name}"
  fi
  return 0
}

# --- 4 (negative first). A PASSING gate writes NO error line -------------------
run_gate passing_gate
[ "$(error_line_count)" = "0" ] \
  || fail "a PASSING fixture gate must write ZERO error-level lines (got $(error_line_count)) — the success path must not call trace_log error"

# --- Positive. A FAILING gate captures its bounded, redacted output ------------
run_gate failing_gate
[ -f "$LOG_FILE" ] \
  || fail "the failing gate did not create ${LOG_FILE}"

# --- 1. Exactly one error line carrying the full failure-capture shape ---------
[ "$(error_line_count)" = "1" ] \
  || fail "expected exactly ONE error-level line after the failing gate (got $(error_line_count))"

err_line="$(jq -c 'select(.level == "error")' "$LOG_FILE")"
printf '%s\n' "$err_line" | jq -e '
    (.level == "error")
    and (.["harness.outcome"] == "fail")
    and ((.["harness.stage"] // "") | length > 0)
    and (.message | test("failing_gate"))
    and ((.payload // "") | length > 0)
  ' >/dev/null \
  || fail "error line missing the failure-capture contract (need level=error, harness.outcome=fail, non-empty harness.stage, message mentioning the gate, non-empty payload): ${err_line}"

# --- 3. That line is valid JSON ------------------------------------------------
printf '%s\n' "$err_line" | jq empty 2>/dev/null \
  || fail "the error-level line is not valid JSON: ${err_line}"

# --- 2. The stored payload is BOUNDED to HARNESS_LOG_PAYLOAD_CAP ----------------
payload="$(printf '%s\n' "$err_line" | jq -r '.payload')"
plen="$(byte_len "$payload")"
[ "$plen" -le "$CAP" ] \
  || fail "captured payload was not bounded to HARNESS_LOG_PAYLOAD_CAP=${CAP} bytes (stored payload is ${plen} bytes): ${err_line}"

# --- 5. Redaction still holds: the synthetic secret never reaches disk ---------
if grep -qF -- "$GHP_SECRET" "$LOG_FILE"; then
  fail "planted synthetic ghp_ secret reached log.jsonl on disk in the captured payload: ${GHP_SECRET}"
fi
printf '%s\n' "$payload" | grep -qF '[REDACTED]' \
  || fail "captured payload carries no [REDACTED] marker where the synthetic secret was: ${payload}"

printf 'trace_log gate/sensor failure-capture capability honored\n'
