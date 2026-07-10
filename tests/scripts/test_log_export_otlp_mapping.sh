#!/usr/bin/env bash
# test_log_export_otlp_mapping.sh — regression sensor for the OTLP/HTTP+JSON
# LOGS projection of scripts/log-export.sh (issue #220, feature
# log-export-mapping, plan Phase 5).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/log-export.sh <path/to/log.jsonl> \
#                         --dry-run-otlp-logs-to-file <out.json>
#
#   A NEW dispatcher, sibling to scripts/trace-export.sh, projecting the
#   step-level detail stream (.copilot-tracking/issues/issue-NN/log.jsonl —
#   schema: log_schema_version:1, timestamp, level (info|warn|error),
#   "harness.issue":<int>, message, optional span_id/parent_span_id, plus
#   allowlisted key=value attrs) onto an OTLP/HTTP+JSON **logs** signal (the
#   OTLPLogService request shape: a top-level { "resourceLogs": [ ... ] }
#   object). Like trace-export.sh's --dry-run-otlp-to-file seam it writes to a
#   file WITHOUT any network call and needs zero config beyond the opt-in flag
#   (LOG_EXPORT_OTLP=1); it never ships, so it never touches curl. A fake curl
#   on the pinned PATH records any invocation, and ANY invocation is a failure.
#
#   schema-v1 log record → OTLP logRecord mapping (the pins this sensor owns):
#   - Envelope: { resourceLogs: [ { resource: { attributes: [...] },
#     scopeLogs: [ { logRecords: [ <one per input record> ] } ] } ] }. The
#     resource carries a service.name attribute (agent-delivery-harness),
#     mirroring the span OTLP resource.
#   - traceId: every logRecord shares ONE 32-lowercase-hex .traceId,
#     deterministic per issue (derived from harness.issue via the SAME
#     derivation as scripts/trace_tools/otlp.py trace_id() — issue 220 →
#     000000000000000000000000000000dc). This is the join key the span export
#     already emits, so a log correlates to its issue's trace.
#   - spanId: a record WITH span_id carries .spanId == that id (16 lowercase
#     hex); a record with NO span_id carries no (or empty) .spanId — honest,
#     never fabricated.
#   - severityNumber: derived from level — info→9, warn→13, error→17 (OTLP
#     SeverityNumber INFO/WARN/ERROR); .severityText == the level string.
#   - body: .body.stringValue == the record message.
#   - timeUnixNano: a numeric string == epoch-seconds(timestamp) * 1e9 (the
#     same epoch derivation as otlp.py: "<epoch>000000000"). Nanosecond values
#     exceed jq float precision, so the per-second delta is checked with bash
#     64-bit integer arithmetic.
#   - attributes: allowlist v1 (deny-by-default) — every attribute key is
#     allowlisted (or a gen_ai.usage.* member); the excluded free-text fields
#     (harness.args_summary, harness.summary and friends) never become
#     attributes and never appear anywhere in the file, secret-shaped tokens
#     included. Each attribute is an OTLP { key, value: { stringValue: ... } }
#     object.
#
# RED while scripts/log-export.sh has no --dry-run-otlp-logs-to-file seam (the
# dispatcher does not exist): the unknown command is a usage/exec error and no
# OTLP logs file is produced.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTER="${ROOT}/scripts/log-export.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# The 32-hex per-issue traceId for issue 220 (otlp.py trace_id: 220 → "dc",
# left-padded with 0 to 32). Shared by every logRecord in this issue's stream.
EXPECT_TRACE_ID="000000000000000000000000000000dc"

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
  || hard_fail "jq is required to validate exporter OTLP logs output"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"

# Pinned PATH: real tools only, plus a tripwire curl — the dry-run OTLP logs
# seam is zero-network by contract (it writes a file, never ships).
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp python3; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done
CURL_MARKER="${TMP_DIR}/curl-was-called"
cat > "${BIN}/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "${CURL_MARKER}"
exit 7
SH
chmod +x "${BIN}/curl"

# Shippable-attribute ALLOWLIST v1 (mirrors the span projection: the same
# deny-by-default surface, plus the gen_ai.usage.* prefix family). A log
# attribute key outside this set is a leak.
ALLOW='["schema_version","timestamp","span","span_id","parent_span_id",
"harness.issue","harness.version",
"harness.lifecycle_step","harness.outcome","harness.failure_mode",
"harness.exit_status","harness.duration_ms","harness.incomplete_count",
"harness.violation_count","harness.warning_count",
"harness.feature_id","harness.stage",
"gen_ai.tool.name","gen_ai.operation.name","gen_ai.agent.name","gen_ai.request.model",
"harness.review_gate_sha","harness.pr_number",
"harness.require_complete","harness.warning","harness.skill.name","harness.subagent"]'

