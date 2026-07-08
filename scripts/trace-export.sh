#!/usr/bin/env bash
# trace-export.sh — opt-in trace exporter: projects a per-issue schema-v1
# trace.jsonl onto Application Insights Track API JSON envelopes and ships
# them to the v2/track ingestion endpoint (issue #112; features
# trace-export-mapping-core, trace-export-redaction-gate,
# trace-export-transport — plan Phases 1–3).
#
# "App-Insights-native envelopes carrying OTel-conventional attribute
# names": the allowlisted gen_ai.* / harness.* keys ride verbatim inside
# each envelope's properties (→ customDimensions), so KQL can slice by
# customDimensions["harness.version"] without a schema translation layer.
#
# Fail-closed export gate (feature 2) — redaction_gate() runs on BOTH
# delivery paths (dry-run is NOT a debugging bypass) before anything leaves
# the staging dir:
#   Gate 1 (input; plan D4 — one redaction policy, never a fork): the trace
#     must pass validate-trace.sh, with ONE conductor-resolved tolerance:
#     if ALL findings are invalid_json the export proceeds (those lines are
#     already skip-and-counted by the mapper); ANY other violation class
#     (redaction_leak, schema_violation, type_violation,
#     failure_mode_violation, completeness, redaction_audit_error) → exit 1,
#     nothing written anywhere.
#   Gate 2 (output; sanitize-trace precedent): the staged envelope file must
#     be a trace_redact fixed point, PLUS a HARDCODED secret-shape backstop
#     (gh[pousr]_/github_pat_/AKIA) that does NOT depend on trace_redact
#     working (a no-op redactor cannot blind it), PLUS a belt check that the
#     four allowlist-excluded field names never appear. A broken or missing
#     trace_redact fails closed (exit 1/2, nothing written). Gate failure
#     messages never echo secret content.
#
# Transport (feature 3) — ship_envelopes(): parses
# APPLICATIONINSIGHTS_CONNECTION_STRING (semicolon key=value pairs, any
# order, trailing slash on the endpoint tolerated, extra fields ignored),
# injects iKey into EVERY envelope, and makes ONE POST per trace (batch,
# all-or-nothing — plan D2) to ${IngestionEndpoint%/}/v2/track with
# Content-Type: application/json. The body reaches curl via @file ONLY:
# the connection string, any InstrumentationKey= fragment, and the raw key
# GUID never appear in curl argv or on stdout/stderr. Success requires
# HTTP 200 AND itemsAccepted == itemsReceived == sent; partial accept
# reports both counts and exits 1; a non-200 status outranks a response
# body that claims acceptance; a curl transport error exits 1.
#
# Opt-in gating (plan Gate 0; decoupling doctrine — never wired into the
# lifecycle scripts, invocation is manual or via a user-side hook):
#   - TRACE_EXPORT_OTLP != 1        → exit 0 no-op notice; NOTHING written.
#   - TRACE_EXPORT_OTLP=1, ship path, APPLICATIONINSIGHTS_CONNECTION_STRING
#     unset                         → exit 0 no-op notice naming the var.
#   - --dry-run-to-file works WITHOUT a connection string (the CI seam
#     needs zero config); dry-run envelopes OMIT iKey entirely — the
#     transport injects it at ship time.
#
# Envelope mapping (plan mapping table v1, conductor-resolved pins):
#   tool/lifecycle → Microsoft.ApplicationInsights.RemoteDependency /
#     RemoteDependencyData: name = gen_ai.tool.name | harness.lifecycle_step,
#     type = harness.tool | harness.lifecycle, id = span_id, duration =
#     harness.duration_ms as a TimeSpan hh:mm:ss.fff (>= 24h gains the day
#     segment d.hh:mm:ss.fff; absent → 00:00:00.000; negative clamps to
#     00:00:00.000), success =
#     harness.outcome == pass (absent → true), resultCode = stringified
#     harness.exit_status when present (else the outcome, else omitted).
#   agent/model → Microsoft.ApplicationInsights.Event / EventData:
#     name = harness.agent/<gen_ai.agent.name> | harness.model/<model>;
#     numeric gen_ai.usage.* land in measurements as JSON NUMBERS.
#   Every envelope: ver 1, time = the span's own timestamp, tags carry
#     ai.cloud.role and ai.operation.id = "issue-<NN>"; properties carry the
#     allowlist-v1 projection, STRINGIFIED, deny-by-default (unknown/future
#     keys and the four excluded free-text fields never leave the process).
#   harness.version is load-bearing (plan D6): any span missing it aborts
#     the whole export (all-or-nothing batch, exit 1).
#
# Malformed lines: the exporter is not a validator — non-JSON(-object)
# lines are skipped and counted (stderr notice); refusal semantics belong
# to the feature-2 redaction gate (which reuses validate-trace.sh).
#
# Usage:
#   ./scripts/trace-export.sh <issue-number> [--dry-run-to-file <out.json>]
#       exports <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl
#   ./scripts/trace-export.sh <path/to/trace.jsonl> [--dry-run-to-file <out.json>]
#       exports the given file directly
#
# The dry-run output file is an INTERNAL SEAM for sensors/CI, not a stable
# contract (leading // comment lines say so in-band).
#
# Exit codes: 0 exported / clean no-op · 1 gate or export failure ·
# 2 usage/environment error — matches validate-trace.sh / sanitize-trace.sh.

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

# trace_redact is the Gate 2 fixed-point oracle (plan D4): reuse the library
# filter, never fork its pattern list. Sourced conditionally; the gate fails
# closed (exit 2) if the function is missing when the gate runs.
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi

