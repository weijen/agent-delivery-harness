#!/usr/bin/env bash
# test_trace_export_mapping.sh — regression sensor for scripts/trace-export.sh
# (issue #112, feature trace-export-mapping-core, plan Phase 1).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/trace-export.sh <issue-number|path/to/trace.jsonl> \
#                           [--dry-run-to-file <out.json>]
#
#   Projects a schema-v1 trace onto Application Insights Track API JSON
#   envelopes ("App-Insights-native envelopes carrying OTel-conventional
#   attribute names"). This sensor covers mapping + gating + the dry-run
#   seam ONLY — transport (curl) and the redaction gate are features 2/3.
#   This sensor never touches the network: a fake curl on the pinned PATH
#   records any invocation, and ANY invocation is a failure.
#
#   Opt-in gating (plan Gate 0, conductor-resolved):
#   - Without TRACE_EXPORT_OTLP=1: exit 0 no-op; the notice names
#     TRACE_EXPORT_OTLP; NOTHING is written — not even the --dry-run-to-file
#     target.
#   - With TRACE_EXPORT_OTLP=1 but no APPLICATIONINSIGHTS_CONNECTION_STRING:
#     the normal (ship) path is an exit-0 no-op whose notice names
#     APPLICATIONINSIGHTS_CONNECTION_STRING, BUT --dry-run-to-file works
#     WITHOUT a connection string (it doesn't ship — the CI seam must be
#     usable with zero config).
#
#   Dry-run output file (internal seam, conductor-resolved):
#   - Leading comment line(s) starting with '//' state that the file is an
#     "internal seam" and "not a stable contract" (case-insensitive), then
#     one JSON array of envelopes (strip '^//' lines before jq).
#   - Dry-run envelopes OMIT the iKey field entirely (the transport injects
#     it at ship time — feature 3's business).
#
#   Envelope mapping (plan mapping table v1):
#   - tool + lifecycle spans → name "Microsoft.ApplicationInsights.RemoteDependency",
#     data.baseType "RemoteDependencyData"; baseData.name = gen_ai.tool.name
#     (tool) or harness.lifecycle_step (lifecycle); baseData.type =
#     "harness.tool" / "harness.lifecycle"; baseData.id = span_id;
#     baseData.duration = harness.duration_ms as hh:mm:ss.fff
#     (omitted input → "00:00:00.000"); baseData.success = true unless
#     harness.outcome is a non-pass value; baseData.resultCode carries
#     harness.exit_status (stringified) when present.
#   - agent + model spans → name "Microsoft.ApplicationInsights.Event",
#     data.baseType "EventData"; baseData.name = "harness.agent/<agent>" /
#     "harness.model/<model>"; model span gen_ai.usage.* land in
#     baseData.measurements as JSON NUMBERS (never strings).
#   - Every envelope: ver == 1; time = the span's ISO-8601 timestamp;
#     tags["ai.operation.id"] == "issue-<NN>" (conductor-resolved);
#     baseData.properties (→ customDimensions) carries harness.version.
#
#   Allowlist v1 (deny-by-default; conductor-resolved: harness.warning IS
#   allowlisted — enum-ish values from our own scripts): properties carry
#   ONLY allowlisted keys (stringified), and every allowlisted key present
#   on a fixture span reaches its envelope's properties. The four excluded
#   fields — harness.args_summary, harness.summary, harness.worktree,
#   harness.branch — are BYTE-ABSENT from the whole output file (names AND
#   planted values), as is any unknown/future key's value.
#
#   harness.version census (plan D6): a single parsed span missing
#   harness.version aborts the WHOLE export — exit 1, nothing written
#   (all-or-nothing batch; the queryable dimension is load-bearing).
#
#   Malformed input lines (dry-run): the exporter is not a validator —
#   non-JSON lines are SKIPPED and COUNTED (notice mentions skipping and
#   the count); valid spans still export; exit 0. (Refusal semantics belong
#   to the feature-2 redaction gate.)
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed (RED
# while scripts/trace-export.sh does not exist).

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
  || hard_fail "jq is required to validate exporter envelope output"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -f "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found (${CONTRACT})"

# Pinned PATH: real tools only, plus a tripwire curl — this sensor is
# zero-network by contract (plan D5: the seam is --dry-run-to-file).
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp; do
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

# Planted MUST-NOT-SHIP values (distinctive, synthetic; chosen so they do
# not trip trace_redact — the byte-absence grep is the whole point).
V_ARGS="ARGSLEAK_zq9 redacted-then-capped args do not ship"
V_SUMMARY="SUMMARYLEAK_zq9 free text handback prose"
V_WORKTREE="/Users/plantedzq9/worktrees/issue-112"
V_BRANCH="feature/issue-112-plantedzq9"
V_UNKNOWN="DROPME_zq9 unknown future key"

# ==============================================================================
# RED gate: the exporter under test must exist before behavior can run.
# ==============================================================================
[ -f "$EXPORTER" ] \
  || { fail "scripts/trace-export.sh not found (${EXPORTER}) — feature trace-export-mapping-core (issue #112 Phase 1) is not implemented yet"; \
       printf '\n%d trace-export mapping contract violation(s).\n' "$fails" >&2; exit 1; }
[ -x "$EXPORTER" ] \
  || hard_fail "scripts/trace-export.sh exists but is not executable (${EXPORTER})"

# --- Fixture repo mirroring the harness layout (exporter resolves trace-lib
#     and friends relative to its own scripts/ dir) --------------------------
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

# Synthetic 5-span fixture: schema-valid, all 4 span types, fixed span_ids
# as join keys, numeric gen_ai.usage.*, and the four MUST-NOT-SHIP fields
# planted with distinctive values (plus one unknown key for deny-by-default).
IN="${TMP_DIR}/in.trace.jsonl"
cat > "$IN" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":112,"harness.version":"abc1234","span_id":"spanlc01","harness.lifecycle_step":"preflight","harness.worktree":"${V_WORKTREE}"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:01Z","span":"tool","harness.issue":112,"harness.version":"abc1234","span_id":"spantool1","parent_span_id":"spanlc01","gen_ai.tool.name":"git","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":1234,"harness.warning":"jq_skipped","harness.args_summary":"${V_ARGS}"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:02Z","span":"tool","harness.issue":112,"harness.version":"abc1234","span_id":"spantool2","gen_ai.tool.name":"gh","harness.outcome":"fail","harness.exit_status":2,"harness.duration_ms":40000,"harness.branch":"${V_BRANCH}"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:03Z","span":"agent","harness.issue":112,"harness.version":"abc1234","span_id":"spanagent","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.feature_id":"trace-export-mapping-core","harness.outcome":"pass","harness.summary":"${V_SUMMARY}"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:04Z","span":"model","harness.issue":112,"harness.version":"abc1234","span_id":"spanmodel","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000,"gen_ai.usage.total_tokens":22000,"custom.future_key":"${V_UNKNOWN}"}
JSONL