# Planted MUST-NOT-SHIP values (distinctive, synthetic; the ghp_ token is
# deliberately short so it does NOT trip trace_redact — the byte-absence grep
# proves the ALLOWLIST drops the whole field, not that redaction masks it).
V_ARGS="ARGSLEAK_zq9 ghp_FAKEtoken must not ship"
V_SUMMARY="SUMLEAK_zq9 free text handback prose"

# --- Fixture log stream ------------------------------------------------------
# Three schema-valid log records for issue 220 covering the mapping surface,
# with 16-hex span_ids (8-byte OTLP SpanId) as join keys:
#   - an info record WITH span_id + parent_span_id + an allowlisted attr
#     (gen_ai.tool.name) plus an EXCLUDED free-text field with a fake token;
#   - a warn record WITH span_id plus a second EXCLUDED free-text field;
#   - an error record WITHOUT span_id (single, uncorrelated — spanId omitted).
IN="${TMP_DIR}/in.log.jsonl"
cat > "$IN" <<JSONL
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:00Z","level":"info","harness.issue":220,"message":"tool invoked","span_id":"aaaaaaaaaaaaaaaa","parent_span_id":"cccccccccccccccc","gen_ai.tool.name":"bash","harness.args_summary":"${V_ARGS}"}
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:01Z","level":"warn","harness.issue":220,"message":"slow step","span_id":"bbbbbbbbbbbbbbbb","harness.summary":"${V_SUMMARY}"}
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:02Z","level":"error","harness.issue":220,"message":"step failed"}
JSONL

run_export() { # run_export <report-file> -- <args...>
  local rep="$1"; shift
  [ "${1:-}" = "--" ] && shift
  (env -u APPLICATIONINSIGHTS_CONNECTION_STRING \
     LOG_EXPORT_OTLP=1 PATH="$BIN" \
     "$EXPORTER" "$@") > "$rep" 2>&1
}

# ==============================================================================
# RED gate: the dispatcher under test must exist before behavior can run.
# ==============================================================================
{ [ -f "$EXPORTER" ] && [ -x "$EXPORTER" ]; } \
  || { fail "scripts/log-export.sh not found or not executable (${EXPORTER}) — feature log-export-mapping (issue #220 Phase 5) is not implemented yet"; \
       printf '\n%d log-export OTLP logs mapping contract violation(s).\n' "$fails" >&2; exit 1; }

# ==============================================================================
# A. The OTLP logs dry-run seam runs, needs zero config, and writes the file.
# ==============================================================================
OUT="${TMP_DIR}/otlp-logs.json"
rc=0
run_export "${TMP_DIR}/a.out" -- "$IN" --dry-run-otlp-logs-to-file "$OUT" || rc=$?
[ "$rc" = "0" ] \
  || fail "A: 'log-export.sh <log> --dry-run-otlp-logs-to-file <out>' must exit 0 (zero-config OTLP logs dry-run seam), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/a.out")"
[ -f "$OUT" ] \
  || hard_fail "A: the --dry-run-otlp-logs-to-file seam is unimplemented — no OTLP logs file was written to ${OUT}. log-export.sh must gain the OTLP/HTTP+JSON logs mapping. Runner output: $(tr '\n' '|' < "${TMP_DIR}/a.out")"

# Strip any leading '//' internal-seam header lines (mirrors the span OTLP
# seam; a no-op when the file has no header) before jq.
PARSED="${TMP_DIR}/otlp-logs.parsed.json"
grep -v '^//' "$OUT" | jq '.' > "$PARSED" 2>/dev/null \
  || hard_fail "A: the OTLP logs dry-run file is not valid JSON after stripping '//' header lines (${OUT})"

# ==============================================================================
# B. Valid OTLP logs envelope: resourceLogs array, resource.attributes with
#    service.name, and one logRecord per input record under scopeLogs.
# ==============================================================================
jq -e '.resourceLogs | type == "array" and length >= 1' "$PARSED" > /dev/null 2>&1 \
  || hard_fail "B: the OTLP payload must have a non-empty .resourceLogs array (OTLPLogService request shape)"
jq -e '.resourceLogs[0].resource.attributes | type == "array" and length >= 1' "$PARSED" > /dev/null 2>&1 \
  || fail "B: .resourceLogs[0].resource.attributes must exist (Resource-level attributes)"
