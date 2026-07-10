#!/usr/bin/env bash
# test_log_export_correlation.sh — cross-stream correlation oracle for the
# span exporter (scripts/trace-export.sh) and the log exporter
# (scripts/log-export.sh) (issue #220, feature `log-export-correlation`,
# plan Phase 8). This is the CI-parity SUBSTITUTE for the human-gated live
# ship: it runs BOTH exporters' dry-run seams over the SAME issue-220 fixture
# pair and asserts that the two signals join into ONE trace.
#
# Contract under test (PINNED HERE as the executable spec):
#
#   ONE issue-220 fixture pair — a trace.jsonl (spans, each with a span_id)
#   and a log.jsonl (log records, some carrying span_id referencing those
#   spans) — is projected through all FOUR dry-run seams, zero-network:
#     - trace-export.sh --dry-run-to-file        (App-Insights envelopes)
#     - trace-export.sh --dry-run-otlp-to-file   (OTLP resourceSpans)
#     - log-export.sh   --dry-run-logs-to-file   (App-Insights MessageData)
#     - log-export.sh   --dry-run-otlp-logs-to-file (OTLP resourceLogs)
#   None of the four ships, so none touches curl. A fake curl on the pinned
#   PATH records ANY invocation, and any invocation is a FAIL.
#
#   Cross-stream correlation obligations (the pins this sensor owns):
#     1. App-Insights operation id equality — the span export's
#        ai.operation.id (== "issue-220") EQUALS the log export's
#        ai.operation.id on EVERY MessageData envelope. One operation groups
#        both streams (#223 deep-link).
#     2. OTLP traceId equality — the span export's OTLP traceId
#        (issue 220 → 000000000000000000000000000000dc, via otlp.py trace_id)
#        EQUALS the log export's OTLP traceId on EVERY logRecord. One trace
#        groups both streams.
#     3. Span linkage (App-Insights) — every log MessageData
#        operation_ParentId (tags["ai.operation.parentId"], present when the
#        record carries a span_id) equals the span id of some ACTUALLY-EMITTED
#        span envelope (a RemoteDependencyData baseData.id). No dangling
#        parent id.
#     4. Span linkage (OTLP) — every log resourceLogs .spanId (present when
#        the record carries a span_id) equals the .spanId of some emitted span
#        in the span export's resourceSpans. No dangling span reference.
#
# Correlation already holds from Phase 5: log-export.sh reuses the SAME
# per-issue trace_id derivation and the SAME "issue-<NN>" operation-id format
# the span export emits. This sensor therefore CHARACTERIZES that existing
# behaviour (a documented no-RED-first waiver, mirroring how
# tests/scripts/test_export_optin_contract.sh characterizes existing
# behaviour). It is load-bearing: perturbing any correlated id in either
# fixture stream breaks an equality/linkage assertion.
#
# Exit codes: 0 contract honored · 1 a correlation obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if TOPLEVEL="$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)"; then
  ROOT="${TOPLEVEL}"
fi
TRACE_EXPORTER="${ROOT}/scripts/trace-export.sh"
LOG_EXPORTER="${ROOT}/scripts/log-export.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Deterministic 32-lowercase-hex per-issue OTLP TraceId for issue 220 (otlp.py
# trace_id: 220 decimal → hex "dc", left-padded with 0 to 32). Shared by every
# span AND every log record of this issue — the join key both streams emit.
EXPECT_TRACE_ID="000000000000000000000000000000dc"
# The App-Insights operation id both streams stamp (the #223 deep-link key).
EXPECT_OP_ID="issue-220"

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
  || hard_fail "jq is required to validate exporter correlation output"
{ [ -f "$TRACE_EXPORTER" ] && [ -x "$TRACE_EXPORTER" ]; } \
  || hard_fail "scripts/trace-export.sh not found or not executable (${TRACE_EXPORTER})"
{ [ -f "$LOG_EXPORTER" ] && [ -x "$LOG_EXPORTER" ]; } \
  || hard_fail "scripts/log-export.sh not found or not executable (${LOG_EXPORTER})"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"

# Pinned PATH: real tools only, plus a tripwire curl — all four dry-run seams
# are zero-network by contract (they write files, never ship). Any curl call
# is a FAIL.
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