# Shippable-attribute ALLOWLIST v1 (plan table + conductor forks: harness.warning
# IN; gen_ai.usage.* is a prefix rule). Deny-by-default: anything else drops.
ALLOW='["schema_version","timestamp","span","span_id","parent_span_id",
"harness.issue","harness.version",
"harness.lifecycle_step","harness.outcome","harness.failure_mode",
"harness.exit_status","harness.duration_ms","harness.incomplete_count",
"harness.violation_count","harness.warning_count",
"harness.feature_id","harness.stage",
"gen_ai.tool.name","gen_ai.operation.name","gen_ai.agent.name","gen_ai.request.model",
"harness.review_gate_sha","harness.pr_number",
"harness.require_complete","harness.warning"]'

run_export() { # run_export <report-file> [ENVKV...] -- <args...>
  local rep="$1"; shift
  local -a envkv=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envkv+=("$1"); shift
  done
  [ "${1:-}" = "--" ] && shift
  (cd "$FIX" \
    && env -u TRACE_EXPORT_OTLP -u APPLICATIONINSIGHTS_CONNECTION_STRING \
       ${envkv[@]+"${envkv[@]}"} PATH="$BIN" \
       "./scripts/trace-export.sh" "$@") > "$rep" 2>&1
}

# ==============================================================================
# A. Opt-in gating (Gate 0).
# ==============================================================================
# A1. No TRACE_EXPORT_OTLP: exit 0, notice names the flag, NOTHING written —
#     including the --dry-run-to-file target.
G0OUT="${TMP_DIR}/g0.envelopes.json"
rc=0
run_export "${TMP_DIR}/a1.out" -- "$IN" --dry-run-to-file "$G0OUT" || rc=$?
[ "$rc" = "0" ] \
  || fail "A1: without TRACE_EXPORT_OTLP=1 the exporter must exit 0 (no-op), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/a1.out")"