jq -e '[.resourceLogs[0].resource.attributes[] | select(.key == "service.name")] | .[0].value.stringValue == "agent-delivery-harness"' "$PARSED" > /dev/null 2>&1 \
  || fail "B: the OTLP resource must carry a service.name attribute == \"agent-delivery-harness\""
jq -e '.resourceLogs[0].scopeLogs[0].logRecords | type == "array"' "$PARSED" > /dev/null 2>&1 \
  || fail "B: .resourceLogs[0].scopeLogs[0].logRecords must be an array"

# Flatten every OTLP logRecord across resourceLogs/scopeLogs as the working set.
RECS="${TMP_DIR}/otlp-logs.records.json"
jq '[.resourceLogs[].scopeLogs[].logRecords[]]' "$PARSED" > "$RECS"
jq -e 'length == 3' "$RECS" > /dev/null 2>&1 \
  || hard_fail "B: the OTLP payload must carry exactly one logRecord per input record (3 expected), got $(jq 'length' "$RECS")"

# ==============================================================================
# C. traceId: one deterministic 32-lowercase-hex id per issue, shared by all
#    records (derived from harness.issue via otlp.py trace_id).
# ==============================================================================
jq -e 'all(.[]; .traceId | type == "string" and test("^[0-9a-f]{32}$"))' "$RECS" > /dev/null 2>&1 \
  || fail "C: every OTLP logRecord .traceId must be a 32-lowercase-hex string (16-byte TraceId)"
jq -e --arg tid "$EXPECT_TRACE_ID" 'all(.[]; .traceId == $tid)' "$RECS" > /dev/null 2>&1 \
  || fail "C: every logRecord must share the deterministic per-issue traceId \"${EXPECT_TRACE_ID}\" (issue 220 via otlp.py trace_id — the span/log join key)"

# ==============================================================================
# D. spanId: present records carry the input span_id; the uncorrelated record
#    carries no / empty spanId (never fabricated).
# ==============================================================================
# The info record (message "tool invoked") carries spanId aaaa; the warn
# record (message "slow step") carries spanId bbbb.
jq -e '[.[] | select(.body.stringValue == "tool invoked")] | .[0].spanId == "aaaaaaaaaaaaaaaa"' "$RECS" > /dev/null 2>&1 \
  || fail "D: the info logRecord must carry .spanId == \"aaaaaaaaaaaaaaaa\" (its input span_id, the log→span join)"
jq -e '[.[] | select(.body.stringValue == "slow step")] | .[0].spanId == "bbbbbbbbbbbbbbbb"' "$RECS" > /dev/null 2>&1 \
  || fail "D: the warn logRecord must carry .spanId == \"bbbbbbbbbbbbbbbb\" (its input span_id)"
# The error record (no input span_id) has no / empty spanId — never fabricated.
jq -e '[.[] | select(.body.stringValue == "step failed")] | .[0] | (has("spanId") | not) or (.spanId == "")' "$RECS" > /dev/null 2>&1 \
  || fail "D: the uncorrelated error logRecord (no input span_id) must have NO (or empty) .spanId — never fabricated"

# ==============================================================================
# E. severity: severityNumber from level (info→9, warn→13, error→17);
#    severityText == the level string.
# ==============================================================================
jq -e '[.[] | select(.body.stringValue == "tool invoked")] | .[0] | .severityNumber == 9 and .severityText == "info"' "$RECS" > /dev/null 2>&1 \
  || fail "E: the info record must map severityNumber==9 (OTLP INFO) and severityText==\"info\""
jq -e '[.[] | select(.body.stringValue == "slow step")] | .[0] | .severityNumber == 13 and .severityText == "warn"' "$RECS" > /dev/null 2>&1 \
  || fail "E: the warn record must map severityNumber==13 (OTLP WARN) and severityText==\"warn\""
jq -e '[.[] | select(.body.stringValue == "step failed")] | .[0] | .severityNumber == 17 and .severityText == "error"' "$RECS" > /dev/null 2>&1 \
  || fail "E: the error record must map severityNumber==17 (OTLP ERROR) and severityText==\"error\""

# ==============================================================================
# F. body: .body.stringValue == the record message (all three carried).
# ==============================================================================
jq -e '[.[] | .body.stringValue] | (index("tool invoked") != null) and (index("slow step") != null) and (index("step failed") != null)' "$RECS" > /dev/null 2>&1 \
  || fail "F: every logRecord .body.stringValue must equal its input record message"

