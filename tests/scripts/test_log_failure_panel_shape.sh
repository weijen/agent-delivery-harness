#!/usr/bin/env bash
# test_log_failure_panel_shape.sh — e2e shape oracle for the Tab 2
# failure-detail LOG panel (issue #225, feature F1
# `dashboard-failure-log-panel`, plan Phase 1 e2e_sensor). This crosses the
# real exporter runtime boundary: it projects a FAILED-GATE log fixture through
# scripts/log-export.sh's App-Insights MessageData dry-run seam
# (--dry-run-logs-to-file) and asserts the MessageData → `traces`-table columns
# the Workbook panel's KQL keys on are ACTUALLY emitted for a failure record.
#
# WHY a runtime sensor (Risk 1 in the plan): the static drift sensor
# (tests/scripts/test_trace_dashboard_pack.sh) can only grep the panel's KQL
# markers; it cannot verify that the NATIVE `traces` columns the panel projects
# (`message` ← baseData.message, `severityLevel` ← baseData.severityLevel,
# `operation_Id` ← tags["ai.operation.id"], `operation_ParentId` ←
# tags["ai.operation.parentId"] = the log record's span_id) are the ones the
# exporter really emits — a typo'd column would chart nulls silently. This
# sensor pins that leg-B fidelity for the traces columns the static sensor
# cannot see.
#
# Contract under test (PINNED HERE as the executable spec) — for a FAILURE log
# record (`level == "error"`, `harness.outcome == "fail"`, a `harness.stage`, a
# `message`, a `span_id`, `harness.issue == 225`), the emitted MessageData
# envelope must carry:
#   1. baseData.message           — the captured failure output (→ traces
#      `message` column), non-empty.
#   2. baseData.severityLevel == 3 — App-Insights Error, which the panel filters
#      as `severityLevel >= 3` (→ traces `severityLevel` column).
#   3. tags["ai.operation.id"] == "issue-225" — the panel's primary run
#      correlation key (→ traces `operation_Id` column).
#   4. tags["ai.operation.parentId"] == <span_id> — the failing-span link
#      (→ traces `operation_ParentId` column); confirmed against logmap.py's
#      operation_ParentId ← span_id (NOT parent_span_id).
#   5. baseData.properties["harness.outcome"] == "fail" — the panel's FAILURE
#      filter dimension (→ traces customDimensions['harness.outcome']).
#   6. baseData.properties["harness.stage"] == <stage> — the failure grouping
#      dimension (→ traces customDimensions['harness.stage']).
#   7. baseData.properties["harness.issue"] == "225" — for grid readability
#      (→ traces customDimensions['harness.issue']).
#
# The seam is zero-network by contract (it writes a file, never ships). A
# tripwire curl on the pinned PATH records ANY invocation, and any invocation
# is a FAIL.
#
# CHARACTERIZATION NOTE (no-RED-first waiver): the MessageData shape is emitted
# by #220's already-merged logmap.py, so this sensor may be GREEN from merge —
# it CHARACTERIZES the existing exporter contract the panel depends on (a
# documented waiver, mirroring tests/scripts/test_log_export_correlation.sh). It
# is load-bearing: perturbing any asserted field breaks an assertion (verified
# by mutation). F1's RED driver is the drift-sensor panel-4 leg, not this e2e.
#
# Exit codes: 0 shape honored (or exporter cleanly skipped) · 1 a shape
# obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if TOPLEVEL="$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT="${TOPLEVEL}"
fi
LOG_EXPORTER="${ROOT}/scripts/log-export.sh"

EXPECT_OP_ID="issue-225"
EXPECT_SPAN_ID="bbbbbbbbbbbbbbbb"
EXPECT_STAGE="ci_checks"
EXPECT_ISSUE="225"

fails=0
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	fails=$((fails + 1))
}