usage() {
  {
    echo "usage: ./scripts/trace-export.sh <issue-number|trace-path> [--dry-run-to-file <out.json>]"
    echo "  <issue-number>  exports <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl"
    echo "  <trace-path>    exports the given trace.jsonl file directly"
    echo "  --dry-run-to-file <out.json>  write the envelope array to a file instead of shipping"
    echo "  --dry-run-otlp-to-file <out.json>  write the OTLP/HTTP+JSON resourceSpans to a file (never ships)"
    echo "opt-in: TRACE_EXPORT_OTLP=1 enables the App Insights Track API ship path (needs"
    echo "        APPLICATIONINSIGHTS_CONNECTION_STRING); TRACE_EXPORT_OTLP_HTTP=1 enables the"
    echo "        native OTLP/HTTP ship path (needs OTEL_EXPORTER_OTLP_ENDPOINT, or the"
    echo "        signal-specific OTEL_EXPORTER_OTLP_TRACES_ENDPOINT). Both switches are"
    echo "        independent — either alone or both together. Dry-run seams need neither."
    echo "        OTEL_EXPORTER_OTLP_HEADERS (comma-separated Key=Value) is sent to the"
    echo "        collector but is SECRET — its values are never echoed."
    echo "exit codes: 0 exported / clean no-op, 1 gate or export failure, 2 usage/environment error"
  } >&2
}

# --- Gate (feature 2, trace-export-redaction-gate) -----------------------------
# Fail-closed export gate: runs on BOTH delivery paths before anything
# leaves the staging dir. Return codes: 0 pass · 1 gate violation · 2 the
# gate itself could not run (both mean NOTHING is written). Failure
# messages carry rule/class names and counts only — never line content or
# attribute values (validate-trace doctrine: findings must not re-leak
# what redaction keeps out of circulation).
redaction_gate() { # redaction_gate <staged-envelope-file>
  local staged="$1"
  local validator="${SCRIPT_DIR}/validate-trace.sh"
  local vout="" vrc=0

  if [ ! -f "$staged" ]; then
    red "error: export gate: staged envelope file is missing — refusing (nothing written)" >&2
    return 2
  fi

  # Gate 1 — input gate: validate-trace.sh is the single validation +
  # redaction-audit authority (plan D4). Conductor-resolved tolerance: a
  # trace whose ONLY findings are invalid_json still exports (those lines
  # are already skip-and-counted by the mapper); any other violation class
  # is disqualifying.
  if [ ! -f "$validator" ]; then
    red "error: export gate: scripts/validate-trace.sh not found — refusing to export unvalidated spans (nothing written)" >&2
    return 2
  fi
  vout="$("$validator" "$TRACE_FILE" 2>&1)" || vrc=$?
  if [ "$vrc" -eq 2 ]; then
    red "error: export gate: validate-trace.sh could not run (exit 2) — refusing (nothing written)" >&2
    return 2
  elif [ "$vrc" -ne 0 ]; then
    if printf '%s\n' "$vout" | grep -e '^VIOLATION' | grep -vq 'invalid_json$'; then
      # Relay the validator's findings (rule names + line numbers only —
      # validate-trace never echoes values, so this cannot re-leak).
      printf '%s\n' "$vout" | grep -e '^VIOLATION' | grep -v 'invalid_json$' >&2
      red "error: export gate: the input trace fails validate-trace.sh with disqualifying violation class(es) — nothing written" >&2
      return 1
    fi
    # invalid_json-only: tolerated (skip-and-count already reported).
  fi

  # Gate 2 — output audit on the STAGED envelopes (sanitize-trace
  # precedent): nothing leaves staging unless the serialized output is
  # provably clean.
  # 2a. trace_redact fixed point — a second pass must change nothing. A
  #     missing or failing redactor fails CLOSED: "the auditor broke" is
  #     never "ship anyway".
  if ! declare -F trace_redact >/dev/null 2>&1; then
    red "error: export gate: scripts/trace-lib.sh (trace_redact) is unavailable — failing closed (nothing written)" >&2
    return 2
  fi
  local audited="${TMP_DIR}/envelopes.redacted.json"
  if ! trace_redact < "$staged" > "$audited" 2>/dev/null; then
    red "error: export gate: trace_redact failed at runtime over the staged envelopes — failing closed (nothing written)" >&2
    return 1
  fi
  if ! cmp -s "$staged" "$audited"; then
    red "error: export gate: staged envelopes are not a trace_redact fixed point — secret-shaped content would ship; refusing (nothing written)" >&2
    return 1
  fi
  # 2b. HARDCODED secret-shape backstop, deliberately INDEPENDENT of
  #     trace_redact (a broken/no-op redactor cannot blind it). Audit-only:
  #     the redaction POLICY stays trace_redact's alone.
  if grep -qE "$TRACE_SECRET_SHAPE_RE" "$staged"; then
    red "error: export gate: a well-known secret shape survived into the staged envelopes (hardcoded backstop) — refusing (nothing written)" >&2
    return 1
  fi
  # 2c. Belt: the allowlist-excluded field names must never appear in
  #     the output (the allowlist projection already drops them; this
  #     catches a projection regression before it ships).
  local excluded
  for excluded in 'harness.args_summary' 'harness.result_summary' 'harness.summary' 'harness.worktree' 'harness.branch'; do
    if grep -qF -- "$excluded" "$staged"; then
      red "error: export gate: excluded field name '${excluded}' appeared in the staged envelopes — refusing (nothing written)" >&2
      return 1
    fi
  done
  # 2d. String value caps (plan feature trace-export-value-caps): every
  #     customDimensions (properties) STRING value must be within the shippable
  #     risk surface — max 256 chars (256 ships, 257 refuses) AND printable
  #     charset only (any C0/C1 control byte, including embedded newline/tab, is
  #     a violation). All-or-nothing, mirroring the harness.version abort: a
  #     value that cannot ship intact takes the whole batch down. This is a
  #     fail-closed AUDIT over the projected values — it NEVER truncates or
  #     strips; it refuses. The measurements map (numeric gen_ai.usage.*) and
  #     any non-string value are exempt by construction (only string values are
  #     scanned). The offending key is named; its value is never echoed.
  local cap_report
  if ! cap_report="$(grep -v '^//' "$staged" | jq -r '
      if type == "array" then
        # App-Insights envelope array: cap customDimensions string values.
        [ .[]?.data.baseData.properties // {}
          | to_entries[]
          | select(.value | type == "string")
          | select((.value | length) > 256
                   or (.value | explode | any(. < 32 or (. >= 127 and . <= 159))))
          | .key ]
      else
        # OTLP resourceSpans body (no customDimensions shape): cap the
        # attribute stringValues over the identical risk surface, so the
        # shape mismatch neither crashes nor no-ops (plan D4 — one policy).
        [ .resourceSpans[]?.scopeSpans[]?.spans[]?.attributes[]?
          | select(.value.stringValue | type == "string")
          | select((.value.stringValue | length) > 256
                   or (.value.stringValue | explode | any(. < 32 or (. >= 127 and . <= 159))))
          | .key ]
      end
      | unique
      | .[]' 2>/dev/null)"; then
    red "error: export gate: could not audit customDimensions value caps over the staged envelopes — failing closed (nothing written)" >&2
    return 1
  fi
  if [ -n "$cap_report" ]; then
    # Name the offending key(s) only; never echo the over-long / control-byte
    # value itself (it may be secret-ish).
    printf 'error: export gate: allowlisted customDimensions value fails the string cap (over 256 chars or non-printable control byte): %s\n' \
      "$(printf '%s' "$cap_report" | tr '\n' ' ')" >&2
    red "error: export gate: a shippable string value exceeds the 256-char cap or carries a control byte — refusing the whole export (all-or-nothing; nothing written)" >&2
    return 1
  fi
  return 0
}

