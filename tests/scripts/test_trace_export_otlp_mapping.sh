#!/usr/bin/env bash
# test_trace_export_otlp_mapping.sh — regression sensor for the OTLP/HTTP+JSON
# projection of scripts/trace-export.sh (issue #151, feature otlp-http-mapping).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/trace-export.sh <path/to/trace.jsonl> \
#                           --dry-run-otlp-to-file <out.json>
#
#   A NEW dry-run seam mirroring the existing App-Insights --dry-run-to-file
#   seam, but emitting an OTLP/HTTP+JSON payload (the OTLP OTLPTraceService
#   request shape: a top-level { "resourceSpans": [ ... ] } object). Like the
#   App-Insights dry-run seam it writes to a file WITHOUT any network call and
#   needs zero config beyond the opt-in flag (TRACE_EXPORT_OTLP=1); it never
#   ships, so it never touches curl. A fake curl on the pinned PATH records any
#   invocation, and ANY invocation is a failure.
#
#   schema-v1 span  →  OTLP span mapping (the pins this sensor owns):
#   - Envelope: { resourceSpans: [ { resource: { attributes: [...] },
#     scopeSpans: [ { spans: [ <one per input span> ] } ] } ] }. The resource
#     carries a service.name attribute (agent-delivery-harness).
#   - span identity: OTLP .spanId == the input span_id (16 lowercase hex);
#     a span WITH parent_span_id carries .parentSpanId == that id; a span with
#     NO parent carries no (or empty) .parentSpanId.
#   - traceId: every span shares ONE 32-lowercase-hex .traceId, deterministic
#     per issue (derived from harness.issue) — the same trace groups the issue.
#   - kind: every span .kind == 1 (SPAN_KIND_INTERNAL).
#   - timestamps: .startTimeUnixNano is a numeric string; a span WITH
#     harness.duration_ms has .endTimeUnixNano == start + duration_ms * 1e6;
#     a single-point span (no duration) has .endTimeUnixNano == start (honest —
#     no fabricated duration). Nanosecond values exceed jq float precision, so
#     the delta is checked with bash 64-bit integer arithmetic.
#   - attributes: allowlist v1 (deny-by-default) — every attribute key is
#     allowlisted (or a gen_ai.usage.* member); the four allowlist-excluded
#     free-text fields (harness.args_summary and friends) never become
#     attributes and never appear anywhere in the file, secret-shaped tokens
#     included. Each attribute is an OTLP { key, value: { stringValue: ... } }
#     object (numeric usage may ride intValue — not exercised here).
#
# RED while scripts/trace-export.sh has no --dry-run-otlp-to-file seam: the
# unknown flag is a usage error (exit 2) and no OTLP file is produced.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

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
if ! command -v jq >/dev/null 2>&1; then
  hard_fail "jq is required to validate exporter OTLP output"
fi
if [ ! -f "$EXPORTER" ]; then
  hard_fail "scripts/trace-export.sh not found (${EXPORTER})"
fi
if [ ! -x "$EXPORTER" ]; then
  hard_fail "scripts/trace-export.sh exists but is not executable (${EXPORTER})"
fi
if [ ! -f "$TRACE_LIB" ]; then
  hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
fi
if [ ! -f "$ISSUE_LIB" ]; then
  hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
fi
if [ ! -f "$VALIDATOR" ]; then
  hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
fi
if [ ! -f "$CONTRACT" ]; then
  hard_fail "trace schema contract not found (${CONTRACT})"
fi

# Pinned PATH: real tools only, plus a tripwire curl — the dry-run OTLP seam
# is zero-network by contract (it writes a file, never ships).
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp; do
  p="$(command -v "$t" || true)"
  if [ -n "$p" ]; then
    ln -sf "$p" "${BIN}/${t}"
  fi
done
CURL_MARKER="${TMP_DIR}/curl-was-called"
cat > "${BIN}/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "${CURL_MARKER}"
exit 7
SH
chmod +x "${BIN}/curl"

# Shippable-attribute ALLOWLIST v1 (mirrors the App-Insights projection: the
# same deny-by-default surface, plus the gen_ai.usage.* prefix family). An
# OTLP span attribute key outside this set is a leak.
ALLOW='["schema_version","timestamp","span","span_id","parent_span_id",
"harness.issue","harness.version",
"harness.lifecycle_step","harness.outcome","harness.failure_mode",
"harness.exit_status","harness.duration_ms","harness.incomplete_count",
"harness.violation_count","harness.warning_count",
"harness.feature_id","harness.stage",
"gen_ai.tool.name","gen_ai.operation.name","gen_ai.agent.name","gen_ai.request.model",
"harness.review_gate_sha","harness.pr_number",
"harness.require_complete","harness.warning","harness.skill.name"]'