# --- Fixture pair (ONE issue-220 stream, two signals) ------------------------
# trace.jsonl — three schema-v1 spans, each carrying harness.version (the
# all-or-nothing census dimension) and a 16-hex span_id (8-byte OTLP SpanId):
#   - a lifecycle span (root, no parent)          span_id cccc…
#   - a tool span (child of the lifecycle span)   span_id aaaa…
#   - an agent span (Event/EventData; has an OTLP spanId but no App-Insights
#     baseData.id)                                span_id dddd…
TRACE_IN="${TMP_DIR}/trace.jsonl"
cat > "$TRACE_IN" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-10T10:00:00Z","span":"lifecycle","harness.issue":220,"harness.version":"abc1234","span_id":"cccccccccccccccc","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"2026-07-10T10:00:01Z","span":"tool","harness.issue":220,"harness.version":"abc1234","span_id":"aaaaaaaaaaaaaaaa","parent_span_id":"cccccccccccccccc","gen_ai.tool.name":"bash","harness.outcome":"pass","harness.duration_ms":1200}
{"schema_version":1,"timestamp":"2026-07-10T10:00:02Z","span":"agent","harness.issue":220,"harness.version":"abc1234","span_id":"dddddddddddddddd","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.outcome":"pass"}
JSONL

# log.jsonl — three schema-v1 log records for the SAME issue:
#   - an info record referencing the tool span      (span_id aaaa…)
#   - a warn record referencing the lifecycle span  (span_id cccc…)
#   - an error record WITHOUT span_id (uncorrelated — no parent id / no spanId)
# The two correlated records deliberately point at tool/lifecycle span ids so
# each parent id resolves to a RemoteDependencyData baseData.id (App-Insights)
# AND an OTLP span spanId.
LOG_IN="${TMP_DIR}/log.jsonl"
cat > "$LOG_IN" <<'JSONL'
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:01Z","level":"info","harness.issue":220,"message":"tool invoked","span_id":"aaaaaaaaaaaaaaaa","gen_ai.tool.name":"bash"}
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:00Z","level":"warn","harness.issue":220,"message":"preflight slow","span_id":"cccccccccccccccc"}
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:03Z","level":"error","harness.issue":220,"message":"step failed"}
JSONL

# --- Drive the four dry-run seams (zero-network) -----------------------------
SPAN_AI="${TMP_DIR}/span-appinsights.json"
SPAN_OTLP="${TMP_DIR}/span-otlp.json"
LOG_AI="${TMP_DIR}/log-messagedata.json"
LOG_OTLP="${TMP_DIR}/log-otlp.json"

# The span exporter: the App-Insights and OTLP span dry-run seams are separate
# runs (the OTLP seam exits after writing its file), over the SAME fixture.
srr=0
( env -u APPLICATIONINSIGHTS_CONNECTION_STRING -u TRACE_EXPORT_OTLP_HTTP \
    TRACE_EXPORT_OTLP=1 PATH="$BIN" \
    "$TRACE_EXPORTER" "$TRACE_IN" \
    --dry-run-to-file "$SPAN_AI" ) > "${TMP_DIR}/span-ai.out" 2>&1 || srr=$?
[ "$srr" = "0" ] \
  || hard_fail "the span App-Insights dry-run run must exit 0, got ${srr}: $(tr '\n' '|' < "${TMP_DIR}/span-ai.out")"
srr=0
( env -u APPLICATIONINSIGHTS_CONNECTION_STRING -u TRACE_EXPORT_OTLP_HTTP \
    TRACE_EXPORT_OTLP=1 PATH="$BIN" \
    "$TRACE_EXPORTER" "$TRACE_IN" \
    --dry-run-otlp-to-file "$SPAN_OTLP" ) > "${TMP_DIR}/span-otlp.out" 2>&1 || srr=$?
[ "$srr" = "0" ] \
  || hard_fail "the span OTLP dry-run run must exit 0, got ${srr}: $(tr '\n' '|' < "${TMP_DIR}/span-otlp.out")"

# The log exporter: both MessageData and OTLP-logs dry-run seams in one run.
lrr=0
( env -u APPLICATIONINSIGHTS_CONNECTION_STRING \
    LOG_EXPORT_OTLP=1 PATH="$BIN" \
    "$LOG_EXPORTER" "$LOG_IN" \
    --dry-run-logs-to-file "$LOG_AI" \
    --dry-run-otlp-logs-to-file "$LOG_OTLP" ) > "${TMP_DIR}/log.out" 2>&1 || lrr=$?
