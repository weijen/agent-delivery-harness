#!/usr/bin/env bash
# test_trace_export_otlp_transport.sh — regression sensor for the LIVE native
# OTLP/HTTP transport of scripts/trace-export.sh (issue #151, feature
# otlp-http-transport). Sibling of test_trace_export_transport.sh (which pins
# the Application Insights /v2/track path) and test_trace_export_otlp_*.sh
# (features 1-2, the OTLP mapping + fail-closed gate on the
# --dry-run-otlp-to-file seam).
#
# Contract under test (PINNED HERE as the executable spec). Coverage is via a
# PATH-shimmed curl STUB (same technique as the transport sensor: no mock HTTP
# listener, zero real network) that records argv and the posted body to files
# and replays a canned response:
#
#   Opt-in + endpoint: TRACE_EXPORT_OTLP_HTTP=1 with
#   OEL_EXPORTER_OTLP_ENDPOINT enables a native OTLP/HTTP+JSON ship. The
#   exporter makes exactly ONE application/json POST of the gated OTLP body
#   (the SAME { resourceSpans: [...] } object features 1-2 produce) to
#   {OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces.
#
#   Independence from the App Insights path: the OTLP transport
#   (TRACE_EXPORT_OTLP_HTTP=1 + OTEL_EXPORTER_OTLP_ENDPOINT) and the Track API
#   transport (TRACE_EXPORT_OTLP=1 + APPLICATIONINSIGHTS_CONNECTION_STRING) are
#   orthogonal switches: either may run alone, both may run together, and each
#   ships to its own endpoint (/v1/traces vs /v2/track). Turning one on never
#   changes the other's behavior.
#
#   Header secret-safety: OTEL_EXPORTER_OTLP_HEADERS is injected onto the POST
#   (so the collector receives it) but the header VALUE is never echoed to the
#   exporter's own stdout/stderr.
#
#   Gate before ship: the fail-closed redaction gate runs BEFORE the OTLP POST
#   (dry-run is not a bypass, and neither is live ship) — a secret-shaped value
#   surviving into the OTLP body aborts with a non-zero exit and NO POST.
#
#   curl missing: TRACE_EXPORT_OTLP_HTTP=1 with no curl on PATH is a clean
#   non-zero error, not a partial send.
#
# RED while scripts/trace-export.sh has no native OTLP/HTTP transport: with
# only TRACE_EXPORT_OTLP_HTTP=1 set (TRACE_EXPORT_OTLP unset) the exporter
# takes the Gate-0 opt-out no-op path and never POSTs to /v1/traces. Cases
# 1/2/4/5/6 fail until the transport lands; case 3 (App Insights alone) already
# passes and is the positive control proving independence.
#
# Exit codes: 0 OTLP transport contract honored · 1 a contract obligation
# regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTER="${ROOT}/scripts/trace-export.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
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

# --- Prerequisites -----------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required to validate the posted OTLP body"
[ -f "$EXPORTER" ] \
  || hard_fail "scripts/trace-export.sh not found (${EXPORTER})"
[ -f "$TRACE_LIB" ] || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -f "$VALIDATOR" ] || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
[ -f "$CONTRACT" ] || hard_fail "trace schema contract not found (${CONTRACT})"

# --- Pinned PATH + curl STUB (byte-shared with the transport sensor) ----------
# The stub records each invocation's argv (one ARG line per argument, runs
# separated by '---- invocation') and the posted body (resolved from
# --data/--data-binary/--data-raw/-d values: @- reads stdin, @file copies the
# file, inline strings are recorded verbatim). Canned behavior per run via env:
#   CURL_STUB_BODY       file whose contents are printed as the response body
#   CURL_STUB_HTTP_CODE  printed when argv asks for -w/--write-out %{http_code}
#   CURL_STUB_EXIT       stub exit status
BIN="${TMP_DIR}/bin"
BIN_NOCURL="${TMP_DIR}/bin-nocurl"
mkdir -p "$BIN" "$BIN_NOCURL"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp comm fold; do
  p="$(command -v "$t" || true)"
  if [ -n "$p" ]; then
    ln -sf "$p" "${BIN}/${t}"
    ln -sf "$p" "${BIN_NOCURL}/${t}"
  fi