# --- Transport (feature 3, trace-export-transport) ------------------------------
# ONE POST per trace (batch, all-or-nothing — plan D2) to the Track API.
# Secrets never in argv: the iKey rides only inside the body file
# (--data-binary @file); the URL is the only connection-string-derived
# argv content. Messages never echo the connection string or the key GUID.
ship_envelopes() { # ship_envelopes <staged-envelope-file> <sent-count>
  local staged="$1" sent="$2"
  local ikey="" endpoint="" part url
  local body="${TMP_DIR}/track-body.json"
  local resp="${TMP_DIR}/track-response.json"
  local http_code="" curl_rc=0 received="" accepted=""

  if ! command -v curl >/dev/null 2>&1; then
    red "error: curl is required to ship envelopes to the Track API" >&2
    exit 2
  fi

  # Connection-string parsing: semicolon-separated key=value pairs, any
  # order, extra fields ignored, trailing endpoint slash tolerated,
  # whitespace around segments trimmed.
  local -a cs_parts=()
  IFS=';' read -r -a cs_parts <<< "${APPLICATIONINSIGHTS_CONNECTION_STRING}"
  for part in ${cs_parts[@]+"${cs_parts[@]}"}; do
    # Trim leading/trailing whitespace on the segment.
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    case "$part" in
      InstrumentationKey=*) ikey="${part#InstrumentationKey=}" ;;
      IngestionEndpoint=*)  endpoint="${part#IngestionEndpoint=}" ;;
    esac
  done
  if [ -z "$ikey" ] || [ -z "$endpoint" ]; then
    red "error: APPLICATIONINSIGHTS_CONNECTION_STRING must be semicolon-separated key=value pairs carrying InstrumentationKey and IngestionEndpoint (value not echoed)" >&2
    exit 2
  fi
  url="${endpoint%/}/v2/track"

  # iKey injection at ship time: every envelope in the posted body carries
  # the parsed key (dry-run output never does — feature-1 pin). The key
  # reaches jq via the ENVIRONMENT ($ENV), never --arg: process argv is
  # ps-visible on shared machines, the environment is not.
  if ! grep -v '^//' "$staged" \
      | TRACE_EXPORT_IKEY="$ikey" jq 'map(. + { iKey: $ENV.TRACE_EXPORT_IKEY })' > "$body"; then
    red "error: failed to build the Track API request body" >&2
    exit 2
  fi

  # ONE POST; body via @file only. -w captures the HTTP status; the
  # response body lands in a temp file, never on the terminal.
  http_code="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    --data-binary "@${body}" \
    -o "$resp" \
    -w '%{http_code}' \
    "$url")" || curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    red "error: transport failure — curl exited ${curl_rc}; nothing confirmed shipped" >&2
    exit 1
  fi
  # The status line outranks the body: a non-200 fails even if the body
  # claims acceptance.
  if [ "$http_code" != "200" ]; then
    red "error: Track API returned HTTP ${http_code} (expected 200) — export failed" >&2
    exit 1
  fi

  received="$(jq -r '.itemsReceived // empty' "$resp" 2>/dev/null)" || received=""
  accepted="$(jq -r '.itemsAccepted // empty' "$resp" 2>/dev/null)" || accepted=""
  if ! [[ "$received" =~ ^[0-9]+$ && "$accepted" =~ ^[0-9]+$ ]]; then
    red "error: Track API response was unreadable (no itemsReceived/itemsAccepted) — cannot confirm ingestion" >&2
    exit 1
  fi
  if [ "$accepted" != "$received" ] || [ "$accepted" != "$sent" ]; then
    red "error: Track API accepted ${accepted} of ${received} received (${sent} sent) — partial accept, export failed" >&2
    exit 1
  fi
  green "shipped: ${accepted} envelope(s) accepted by the Track API (${sent} sent, HTTP 200)"
}

