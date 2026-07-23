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
#   5. Loop-2 review hardening (issue #93): (a) a numeric gen_ai.usage.* key
#      whose leaf STARTS with "token" (gen_ai.usage.token_total=42) must not
#      be corrupted by the token pattern into invalid JSON — the on-disk line
#      stays valid and schema-valid with the number intact; (b) env-style
#      (AWS_SECRET_ACCESS_KEY=...) and header-style (X-Api-Key: ...) synthetic
#      secret values must be redacted.
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

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts trace-lib.sh
TMP_DIR="$FIXTURE_TMP_DIR"

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
AWS_SK_SECRET='wJalrSYNTHETICSYNTHETICSYNTHETIC'
XAPI_SECRET='synthetic-api-key-value-0001'

# --- Fixture: throwaway git repo faking an issue-07 worktree ---------------------
REPO="$FIXTURE_REPO"
if [ "$LIB" != "${ROOT}/scripts/trace-lib.sh" ]; then
  cp "$LIB" "${REPO}/scripts/trace-lib.sh"
fi
cd "$REPO"
git checkout -q -b feature/issue-07-redaction-fixture

# The fixture must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"

# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh" \
  || fail "sourcing trace-lib.sh failed under set -euo pipefail"
declare -F trace_span >/dev/null \
  || fail "trace-lib.sh did not define a trace_span function"
declare -F trace_redact >/dev/null \
  || fail "trace-lib.sh did not define a trace_redact function"

# --- RED: already-JSON-escaped quoted key=value values stay valid JSON ----------
# trace_redact runs after trace lines are fully JSON-serialized. If a JSON string
# value contains shell text such as token_source=\"$3\", password=\"p@ss\", or
# secret=\"s\", redaction may mask the value but must never consume the JSON
# escape backslash and introduce an unescaped quote into the line.
assert_trace_redact_preserves_json() {
  local label="$1" input="$2" out

  printf '%s\n' "$input" | jq -e . >/dev/null \
    || fail "test fixture for ${label} is not valid JSON before redaction: ${input}"

  out="$(printf '%s\n' "$input" | trace_redact)"
  if ! printf '%s\n' "$out" | jq -e . >/dev/null; then
    fail "trace_redact broke valid JSON for ${label}: ${out}"
  fi
}

assert_trace_redact_preserves_json \
  "JSON-escaped token_source quoted assignment" \
  "{\"span\":\"tool\",\"harness.result_summary\":\"local token_source=\\\"\$3\\\" here\"}"
assert_trace_redact_preserves_json \
  "JSON-escaped password quoted assignment" \
  '{"span":"tool","harness.result_summary":"local password=\"p@ss\" here"}'
assert_trace_redact_preserves_json \
  "JSON-escaped secret quoted assignment" \
  '{"span":"tool","harness.result_summary":"local secret=\"s\" here"}'

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

# --- 5. Loop-2 review hardening (issue #93) ---------------------------------------
# 5a. Numeric coercion x token-keyword: gen_ai.usage.token_total=42 serializes
# as an unquoted JSON number whose key leaf starts with "token"; the generic
# token pattern must not turn the bare number into invalid JSON. The on-disk
# line must stay valid JSON, pass the #92 filter, and keep all three numbers.
trace_span model "gen_ai.request.model=m" \
  "gen_ai.usage.input_tokens=1" "gen_ai.usage.output_tokens=1" \
  "gen_ai.usage.token_total=42" \
  || fail "trace_span (gen_ai.usage.token_total) returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "7" ] \
  || fail "gen_ai.usage.token_total call must append exactly one line (got $(line_count "$TRACE_FILE"))"
token_total_line="$(nth_line "$TRACE_FILE" 7)"
printf '%s\n' "$token_total_line" | jq empty 2>/dev/null \
  || fail "numeric gen_ai.usage.token_total was corrupted into invalid JSON on disk (token pattern x numeric coercion): ${token_total_line}"
validate_span "$token_total_line" \
  || fail "gen_ai.usage.token_total line rejected by the #92 contract-driven jq filter: ${token_total_line}"
printf '%s\n' "$token_total_line" | jq -e '
    (.["gen_ai.usage.token_total"] == 42)
    and (.["gen_ai.usage.input_tokens"] == 1)
    and (.["gen_ai.usage.output_tokens"] == 1)
  ' >/dev/null \
  || fail "innocent numeric gen_ai.usage.* values (token_total=42, input/output=1) were mangled: ${token_total_line}"
if printf '%s\n' "$token_total_line" | grep -qF '[REDACTED]'; then
  fail "innocent gen_ai.usage.token_total line was wrongly redacted: ${token_total_line}"
fi

# 5b. Env-style and header-style synthetic secret values must be redacted.
trace_span tool "gen_ai.tool.name=env" \
  "aws.env=AWS_SECRET_ACCESS_KEY=${AWS_SK_SECRET}" \
  "http.header=X-Api-Key: ${XAPI_SECRET}" \
  || fail "trace_span (AWS_SECRET_ACCESS_KEY/X-Api-Key secrets) returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "8" ] \
  || fail "env/header secret call must append exactly one line (got $(line_count "$TRACE_FILE"))"
assert_absent "AWS_SECRET_ACCESS_KEY env-style" "$AWS_SK_SECRET"
assert_absent "X-Api-Key header-style" "$XAPI_SECRET"
header_line="$(nth_line "$TRACE_FILE" 8)"
printf '%s\n' "$header_line" | grep -qF '[REDACTED]' \
  || fail "env/header secret line carries no [REDACTED] marker: ${header_line}"
