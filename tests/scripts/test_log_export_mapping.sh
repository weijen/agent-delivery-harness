#!/usr/bin/env bash
# test_log_export_mapping.sh — regression sensor for the App-Insights
# MessageData projection of scripts/log-export.sh (issue #220, feature
# log-export-mapping, plan Phase 5).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/log-export.sh <path/to/log.jsonl> \
#                         --dry-run-logs-to-file <out.json>
#
#   A NEW dispatcher, sibling to scripts/trace-export.sh, projecting the
#   step-level detail stream (.copilot-tracking/issues/issue-NN/log.jsonl —
#   schema: log_schema_version:1, timestamp, level (info|warn|error),
#   "harness.issue":<int>, message, optional span_id/parent_span_id, plus
#   allowlisted key=value attrs) onto Application Insights Track API MessageData
#   envelopes (one per record). Like the trace App-Insights dry-run seam it
#   writes a file WITHOUT any network call and needs zero config beyond the
#   opt-in flag (LOG_EXPORT_OTLP=1); it never ships, so it never touches curl.
#   A fake curl on the pinned PATH records any invocation, and ANY invocation
#   is a failure.
#
#   schema-v1 log record → MessageData envelope mapping (the pins owned here):
#   - name "Microsoft.ApplicationInsights.Message"; data.baseType
#     "MessageData"; ver == 1 (JSON number); time == the record's ISO-8601
#     timestamp; dry-run envelopes OMIT iKey (the transport injects it).
#   - data.baseData.message == the record message.
#   - data.baseData.severityLevel from level — info→1, warn→2, error→3
#     (App-Insights SeverityLevel Information/Warning/Error, JSON numbers).
#   - tags["ai.operation.id"] == "issue-<NN>" (issue 220 → "issue-220"), the
#     correlation key #223 deep-links on.
#   - tags["ai.operation.parentId"] == the record span_id WHEN present
#     (correlates the log to its span); ABSENT when the record has no span_id.
#   - data.baseData.properties (→ customDimensions) carries ONLY allowlisted
#     structured fields (stringified); the excluded free-text fields
#     (harness.args_summary, harness.summary and friends) and secret-shaped
#     tokens are BYTE-ABSENT from the whole output file.
#
# RED while scripts/log-export.sh has no --dry-run-logs-to-file seam (the
# dispatcher does not exist): the unknown command is a usage/exec error and no
# MessageData file is produced.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTER="${ROOT}/scripts/log-export.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
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
  || hard_fail "jq is required to validate exporter MessageData output"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"

# Pinned PATH: real tools only, plus a tripwire curl — the dry-run MessageData
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
# deny-by-default surface, plus the gen_ai.usage.* prefix family). A property
# key outside this set is a leak.
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
# with 16-hex span_ids as the log→span correlation key:
#   - an info record WITH span_id + parent_span_id + an allowlisted attr
#     (gen_ai.tool.name) plus an EXCLUDED free-text field with a fake token;
#   - a warn record WITH span_id plus a second EXCLUDED free-text field;
#   - an error record WITHOUT span_id (uncorrelated — parentId omitted).
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
       printf '\n%d log-export MessageData mapping contract violation(s).\n' "$fails" >&2; exit 1; }

# ==============================================================================
# A. The MessageData dry-run seam runs, needs zero config, and writes the file.
# ==============================================================================
OUT="${TMP_DIR}/messages.json"
rc=0
run_export "${TMP_DIR}/a.out" -- "$IN" --dry-run-logs-to-file "$OUT" || rc=$?
[ "$rc" = "0" ] \
  || fail "A: 'log-export.sh <log> --dry-run-logs-to-file <out>' must exit 0 (zero-config MessageData dry-run seam), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/a.out")"
[ -f "$OUT" ] \
  || hard_fail "A: the --dry-run-logs-to-file seam is unimplemented — no MessageData file was written to ${OUT}. log-export.sh must gain the App-Insights MessageData mapping. Runner output: $(tr '\n' '|' < "${TMP_DIR}/a.out")"

# Strip any leading '//' internal-seam header lines (mirrors the trace
# App-Insights seam) before jq: the rest is ONE JSON array of 3 envelopes.
ENV_JSON="${TMP_DIR}/messages.parsed.json"
grep -v '^//' "$OUT" | jq -e 'type == "array" and length == 3' > /dev/null 2>&1 \
  || hard_fail "A: after stripping '//' comment lines the dry-run file must be one JSON array with 3 MessageData envelopes (one per record)"
grep -v '^//' "$OUT" | jq '.' > "$ENV_JSON"