# --- Fixture trace -----------------------------------------------------------
# Two schema-valid spans covering the OTLP mapping surface, with 16-hex
# span_ids (8-byte OTLP SpanId) as join keys:
#   - a `tool` span (self-measured: harness.duration_ms=120) carrying an
#     EXCLUDED harness.args_summary with a SUB-THRESHOLD fake token. The token
#     is deliberately short (< 20 chars after `ghp_`) so it does NOT trip
#     trace_redact — the point of assertion F is that the ALLOWLIST drops the
#     whole field, not that redaction masks it. A redactable (>=20 char) token
#     would fail the input at validate-trace.sh's redaction audit before any
#     OTLP mapping could run.
#   - an `agent` span parented on the tool span, single-point (no duration).
# harness.version is added to every span: the schema requires it and the
# exporter aborts the batch without it (harness.version census, plan D6), so a
# fixture that omits it could never reach the OTLP projection.
V_ARGS="SECRET ghp_FAKEtoken must not ship"
IN="${TMP_DIR}/in.trace.jsonl"
cat > "$IN" <<JSONL
{"schema_version":1,"timestamp":"2026-07-07T10:15:00Z","span":"tool","harness.issue":151,"harness.version":"1.2.3","span_id":"aaaaaaaaaaaaaaaa","gen_ai.tool.name":"bash","gen_ai.operation.name":"execute_tool","harness.outcome":"pass","harness.duration_ms":120,"harness.args_summary":"${V_ARGS}"}
{"schema_version":1,"timestamp":"2026-07-07T10:15:01Z","span":"agent","harness.issue":151,"harness.version":"1.2.3","span_id":"bbbbbbbbbbbbbbbb","parent_span_id":"aaaaaaaaaaaaaaaa","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"github-copilot","harness.outcome":"pass"}
JSONL

run_export() { # run_export <report-file> -- <args...>
  local rep="$1"; shift
  [ "${1:-}" = "--" ] && shift
  (env -u APPLICATIONINSIGHTS_CONNECTION_STRING \
     TRACE_EXPORT_OTLP=1 PATH="$BIN" \
     "$EXPORTER" "$@") > "$rep" 2>&1
}

# ==============================================================================
# A. The new OTLP dry-run seam runs, needs zero config, and writes the file.
# ==============================================================================
OUT="${TMP_DIR}/otlp.json"
rc=0
run_export "${TMP_DIR}/a.out" -- "$IN" --dry-run-otlp-to-file "$OUT" || rc=$?
if [ "$rc" != "0" ]; then
  fail "A: 'trace-export.sh <trace> --dry-run-otlp-to-file <out>' must exit 0 (zero-config OTLP dry-run seam), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/a.out")"
fi
if [ ! -f "$OUT" ]; then
  hard_fail "A: the --dry-run-otlp-to-file seam is unimplemented — no OTLP file was written to ${OUT} (unknown flag / usage error). trace-export.sh must gain the OTLP/HTTP+JSON mapping. Runner output: $(tr '\n' '|' < "${TMP_DIR}/a.out")"
fi

# Strip any leading '//' internal-seam header lines (mirrors the App-Insights
# seam; a no-op when the OTLP file has no header) before jq.
PARSED="${TMP_DIR}/otlp.parsed.json"
if ! grep -v '^//' "$OUT" | jq '.' > "$PARSED" 2>/dev/null; then
  hard_fail "A: the OTLP dry-run file is not valid JSON after stripping '//' header lines (${OUT})"
fi

# ==============================================================================
# B. Valid OTLP envelope: resourceSpans array, resource.attributes with
#    service.name, and one span per input span under scopeSpans.
# ==============================================================================
if ! jq -e '.resourceSpans | type == "array" and length >= 1' "$PARSED" > /dev/null 2>&1; then
  hard_fail "B: the OTLP payload must have a non-empty .resourceSpans array (OTLPTraceService request shape)"