# ==============================================================================
# G. timeUnixNano: numeric string == epoch-seconds(timestamp) * 1e9. The three
#    fixture timestamps are consecutive whole seconds, so the info→warn and
#    warn→error deltas are exactly 1e9 ns (checked in bash 64-bit integers,
#    which the nanosecond magnitude requires).
# ==============================================================================
T_INFO="$(jq -r '[.[] | select(.body.stringValue == "tool invoked")] | .[0].timeUnixNano // ""' "$RECS")"
T_WARN="$(jq -r '[.[] | select(.body.stringValue == "slow step")] | .[0].timeUnixNano // ""' "$RECS")"
T_ERR="$(jq -r '[.[] | select(.body.stringValue == "step failed")] | .[0].timeUnixNano // ""' "$RECS")"
if ! [[ "$T_INFO" =~ ^[0-9]+000000000$ ]]; then
  fail "G: the info logRecord .timeUnixNano must be a numeric string of epoch-seconds*1e9 (…000000000), got '${T_INFO}'"
elif ! [[ "$T_WARN" =~ ^[0-9]+000000000$ ]] || ! [[ "$T_ERR" =~ ^[0-9]+000000000$ ]]; then
  fail "G: every logRecord .timeUnixNano must be a numeric string of epoch-seconds*1e9 (…000000000), got warn='${T_WARN}' error='${T_ERR}'"
else
  if [ "$T_WARN" != "$(( T_INFO + 1000000000 ))" ]; then
    fail "G: the warn record (timestamp +1s) must have timeUnixNano == info + 1000000000 ($(( T_INFO + 1000000000 ))), got ${T_WARN}"
  fi
  if [ "$T_ERR" != "$(( T_INFO + 2000000000 ))" ]; then
    fail "G: the error record (timestamp +2s) must have timeUnixNano == info + 2000000000 ($(( T_INFO + 2000000000 ))), got ${T_ERR}"
  fi
fi

# ==============================================================================
# H. Allowlist + secret-safety over logRecord attributes.
# ==============================================================================
# H1. Deny-by-default: every attribute key is allowlisted (or gen_ai.usage.*).
jq -e --argjson allow "$ALLOW" '
  all(.[]; (.attributes // [])
    | all(.[]; .key as $k
        | (($allow | index($k)) != null) or ($k | startswith("gen_ai.usage."))))' \
  "$RECS" > /dev/null 2>&1 \
  || fail "H1: an OTLP logRecord attribute key is outside allowlist v1 (deny-by-default violated)"
# H2. An allowlisted key IS present as an attribute (the info record tool name).
jq -e '[.[] | select(.body.stringValue == "tool invoked")] | .[0].attributes
    | (type == "array")
      and ([.[] | select(.key == "gen_ai.tool.name")] | .[0].value.stringValue == "bash")' \
  "$RECS" > /dev/null 2>&1 \
  || fail "H2: the info record must carry an allowlisted gen_ai.tool.name attribute (stringValue \"bash\")"
# H3. The EXCLUDED free-text fields must never become attributes.
jq -e 'all(.[]; (.attributes // []) | all(.[]; .key != "harness.args_summary" and .key != "harness.summary"))' "$RECS" > /dev/null 2>&1 \
  || fail "H3: harness.args_summary / harness.summary are allowlist-excluded — they must never appear as OTLP attributes"

# ==============================================================================
# I. Attribute shape: OTLP { key, value: { stringValue: ... } } objects.
# ==============================================================================
jq -e 'all(.[]; (.attributes // [])
    | all(.[];
        (.key | type == "string")
        and (.value | type == "object")
        and ((.value | has("stringValue")) or (.value | has("intValue")) or (.value | has("boolValue")))))' \
  "$RECS" > /dev/null 2>&1 \
  || fail "I: every OTLP attribute must be a { key, value: { stringValue|intValue|boolValue } } object"

# ==============================================================================
# J. Byte-absence of excluded/secret material across the whole output file.
# ==============================================================================
for needle in \
  'harness.args_summary' 'harness.summary' \
  'ARGSLEAK_zq9' 'SUMLEAK_zq9' 'ghp_'; do
  { grep -qF -- "$needle" "$OUT" \
    && fail "J: excluded/secret material '${needle}' is present in the OTLP logs output — must be byte-absent (allowlist drop)"; } || true
done

# ==============================================================================
# K. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "K: the exporter invoked curl during the OTLP logs dry-run path — this seam is zero-network by contract: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d log-export OTLP logs mapping contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'log-export OTLP/HTTP+JSON logs mapping contract honored\n'