grep -q 'TRACE_EXPORT_OTLP' "${TMP_DIR}/a1.out" \
  || fail "A1: the disabled notice must name TRACE_EXPORT_OTLP (actionable opt-in message)"
[ ! -e "$G0OUT" ] \
  || fail "A1: without the opt-in flag NOTHING may be written — dry-run file exists at ${G0OUT}"

# A2. TRACE_EXPORT_OTLP=1 but no connection string, normal (ship) path:
#     exit 0 no-op, notice names APPLICATIONINSIGHTS_CONNECTION_STRING.
rc=0
run_export "${TMP_DIR}/a2.out" TRACE_EXPORT_OTLP=1 -- "$IN" || rc=$?
[ "$rc" = "0" ] \
  || fail "A2: opt-in without APPLICATIONINSIGHTS_CONNECTION_STRING (ship path) must exit 0 no-op, got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/a2.out")"
grep -q 'APPLICATIONINSIGHTS_CONNECTION_STRING' "${TMP_DIR}/a2.out" \
  || fail "A2: the no-op notice must name APPLICATIONINSIGHTS_CONNECTION_STRING (actionable env contract)"

# ==============================================================================
# B. Dry-run seam: works with ZERO config beyond the opt-in flag (no
#    connection string), writes the header comment + one JSON envelope array.
# ==============================================================================
OUT="${TMP_DIR}/envelopes.json"
rc=0
run_export "${TMP_DIR}/b.out" TRACE_EXPORT_OTLP=1 -- "$IN" --dry-run-to-file "$OUT" || rc=$?
[ "$rc" = "0" ] \
  || fail "B: dry-run without a connection string must exit 0 (the CI seam needs zero config), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/b.out")"
[ -f "$OUT" ] \
  || { fail "B: dry-run must write the envelope file (${OUT}) — cannot continue mapping checks"; \
       printf '\n%d trace-export mapping contract violation(s).\n' "$fails" >&2; exit 1; }

# B1. Internal-seam header comment (conductor-resolved pin): leading '//'
#     line(s) saying the file is an internal seam, not a stable contract.
head -n 5 "$OUT" | grep -q '^//' \
  || fail "B1: the dry-run file must start with a '//' header comment (internal-seam disclaimer)"
head -n 5 "$OUT" | grep -qi 'internal seam' \
  || fail "B1: the header comment must call the dry-run file an internal seam"
head -n 5 "$OUT" | grep -qi 'not a stable contract' \
  || fail "B1: the header comment must say the format is not a stable contract"

# B2. Stripped of '^//' lines, the rest is ONE JSON array of 5 envelopes.
ENV_JSON="${TMP_DIR}/envelopes.parsed.json"
grep -v '^//' "$OUT" | jq -e 'type == "array" and length == 5' > /dev/null 2>&1 \
  || { fail "B2: after stripping '//' comment lines the dry-run file must be one JSON array with 5 envelopes (one per span)"; \
       printf '\n%d trace-export mapping contract violation(s).\n' "$fails" >&2; exit 1; }