# --- Prerequisites (honest SKIP when an optional tool is absent) --------------
if ! command -v jq >/dev/null 2>&1; then
	printf 'warning: jq not installed — cannot validate MessageData shape; skipping\n' >&2
	printf 'ok - log failure-panel shape # SKIP jq not installed\n'
	exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
	printf 'warning: python3 not installed — the log exporter mapping engine is unavailable; skipping\n' >&2
	printf 'ok - log failure-panel shape # SKIP python3 not installed\n'
	exit 0
fi
if ! { [ -f "$LOG_EXPORTER" ] && [ -x "$LOG_EXPORTER" ]; }; then
	fail "scripts/log-export.sh not found or not executable (${LOG_EXPORTER})"
	exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Pinned PATH: real tools only, plus a tripwire curl — the dry-run seam is
# zero-network by contract (it writes a file, never ships). Any curl call FAILS.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
	date dirname basename mkdir rm cp mv od cmp touch mktemp python3 uv; do
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

# --- Fixture: one FAILED-GATE log record (the #219 failure-path shape) --------
# A gate FAILURE log record: level=="error", harness.outcome=="fail", grouped by
# harness.stage, carrying the captured message and a span_id linking it to the
# failing span. A second (info) record and a third (warn) record ensure the
# projection is not vacuously single-row and that the FAILURE filter is
# discriminating.
LOG_IN="${TMP_DIR}/log.jsonl"
cat > "$LOG_IN" <<'JSONL'
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:00Z","level":"info","harness.issue":225,"message":"ci_checks started","span_id":"aaaaaaaaaaaaaaaa","harness.stage":"ci_checks","harness.outcome":"pass"}
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:02Z","level":"error","harness.issue":225,"message":"gate failed: shellcheck reported 2 findings","span_id":"bbbbbbbbbbbbbbbb","harness.stage":"ci_checks","harness.outcome":"fail"}
{"log_schema_version":1,"timestamp":"2026-07-10T10:00:03Z","level":"warn","harness.issue":225,"message":"retrying","span_id":"cccccccccccccccc","harness.stage":"ci_checks"}
JSONL

# --- Drive the App-Insights MessageData dry-run seam (zero-network) -----------
LOG_AI="${TMP_DIR}/log-messagedata.json"
lrr=0
( env -u APPLICATIONINSIGHTS_CONNECTION_STRING \
	LOG_EXPORT_OTLP=1 PATH="$BIN" \
	"$LOG_EXPORTER" "$LOG_IN" \
	--dry-run-logs-to-file "$LOG_AI" ) > "${TMP_DIR}/log.out" 2>&1 || lrr=$?
[ "$lrr" = "0" ] \
	|| { fail "the log exporter dry-run run must exit 0, got ${lrr}: $(tr '\n' '|' < "${TMP_DIR}/log.out")"; exit 1; }
[ -f "$LOG_AI" ] \
	|| { fail "expected dry-run output file was not written: ${LOG_AI}"; exit 1; }

# Strip the leading '//' internal-seam header lines before jq (no-op when none).
LOG_ENV="${TMP_DIR}/log-envelopes.json"
grep -v '^//' "$LOG_AI" | jq '.' > "$LOG_ENV" 2>/dev/null \
	|| { fail "MessageData dry-run output is not valid JSON after stripping '//' header lines (${LOG_AI})"; exit 1; }

jq -e 'type == "array" and length >= 1' "$LOG_ENV" > /dev/null 2>&1 \
	|| { fail "the log MessageData export produced no envelopes"; exit 1; }

# --- Isolate the FAILURE envelope (the one the panel surfaces) ---------------
# Select by the FAILURE filter the panel itself keys on: severityLevel >= 3 AND
# properties["harness.outcome"] == "fail". Exactly one such record in the
# fixture.
FAIL_ENV="${TMP_DIR}/failure-envelope.json"
jq '[ .[]
	| select(.data.baseData.severityLevel >= 3)
	| select(.data.baseData.properties["harness.outcome"] == "fail") ]' \
	"$LOG_ENV" > "$FAIL_ENV"
n_fail="$(jq 'length' "$FAIL_ENV")"
[ "${n_fail:-0}" -eq 1 ] \
	|| { fail "expected EXACTLY one FAILURE MessageData envelope (severityLevel>=3 AND harness.outcome=='fail'); got ${n_fail:-0} — the panel's FAILURE filter is not discriminating"; exit 1; }