# --- Native OTLP/HTTP transport (feature otlp-http-transport) -------------------
# The LIVE sibling of the --dry-run-otlp-to-file seam: POSTs the SAME gated
# OTLP resourceSpans body (features 1–2) to an OpenTelemetry collector over
# OTLP/HTTP+JSON. Opt-in (TRACE_EXPORT_OTLP_HTTP=1) and endpoint are
# independent of the App-Insights path — both may run in one invocation, each
# to its own URL (/v1/traces vs /v2/track). Mirrors ship_envelopes' safety:
# curl is required; the body reaches curl by @file ONLY; the header VALUES
# from OTEL_EXPORTER_OTLP_HEADERS (a secret surface) are injected onto the
# POST but never echoed to stdout/stderr.
ship_otlp() { # ship_otlp <staged-otlp-body-file>
  local staged="$1"
  local url="" body="${TMP_DIR}/otlp-body.json"
  local resp="${TMP_DIR}/otlp-response.json"
  local http_code="" curl_rc=0

  if ! command -v curl >/dev/null 2>&1; then
    red "error: curl is required to ship spans over OTLP/HTTP" >&2
    exit 2
  fi

  # Endpoint resolution: the traces-specific var is the full signal URL (used
  # as-is); otherwise the base endpoint gains the OTLP/HTTP traces path. Either
  # way the collector is reached at .../v1/traces.
  if [ -n "${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-}" ]; then
    url="${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT}"
  elif [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
    url="${OTEL_EXPORTER_OTLP_ENDPOINT%/}/v1/traces"
  else
    red "error: OTLP/HTTP transport needs OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT (nothing sent)" >&2
    exit 2
  fi

  # Body via @file only (never argv): strip the // seam header down to the
  # bare OTLP resourceSpans JSON object the collector expects.
  if ! grep -v '^//' "$staged" > "$body"; then
    red "error: failed to assemble the OTLP request body — nothing sent" >&2
    exit 1
  fi

  # Headers: always application/json. OTEL_EXPORTER_OTLP_HEADERS (OTEL spec:
  # comma-separated Key=Value pairs) is injected so the collector receives it;
  # the header VALUE is a secret surface — this function never prints it.
  local -a hdr_args=(-H 'Content-Type: application/json')
  if [ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]; then
    local -a hdr_pairs=()
    local pair hkey hval
    IFS=',' read -r -a hdr_pairs <<< "${OTEL_EXPORTER_OTLP_HEADERS}"
    for pair in ${hdr_pairs[@]+"${hdr_pairs[@]}"}; do
      # Trim surrounding whitespace on the pair; skip empties.
      pair="${pair#"${pair%%[![:space:]]*}"}"
      pair="${pair%"${pair##*[![:space:]]}"}"
      [ -n "$pair" ] || continue
      case "$pair" in
        *=*)
          hkey="${pair%%=*}"
          hval="${pair#*=}"
          # Trim the key only (preserve the value byte-for-byte).
          hkey="${hkey#"${hkey%%[![:space:]]*}"}"
          hkey="${hkey%"${hkey##*[![:space:]]}"}"
          hdr_args+=(-H "${hkey}: ${hval}")
          ;;
      esac
    done
  fi

  # ONE POST; body by @file, response to a temp file (never the terminal).
  # A transport error (curl non-zero) or a non-2xx status ships nothing
  # confirmed and exits 1.
  http_code="$(curl -sS -X POST \
    "${hdr_args[@]}" \
    --data "@${body}" \
    -o "$resp" \
    -w '%{http_code}' \
    "$url")" || curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    red "error: OTLP transport failure — curl exited ${curl_rc}; nothing confirmed shipped" >&2
    exit 1
  fi
  if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    red "error: OTLP endpoint returned HTTP ${http_code:-<none>} (expected 2xx) — export failed" >&2
    exit 1
  fi
  green "shipped: OTLP resourceSpans accepted over OTLP/HTTP (HTTP ${http_code})"
}

# --- Argument parsing (exit 2: usage error) -----------------------------------
ARG=""
DRY_RUN_FILE=""
DRY_RUN_OTLP_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run-to-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      DRY_RUN_FILE="$2"
      shift 2
      ;;
    --dry-run-otlp-to-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      DRY_RUN_OTLP_FILE="$2"
      shift 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [ -n "$ARG" ]; then
        usage
        exit 2
      fi
      ARG="$1"
      shift
      ;;
  esac
done
if [ -z "$ARG" ]; then
  usage
  exit 2
fi

# --- Gate 0: opt-in (plan Gate 0) ---------------------------------------------
# Disabled is a clean no-op BEFORE anything is resolved or written — not even
# a dry-run target may appear. The exporter engages when a delivery switch is
# on: TRACE_EXPORT_OTLP=1 (App Insights Track API + its dry-run seams) or
# TRACE_EXPORT_OTLP_HTTP=1 (native OTLP/HTTP). NEITHER set → the historical
# opt-out no-op, even with a --dry-run flag (both dry-run seams still require
# TRACE_EXPORT_OTLP=1). App-Insights-only behavior is unchanged.
if [ "${TRACE_EXPORT_OTLP:-}" != "1" ] \
    && [ "${TRACE_EXPORT_OTLP_HTTP:-}" != "1" ]; then
  yellow "notice: trace export is disabled — set TRACE_EXPORT_OTLP=1 (App Insights) or TRACE_EXPORT_OTLP_HTTP=1 (OTLP/HTTP) to opt in (nothing written)" >&2
  exit 0
fi
# App Insights ship path needs the connection string; the dry-run seams and
# the native OTLP/HTTP transport do not (zero config beyond their own opt-in —
# plan D5, the CI seam). This no-op fires ONLY when the App-Insights path is the
# sole thing requested and its connection string is missing; it must never
# swallow an OTLP/HTTP ship (TRACE_EXPORT_OTLP_HTTP=1 has its own endpoint).
if [ -z "$DRY_RUN_FILE" ] && [ -z "$DRY_RUN_OTLP_FILE" ] \
    && [ "${TRACE_EXPORT_OTLP_HTTP:-}" != "1" ] \
    && [ -z "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}" ]; then
  yellow "notice: TRACE_EXPORT_OTLP=1 but APPLICATIONINSIGHTS_CONNECTION_STRING is not set — nothing to ship (no-op); dry-run via --dry-run-to-file needs no connection string" >&2
  exit 0
fi

# --- Environment preconditions (exit 2: the exporter could not run) -----------
if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to build export envelopes" >&2
  exit 2
fi

# --- Resolve the trace file (CLI parity with validate-trace.sh / trace-report.sh)
TRACE_FILE=""
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file explicitly.
    TRACE_FILE="$ARG"
    ;;
  *)
    # Issue-number mode: resolve the main-checkout trace path.
    if ! ISSUE_NUM="$(issue_parse_number "$ARG" 2>/dev/null)"; then
      usage
      exit 2
    fi
    if ! MAIN_ROOT="$(issue_main_root 2>/dev/null)"; then
      red "error: cannot resolve the main checkout root (not inside a git repo?)" >&2
      exit 2
    fi
    ISSUE_PAD="$(printf '%02d' "$ISSUE_NUM")"
    TRACE_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/trace.jsonl"
    ;;
esac

if [ ! -f "$TRACE_FILE" ]; then
  red "error: trace file not found: ${TRACE_FILE}" >&2
  usage
  exit 2
fi
if [ ! -r "$TRACE_FILE" ]; then
  red "error: trace file is not readable: ${TRACE_FILE}" >&2
  exit 2
fi

# mktemp when available; a mkdir fallback keeps the exporter usable in
# minimal environments (e.g. sensor-pinned PATHs) without weakening cleanup.
# ALL output is staged here first (sanitize-trace precedent): nothing lands
# at its destination until the gate seam has passed.
if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d)"
else
  TMP_DIR="${TMPDIR:-/tmp}/trace-export.$$.${RANDOM}"
  # Private perms, atomic fail-if-exists: never -p here — -p would happily
  # reuse a pre-existing (potentially attacker-owned) dir AND skip -m on
  # it. A collision refuses instead of reusing.
  if ! mkdir -m 700 "$TMP_DIR" 2>/dev/null; then
    red "error: staging dir cannot be created (pre-existing path refused): ${TMP_DIR}" >&2
    exit 2
  fi
