#!/usr/bin/env bash
# test_trace_log_redaction.sh — regression sensor for scripts/trace-lib.sh
# trace_log secret redaction + bounded payload (issue #219, feature
# trace-log-redaction).
#
# trace_log is the detail stream (log.jsonl), a sibling of trace.jsonl. Feature
# trace-log-core-emit landed the emitter WITHOUT redaction or a payload cap;
# this feature adds them. The contract (docs/evaluation/log-schema.v1.json
# "redaction" block) is redact-before-cap:
#
#   Secret-shaped input is redacted BEFORE any truncation, so a truncation
#   boundary can NEVER bisect and leak a partially-redacted secret. The
#   per-record `payload` attribute is then bounded to HARNESS_LOG_PAYLOAD_CAP
#   bytes (default 4096). Redaction always precedes the cap.
#
# Per the redaction authorities (docs/evaluation/security-evals.md,
# docs/evaluation/dataset-governance.md) every planted secret below is
# SYNTHETIC — shaped like a credential, never a real one. This sensor mirrors
# the fixture pattern of test_trace_log.sh (throwaway git repo on a
# feature/issue-07-* branch) and the redaction-sensor pattern of
# test_trace_lib_redaction.sh, reusing scripts/trace-lib.sh trace_redact.
#
# It asserts (proving each failure mode with a NEGATIVE assertion — the secret
# must be ABSENT, not merely masked-somewhere):
#
#   1. A ghp_-shaped secret in the `message` argument never appears in
#      log.jsonl; [REDACTED] stands in; the line is still valid JSON.
#   2. AKIA-/api_key=-shaped secrets in a `payload=<text>` argument never
#      appear on disk; [REDACTED] stands in; the line is still valid JSON.
#   3. redact-before-cap (the crux): with a small HARNESS_LOG_PAYLOAD_CAP, a
#      secret STRADDLING the cap byte boundary is FULLY ABSENT from disk — not
#      a truncated `ghp_...` prefix. A cap-first implementation would truncate
#      mid-secret into an ~8-char fragment the redactor can no longer match and
#      leak the `ghp_` prefix; redact-first cannot.
#   4. An oversized innocent `payload` (longer than the cap) is truncated so
#      the stored payload field's byte length is <= the cap.
#   5. Innocents survive un-mangled: a normal message and payload=hello world
#      are intact and carry no [REDACTED] marker.
#
# Exit codes: 0 redaction + bounded-payload contract honored · 1 a planted
# secret reached log.jsonl on disk or a bound/JSON obligation regressed.

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
  || fail "jq is required to validate trace_log redaction"

[ -f "$SCHEMA" ] \
  || fail "log schema contract not found at docs/evaluation/log-schema.v1.json (${SCHEMA})"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — the trace_log emitter is not available"

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }

nth_line() { sed -n "${2}p" "$1"; }

byte_len() { printf '%s' "$1" | wc -c | tr -d '[:space:]'; }

# --- Planted SYNTHETIC secrets (never real; dataset-governance.md) --------------
# ghp_ + 36 word chars (redactor needs >=20); AKIA + 16 upper/digits.
GHP_SECRET='ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ'
AKIA_SECRET='AKIAABCDEFGH12345678'
APIKEY_SECRET='synthkey-0451-abcdef'

# --- Fixture: throwaway git repo faking an issue-07 worktree --------------------
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
git checkout -q -b feature/issue-07-trace-log-redaction-fixture

# The fixture must control issue resolution + span correlation: no ambient leak.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_LAST_SPAN_ID 2>/dev/null || true

LOG_FILE="${REPO}/.copilot-tracking/issues/issue-07/log.jsonl"

# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh" \
  || fail "sourcing scripts/trace-lib.sh failed under set -euo pipefail"
declare -F trace_log >/dev/null \
  || fail "scripts/trace-lib.sh did not define a trace_log function"
declare -F trace_redact >/dev/null \
  || fail "scripts/trace-lib.sh did not define a trace_redact function to reuse"

# --- Emit records --------------------------------------------------------------
# Lines 1-3 use the DEFAULT payload cap (no small cap should truncate the
# [REDACTED] marker); lines 4-5 exercise the small-cap redact-before-cap crux.

# Line 1: ghp_ secret embedded in the free-text MESSAGE argument.
trace_log info "cloning repo with ${GHP_SECRET} now" \
  || fail "trace_log (ghp_ secret in message) returned non-zero"

