#!/usr/bin/env bash
# test_trace_export_transport.sh — regression sensor for the ship path of
# scripts/trace-export.sh (issue #112, feature trace-export-transport,
# plan Phase 3: connection-string parsing + curl POST to v2/track).
#
# Contract under test (PINNED HERE as the executable spec). All coverage is
# via a PATH-shimmed curl STUB (plan D5: no mock HTTP listener, zero real
# network) that records argv and the posted body to files and replays
# canned responses:
#
#   Connection-string parsing: from APPLICATIONINSIGHTS_CONNECTION_STRING
#   (semicolon-separated key=value pairs, ANY order, with or without a
#   trailing slash on the endpoint, extra fields ignored) the exporter
#   derives the POST URL {IngestionEndpoint}/v2/track (exactly one slash
#   before v2) and the iKey from InstrumentationKey.
#
#   iKey injection at ship time: EVERY envelope in the POSTED body carries
#   iKey == the parsed InstrumentationKey (dry-run omits iKey — feature 1;
#   ship injects it — this feature).
#
#   Batch, all-or-nothing (plan D2): ONE POST per trace (the stub records
#   exactly one invocation), body is the full envelope array.
#
#   Response verification: HTTP 200 with itemsReceived == itemsAccepted ==
#   envelope count → exit 0 and a summary naming the accepted count.
#   Partial accept (accepted < received) → exit 1 with an HONEST count
#   report (both numbers). HTTP non-200 / curl failure → exit 1.
#
#   SECRETS NEVER IN ARGV (pinned mechanism): the posted body must reach
#   curl via a file reference (--data(-binary) @file or stdin), NEVER as an
#   inline argv string — so neither the full connection string, nor
#   "InstrumentationKey=", nor the raw key GUID may appear in the recorded
#   curl argv. The URL (endpoint host + /v2/track) is the only
#   connection-string-derived argv content allowed. The connection string
#   and the GUID must also never appear on the exporter's stdout/stderr.
#
#   Gating interplay: --dry-run-to-file with a connection string set still
#   ships NOTHING (no curl call); TRACE_EXPORT_OTLP unset with a connection
#   string set is still a clean no-op (no curl call).
#
# RED while ship_envelopes() in scripts/trace-export.sh refuses with the
# feature-1 not-implemented notice (exit 2).
#
# Exit codes: 0 transport contract honored · 1 a contract obligation
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
  || hard_fail "jq is required to validate the posted envelope body"
[ -f "$EXPORTER" ] \
  || hard_fail "scripts/trace-export.sh not found (${EXPORTER}) — feature 1 must land before transport"
[ -f "$TRACE_LIB" ] || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -f "$VALIDATOR" ] || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
[ -f "$CONTRACT" ] || hard_fail "trace schema contract not found (${CONTRACT})"

# --- Pinned PATH + curl STUB ---------------------------------------------------
# The stub records each invocation's argv (one ARG line per argument, runs
# separated by '---- invocation') and the posted body (resolved from
# --data/--data-binary/--data-raw/-d values: @- reads stdin, @file copies
# the file, inline strings are recorded verbatim so the secrets-in-argv pin
# can catch them). Canned behavior per run via env:
#   CURL_STUB_BODY       file whose contents are printed as the response body
#   CURL_STUB_HTTP_CODE  printed when argv asks for -w/--write-out %{http_code}
#   CURL_STUB_EXIT       stub exit status (e.g. 22 to emulate curl --fail on 4xx)
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
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
# Synthetic connection strings (never real): CS1 has extra fields, ordering,
# and a TRAILING slash on the endpoint; CS2 reverses key order and has NO
# trailing slash. Both must yield exactly one slash before v2/track.
IKEY1="0000abcd-1111-4222-8333-000000000112"
CS1="InstrumentationKey=${IKEY1};IngestionEndpoint=https://synthetic-region.in.applicationinsights.example.invalid/;LiveEndpoint=https://live.example.invalid/"
URL1="https://synthetic-region.in.applicationinsights.example.invalid/v2/track"
IKEY2="9999abcd-1111-4222-8333-000000000112"
CS2="IngestionEndpoint=https://second.in.applicationinsights.example.invalid;InstrumentationKey=${IKEY2}"
URL2="https://second.in.applicationinsights.example.invalid/v2/track"

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

# Clean, schema-valid, gate-passing 2-span trace → 2 envelopes.
IN="${TMP_DIR}/in.trace.jsonl"
cat > "$IN" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-05T12:00:00Z","span":"tool","harness.issue":112,"harness.version":"abc1234","span_id":"ttool001","gen_ai.tool.name":"git","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":80}
{"schema_version":1,"timestamp":"2026-07-05T12:00:01Z","span":"model","harness.issue":112,"harness.version":"abc1234","span_id":"tmodel01","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":500,"gen_ai.usage.output_tokens":100}
JSONL