# ==============================================================================
# B. Every-envelope pins: name, baseType, ver, no iKey, time, operation id.
# ==============================================================================
jq -e 'all(.[]; .name == "Microsoft.ApplicationInsights.Message" and .data.baseType == "MessageData")' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "B: every envelope must be name \"Microsoft.ApplicationInsights.Message\" with data.baseType \"MessageData\""
jq -e 'all(.[]; .ver == 1)' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "B: every envelope must carry ver == 1 (JSON number)"
jq -e 'all(.[]; has("iKey") | not)' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "B: dry-run envelopes must OMIT iKey entirely (transport injects it at ship time)"
jq -e 'all(.[]; .time | strings | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "B: every envelope time must be an ISO-8601 UTC string (the source record timestamp)"
jq -e '[.[] | select(.data.baseData.message == "tool invoked")] | .[0].time == "2026-07-10T10:00:00Z"' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "B: envelope time must be the SOURCE RECORD timestamp (info record drifted)"
jq -e 'all(.[]; .tags["ai.operation.id"] == "issue-220")' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "B: every envelope's tags must carry ai.operation.id == \"issue-220\" (the #223 deep-link correlation key)"

# ==============================================================================
# C. baseData.message == the record message.
# ==============================================================================
jq -e '[.[] | .data.baseData.message] | (index("tool invoked") != null) and (index("slow step") != null) and (index("step failed") != null)' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "C: every envelope's data.baseData.message must equal its input record message"

# ==============================================================================
# D. severityLevel from level — info→1, warn→2, error→3 (JSON numbers).
# ==============================================================================
jq -e '[.[] | select(.data.baseData.message == "tool invoked")] | .[0].data.baseData.severityLevel == 1' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "D: the info record must map data.baseData.severityLevel == 1 (App-Insights Information)"
jq -e '[.[] | select(.data.baseData.message == "slow step")] | .[0].data.baseData.severityLevel == 2' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "D: the warn record must map data.baseData.severityLevel == 2 (App-Insights Warning)"
jq -e '[.[] | select(.data.baseData.message == "step failed")] | .[0].data.baseData.severityLevel == 3' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "D: the error record must map data.baseData.severityLevel == 3 (App-Insights Error)"

# ==============================================================================
# E. ai.operation.parentId == span_id when present; absent when no span_id.
# ==============================================================================
jq -e '[.[] | select(.data.baseData.message == "tool invoked")] | .[0].tags["ai.operation.parentId"] == "aaaaaaaaaaaaaaaa"' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "E: the info record envelope must carry tags[\"ai.operation.parentId\"] == \"aaaaaaaaaaaaaaaa\" (its span_id — the log→span correlation)"
jq -e '[.[] | select(.data.baseData.message == "slow step")] | .[0].tags["ai.operation.parentId"] == "bbbbbbbbbbbbbbbb"' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "E: the warn record envelope must carry tags[\"ai.operation.parentId\"] == \"bbbbbbbbbbbbbbbb\" (its span_id)"
jq -e '[.[] | select(.data.baseData.message == "step failed")] | .[0].tags | (has("ai.operation.parentId") | not) or (.["ai.operation.parentId"] == "")' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "E: the uncorrelated error record (no span_id) must have NO (or empty) tags[\"ai.operation.parentId\"] — never fabricated"

# ==============================================================================
# F. properties (customDimensions): allowlist deny-by-default + stringified;
#    an allowlisted field present on a record reaches its envelope properties.
# ==============================================================================
jq -e --argjson allow "$ALLOW" '
  all(.[]; (.data.baseData.properties // {}) | keys
    | all(. as $k | (($allow | index($k)) != null) or ($k | startswith("gen_ai.usage."))))' \
  "$ENV_JSON" > /dev/null 2>&1 \
  || fail "F1: an envelope's customDimensions carries a key outside allowlist v1 (deny-by-default violated)"
jq -e 'all(.[]; (.data.baseData.properties // {}) | to_entries | all(.value | type == "string"))' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "F2: properties (customDimensions) values must be stringified"
jq -e '[.[] | select(.data.baseData.message == "tool invoked")] | .[0].data.baseData.properties["gen_ai.tool.name"] == "bash"' "$ENV_JSON" > /dev/null 2>&1 \
  || fail "F3: the info record's allowlisted gen_ai.tool.name must reach its envelope customDimensions (stringValue \"bash\")"

# ==============================================================================
# G. Byte-absence of excluded/secret material across the whole output file.
# ==============================================================================
for needle in \
  'harness.args_summary' 'harness.summary' \
  'ARGSLEAK_zq9' 'SUMLEAK_zq9' 'ghp_'; do
  { grep -qF -- "$needle" "$OUT" \
    && fail "G: excluded/secret material '${needle}' is present in the MessageData output — must be byte-absent (allowlist drop)"; } || true
done

# ==============================================================================
# H. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "H: the exporter invoked curl during the MessageData dry-run path — this seam is zero-network by contract: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d log-export MessageData mapping contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'log-export App-Insights MessageData mapping contract honored\n'