printf '%s\n' "$header_line" | jq empty 2>/dev/null \
  || fail "env/header secret line is no longer valid JSON after redaction: ${header_line}"
validate_span "$header_line" \
  || fail "env/header secret line rejected by the #92 contract-driven jq filter: ${header_line}"

# --- 6. Issue #172: close secret-shape gaps -------------------------------------
# Synthetic (never real) values for four shapes the earlier rules missed:
# bare JWTs, Azure SAS `sig=` query values, storage `AccountKey=` values, and
# escaped PEM PRIVATE KEY blocks. Each must be masked, stay valid JSON/schema,
# and leave co-located innocent content intact.
JWT_SECRET='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6InN5bnRoZXRpYyJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6ySYNTHETICsig01'
SAS_SIG_SECRET='aB3dEf2gHiJkLmNoP0987654321syntheticSIGvalue'
ACCOUNT_KEY_SECRET='abcDEF123synthetic4567890base64padSYNTHETIC=='
PEM_BODY_SECRET='MIIEowIBAAKCAQEAsyntheticPRIVATEkeybodyLine1'

trace_span tool "gen_ai.tool.name=curl" \
  "http.header=Authorization: ${JWT_SECRET}" \
  || fail "trace_span (bare JWT) returned non-zero"
trace_span tool "gen_ai.tool.name=az" \
  "harness.sas=https://acct.blob.core.windows.net/c/b?sv=2021-06-08&ss=b&sig=${SAS_SIG_SECRET}" \
  || fail "trace_span (SAS sig=) returned non-zero"
trace_span tool "gen_ai.tool.name=az" \
  "harness.conn=DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=${ACCOUNT_KEY_SECRET};EndpointSuffix=core.windows.net" \
  || fail "trace_span (AccountKey=) returned non-zero"
trace_span tool "gen_ai.tool.name=openssl" \
  "harness.pem=-----BEGIN RSA PRIVATE KEY-----
${PEM_BODY_SECRET}
morebase64synthetic==
-----END RSA PRIVATE KEY-----" \
  "harness.note2=keep-me-visible" \
  || fail "trace_span (PEM block) returned non-zero"

[ "$(line_count "$TRACE_FILE")" = "12" ] \
  || fail "issue #172 fixtures must append 4 lines (expected 12, got $(line_count "$TRACE_FILE"))"

assert_absent "bare JWT" "$JWT_SECRET"
assert_absent "SAS sig= value" "$SAS_SIG_SECRET"
assert_absent "AccountKey= value" "$ACCOUNT_KEY_SECRET"
assert_absent "PEM private-key body" "$PEM_BODY_SECRET"

for i in 9 10 11 12; do
  line="$(nth_line "$TRACE_FILE" "$i")"
  printf '%s\n' "$line" | grep -qF '[REDACTED]' \
    || fail "issue #172 secret-carrying line ${i} carries no [REDACTED] marker: ${line}"
  printf '%s\n' "$line" | jq empty 2>/dev/null \
    || fail "issue #172 redacted line ${i} is no longer valid JSON: ${line}"
  validate_span "$line" \
    || fail "issue #172 redacted line ${i} rejected by the #92 contract-driven jq filter: ${line}"
done

# Key kept, value masked for AccountKey= (co-located AccountName survives).
conn_line="$(nth_line "$TRACE_FILE" 11)"
printf '%s\n' "$conn_line" | jq -e '
    (.["harness.conn"] | contains("AccountName=acct"))
    and (.["harness.conn"] | contains("AccountKey=[REDACTED]"))
  ' >/dev/null \
  || fail "AccountKey= redaction must keep AccountName and mask only the key value: ${conn_line}"

# PEM redaction must not corrupt the co-located innocent attribute.
pem_line="$(nth_line "$TRACE_FILE" 12)"
printf '%s\n' "$pem_line" | jq -e '.["harness.note2"] == "keep-me-visible"' >/dev/null \
  || fail "PEM redaction mangled the co-located innocent value harness.note2: ${pem_line}"

# Two PEM blocks on ONE serialized line, separated by an innocent attribute:
# the rule must redact each block independently (block-local) and must NOT
# greedily merge across the intervening JSON field.
trace_span tool "gen_ai.tool.name=openssl" \
  "harness.pem1=-----BEGIN EC PRIVATE KEY-----
firstbodysynthetic1234==
-----END EC PRIVATE KEY-----" \
  "harness.between=innocent-between-blocks" \
  "harness.pem2=-----BEGIN RSA PRIVATE KEY-----
secondbodysynthetic5678==
-----END RSA PRIVATE KEY-----" \
  || fail "trace_span (two PEM blocks) returned non-zero"
two_pem_line="$(nth_line "$TRACE_FILE" 13)"
printf '%s\n' "$two_pem_line" | jq empty 2>/dev/null \
  || fail "two-PEM-block line is not valid JSON (greedy merge across a field?): ${two_pem_line}"
printf '%s\n' "$two_pem_line" | jq -e '
    (.["harness.pem1"] == "[REDACTED]")
    and (.["harness.pem2"] == "[REDACTED]")
    and (.["harness.between"] == "innocent-between-blocks")
  ' >/dev/null \
  || fail "two PEM blocks must each be masked with the innocent field intact: ${two_pem_line}"

printf 'trace-lib redaction contract honored\n'