grep -v '^//' "$OUT" | jq '.' > "$ENV_JSON"

# ==============================================================================
# C. Every-envelope pins: ver, time, no iKey, tags, harness.version.
# ==============================================================================
jq -e 'all(.[]; .ver == 1)' "$ENV_JSON" > /dev/null \
  || fail "C: every envelope must carry ver == 1 (JSON number)"
jq -e 'all(.[]; has("iKey") | not)' "$ENV_JSON" > /dev/null \
  || fail "C: dry-run envelopes must OMIT iKey entirely (transport injects it at ship time)"
jq -e 'all(.[]; .time | strings | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))' "$ENV_JSON" > /dev/null \
  || fail "C: every envelope time must be an ISO-8601 UTC string"
jq -e '[.[] | select(.data.baseData.properties["span_id"] == "spantool1")] | .[0].time == "2026-07-04T10:00:01Z"' "$ENV_JSON" > /dev/null \
  || fail "C: envelope time must be the SOURCE SPAN timestamp (spantool1 drifted)"
jq -e 'all(.[]; .tags["ai.operation.id"] == "issue-112")' "$ENV_JSON" > /dev/null \
  || fail "C: every envelope's tags must carry ai.operation.id == \"issue-112\" (conductor-resolved correlation id)"
jq -e 'all(.[]; .data.baseData.properties["harness.version"] == "abc1234")' "$ENV_JSON" > /dev/null \
  || fail "C: every envelope's customDimensions must carry harness.version (the queryable dimension)"
jq -e 'all(.[]; .data.baseData.properties | to_entries | all(.value | type == "string"))' "$ENV_JSON" > /dev/null \
  || fail "C: properties (customDimensions) values must be stringified"

# ==============================================================================
# D. Per-type envelope mapping pins.
# ==============================================================================
# D1. tool pass span → RemoteDependency: name/type/id/duration/success.
jq -e '[.[] | select(.data.baseData.properties["span_id"] == "spantool1")]
  | length == 1 and (.[0]
    | .name == "Microsoft.ApplicationInsights.RemoteDependency"
      and .data.baseType == "RemoteDependencyData"
      and .data.baseData.name == "git"
      and .data.baseData.type == "harness.tool"
      and .data.baseData.id == "spantool1"
      and .data.baseData.duration == "00:00:01.234"
      and .data.baseData.success == true)' "$ENV_JSON" > /dev/null \
  || fail "D1: tool pass span must map to RemoteDependency (name=git, type=harness.tool, id=span_id, duration 1234ms → 00:00:01.234, success=true)"

# D2. tool fail span → success=false, resultCode from harness.exit_status.
jq -e '[.[] | select(.data.baseData.properties["span_id"] == "spantool2")]
  | length == 1 and (.[0]
    | .name == "Microsoft.ApplicationInsights.RemoteDependency"
      and .data.baseData.success == false
      and .data.baseData.resultCode == "2"
      and .data.baseData.duration == "00:00:40.000")' "$ENV_JSON" > /dev/null \
  || fail "D2: tool fail span must map success=false and resultCode=\"2\" from harness.exit_status (40000ms → 00:00:40.000)"

# D3. lifecycle span → RemoteDependency named by lifecycle_step; no
#     harness.duration_ms in the input → pinned default duration; no
#     harness.outcome → success defaults to true.
jq -e '[.[] | select(.data.baseData.properties["span_id"] == "spanlc01")]
  | length == 1 and (.[0]
    | .name == "Microsoft.ApplicationInsights.RemoteDependency"
      and .data.baseType == "RemoteDependencyData"
      and .data.baseData.name == "preflight"
      and .data.baseData.type == "harness.lifecycle"
      and .data.baseData.duration == "00:00:00.000"
      and .data.baseData.success == true)' "$ENV_JSON" > /dev/null \
  || fail "D3: lifecycle span must map to RemoteDependency (name=lifecycle_step, type=harness.lifecycle, absent duration → 00:00:00.000, absent outcome → success=true)"