E="${TMP_DIR}/e.json"
jq '.[0]' "$FAIL_ENV" > "$E"

# ==============================================================================
# 1. baseData.message — the captured failure output (→ traces `message`),
#    non-empty.
# ==============================================================================
jq -e '.data.baseData.message | type == "string" and (. | length) > 0' "$E" > /dev/null 2>&1 \
	|| fail "1: the FAILURE envelope must carry a non-empty baseData.message (→ traces 'message' column)"

# ==============================================================================
# 2. baseData.severityLevel == 3 — App-Insights Error; the panel filters
#    severityLevel >= 3 (→ traces `severityLevel`).
# ==============================================================================
jq -e '.data.baseData.severityLevel == 3' "$E" > /dev/null 2>&1 \
	|| fail "2: the FAILURE envelope must map level 'error' to baseData.severityLevel == 3 (→ traces 'severityLevel' >= 3 filter)"

# ==============================================================================
# 3. tags["ai.operation.id"] == "issue-225" — the panel's primary run
#    correlation key (→ traces `operation_Id`).
# ==============================================================================
jq -e --arg op "$EXPECT_OP_ID" '.tags["ai.operation.id"] == $op' "$E" > /dev/null 2>&1 \
	|| fail "3: the FAILURE envelope must stamp ai.operation.id == \"${EXPECT_OP_ID}\" (→ traces 'operation_Id' == 'issue-{Issue}')"

# ==============================================================================
# 4. tags["ai.operation.parentId"] == <span_id> — the failing-span link
#    (→ traces `operation_ParentId`; logmap operation_ParentId ← span_id, NOT
#    parent_span_id).
# ==============================================================================
jq -e --arg sid "$EXPECT_SPAN_ID" '.tags["ai.operation.parentId"] == $sid' "$E" > /dev/null 2>&1 \
	|| fail "4: the FAILURE envelope must carry ai.operation.parentId == the record span_id \"${EXPECT_SPAN_ID}\" (→ traces 'operation_ParentId' span correlation; NOT parent_span_id)"

# ==============================================================================
# 5. baseData.properties["harness.outcome"] == "fail" — the panel's FAILURE
#    filter dimension (→ traces customDimensions['harness.outcome']).
# ==============================================================================
jq -e '.data.baseData.properties["harness.outcome"] == "fail"' "$E" > /dev/null 2>&1 \
	|| fail "5: the FAILURE envelope must carry baseData.properties['harness.outcome'] == 'fail' (→ traces customDimensions['harness.outcome'])"

# ==============================================================================
# 6. baseData.properties["harness.stage"] == <stage> — the failure grouping
#    dimension (→ traces customDimensions['harness.stage']).
# ==============================================================================
jq -e --arg st "$EXPECT_STAGE" '.data.baseData.properties["harness.stage"] == $st' "$E" > /dev/null 2>&1 \
	|| fail "6: the FAILURE envelope must carry baseData.properties['harness.stage'] == \"${EXPECT_STAGE}\" (→ traces customDimensions['harness.stage'])"

# ==============================================================================
# 7. baseData.properties["harness.issue"] == "225" — grid readability
#    (→ traces customDimensions['harness.issue']).
# ==============================================================================
jq -e --arg iss "$EXPECT_ISSUE" '.data.baseData.properties["harness.issue"] == $iss' "$E" > /dev/null 2>&1 \
	|| fail "7: the FAILURE envelope must carry baseData.properties['harness.issue'] == \"${EXPECT_ISSUE}\" (→ traces customDimensions['harness.issue'])"

# ==============================================================================
# 8. Zero-network pin: the dry-run seam must never invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
	fail "8: the log exporter invoked curl during the dry-run seam — the seam is zero-network by contract: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
	printf '\n%d failure-detail log-panel shape contract violation(s).\n' "$fails" >&2
	exit 1
fi
printf 'failure-detail log-panel traces-shape contract honored\n'