done
cat > "${BIN}/curl" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf -- '---- invocation\n'
  for a in "$@"; do printf 'ARG %s\n' "$a"; done
} >> "${CURL_ARGV_LOG:?}"
prev=""
for a in "$@"; do
  case "$prev" in
    --data|--data-binary|--data-raw|-d)
      case "$a" in
        @-) cat >> "${CURL_BODY_LOG:?}" ;;
        @*) cat "${a#@}" >> "${CURL_BODY_LOG:?}" ;;
        *)  printf '%s' "$a" >> "${CURL_BODY_LOG:?}" ;;
      esac
      ;;
  esac
  prev="$a"
done
# Response body goes to the -o/--output target when given, else stdout.
out_target=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out_target="$a"; fi
  prev="$a"
done
if [ -n "${CURL_STUB_BODY:-}" ] && [ -f "${CURL_STUB_BODY}" ]; then
  if [ -n "$out_target" ]; then
    cat "${CURL_STUB_BODY}" > "$out_target"
  else
    cat "${CURL_STUB_BODY}"
  fi
fi
# Honor -w/--write-out formats: substitute %{http_code}, render \n literally.
prev=""
for a in "$@"; do
  if [ "$prev" = "-w" ] || [ "$prev" = "--write-out" ]; then
    case "$a" in
      *'%{http_code}'*)
        fmt="${a//'%{http_code}'/${CURL_STUB_HTTP_CODE:-200}}"
        fmt="${fmt//\\n/$'\n'}"
        printf '%s' "$fmt"
        ;;
    esac
  fi
  prev="$a"
done
# Emulate --fail/-f: real curl exits 22 on HTTP >= 400 when asked to fail.
code="${CURL_STUB_HTTP_CODE:-200}"
for a in "$@"; do
  if { [ "$a" = "--fail" ] || [ "$a" = "-f" ] || [ "$a" = "--fail-with-body" ]; } \
     && [ "$code" -ge 400 ] 2>/dev/null; then
    exit 22
  fi
done
exit "${CURL_STUB_EXIT:-0}"
SH
chmod +x "${BIN}/curl"

# --- Fixtures ------------------------------------------------------------------
OTLP_ENDPOINT="https://otel.example"
OTLP_URL="https://otel.example/v1/traces"
# Synthetic App Insights connection string (never real): trailing-slash
# endpoint, keys in canonical order. Derived Track URL = one slash before v2.
IKEY="0000abcd-1111-4222-8333-000000000151"
CS="InstrumentationKey=${IKEY};IngestionEndpoint=https://track.example/"
TRACK_URL="https://track.example/v2/track"
SECRET_HEADER='Authorization=Bearer SUPERSECRETTOKEN'
SECRET_TOKEN='SUPERSECRETTOKEN'

FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
cp "$EXPORTER" "${FIX}/scripts/trace-export.sh"
cp "$TRACE_LIB" "${FIX}/scripts/trace-lib.sh"
cp "$ISSUE_LIB" "${FIX}/scripts/issue-lib.sh"
cp "$VALIDATOR" "${FIX}/scripts/validate-trace.sh"
cp "$CONTRACT" "${FIX}/docs/evaluation/trace-schema.v1.json"
chmod +x "${FIX}/scripts/trace-export.sh" "${FIX}/scripts/validate-trace.sh"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name "Harness Test"
git -C "$FIX" config user.email "harness-test@example.invalid"

# Clean, schema-valid, gate-passing 2-span trace (tool + agent) → 2 spans.
TRACE="${TMP_DIR}/in.trace.jsonl"
cat > "$TRACE" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-05T12:00:00Z","span":"tool","harness.issue":151,"harness.version":"1.2.3","span_id":"tool0001","gen_ai.tool.name":"git","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":80}
{"schema_version":1,"timestamp":"2026-07-05T12:00:01Z","span":"agent","harness.issue":151,"harness.version":"1.2.3","span_id":"agnt0001","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent"}
JSONL