fi
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- OTLP/HTTP+JSON path (dry-run seam + live transport) ----------------------
# The OTLP projection builds the SAME { resourceSpans: [...] } body for two
# consumers: the --dry-run-otlp-to-file seam (writes + exits, zero network) and
# the live TRACE_EXPORT_OTLP_HTTP=1 transport (POSTs to the collector). Both
# reuse the allowlist-v1 attribute projection, so excluded free-text keys stay
# byte-absent, and both run redaction_gate on the staged body BEFORE it leaves
# staging — dry-run is not a bypass and neither is a live ship. A jq failure
# fails closed (non-zero, nothing written/sent). The App-Insights envelope/ship
# path is untouched here.
if [ -n "$DRY_RUN_OTLP_FILE" ] || [ "${TRACE_EXPORT_OTLP_HTTP:-}" = "1" ]; then
  OTLP_FILTER="${TMP_DIR}/export-otlp.jq"
  cat > "$OTLP_FILTER" <<'JQ'
# Shippable-attribute ALLOWLIST v1 — the SAME deny-by-default surface the
# App-Insights projection uses (26 keys + the gen_ai.usage.* prefix family).
# Any key not matched here is dropped, so excluded free text
# (harness.args_summary, harness.summary, harness.worktree, harness.branch)
# and unknown/future keys are byte-absent from the OTLP output.
def allowlist:
  ["schema_version", "timestamp", "span", "span_id", "parent_span_id",
   "harness.issue", "harness.version",
   "harness.lifecycle_step", "harness.outcome", "harness.failure_mode",
   "harness.exit_status", "harness.duration_ms", "harness.incomplete_count",
   "harness.violation_count", "harness.warning_count",
   "harness.feature_id", "harness.stage",
   "gen_ai.tool.name", "gen_ai.operation.name", "gen_ai.agent.name",
   "gen_ai.request.model",
   "harness.review_gate_sha", "harness.pr_number",
   "harness.require_complete", "harness.warning", "harness.skill.name"];