fi
if ! jq -e '.resourceSpans[0].resource.attributes | type == "array" and length >= 1' "$PARSED" > /dev/null 2>&1; then
  fail "B: .resourceSpans[0].resource.attributes must exist (Resource-level attributes)"
fi
if ! jq -e '[.resourceSpans[0].resource.attributes[] | select(.key == "service.name")] | .[0].value.stringValue == "agent-delivery-harness"' "$PARSED" > /dev/null 2>&1; then
  fail "B: the OTLP resource must carry a service.name attribute == \"agent-delivery-harness\""
fi
if ! jq -e '.resourceSpans[0].scopeSpans[0].spans | type == "array"' "$PARSED" > /dev/null 2>&1; then
  fail "B: .resourceSpans[0].scopeSpans[0].spans must be an array"
fi

# Flatten every OTLP span across resourceSpans/scopeSpans as the working set.
SPANS="${TMP_DIR}/otlp.spans.json"
jq '[.resourceSpans[].scopeSpans[].spans[]]' "$PARSED" > "$SPANS"
if ! jq -e 'length == 2' "$SPANS" > /dev/null 2>&1; then
  hard_fail "B: the OTLP payload must carry exactly one span per input span (2 expected), got $(jq 'length' "$SPANS")"
fi

# ==============================================================================
# C. Span identity + parent linkage.
# ==============================================================================
# Each OTLP spanId equals its input span_id (16 lowercase hex).
if ! jq -e 'all(.[]; .spanId | type == "string" and test("^[0-9a-f]{16}$"))' "$SPANS" > /dev/null 2>&1; then
  fail "C: every OTLP .spanId must be a 16-lowercase-hex string (8-byte SpanId)"
fi
if ! jq -e '[.[] | .spanId] | (index("aaaaaaaaaaaaaaaa") != null) and (index("bbbbbbbbbbbbbbbb") != null)' "$SPANS" > /dev/null 2>&1; then
  fail "C: OTLP .spanId values must equal the input span_id join keys (aaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbb)"
fi
# The agent span (bbbb) carries parentSpanId == the tool span (aaaa).
if ! jq -e '[.[] | select(.spanId == "bbbbbbbbbbbbbbbb")] | .[0].parentSpanId == "aaaaaaaaaaaaaaaa"' "$SPANS" > /dev/null 2>&1; then
  fail "C: the agent span must carry parentSpanId == \"aaaaaaaaaaaaaaaa\" (parent_span_id linkage)"
fi
# The tool span (no input parent) has no / empty parentSpanId (never fabricated).
if ! jq -e '[.[] | select(.spanId == "aaaaaaaaaaaaaaaa")] | .[0] | (has("parentSpanId") | not) or (.parentSpanId == "")' "$SPANS" > /dev/null 2>&1; then
  fail "C: the root tool span must have NO (or empty) parentSpanId — no fabricated parent"
fi

# ==============================================================================
# D. traceId: one deterministic 32-lowercase-hex id per issue, shared by all
#    spans (derived from harness.issue).
# ==============================================================================
if ! jq -e 'all(.[]; .traceId | type == "string" and test("^[0-9a-f]{32}$"))' "$SPANS" > /dev/null 2>&1; then
  fail "D: every OTLP .traceId must be a 32-lowercase-hex string (16-byte TraceId)"
fi
if ! jq -e '[.[] | .traceId] | unique | length == 1' "$SPANS" > /dev/null 2>&1; then
  fail "D: all spans of one issue must share ONE .traceId (deterministic per harness.issue)"
fi

# ==============================================================================
# E. kind: every span is SPAN_KIND_INTERNAL (1).
# ==============================================================================
if ! jq -e 'all(.[]; .kind == 1)' "$SPANS" > /dev/null 2>&1; then
  fail "E: every OTLP span .kind must == 1 (SPAN_KIND_INTERNAL)"
fi

# ==============================================================================
# E2. Timestamps: startTimeUnixNano numeric-string; the tool span (120ms)
#     ends 120000000 ns later; the single-point agent span ends at its start.
#     Nanosecond values exceed jq's float precision, so the arithmetic runs in
#     bash 64-bit integers.
# ==============================================================================
TOOL_START="$(jq -r '[.[] | select(.spanId == "aaaaaaaaaaaaaaaa")] | .[0].startTimeUnixNano // ""' "$SPANS")"
TOOL_END="$(jq -r '[.[] | select(.spanId == "aaaaaaaaaaaaaaaa")] | .[0].endTimeUnixNano // ""' "$SPANS")"
AGENT_START="$(jq -r '[.[] | select(.spanId == "bbbbbbbbbbbbbbbb")] | .[0].startTimeUnixNano // ""' "$SPANS")"
AGENT_END="$(jq -r '[.[] | select(.spanId == "bbbbbbbbbbbbbbbb")] | .[0].endTimeUnixNano // ""' "$SPANS")"