# Same shape but with a FULL-LENGTH secret (ghp_ + 24 chars >= 20) in an
# allowlisted field so it survives into the projected OTLP body — the gate
# must catch it before any POST.
TRACE_SECRET="${TMP_DIR}/in.secret.jsonl"
cat > "$TRACE_SECRET" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-05T12:00:00Z","span":"tool","harness.issue":151,"harness.version":"1.2.3","span_id":"tool0001","gen_ai.tool.name":"ghp_AAAAAAAAAAAAAAAAAAAAAAAA","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":80}
JSONL

# Full-accept Track API response (used by the App Insights half of cases 3+4).
RESP_OK="${TMP_DIR}/resp-ok.json"
printf '%s' '{"itemsReceived":2,"itemsAccepted":2,"errors":[]}' > "$RESP_OK"

# Shared env unsets so every case starts from a clean control-var baseline.
UNSET_ENV=(
  -u TRACE_EXPORT_OTLP -u TRACE_EXPORT_OTLP_HTTP
  -u APPLICATIONINSIGHTS_CONNECTION_STRING
  -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  -u OTEL_EXPORTER_OTLP_HEADERS
)

# count_matches <file> <exact-line> — bare count in all cases (absent file /
# zero matches included; grep -c prints 0 and exits 1 on no match).
count_matches() {
  local n=""
  n="$(grep -cxF -- "$2" "$1" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# ==============================================================================
# Case 1. OTLP ship happy path: TRACE_EXPORT_OTLP_HTTP=1 +
#   OTEL_EXPORTER_OTLP_ENDPOINT → exactly ONE POST to {endpoint}/v1/traces,
#   application/json, body parses as an OTLP resourceSpans object. Exit 0.
# ==============================================================================
A_OUT="${TMP_DIR}/c1.out"; A_ARGV="${TMP_DIR}/c1.argv"; A_BODY="${TMP_DIR}/c1.body"
: > "$A_ARGV"; : > "$A_BODY"
rc=0
(cd "$FIX" && env "${UNSET_ENV[@]}" \
   "CURL_ARGV_LOG=${A_ARGV}" "CURL_BODY_LOG=${A_BODY}" \
   "CURL_STUB_BODY=${RESP_OK}" "CURL_STUB_HTTP_CODE=200" "CURL_STUB_EXIT=0" \
   TRACE_EXPORT_OTLP_HTTP=1 "OTEL_EXPORTER_OTLP_ENDPOINT=${OTLP_ENDPOINT}" \
   PATH="${BIN}" \
   ./scripts/trace-export.sh "$TRACE") > "$A_OUT" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "1: OTLP ship must exit 0, got ${rc}: $(tr '\n' '|' < "$A_OUT")"
[ "$(count_matches "$A_ARGV" 'ARG POST')" -ge 1 ] \
  || fail "1: the OTLP call must be an explicit POST"
[ "$(count_matches "$A_ARGV" "ARG ${OTLP_URL}")" = "1" ] \
  || fail "1: exactly ONE POST to ${OTLP_URL} expected, got $(count_matches "$A_ARGV" "ARG ${OTLP_URL}") (no native OTLP/HTTP transport => RED)"
grep -qiF 'Content-Type: application/json' "$A_ARGV" \
  || fail "1: the OTLP POST must declare Content-Type: application/json"
if [ -s "$A_BODY" ]; then
  jq -e '(.resourceSpans | type) == "array" and (.resourceSpans | length) >= 1' \
    "$A_BODY" > /dev/null 2>&1 \
    || fail "1: the POSTed body must parse as an OTLP object carrying a non-empty .resourceSpans array"
else
  fail "1: the stub recorded no OTLP body (no --data/--data-binary/-d value reached curl)"
fi

# ==============================================================================
# Case 2. Header secret-safety: OTEL_EXPORTER_OTLP_HEADERS is sent as a header
#   (visible to the stub) but its VALUE never lands on the exporter's
#   stdout/stderr.
# ==============================================================================
B_OUT="${TMP_DIR}/c2.out"; B_ARGV="${TMP_DIR}/c2.argv"; B_BODY="${TMP_DIR}/c2.body"
: > "$B_ARGV"; : > "$B_BODY"
rc=0
(cd "$FIX" && env "${UNSET_ENV[@]}" \
   "CURL_ARGV_LOG=${B_ARGV}" "CURL_BODY_LOG=${B_BODY}" \
   "CURL_STUB_BODY=${RESP_OK}" "CURL_STUB_HTTP_CODE=200" "CURL_STUB_EXIT=0" \
   TRACE_EXPORT_OTLP_HTTP=1 "OTEL_EXPORTER_OTLP_ENDPOINT=${OTLP_ENDPOINT}" \
   "OTEL_EXPORTER_OTLP_HEADERS=${SECRET_HEADER}" \
   PATH="${BIN}" \
   ./scripts/trace-export.sh "$TRACE") > "$B_OUT" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "2: OTLP ship with a custom header must exit 0, got ${rc}: $(tr '\n' '|' < "$B_OUT")"
grep -qxF 'ARG -H' "$B_ARGV" \
  || fail "2: OTEL_EXPORTER_OTLP_HEADERS must be injected as a curl -H header"
grep -qF -- "$SECRET_TOKEN" "$B_ARGV" \
  || fail "2: the header value must actually reach curl (proof it is sent) — token absent from curl argv"
if grep -qF -- "$SECRET_TOKEN" "$B_OUT"; then
  fail "2: the header secret must NEVER appear on the exporter's stdout/stderr"
fi

# ==============================================================================
# Case 3. Independence — OTLP off, App Insights on: TRACE_EXPORT_OTLP=1 + conn
#   string, TRACE_EXPORT_OTLP_HTTP unset → POST to /v2/track, NEVER /v1/traces.
#   (Positive control: already passes today.)
# ==============================================================================
C_OUT="${TMP_DIR}/c3.out"; C_ARGV="${TMP_DIR}/c3.argv"; C_BODY="${TMP_DIR}/c3.body"
: > "$C_ARGV"; : > "$C_BODY"
rc=0
(cd "$FIX" && env "${UNSET_ENV[@]}" \
   "CURL_ARGV_LOG=${C_ARGV}" "CURL_BODY_LOG=${C_BODY}" \
   "CURL_STUB_BODY=${RESP_OK}" "CURL_STUB_HTTP_CODE=200" "CURL_STUB_EXIT=0" \
   TRACE_EXPORT_OTLP=1 "APPLICATIONINSIGHTS_CONNECTION_STRING=${CS}" \
   PATH="${BIN}" \
   ./scripts/trace-export.sh "$TRACE") > "$C_OUT" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "3: App Insights ship must exit 0, got ${rc}: $(tr '\n' '|' < "$C_OUT")"
[ "$(count_matches "$C_ARGV" "ARG ${TRACK_URL}")" = "1" ] \
  || fail "3: App Insights alone must POST once to ${TRACK_URL}"
[ "$(count_matches "$C_ARGV" "ARG ${OTLP_URL}")" = "0" ] \
  || fail "3: App Insights alone must NEVER POST to /v1/traces (paths are independent)"

# ==============================================================================
# Case 4. Both on → both ship: TRACE_EXPORT_OTLP=1 (+conn) AND
#   TRACE_EXPORT_OTLP_HTTP=1 (+endpoint) → one POST to /v2/track AND one to
#   /v1/traces.
# ==============================================================================
D_OUT="${TMP_DIR}/c4.out"; D_ARGV="${TMP_DIR}/c4.argv"; D_BODY="${TMP_DIR}/c4.body"
: > "$D_ARGV"; : > "$D_BODY"
rc=0
(cd "$FIX" && env "${UNSET_ENV[@]}" \
   "CURL_ARGV_LOG=${D_ARGV}" "CURL_BODY_LOG=${D_BODY}" \
   "CURL_STUB_BODY=${RESP_OK}" "CURL_STUB_HTTP_CODE=200" "CURL_STUB_EXIT=0" \
   TRACE_EXPORT_OTLP=1 "APPLICATIONINSIGHTS_CONNECTION_STRING=${CS}" \
   TRACE_EXPORT_OTLP_HTTP=1 "OTEL_EXPORTER_OTLP_ENDPOINT=${OTLP_ENDPOINT}" \
   PATH="${BIN}" \
   ./scripts/trace-export.sh "$TRACE") > "$D_OUT" 2>&1 || rc=$?
[ "$(count_matches "$D_ARGV" "ARG ${TRACK_URL}")" = "1" ] \
  || fail "4: both-on must still POST once to the Track API ${TRACK_URL}"
[ "$(count_matches "$D_ARGV" "ARG ${OTLP_URL}")" = "1" ] \
  || fail "4: both-on must ALSO POST once to the OTLP endpoint ${OTLP_URL} (no native OTLP/HTTP transport => RED)"

# ==============================================================================
# Case 5. Gate before ship: TRACE_EXPORT_OTLP_HTTP=1 + endpoint + a fixture with
#   a full-length secret → FAIL CLOSED — non-zero exit, NO /v1/traces POST.
# ==============================================================================
E_OUT="${TMP_DIR}/c5.out"; E_ARGV="${TMP_DIR}/c5.argv"; E_BODY="${TMP_DIR}/c5.body"
: > "$E_ARGV"; : > "$E_BODY"
rc=0
(cd "$FIX" && env "${UNSET_ENV[@]}" \
   "CURL_ARGV_LOG=${E_ARGV}" "CURL_BODY_LOG=${E_BODY}" \
   "CURL_STUB_BODY=${RESP_OK}" "CURL_STUB_HTTP_CODE=200" "CURL_STUB_EXIT=0" \
   TRACE_EXPORT_OTLP_HTTP=1 "OTEL_EXPORTER_OTLP_ENDPOINT=${OTLP_ENDPOINT}" \
   PATH="${BIN}" \
   ./scripts/trace-export.sh "$TRACE_SECRET") > "$E_OUT" 2>&1 || rc=$?
[ "$rc" != "0" ] \
  || fail "5: a secret-shaped value must fail the gate BEFORE shipping (non-zero exit), got ${rc}"
[ "$(count_matches "$E_ARGV" "ARG ${OTLP_URL}")" = "0" ] \
  || fail "5: the fail-closed gate must ship NOTHING — no /v1/traces POST allowed"

# ==============================================================================
# Case 6. curl missing: TRACE_EXPORT_OTLP_HTTP=1 + endpoint but no curl on PATH
#   → clean non-zero error naming curl, no partial send.
# ==============================================================================
F_OUT="${TMP_DIR}/c6.out"
rc=0
(cd "$FIX" && env "${UNSET_ENV[@]}" \
   "CURL_STUB_HTTP_CODE=200" "CURL_STUB_EXIT=0" \
   TRACE_EXPORT_OTLP_HTTP=1 "OTEL_EXPORTER_OTLP_ENDPOINT=${OTLP_ENDPOINT}" \
   PATH="${BIN_NOCURL}" \
   ./scripts/trace-export.sh "$TRACE") > "$F_OUT" 2>&1 || rc=$?
[ "$rc" != "0" ] \
  || fail "6: OTLP ship with no curl on PATH must exit non-zero (clean error, no partial send), got ${rc}"
grep -qi 'curl' "$F_OUT" \
  || fail "6: the missing-curl error must name curl so the operator can fix it"

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export OTLP transport contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export OTLP transport contract honored\n'