def shippable_key:
  . as $k
  | ((allowlist | index($k)) != null) or ($k | startswith("gen_ai.usage."));

# Left-pad a value's string form with "0" to a fixed width.
def zpad($n):
  tostring | if length >= $n then . else ("0" * ($n - length)) + . end;

# Integer → lowercase hex string (portable, no crypto): recurse yields the
# number then each successive quotient; the reversed remainders are the
# digits, most significant first.
def to_hex_digits:
  [ recurse(if . >= 16 then (. / 16 | floor) else empty end) ]
  | reverse
  | map(. % 16)
  | map("0123456789abcdef"[.:. + 1])
  | join("");

# Deterministic 32-lowercase-hex TraceId from harness.issue — every span of
# one issue shares it. Missing/zero issue → 32 zeros.
def trace_id:
  ((.["harness.issue"] // 0) | floor | if . < 0 then 0 else . end)
  | (if . == 0 then "0" else to_hex_digits end)
  | zpad(32);

# Span timestamp (ISO-8601 ...Z) → integer epoch seconds.
def epoch_seconds:
  (.["timestamp"] // "") | fromdateiso8601;

# Nanosecond values exceed jq float precision, so they are built by STRING
# concatenation, never multiplied: start = "<epoch>000000000".
def start_nanos:
  "\(epoch_seconds)000000000";

# end = start + harness.duration_ms * 1e6, carried exactly: whole seconds
# fold into the epoch, the sub-second remainder is a zero-padded 9-digit
# nanos field. No duration (or negative) → end == start (single-point; never
# a fabricated duration).
def end_nanos:
  epoch_seconds as $e
  | ((.["harness.duration_ms"] // 0) | floor | if . < 0 then 0 else . end) as $ms
  | ($e + ($ms / 1000 | floor)) as $end_e
  | (($ms % 1000) * 1000000) as $rem_ns
  | "\($end_e)\($rem_ns | zpad(9))";

# Span display name mirrors the App-Insights naming spirit; falls back to the
# span type when the primary field is absent.
def span_name:
  if .span == "tool" then (.["gen_ai.tool.name"] // .span)
  elif .span == "lifecycle" then (.["harness.lifecycle_step"] // .span)
  elif .span == "agent" then (.["gen_ai.agent.name"] // .span)
  elif .span == "model" then (.["gen_ai.request.model"] // .span)
  else (.span // "span")
  end;

# Allowlist projection → OTLP attribute objects. Values are stringified
# (stringValue); numeric gen_ai.usage.* MAY ride intValue but stringValue is
# accepted and simpler.
def otlp_attributes:
  [ to_entries[]
    | select(.key | shippable_key)
    | { key: .key, value: { stringValue: (.value | tostring) } } ];

# One schema-v1 span → one OTLP span. parentSpanId is OMITTED entirely when
# there is no non-empty parent_span_id (never fabricated).
def otlp_span:
  . as $s
  | { traceId: ($s | trace_id),
      spanId: ($s["span_id"] // ""),
      name: ($s | span_name),
      kind: 1,
      startTimeUnixNano: ($s | start_nanos),
      endTimeUnixNano: ($s | end_nanos),
      attributes: ($s | otlp_attributes) }
  + (if (($s["parent_span_id"] // "") | length) > 0
     then { parentSpanId: $s["parent_span_id"] }
     else {} end);

# Same census as the App-Insights path: skip-and-count non-object lines and
# tally spans missing harness.version (the queryable dimension).
[inputs] as $lines
| [ $lines[] | fromjson? | select(type == "object") ] as $spans
| (($lines | length) - ($spans | length)) as $skipped
| ([ $spans[] | select(has("harness.version") | not) ] | length) as $noversion
| "::skipped \($skipped)",
  "::noversion \($noversion)",
  "::count \($spans | length)",
  ({ resourceSpans:
       [ { resource:
             { attributes:
                 [ { key: "service.name",
                     value: { stringValue: "agent-delivery-harness" } } ] },
           scopeSpans:
             [ { scope: { name: "agent-delivery-harness" },
                 spans: [ $spans[] | otlp_span ] } ] } ] })
JQ

  if ! otlp_projection="$(jq -nRr -f "$OTLP_FILTER" < "$TRACE_FILE")"; then
    red "error: the OTLP projection jq pass failed to run" >&2
    exit 2
  fi

  otlp_skipped="$(printf '%s\n' "$otlp_projection" | sed -n '1s/^::skipped //p')"
  otlp_noversion="$(printf '%s\n' "$otlp_projection" | sed -n '2s/^::noversion //p')"
  otlp_count="$(printf '%s\n' "$otlp_projection" | sed -n '3s/^::count //p')"
  if ! [[ "$otlp_skipped" =~ ^[0-9]+$ && "$otlp_noversion" =~ ^[0-9]+$ && "$otlp_count" =~ ^[0-9]+$ ]]; then
    red "error: the OTLP projection produced an unreadable header" >&2
    exit 2
  fi

  if [ "$otlp_skipped" -gt 0 ]; then
    yellow "notice: skipped ${otlp_skipped} malformed line(s) (not valid JSON spans); run ./scripts/validate-trace.sh for details" >&2
  fi

  # harness.version census (plan D6): all-or-nothing — a single span without
  # it aborts the whole OTLP projection (nothing written).
  if [ "$otlp_noversion" -gt 0 ]; then
    red "error: ${otlp_noversion} span(s) lack harness.version — refusing to export (harness.version is the queryable dimension; nothing written)" >&2
    exit 1
  fi

  # Stage first, then move into place (never write the destination directly).
  OTLP_STAGED="${TMP_DIR}/otlp.staged.json"
  {
    printf '// trace-export OTLP/HTTP+JSON dry-run dump — INTERNAL SEAM for sensors/CI only.\n'
    printf '// This format is not a stable contract; it may change without notice.\n'
    printf '// Strip these // comment lines to obtain one OTLP resourceSpans JSON object.\n'
    printf '%s\n' "$otlp_projection" | tail -n +4
  } > "$OTLP_STAGED"

  # Gate (feature 2): the SAME fail-closed redaction_gate that guards the
  # App-Insights path also guards the OTLP staged body — dry-run is NOT a
  # bypass (plan D4, one redaction policy). One call runs Gate 1 on the
  # INPUT trace ($TRACE_FILE) and Gate 2 on the staged OTLP OUTPUT before
  # anything leaves staging; any failure writes zero, and the gate's own
  # return code carries the house exit family (1 violation, 2 could-not-run).
  gate_rc=0
  redaction_gate "$OTLP_STAGED" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    exit "$gate_rc"
  fi

  # Dry-run seam: write the gated body and stop (never ships).
  if [ -n "$DRY_RUN_OTLP_FILE" ]; then
    OTLP_OUT_DIR="$(dirname "$DRY_RUN_OTLP_FILE")"
    mkdir -p "$OTLP_OUT_DIR"
    mv "$OTLP_STAGED" "$DRY_RUN_OTLP_FILE"
    green "dry run: wrote OTLP resourceSpans with ${otlp_count} span(s) to ${DRY_RUN_OTLP_FILE} (nothing shipped)"
    exit 0
  fi

  # Live native OTLP/HTTP ship (TRACE_EXPORT_OTLP_HTTP=1): the gate above
  # already passed on this exact staged body, so nothing secret-shaped can
  # POST. Independent of the App-Insights path — control falls through below to
  # the Track API ship as well when TRACE_EXPORT_OTLP=1 is ALSO set.
  ship_otlp "$OTLP_STAGED"
fi

# App-Insights path runs only when engaged: TRACE_EXPORT_OTLP=1 (live ship) or
# the --dry-run-to-file seam. When only the native OTLP/HTTP transport was
# requested, the block above already shipped — nothing more to do.
if [ "${TRACE_EXPORT_OTLP:-}" != "1" ] && [ -z "$DRY_RUN_FILE" ]; then
  exit 0
fi

# --- Single-pass jq projection (one jq invocation builds the whole array) -----
# Output protocol (parsed by bash below): three marker lines, then the
# pretty-printed envelope array:
#   ::skipped <N>     lines that are not JSON objects (skip-and-count);
#   ::noversion <N>   parsed spans missing harness.version (plan D6 abort);
#   ::count <N>       envelopes built.
MAPPING_FILTER="${TMP_DIR}/export-envelopes.jq"
cat > "$MAPPING_FILTER" <<'JQ'
# Shippable-attribute ALLOWLIST v1 (plan table + conductor-resolved forks:
# harness.warning IS allowlisted — enum-ish values from our own scripts;
# gen_ai.usage.* is a PREFIX rule). Deny-by-default: any key not matched
# here is dropped before envelope construction, so excluded free text
# (harness.args_summary, harness.summary, harness.worktree, harness.branch)
# and unknown/future keys are byte-absent from the output.
def allowlist:
  ["schema_version", "timestamp", "span", "span_id", "parent_span_id",
   "harness.issue", "harness.version",
   "harness.lifecycle_step", "harness.outcome", "harness.failure_mode",
   "harness.exit_status", "harness.duration_ms", "harness.incomplete_count",
   "harness.violation_count", "harness.warning_count",
   "harness.feature_id", "harness.stage",
   "gen_ai.tool.name", "gen_ai.operation.name", "gen_ai.agent.name",
   "gen_ai.request.model",
   "harness.review_gate_sha", "harness.pr_number",
   "harness.require_complete", "harness.warning", "harness.skill.name"];

def shippable_key:
  . as $k
  | ((allowlist | index($k)) != null) or ($k | startswith("gen_ai.usage."));

# properties → customDimensions: allowlisted keys only, values STRINGIFIED
# (Track API customDimensions are strings; numeric analysis rides
# measurements instead).
def props:
  [ to_entries[]
    | select(.key | shippable_key)
    | { key: .key, value: (.value | tostring) } ]
  | from_entries;

def lpad($n):
  tostring | if length >= $n then . else ("0" * ($n - length)) + . end;

# harness.duration_ms → Track API duration string, a .NET TimeSpan:
# hh:mm:ss.fff, gaining a day segment (d.hh:mm:ss.fff) at >= 24h — a bare
# hours field of 24+ is a malformed TimeSpan App Insights rejects or
# misparses. Absent input → "00:00:00.000"; a NEGATIVE input clamps to the
# honest floor "00:00:00.000" (garbage in never becomes malformed output).
def fmt_duration:
  ((. // 0) | floor | if . < 0 then 0 else . end) as $t
  | (($t / 86400000) | floor) as $days
  | (if $days > 0 then "\($days)." else "" end)
    + (((($t % 86400000) / 3600000) | floor) | lpad(2)) + ":"
    + (((($t % 3600000) / 60000) | floor) | lpad(2)) + ":"
    + (((($t % 60000) / 1000) | floor) | lpad(2)) + "."
    + (($t % 1000) | lpad(3));

# tool + lifecycle spans → RemoteDependencyData (AI dependencies table).
def dependency_base:
  . as $s
  | { ver: 2,
      name: (if $s.span == "tool"
             then ($s["gen_ai.tool.name"] // "unknown")
             else ($s["harness.lifecycle_step"] // "unknown")
             end),
      id: ($s["span_id"] // ""),
      type: (if $s.span == "tool" then "harness.tool" else "harness.lifecycle" end),
      duration: ($s["harness.duration_ms"] | fmt_duration),
      success: (if $s | has("harness.outcome")
                then ($s["harness.outcome"] == "pass")
                else true
                end),
      properties: ($s | props) }
  + (if $s | has("harness.exit_status")
     then { resultCode: ($s["harness.exit_status"] | tostring) }
     elif $s | has("harness.outcome")
     then { resultCode: ($s["harness.outcome"] | tostring) }
     else {}
     end);

# agent + model spans → EventData (AI customEvents table); numeric
# gen_ai.usage.* become measurements (JSON NUMBERS, never strings).
def event_base:
  . as $s
  | [ $s | to_entries[]
      | select((.key | startswith("gen_ai.usage.")) and (.value | type == "number")) ]
    as $usage
  | { ver: 2,
      name: (if $s.span == "agent"
             then "harness.agent/\($s["gen_ai.agent.name"] // "unknown")"
             else "harness.model/\($s["gen_ai.request.model"] // "unknown")"
             end),
      properties: ($s | props) }
  + (if ($usage | length) > 0 then { measurements: ($usage | from_entries) } else {} end);

# One span → one envelope. Dry-run envelopes OMIT iKey entirely; the
# transport (feature 3) injects it at ship time.
def envelope:
  . as $s
  | (if $s.span == "tool" or $s.span == "lifecycle"
     then { name: "Microsoft.ApplicationInsights.RemoteDependency",
            data: { baseType: "RemoteDependencyData", baseData: ($s | dependency_base) } }
     else { name: "Microsoft.ApplicationInsights.Event",
            data: { baseType: "EventData", baseData: ($s | event_base) } }
     end) as $shape
  | { ver: 1,
      name: $shape.name,
      time: ($s["timestamp"] // ""),
      sampleRate: 100,
      tags: { "ai.cloud.role": "agent-delivery-harness",
              "ai.operation.id": "issue-\($s["harness.issue"] // "unknown")" },
      data: $shape.data };

[inputs] as $lines
| [ $lines[] | fromjson? | select(type == "object") ] as $spans
| (($lines | length) - ($spans | length)) as $skipped
| ([ $spans[] | select(has("harness.version") | not) ] | length) as $noversion
| "::skipped \($skipped)",
  "::noversion \($noversion)",
  "::count \($spans | length)",
  ([ $spans[] | envelope ])
JQ

if ! projection="$(jq -nRr -f "$MAPPING_FILTER" < "$TRACE_FILE")"; then
  red "error: the envelope projection jq pass failed to run" >&2
  exit 2
fi

skipped="$(printf '%s\n' "$projection" | sed -n '1s/^::skipped //p')"
noversion="$(printf '%s\n' "$projection" | sed -n '2s/^::noversion //p')"
count="$(printf '%s\n' "$projection" | sed -n '3s/^::count //p')"
if ! [[ "$skipped" =~ ^[0-9]+$ && "$noversion" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]]; then
  red "error: the envelope projection produced an unreadable header" >&2
  exit 2
fi

# Skip-and-count (not refuse — refusal semantics are the feature-2 gate's).
if [ "$skipped" -gt 0 ]; then
  yellow "notice: skipped ${skipped} malformed line(s) (not valid JSON spans); run ./scripts/validate-trace.sh for details" >&2
fi

# harness.version is the queryable dimension (plan D6): all-or-nothing
# batch — a single span without it aborts the whole export.
if [ "$noversion" -gt 0 ]; then
  red "error: ${noversion} span(s) lack harness.version — refusing to export (harness.version is the queryable dimension; nothing shipped)" >&2
  exit 1
fi

# --- Stage the serialized envelope array (never write destinations directly) --
STAGED="${TMP_DIR}/envelopes.staged.json"
{
  printf '// trace-export dry-run envelope dump — INTERNAL SEAM for sensors/CI only.\n'
  printf '// This format is not a stable contract; it may change without notice.\n'
  printf '// Strip these // comment lines to obtain one JSON array of Track API envelopes.\n'
  printf '%s\n' "$projection" | tail -n +4
} > "$STAGED"

# Gate (feature 2): validates the INPUT and audits the staged OUTPUT
# before anything leaves the staging dir, on BOTH delivery paths. Any gate
# failure ships/writes zero envelopes; the gate's own return code carries
# the house exit family (1 violation, 2 could-not-run).
gate_rc=0
redaction_gate "$STAGED" || gate_rc=$?
if [ "$gate_rc" -ne 0 ]; then
  exit "$gate_rc"
fi

# --- Deliver: dry-run file or ship seam ---------------------------------------
if [ -n "$DRY_RUN_FILE" ]; then
  OUT_DIR="$(dirname "$DRY_RUN_FILE")"
  mkdir -p "$OUT_DIR"
  mv "$STAGED" "$DRY_RUN_FILE"
  green "dry run: wrote ${count} envelope(s) to ${DRY_RUN_FILE} (nothing shipped)"
  exit 0
fi

ship_envelopes "$STAGED" "$count"
