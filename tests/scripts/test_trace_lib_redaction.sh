#!/usr/bin/env bash
# test_trace_lib_redaction.sh — regression sensor for scripts/trace-lib.sh
# built-in secret redaction (issue #93, feature trace-lib-redaction).
#
# trace_redact runs over the fully-serialized span line immediately before
# append (plan D3), so no field can bypass it. Per the redaction authorities
# (docs/evaluation/security-evals.md, docs/evaluation/dataset-governance.md)
# every planted secret below is SYNTHETIC — shaped like a credential, never a
# real one. This sensor builds a throwaway git repo fixture (same pattern as
# test_trace_lib.sh), emits spans whose values carry the planted secret
# shapes, and asserts:
#
#   1. None of the planted secret literals appears anywhere in the trace.jsonl
#      bytes on disk: ghp_/gho_ (36 token chars), github_pat_, AKIA + 16
#      uppercase/digits, Bearer eyJ... header values, and generic
#      password/api_key/secret/token key=value shapes.
#   2. The library's replacement marker [REDACTED] is present on every
#      secret-carrying line instead (key kept, value masked).
#   3. Every redacted line is still valid JSON and still passes the
#      contract-driven jq filter lifted verbatim from the TRACE SPAN
#      VALIDATION FILTER block in test_trace_schema.sh (issue #92).
#   4. Innocents survive un-mangled: gen_ai.usage.* token counts stay JSON
#      numbers, a digits-only harness.review_gate_sha stays intact, a value
#      containing the lowercase substring "akiaish" is untouched, and the key
#      literally named gen_ai.usage.output_tokens is not mangled by the
#      `token` pattern (innocent lines carry no [REDACTED] at all).
#
# Mutation hook: set TRACE_LIB_UNDER_TEST=<path> to point the sensor at an
# alternate copy of trace-lib.sh (e.g. one whose trace_redact is a no-op) and
# prove the sensor FAILS against the mutant. Default is the real library.
#
# Exit codes: 0 redaction contract honored · 1 a planted secret reached disk
# or a redacted line broke the schema contract.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${TRACE_LIB_UNDER_TEST:-${ROOT}/scripts/trace-lib.sh}"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace-lib redaction"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

[ -f "$LIB" ] \
  || fail "trace-lib not found (${LIB}) — the redacting emitter for feature trace-lib-redaction (issue #93) is not available"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }

nth_line() { sed -n "${2}p" "$1"; }

# --- Planted SYNTHETIC secrets (never real; dataset-governance.md) --------------
# 36 alnum token chars after each GitHub prefix; 16 uppercase/digits after AKIA.
GHP_SECRET='ghp_abcdefghijklmnopqrstuvwxyz0123456789'
GHO_SECRET='gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ9876543210'
GHPAT_SECRET='github_pat_11SYNTHETIC00_abcdefghijklmnopqrstuvwxyz0123456789'
AKIA_SECRET='AKIAABCDEFGH12345678'
BEARER_TOKEN_PART='eyJhbGciOiJIUzI1NiJ9.eyJzeW50aGV0aWMiOnRydWV9.c2lnbmF0dXJl'
PASSWORD_SECRET='hunter2-synthetic'
APIKEY_SECRET='synthkey-0451-abcdef'
SECRET_SECRET='swordfish-synthetic'
TOKEN_SECRET='tok-synthetic-2718281828'

# --- Fixture: throwaway git repo faking an issue-07 worktree ---------------------
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
git checkout -q -b feature/issue-07-redaction-fixture

# The fixture must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"

# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh" \
  || fail "sourcing trace-lib.sh failed under set -euo pipefail"
declare -F trace_span >/dev/null \
  || fail "trace-lib.sh did not define a trace_span function"

# --- Emit spans carrying the planted secrets -------------------------------------
# Lines 1-4 carry secrets (embedded in free-text values AND as secret-named
# key=value attributes); lines 5-6 are the innocents that must survive intact.
trace_span tool "gen_ai.tool.name=git" \
  "harness.cmd=git clone https://oauth:${GHP_SECRET}@github.com/org/repo" \
  || fail "trace_span (ghp_ secret) returned non-zero"
trace_span tool "gen_ai.tool.name=gh" \
  "harness.env=GITHUB_TOKEN=${GHO_SECRET}" \
  "harness.pat=${GHPAT_SECRET}" \
  || fail "trace_span (gho_/github_pat_ secrets) returned non-zero"
trace_span tool "gen_ai.tool.name=aws" \
  "harness.aws_key=${AKIA_SECRET}" \
  "Authorization=Bearer ${BEARER_TOKEN_PART}" \
  || fail "trace_span (AKIA/Bearer secrets) returned non-zero"
trace_span tool "gen_ai.tool.name=curl" \
  "password=${PASSWORD_SECRET}" \
  "api_key=${APIKEY_SECRET}" \
  "secret=${SECRET_SECRET}" \
  "token=${TOKEN_SECRET}" \
  || fail "trace_span (password/api_key/secret/token key=value secrets) returned non-zero"