[ "$lrr" = "0" ] \
  || hard_fail "the log exporter dry-run run must exit 0, got ${lrr}: $(tr '\n' '|' < "${TMP_DIR}/log.out")"

for f in "$SPAN_AI" "$SPAN_OTLP" "$LOG_AI" "$LOG_OTLP"; do
  [ -f "$f" ] \
    || hard_fail "expected dry-run output file was not written: ${f}"
done

# Strip the leading '//' internal-seam header lines before jq (a no-op when a
# file has no header).
parse() { # parse <raw-file> <parsed-file> <label>
  grep -v '^//' "$1" | jq '.' > "$2" 2>/dev/null \
    || hard_fail "${3}: dry-run output is not valid JSON after stripping '//' header lines ($1)"
}
SPAN_AI_P="${TMP_DIR}/span-appinsights.parsed.json"
SPAN_OTLP_P="${TMP_DIR}/span-otlp.parsed.json"
LOG_AI_P="${TMP_DIR}/log-messagedata.parsed.json"
LOG_OTLP_P="${TMP_DIR}/log-otlp.parsed.json"
parse "$SPAN_AI" "$SPAN_AI_P" "span App-Insights"
parse "$SPAN_OTLP" "$SPAN_OTLP_P" "span OTLP"
parse "$LOG_AI" "$LOG_AI_P" "log MessageData"
parse "$LOG_OTLP" "$LOG_OTLP_P" "log OTLP"

# Working sets: log envelopes/records, and the emitted span id sets.
LOG_ENV="${TMP_DIR}/log-envelopes.json"       # App-Insights MessageData array
LOG_RECS="${TMP_DIR}/log-records.json"        # OTLP logRecords, flattened
SPAN_ENV="${TMP_DIR}/span-envelopes.json"     # App-Insights envelope array
SPAN_OTLP_SPANS="${TMP_DIR}/span-otlp-spans.json"  # OTLP spans, flattened
cp "$LOG_AI_P" "$LOG_ENV"
jq '[.resourceLogs[].scopeLogs[].logRecords[]]' "$LOG_OTLP_P" > "$LOG_RECS"
cp "$SPAN_AI_P" "$SPAN_ENV"
jq '[.resourceSpans[].scopeSpans[].spans[]]' "$SPAN_OTLP_P" > "$SPAN_OTLP_SPANS"

# Sanity: non-empty working sets (guards against a vacuously-true "all(...)").
jq -e 'type == "array" and length >= 1' "$LOG_ENV" > /dev/null 2>&1 \
  || hard_fail "the log MessageData export produced no envelopes"
jq -e 'length >= 1' "$LOG_RECS" > /dev/null 2>&1 \
  || hard_fail "the log OTLP export produced no logRecords"
jq -e 'type == "array" and length >= 1' "$SPAN_ENV" > /dev/null 2>&1 \
  || hard_fail "the span App-Insights export produced no envelopes"
jq -e 'length >= 1' "$SPAN_OTLP_SPANS" > /dev/null 2>&1 \
  || hard_fail "the span OTLP export produced no spans"

# ==============================================================================
# 1. App-Insights operation id equality: span export's ai.operation.id ==
#    "issue-220" == the log export's ai.operation.id on EVERY MessageData
#    envelope (one operation groups both streams).
# ==============================================================================
jq -e --arg op "$EXPECT_OP_ID" 'all(.[]; .tags["ai.operation.id"] == $op)' "$SPAN_ENV" > /dev/null 2>&1 \
  || fail "1: every span envelope must stamp ai.operation.id == \"${EXPECT_OP_ID}\" (the span side of the join)"
jq -e --arg op "$EXPECT_OP_ID" 'all(.[]; .tags["ai.operation.id"] == $op)' "$LOG_ENV" > /dev/null 2>&1 \
  || fail "1: every log MessageData envelope must stamp ai.operation.id == \"${EXPECT_OP_ID}\" (the log side of the join)"
# Cross-stream equality: the distinct operation ids of BOTH streams collapse to
# the single shared id (not merely each equal to a literal in isolation).
SPAN_OPS="$(jq -c '[.[].tags["ai.operation.id"]] | unique' "$SPAN_ENV")"
LOG_OPS="$(jq -c '[.[].tags["ai.operation.id"]] | unique' "$LOG_ENV")"
{ [ "$SPAN_OPS" = "[\"${EXPECT_OP_ID}\"]" ] && [ "$LOG_OPS" = "$SPAN_OPS" ]; } \
  || fail "1: the span and log streams must share ONE ai.operation.id; span=${SPAN_OPS} log=${LOG_OPS} (expected [\"${EXPECT_OP_ID}\"])"