if ! [[ "$TOOL_START" =~ ^[0-9]+$ ]]; then
  fail "E2: the tool span .startTimeUnixNano must be a numeric string, got '${TOOL_START}'"
elif ! [[ "$TOOL_END" =~ ^[0-9]+$ ]]; then
  fail "E2: the tool span .endTimeUnixNano must be a numeric string, got '${TOOL_END}'"
else
  expected_end=$(( TOOL_START + 120000000 ))
  if [ "$TOOL_END" != "$expected_end" ]; then
    fail "E2: the tool span (harness.duration_ms=120) must have endTimeUnixNano == startTimeUnixNano + 120000000 (${expected_end}), got ${TOOL_END}"
  fi
fi
if ! [[ "$AGENT_START" =~ ^[0-9]+$ ]]; then
  fail "E2: the agent span .startTimeUnixNano must be a numeric string, got '${AGENT_START}'"
elif ! [[ "$AGENT_END" =~ ^[0-9]+$ ]]; then
  fail "E2: the agent span .endTimeUnixNano must be a numeric string, got '${AGENT_END}'"
elif [ "$AGENT_START" != "$AGENT_END" ]; then
  fail "E2: the single-point agent span (no duration) must have endTimeUnixNano == startTimeUnixNano (no fabricated duration), got start=${AGENT_START} end=${AGENT_END}"
fi

# ==============================================================================
# F. Allowlist + secret-safety over span attributes.
# ==============================================================================
# F1. Deny-by-default: every attribute key is allowlisted (or gen_ai.usage.*).
if ! jq -e --argjson allow "$ALLOW" '
  all(.[]; (.attributes // [])
    | all(.[]; .key as $k
        | (($allow | index($k)) != null) or ($k | startswith("gen_ai.usage."))))' \
  "$SPANS" > /dev/null 2>&1; then
  fail "F1: an OTLP span attribute key is outside allowlist v1 (deny-by-default violated)"
fi
# F2. An allowlisted key IS present as an attribute (the tool span's tool name).
if ! jq -e '[.[] | select(.spanId == "aaaaaaaaaaaaaaaa")] | .[0].attributes
    | (type == "array")
      and ([.[] | select(.key == "gen_ai.tool.name")] | .[0].value.stringValue == "bash")' \
  "$SPANS" > /dev/null 2>&1; then
  fail "F2: the tool span must carry an allowlisted gen_ai.tool.name attribute (stringValue \"bash\")"
fi
# F3. The EXCLUDED harness.args_summary must never become an attribute.
if ! jq -e 'all(.[]; (.attributes // []) | all(.[]; .key != "harness.args_summary"))' "$SPANS" > /dev/null 2>&1; then
  fail "F3: harness.args_summary is allowlist-excluded — it must never appear as an OTLP attribute"
fi
# F4. The fake token substring must be byte-absent from the whole output file.
if grep -qF -- 'ghp_' "$OUT"; then
  fail "F4: the excluded fake-token material 'ghp_' is present in the OTLP output — must be byte-absent (allowlist drop)"
fi
if grep -qF -- 'harness.args_summary' "$OUT"; then
  fail "F4: the excluded field name 'harness.args_summary' is present in the OTLP output — must be byte-absent"
fi

# ==============================================================================
# G. Attribute shape: OTLP { key, value: { stringValue: ... } } objects.
# ==============================================================================
if ! jq -e 'all(.[]; (.attributes // [])
    | all(.[];
        (.key | type == "string")
        and (.value | type == "object")
        and ((.value | has("stringValue")) or (.value | has("intValue")) or (.value | has("boolValue")))))' \
  "$SPANS" > /dev/null 2>&1; then
  fail "G: every OTLP attribute must be a { key, value: { stringValue|intValue|boolValue } } object"
fi

# ==============================================================================
# H. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "H: the exporter invoked curl during the OTLP dry-run path — this seam is zero-network by contract: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export OTLP mapping contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export OTLP/HTTP+JSON mapping contract honored\n'