trace_span model "gen_ai.request.model=example-model" \
  "gen_ai.usage.input_tokens=18000" "gen_ai.usage.output_tokens=4000" \
  || fail "trace_span (innocent model span) returned non-zero"
trace_span tool "gen_ai.tool.name=git" \
  "harness.review_gate_sha=1234567" \
  "harness.note=the akiaish marker must survive" \
  || fail "trace_span (innocent tool span) returned non-zero"

[ -f "$TRACE_FILE" ] || fail "trace_span calls did not create ${TRACE_FILE}"
[ "$(line_count "$TRACE_FILE")" = "6" ] \
  || fail "expected exactly 6 emitted lines, got $(line_count "$TRACE_FILE")"

# --- 1. No planted secret literal reaches the bytes on disk ----------------------
assert_absent() {
  local label="$1" literal="$2"
  if grep -qF -- "$literal" "$TRACE_FILE"; then
    fail "planted synthetic ${label} secret reached trace.jsonl on disk: ${literal}"
  fi
}
assert_absent "ghp_" "$GHP_SECRET"
assert_absent "gho_" "$GHO_SECRET"
assert_absent "github_pat_" "$GHPAT_SECRET"
assert_absent "AKIA" "$AKIA_SECRET"
assert_absent "Bearer" "$BEARER_TOKEN_PART"
assert_absent "password=" "$PASSWORD_SECRET"
assert_absent "api_key=" "$APIKEY_SECRET"
assert_absent "secret=" "$SECRET_SECRET"
assert_absent "token=" "$TOKEN_SECRET"

# --- 2. The [REDACTED] marker stands in on every secret-carrying line ------------
grep -qF '[REDACTED]' "$TRACE_FILE" \
  || fail "the [REDACTED] replacement marker is absent from trace.jsonl"
for i in 1 2 3 4; do
  printf '%s\n' "$(nth_line "$TRACE_FILE" "$i")" | grep -qF '[REDACTED]' \
    || fail "secret-carrying line ${i} carries no [REDACTED] marker: $(nth_line "$TRACE_FILE" "$i")"
done
# Key kept, value masked (plan D3) — spot-check the generic key=value shape.
printf '%s\n' "$(nth_line "$TRACE_FILE" 4)" \
  | jq -e '.password == "[REDACTED]" and (has("password"))' >/dev/null \
  || fail "generic key=value redaction must keep the key and mask the value: $(nth_line "$TRACE_FILE" 4)"
printf '%s\n' "$(nth_line "$TRACE_FILE" 3)" \
  | jq -e '.Authorization | contains("[REDACTED]")' >/dev/null \
  || fail "Bearer header value must be masked with [REDACTED]: $(nth_line "$TRACE_FILE" 3)"

# --- 3. Redacted lines are still valid JSON and still schema-valid ---------------
n=0
while IFS= read -r line; do
  n=$((n + 1))
  printf '%s\n' "$line" | jq empty 2>/dev/null \
    || fail "redacted line ${n} is no longer valid JSON: ${line}"
  validate_span "$line" \
    || fail "redacted line ${n} rejected by the #92 contract-driven jq filter: ${line}"
done < "$TRACE_FILE"
[ "$n" = "6" ] || fail "expected to validate 6 lines, saw ${n}"

# --- 4. Innocents survive un-mangled ---------------------------------------------
model_line="$(nth_line "$TRACE_FILE" 5)"
printf '%s\n' "$model_line" | jq -e '
    has("gen_ai.usage.output_tokens")
    and ((.["gen_ai.usage.input_tokens"] | type) == "number")
    and (.["gen_ai.usage.input_tokens"] == 18000)
    and ((.["gen_ai.usage.output_tokens"] | type) == "number")
    and (.["gen_ai.usage.output_tokens"] == 4000)
  ' >/dev/null \
  || fail "the token pattern mangled the innocent gen_ai.usage.*_tokens key or numeric values: ${model_line}"

innocent_line="$(nth_line "$TRACE_FILE" 6)"
printf '%s\n' "$innocent_line" | jq -e '
    (.["harness.review_gate_sha"] == "1234567")
    and (.["harness.note"] == "the akiaish marker must survive")
  ' >/dev/null \
  || fail "innocent values were mangled (digits-only sha or lowercase akiaish substring): ${innocent_line}"
grep -qF 'akiaish' "$TRACE_FILE" \
  || fail "the innocent lowercase substring 'akiaish' vanished from trace.jsonl"
for i in 5 6; do
  if printf '%s\n' "$(nth_line "$TRACE_FILE" "$i")" | grep -qF '[REDACTED]'; then
    fail "innocent line ${i} was wrongly redacted: $(nth_line "$TRACE_FILE" "$i")"
  fi
done

printf 'trace-lib redaction contract honored\n'