# D4. agent span → Event envelope.
jq -e '[.[] | select(.data.baseData.properties["span_id"] == "spanagent")]
  | length == 1 and (.[0]
    | .name == "Microsoft.ApplicationInsights.Event"
      and .data.baseType == "EventData"
      and .data.baseData.name == "harness.agent/conductor")' "$ENV_JSON" > /dev/null \
  || fail "D4: agent span must map to Event/EventData named harness.agent/<gen_ai.agent.name>"

# D5. model span → Event envelope; gen_ai.usage.* as NUMERIC measurements.
jq -e '[.[] | select(.data.baseData.properties["span_id"] == "spanmodel")]
  | length == 1 and (.[0]
    | .name == "Microsoft.ApplicationInsights.Event"
      and .data.baseType == "EventData"
      and .data.baseData.name == "harness.model/example-model"
      and .data.baseData.measurements["gen_ai.usage.input_tokens"] == 18000
      and .data.baseData.measurements["gen_ai.usage.output_tokens"] == 4000
      and .data.baseData.measurements["gen_ai.usage.total_tokens"] == 22000
      and (.data.baseData.measurements | to_entries | all(.value | type == "number")))' "$ENV_JSON" > /dev/null \
  || fail "D5: model span must map to Event/EventData named harness.model/<model> with gen_ai.usage.* as NUMERIC measurements (numbers, not strings)"

# ==============================================================================
# E. Allowlist exactness — BOTH directions.
# ==============================================================================
# E1. Deny-by-default: properties carry ONLY allowlisted keys (plus the
#     gen_ai.usage.* prefix family). custom.future_key must be dropped.
jq -e --argjson allow "$ALLOW" '
  all(.[]; .data.baseData.properties | keys
    | all(. as $k | (($allow | index($k)) != null) or ($k | startswith("gen_ai.usage."))))' \
  "$ENV_JSON" > /dev/null \
  || fail "E1: an envelope's customDimensions carries a key outside allowlist v1 (deny-by-default violated)"