run_ship() { # run_ship <report> <argvlog> <bodylog> <respfile> <httpcode> <curlexit> [CONN] [extra args...]
  local rep="$1" alog="$2" blog="$3" resp="$4" code="$5" cexit="$6" conn="${7-}"
  shift 7 || shift "$#"
  : > "$alog"
  : > "$blog"
  local -a envs=(
    TRACE_EXPORT_OTLP=1
    "CURL_ARGV_LOG=${alog}" "CURL_BODY_LOG=${blog}"
    "CURL_STUB_BODY=${resp}" "CURL_STUB_HTTP_CODE=${code}" "CURL_STUB_EXIT=${cexit}"
  )
  [ -n "$conn" ] && envs+=("APPLICATIONINSIGHTS_CONNECTION_STRING=${conn}")
  (cd "$FIX" \
    && env -u TRACE_EXPORT_OTLP -u APPLICATIONINSIGHTS_CONNECTION_STRING \
       "${envs[@]}" PATH="$BIN" \
       "./scripts/trace-export.sh" "$IN" "$@") > "$rep" 2>&1
}

count_invocations() { # count_invocations <argvlog>
  # grep -c prints the count but exits 1 on zero matches; normalize to a
  # bare number in all cases (absent file included).
  local n=""
  n="$(grep -c -- '---- invocation' "$1" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# ==============================================================================
# A. Happy path (CS1): one POST to {IngestionEndpoint}v2/track, iKey in
#    every posted envelope, full-accept response → exit 0 + summary.
# ==============================================================================
RESP_OK="${TMP_DIR}/resp-ok.json"
printf '%s' '{"itemsReceived":2,"itemsAccepted":2,"errors":[]}' > "$RESP_OK"
ALOG="${TMP_DIR}/a.argv"; BLOG="${TMP_DIR}/a.body"
rc=0
run_ship "${TMP_DIR}/a.out" "$ALOG" "$BLOG" "$RESP_OK" 200 0 "$CS1" || rc=$?
[ "$rc" = "0" ] \
  || fail "A: full-accept ship must exit 0, got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/a.out")"
[ "$(count_invocations "$ALOG")" = "1" ] \
  || fail "A: exactly ONE curl POST per trace (batch, plan D2) — got $(count_invocations "$ALOG") invocation(s)"
grep -qxF "ARG ${URL1}" "$ALOG" \
  || fail "A: curl argv must carry the derived URL ${URL1} (IngestionEndpoint + v2/track, single slash)"
grep -q 'ARG POST' "$ALOG" \
  || fail "A: the Track API call must be an explicit POST"
grep -qi 'Content-Type: application/json' "$ALOG" \
  || fail "A: the POST must declare Content-Type: application/json"
if [ -s "$BLOG" ]; then
  jq -e --arg k "$IKEY1" \
    'type == "array" and length == 2 and all(.[]; .iKey == $k)' "$BLOG" > /dev/null 2>&1 \
    || fail "A: the posted body must be the 2-envelope array with iKey == InstrumentationKey injected into EVERY envelope"
  jq -e 'all(.[]; .data.baseData.properties["harness.version"] == "abc1234")' "$BLOG" > /dev/null 2>&1 \
    || fail "A: shipped envelopes must still carry harness.version in customDimensions"
else
  fail "A: the stub recorded no posted body (no --data/--data-binary/-d value reached curl)"
fi
grep -qi 'accept' "${TMP_DIR}/a.out" \
  || fail "A: the success summary must speak of accepted items"
grep -qE '(^|[^0-9])2([^0-9]|$)' "${TMP_DIR}/a.out" \
  || fail "A: the success summary must name the accepted count (2)"

# A-secrets: nothing connection-string-derived in argv beyond the URL, and
# never on stdout/stderr.
for log in "$ALOG" "${TMP_DIR}/a.out"; do
  grep -qF -- "$CS1" "$log" \
    && fail "A: the FULL connection string appeared in $(basename "$log") — secrets never in argv/logs"
  grep -qF -- 'InstrumentationKey=' "$log" \
    && fail "A: an InstrumentationKey= fragment appeared in $(basename "$log")"
  grep -qF -- "$IKEY1" "$log" \
    && fail "A: the raw instrumentation key GUID appeared in $(basename "$log") — the body must reach curl via @file/stdin, and logs must not echo it"
done

# ==============================================================================
# B. Connection-string variants (CS2): reversed key order, no trailing
#    slash — same derived URL shape, correct iKey.
# ==============================================================================
ALOG2="${TMP_DIR}/b.argv"; BLOG2="${TMP_DIR}/b.body"
rc=0
run_ship "${TMP_DIR}/b.out" "$ALOG2" "$BLOG2" "$RESP_OK" 200 0 "$CS2" || rc=$?
[ "$rc" = "0" ] \
  || fail "B: ship with the reordered/no-trailing-slash connection string must exit 0, got ${rc}"