# ==============================================================================
# 2. OTLP traceId equality: span export's traceId (…dc) == the log export's
#    traceId on EVERY logRecord (one trace groups both streams).
# ==============================================================================
jq -e --arg tid "$EXPECT_TRACE_ID" 'all(.[]; .traceId == $tid)' "$SPAN_OTLP_SPANS" > /dev/null 2>&1 \
  || fail "2: every OTLP span must carry traceId == \"${EXPECT_TRACE_ID}\" (the span side of the join)"
jq -e --arg tid "$EXPECT_TRACE_ID" 'all(.[]; .traceId == $tid)' "$LOG_RECS" > /dev/null 2>&1 \
  || fail "2: every OTLP logRecord must carry traceId == \"${EXPECT_TRACE_ID}\" (the log side of the join)"
SPAN_TIDS="$(jq -c '[.[].traceId] | unique' "$SPAN_OTLP_SPANS")"
LOG_TIDS="$(jq -c '[.[].traceId] | unique' "$LOG_RECS")"
{ [ "$SPAN_TIDS" = "[\"${EXPECT_TRACE_ID}\"]" ] && [ "$LOG_TIDS" = "$SPAN_TIDS" ]; } \
  || fail "2: the span and log streams must share ONE OTLP traceId; span=${SPAN_TIDS} log=${LOG_TIDS} (expected [\"${EXPECT_TRACE_ID}\"])"

# ==============================================================================
# 3. Span linkage (App-Insights): every log envelope's operation_ParentId
#    (tags["ai.operation.parentId"], present when the record carried a span_id)
#    equals the span id of some ACTUALLY-EMITTED span envelope
#    (RemoteDependencyData baseData.id). No dangling parent id.
# ==============================================================================
# The set of span ids the App-Insights span export actually emitted.
SPAN_AI_IDS="$(jq -c '[.[].data.baseData.id | select(. != null and . != "")] | unique' "$SPAN_ENV")"
# Positive coverage: at least one log envelope carries an operation.parentId
# (otherwise the linkage check would be vacuous).
n_parent="$(jq '[.[] | select(.tags | has("ai.operation.parentId"))] | length' "$LOG_ENV")"
[ "${n_parent:-0}" -ge 1 ] \
  || fail "3: expected at least one log MessageData envelope carrying ai.operation.parentId (correlated record) — linkage would be vacuous"
# Every present parent id resolves to an emitted span baseData.id.
jq -e --argjson ids "$SPAN_AI_IDS" '
  all(.[]
      | select(.tags | has("ai.operation.parentId"))
      | .tags["ai.operation.parentId"];
      . as $p | ($ids | index($p)) != null)' "$LOG_ENV" > /dev/null 2>&1 \
  || fail "3: a log MessageData operation_ParentId does not match any emitted span baseData.id (dangling App-Insights linkage); emitted span ids=${SPAN_AI_IDS}"

# ==============================================================================
# 4. Span linkage (OTLP): every log logRecord's .spanId (present when the
#    record carried a span_id) equals the .spanId of some emitted span in the
#    span export's resourceSpans. No dangling span reference.
# ==============================================================================
SPAN_OTLP_IDS="$(jq -c '[.[].spanId | select(. != null and . != "")] | unique' "$SPAN_OTLP_SPANS")"
n_spanid="$(jq '[.[] | select(has("spanId") and (.spanId != ""))] | length' "$LOG_RECS")"
[ "${n_spanid:-0}" -ge 1 ] \
  || fail "4: expected at least one OTLP logRecord carrying a spanId (correlated record) — linkage would be vacuous"
jq -e --argjson ids "$SPAN_OTLP_IDS" '
  all(.[]
      | select(has("spanId") and (.spanId != ""))
      | .spanId;
      . as $s | ($ids | index($s)) != null)' "$LOG_RECS" > /dev/null 2>&1 \
  || fail "4: a log OTLP logRecord .spanId does not match any emitted span .spanId (dangling OTLP linkage); emitted span ids=${SPAN_OTLP_IDS}"

# ==============================================================================
# 5. Zero-network pin: no seam in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "5: an exporter invoked curl during a dry-run seam — all four seams are zero-network by contract: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d span+log cross-stream correlation contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'span+log cross-stream correlation contract honored\n'