# E2. Coverage: every allowlisted key present on a fixture span must land in
#     that span's envelope properties (joined on span_id).
jq -e -n --argjson allow "$ALLOW" --slurpfile spans "$IN" --slurpfile envs "$ENV_JSON" '
  ([$envs[0][] | {key: (.data.baseData.properties["span_id"] // "MISSING"),
                  value: .data.baseData.properties}] | from_entries) as $pmap
  | all($spans[]; . as $s
      | ($pmap[$s["span_id"]] // null) as $p
      | ($p != null)
        and ([$s | keys[] | . as $k
              | select((($allow | index($k)) != null)
                       or ($k | startswith("gen_ai.usage.")))]
             | all(. as $k | $p | has($k))))' > /dev/null \
  || fail "E2: an allowlisted field present on a fixture span did not reach its envelope's customDimensions (allowlist coverage gap)"

# E3. Byte-absence of the four excluded fields: names AND planted values
#     must not appear ANYWHERE in the raw output file (comments included).
for needle in \
  'harness.args_summary' 'harness.summary' 'harness.worktree' 'harness.branch' \
  'ARGSLEAK_zq9' 'SUMMARYLEAK_zq9' 'plantedzq9' 'DROPME_zq9'; do
  grep -qF -- "$needle" "$OUT" \
    && fail "E3: excluded/unknown material '${needle}' is present in the raw dry-run output — must be byte-absent"
done

# ==============================================================================
# F. Malformed input lines: skipped-with-count, valid spans still export.
# ==============================================================================
IN2="${TMP_DIR}/in2.trace.jsonl"
head -n 2 "$IN" > "$IN2"
printf '%s\n' '{"broken": ' >> "$IN2"
printf '%s\n' 'this is not json at all' >> "$IN2"
OUT2="${TMP_DIR}/envelopes2.json"
rc=0
run_export "${TMP_DIR}/f.out" TRACE_EXPORT_OTLP=1 -- "$IN2" --dry-run-to-file "$OUT2" || rc=$?
[ "$rc" = "0" ] \
  || fail "F: dry-run over a trace with malformed lines must exit 0 (skip-and-count, not refuse — refusal is feature 2), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/f.out")"
grep -qi 'skip' "${TMP_DIR}/f.out" \
  || fail "F: the exporter must report that malformed lines were SKIPPED"
grep -qE '(^|[^0-9])2([^0-9]|$)' "${TMP_DIR}/f.out" \
  || fail "F: the skip notice must carry the COUNT of skipped lines (2)"
if [ -f "$OUT2" ]; then
  grep -v '^//' "$OUT2" | jq -e 'type == "array" and length == 2' > /dev/null 2>&1 \
    || fail "F: the 2 valid spans must still export as 2 envelopes despite the 2 skipped lines"
else
  fail "F: skip-and-count dry-run must still write the envelope file (${OUT2})"
fi

# ==============================================================================
# F2. harness.version census (plan D6, all-or-nothing): a single span missing
#     harness.version aborts the WHOLE export — exit 1, NOTHING written (not
#     skip-and-count; the queryable dimension is load-bearing).
# ==============================================================================
IN3="${TMP_DIR}/in3.trace.jsonl"
head -n 2 "$IN" > "$IN3"
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T10:00:05Z","span":"tool","harness.issue":112,"span_id":"spannover","gen_ai.tool.name":"jq"}' >> "$IN3"
OUTV="${TMP_DIR}/envelopes-noversion.json"
rc=0
run_export "${TMP_DIR}/f2.out" TRACE_EXPORT_OTLP=1 -- "$IN3" --dry-run-to-file "$OUTV" || rc=$?
[ "$rc" = "1" ] \
  || fail "F2: a span missing harness.version must abort the whole export with exit 1 (all-or-nothing batch, plan D6), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/f2.out")"
grep -q 'harness\.version' "${TMP_DIR}/f2.out" \
  || fail "F2: the abort notice must name harness.version (actionable)"
[ ! -e "$OUTV" ] \
  || fail "F2: the harness.version abort must write NOTHING — dry-run file exists at ${OUTV}"

# ==============================================================================
# G. Issue-number input mode: <issue-number> resolves the contract trace
#    location .copilot-tracking/issues/issue-NN/trace.jsonl.
# ==============================================================================
mkdir -p "${FIX}/.copilot-tracking/issues/issue-112"
cp "$IN" "${FIX}/.copilot-tracking/issues/issue-112/trace.jsonl"
OUT3="${TMP_DIR}/envelopes3.json"
rc=0
run_export "${TMP_DIR}/g.out" TRACE_EXPORT_OTLP=1 -- 112 --dry-run-to-file "$OUT3" || rc=$?
[ "$rc" = "0" ] \
  || fail "G: issue-number mode (trace-export.sh 112) must resolve .copilot-tracking/issues/issue-112/trace.jsonl and exit 0, got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/g.out")"
if [ -f "$OUT3" ]; then
  grep -v '^//' "$OUT3" | jq -e 'type == "array" and length == 5' > /dev/null 2>&1 \
    || fail "G: issue-number mode must export the same 5 envelopes as path mode"
else
  fail "G: issue-number mode dry-run did not write the envelope file (${OUT3})"
fi

# ==============================================================================
# H. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "H: the exporter invoked curl during a gated/no-op/dry-run path — this sensor is zero-network by contract: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export mapping contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export mapping-core contract honored\n'