grep -qxF "ARG ${URL2}" "$ALOG2" \
  || fail "B: derived URL must be ${URL2} (no double or missing slash before v2/track)"
if [ -s "$BLOG2" ]; then
  jq -e --arg k "$IKEY2" 'all(.[]; .iKey == $k)' "$BLOG2" > /dev/null 2>&1 \
    || fail "B: every posted envelope must carry the CS2 InstrumentationKey as iKey"
fi

# ==============================================================================
# C. Partial accept: itemsAccepted < itemsReceived → exit 1 + honest counts.
# ==============================================================================
RESP_PART="${TMP_DIR}/resp-part.json"
printf '%s' '{"itemsReceived":2,"itemsAccepted":1,"errors":[{"index":1,"statusCode":400,"message":"synthetic"}]}' > "$RESP_PART"
rc=0
run_ship "${TMP_DIR}/c.out" "${TMP_DIR}/c.argv" "${TMP_DIR}/c.body" "$RESP_PART" 200 0 "$CS1" || rc=$?
[ "$rc" = "1" ] \
  || fail "C: partial accept (1 of 2) must exit 1 (all-or-nothing honesty), got ${rc}"
grep -qi 'accept' "${TMP_DIR}/c.out" \
  || fail "C: the partial-accept report must speak of accepted items"
grep -qE '(^|[^0-9])1([^0-9]|$)' "${TMP_DIR}/c.out" \
  || fail "C: the partial-accept report must name the accepted count (1)"
grep -qE '(^|[^0-9])2([^0-9]|$)' "${TMP_DIR}/c.out" \
  || fail "C: the partial-accept report must name the received/sent count (2)"

# ==============================================================================
# D. HTTP non-200 and curl transport failure — each signal ALONE must fail.
# ==============================================================================
# D1. HTTP 400 with curl exiting 0 (real curl WITHOUT --fail does exactly
#     this on a 4xx; the stub emulates --fail → 22 when the flag is passed,
#     so both implementation styles are exercised honestly) → exit 1. The
#     canned body deliberately CLAIMS full acceptance so only the HTTP-code
#     check can catch it — the status line outranks the body.
rc=0
run_ship "${TMP_DIR}/d1.out" "${TMP_DIR}/d1.argv" "${TMP_DIR}/d1.body" "$RESP_OK" 400 0 "$CS1" || rc=$?
[ "$rc" = "1" ] \
  || fail "D1: HTTP 400 (even with curl exit 0 — no --fail — and a body claiming acceptance) must exit 1, got ${rc}"

# D2. curl transport failure (exit 7, connection refused; %{http_code}
#     reports 000 as real curl does) with no usable response → exit 1.
rc=0
run_ship "${TMP_DIR}/d2.out" "${TMP_DIR}/d2.argv" "${TMP_DIR}/d2.body" "$RESP_OK" 000 7 "$CS1" || rc=$?
[ "$rc" = "1" ] \
  || fail "D2: a failed curl (transport error, exit 7) must exit 1, got ${rc}"

# ==============================================================================
# E. Gating interplay: no curl on the non-ship paths.
# ==============================================================================
# E1. Dry-run with a connection string set still ships nothing.
ALOGE="${TMP_DIR}/e1.argv"
rc=0
run_ship "${TMP_DIR}/e1.out" "$ALOGE" "${TMP_DIR}/e1.body" "$RESP_OK" 200 0 "$CS1" \
  --dry-run-to-file "${TMP_DIR}/e1.envelopes.json" || rc=$?
[ "$rc" = "0" ] \
  || fail "E1: dry-run with a connection string set must exit 0, got ${rc}"
[ "$(count_invocations "$ALOGE")" = "0" ] \
  || fail "E1: dry-run must NEVER invoke curl, even with a connection string set"

# E2. Opt-in flag unset (connection string set) → clean no-op, no curl.
ALOGE2="${TMP_DIR}/e2.argv"; : > "$ALOGE2"
rc=0
(cd "$FIX" \
  && env -u TRACE_EXPORT_OTLP \
     "APPLICATIONINSIGHTS_CONNECTION_STRING=${CS1}" \
     "CURL_ARGV_LOG=${ALOGE2}" "CURL_BODY_LOG=${TMP_DIR}/e2.body" \
     "CURL_STUB_BODY=${RESP_OK}" PATH="$BIN" \
     "./scripts/trace-export.sh" "$IN") > "${TMP_DIR}/e2.out" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "E2: connection string set but TRACE_EXPORT_OTLP unset must be a clean exit-0 no-op, got ${rc}"
[ "$(count_invocations "$ALOGE2")" = "0" ] \
  || fail "E2: the opt-out no-op must never invoke curl"

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export transport contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export transport contract honored\n'