# Line 2: AKIA + api_key= secrets embedded in a payload=<text> attribute.
trace_log info "gate output excerpt" \
  "payload=aws ${AKIA_SECRET} then api_key=${APIKEY_SECRET} done" \
  || fail "trace_log (AKIA/api_key secrets in payload) returned non-zero"

# Line 3: fully innocent message + payload (must survive un-mangled).
trace_log info "normal message" "payload=hello world" \
  || fail "trace_log (innocent message + payload) returned non-zero"

# Line 4: redact-before-cap crux. A 20-byte innocent filler places the ghp_
# secret STRADDLING the 32-byte cap boundary. Cap-first truncates the payload
# to filler(20) + "ghp_abcdefgh" (an 8-char body the redactor can no longer
# match) and leaks the ghp_ prefix; redact-first masks the whole secret first.
STRADDLE_FILLER='PADpadPADpadPADpad12'
HARNESS_LOG_PAYLOAD_CAP=32 \
  trace_log info "straddle" "payload=${STRADDLE_FILLER}${GHP_SECRET}" \
  || fail "trace_log (redact-before-cap straddle) returned non-zero"

# Line 5: oversized INNOCENT payload (100 bytes) must be truncated to the cap.
BIG_INNOCENT="$(printf 'a%.0s' {1..100})"
HARNESS_LOG_PAYLOAD_CAP=32 \
  trace_log info "oversized" "payload=${BIG_INNOCENT}" \
  || fail "trace_log (oversized innocent payload) returned non-zero"

[ -f "$LOG_FILE" ] \
  || fail "trace_log calls did not create ${LOG_FILE}"
[ "$(line_count "$LOG_FILE")" = "5" ] \
  || fail "expected exactly 5 emitted lines, got $(line_count "$LOG_FILE")"

# --- 1 & 2. No planted secret literal reaches the bytes on disk -----------------
assert_absent() {
  local label="$1" literal="$2"
  if grep -qF -- "$literal" "$LOG_FILE"; then
    fail "planted synthetic ${label} secret reached log.jsonl on disk: ${literal}"
  fi
}
assert_absent "ghp_ (message + straddle payload)" "$GHP_SECRET"
assert_absent "AKIA (payload)" "$AKIA_SECRET"
assert_absent "api_key= (payload)" "$APIKEY_SECRET"

# The [REDACTED] marker must stand in on both secret-carrying default-cap lines,
# and each such line must remain valid JSON.
for i in 1 2; do
  line="$(nth_line "$LOG_FILE" "$i")"
  printf '%s\n' "$line" | grep -qF '[REDACTED]' \
    || fail "secret-carrying line ${i} carries no [REDACTED] marker: ${line}"
  printf '%s\n' "$line" | jq empty 2>/dev/null \
    || fail "secret-carrying line ${i} is not valid JSON after redaction: ${line}"
done

# --- 3. redact-before-cap: no ghp_ prefix fragment survives on the straddle line
line4="$(nth_line "$LOG_FILE" 4)"
if printf '%s\n' "$line4" | grep -qF 'ghp_'; then
  fail "redact-before-cap violated: a truncated ghp_ prefix leaked on the straddle line (cap-first bisected the secret): ${line4}"
fi
printf '%s\n' "$line4" | jq empty 2>/dev/null \
  || fail "straddle line is not valid JSON after redact-before-cap: ${line4}"

# --- 4. Oversized innocent payload is truncated to at most the cap --------------
line5="$(nth_line "$LOG_FILE" 5)"
printf '%s\n' "$line5" | jq empty 2>/dev/null \
  || fail "oversized-payload line is not valid JSON: ${line5}"
payload5="$(printf '%s\n' "$line5" | jq -r '.payload')"
plen="$(byte_len "$payload5")"
[ "$plen" -le 32 ] \
  || fail "payload was not bounded to HARNESS_LOG_PAYLOAD_CAP=32 bytes (stored payload is ${plen} bytes): ${line5}"

# --- 5. Innocents survive un-mangled -------------------------------------------
line3="$(nth_line "$LOG_FILE" 3)"
printf '%s\n' "$line3" | jq -e '.message == "normal message" and .payload == "hello world"' >/dev/null \
  || fail "innocent message/payload were mangled: ${line3}"
if printf '%s\n' "$line3" | grep -qF '[REDACTED]'; then
  fail "innocent line 3 was wrongly redacted: ${line3}"
fi

printf 'trace_log redaction + bounded-payload contract honored\n'
