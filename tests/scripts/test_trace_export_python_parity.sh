#!/usr/bin/env bash
# test_trace_export_python_parity.sh — regression sensor for the Python
# App-Insights mapping pilot (issue #220, feature
# `python-appinsights-mapping-parity`, plan Phase 2).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/trace-export.sh reimplements its App-Insights envelope projection
#   (the --dry-run-to-file path) in Python under scripts/trace_tools/, and
#   dispatches to it when a Python engine is selected. The engine is chosen by
#   TRACE_EXPORT_ENGINE:
#     jq      → force the historical jq projection;
#     python  → force the new Python projection (scripts/trace_tools);
#     auto    → Python when available, else jq (default; not exercised here).
#
#   The Python path MUST produce a --dry-run-to-file output that is
#   BYTE-IDENTICAL to the jq path over a corpus of representative schema-v1
#   traces. This protects the #223 dashboard deep-link, which keys on the
#   deterministic per-issue `ai.operation.id = issue-<NN>` produced by this
#   mapping. Byte-identity is the CI-parity substitute for the live boundary:
#   this sensor never ships — it only compares the --dry-run-to-file seam.
#
#   Corpus dimensions (App-Insights envelope diversity):
#     - a tool span, a lifecycle span, an agent span, a model span (with
#       numeric gen_ai.usage.* tokens);
#     - spans WITH and WITHOUT parent_span_id;
#     - a span carrying only a minimal slice of allowlisted keys;
#     - harness.duration_ms present / absent / >= 24h (TimeSpan day segment);
#     - multiple spans in one trace;
#     - a malformed (non-JSON) line to exercise the skip-and-count census;
#     - the deterministic harness.issue on every span so the
#       ai.operation.id = issue-<NN> / TraceId derivation is exercised.
#     Every span carries harness.version (the all-or-nothing D6 census; a
#     single span without it aborts the export).
#
#   Assertions per corpus fixture:
#     1. jq engine  → --dry-run-to-file emits a non-empty valid JSON envelope
#        array (jq-path sanity; runs on every host).
#     2. python engine is GENUINELY selected — see the genuineness mechanism
#        below (guards against the knob being ignored / silently falling back
#        to jq, which would make cmp pass spuriously).
#     3. cmp -s jq-output vs python-output → byte-identical.
#   Plus an explicit assertion that BOTH engines stamp
#   `ai.operation.id == issue-220` on every envelope of the issue-bearing
#   fixture (the #223 deep-link contract, checked directly).
#
# GENUINENESS MECHANISM (why this is RED today, and mutation-verifiable):
#   A byte-parity cmp alone is NOT enough: TRACE_EXPORT_ENGINE is not honored
#   by trace-export.sh yet, so a `python` run silently falls through to the jq
#   path and cmp would pass SPURIOUSLY (identical bytes, but the Python code
#   never ran). To distinguish "Python path actually ran and matched" from
#   "python knob ignored → jq ran twice", this sensor REQUIRES the
#   TRACE_EXPORT_ENGINE=python run to ANNOUNCE the resolved engine on its
#   output, matching /engine[=: ]+python/i (e.g. `notice: engine=python`).
#   No such announcement exists today → the genuineness rows are `not ok` →
#   RED for the RIGHT reason. This marker can only appear once trace-export.sh
#   genuinely resolves TRACE_EXPORT_ENGINE and dispatches to the Python
#   projection, so the sensor legitimately flips GREEN only when the Python
#   dispatch truly exists (and, jointly with cmp, only when its bytes match).
#
# DEGRADATION CONTRACT: the Python engine depends on the OPTIONAL python3
# runtime (`python3 -m trace_tools`). Matching the jq-missing precedent in
# tests/scripts/test_feature_list_check.sh and the uv-missing precedent in
# tests/scripts/test_trace_tools_scaffold.sh, when python3 (or uv) is absent
# the python-engine comparisons SKIP with a warning and the run stays exit 0 —
# but the jq-engine sanity (valid non-empty array + the issue-<NN> operation
# id) STILL runs on every host. When the tools are present the parity and
# genuineness assertions are HARD.
#
# Exit codes: 0 contract honored (or Python engine cleanly skipped) · non-zero
# iff a required (non-skipped) assertion regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if TOPLEVEL="$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT="${TOPLEVEL}"
fi
EXPORTER="${ROOT}/scripts/trace-export.sh"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# tap_skip — record a SKIPPED assertion (TAP SKIP directive counts as a pass and
# keeps the run at exit 0) plus a human-facing warning. Matches the repo's
# "optional tool absent => warn and skip, never fail" degradation rule.
tap_skip() {
	printf 'warning: %s (skipping: %s)\n' "$1" "$2" >&2
	tap_ok "$1 # SKIP $2"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Prerequisites -----------------------------------------------------------
command -v jq >/dev/null 2>&1 \
	|| { printf 'warning: jq not installed — cannot validate envelope output; skipping\n' >&2; tap_ok "jq available for envelope validation # SKIP jq not installed"; tap_done; exit $?; }
[ -f "${EXPORTER}" ] && [ -x "${EXPORTER}" ] \
	|| { tap_not_ok "scripts/trace-export.sh exists and is executable"; tap_done; exit $?; }

ISSUE="220"

# --- Corpus: representative schema-v1 traces, built inline (no static fixtures,
#     matching the neighbour sensors) -------------------------------------------
# Every real span carries harness.issue=220 and harness.version (census). Files
# are named NN-<dimension>.jsonl and iterated in sorted order for a stable run.
CORPUS="${TMP_DIR}/corpus"
mkdir -p "${CORPUS}"

# 01 — tool span WITH parent_span_id and harness.duration_ms present.
cat > "${CORPUS}/01-tool-with-parent.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanlc01","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:01Z","span":"tool","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spantool1","parent_span_id":"spanlc01","gen_ai.tool.name":"git","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":1234}
JSONL

# 02 — lifecycle span, NO parent_span_id, NO harness.duration_ms (absent
#      TimeSpan → 00:00:00.000), NO harness.outcome (success defaults true).
cat > "${CORPUS}/02-lifecycle-no-parent.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:02Z","span":"lifecycle","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanlc02","harness.lifecycle_step":"worktree_create"}
JSONL

# 03 — agent span → Event/EventData.
cat > "${CORPUS}/03-agent.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:03Z","span":"agent","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanag03","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.feature_id":"python-appinsights-mapping-parity","harness.outcome":"pass"}
JSONL

# 04 — model span with numeric gen_ai.usage.* → measurements as JSON numbers.
cat > "${CORPUS}/04-model-usage.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:04Z","span":"model","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanmd04","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000,"gen_ai.usage.total_tokens":22000}
JSONL

# 05 — span carrying only a MINIMAL slice of allowlisted keys (no optional
#      outcome / duration / exit_status → all defaults exercised).
cat > "${CORPUS}/05-minimal-allowlist.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:05Z","span":"tool","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spantl05","gen_ai.tool.name":"gh"}
JSONL

# 06 — TimeSpan diversity: a normal duration AND a >= 24h duration that gains
#      the day segment (d.hh:mm:ss.fff), plus a tool fail with resultCode.
cat > "${CORPUS}/06-duration-variants.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:06Z","span":"tool","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spantl06a","gen_ai.tool.name":"pytest","harness.outcome":"pass","harness.duration_ms":40000}
{"schema_version":1,"timestamp":"2026-07-04T10:00:07Z","span":"tool","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spantl06b","gen_ai.tool.name":"build","harness.outcome":"fail","harness.exit_status":2,"harness.duration_ms":90061234}
JSONL

# 07 — kitchen sink (the ISSUE-BEARING fixture for the operation-id contract):
#      multiple spans of every type, WITH and WITHOUT parent_span_id, and a
#      MALFORMED non-JSON line to exercise the skip-and-count census. Valid
#      spans still export; every real span carries harness.version.
cat > "${CORPUS}/07-multi-malformed.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:08Z","span":"lifecycle","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanlc07","harness.lifecycle_step":"impl_handback"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:09Z","span":"tool","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spantl07","parent_span_id":"spanlc07","gen_ai.tool.name":"ruff","harness.outcome":"pass","harness.duration_ms":250}
this is not a json line at all — skip-and-count census fodder
{"schema_version":1,"timestamp":"2026-07-04T10:00:10Z","span":"agent","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanag07","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:11Z","span":"model","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanmd07","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":10,"gen_ai.usage.output_tokens":20,"gen_ai.usage.total_tokens":30}
JSONL

# --- Engine runner: drive the --dry-run-to-file seam for one engine ----------
# Unset ship-triggering env so nothing can POST; opt in with TRACE_EXPORT_OTLP=1
# (the dry-run seam needs no connection string). stdout+stderr → the log file so
# the engine-selection notice can be grepped regardless of which stream it uses.
run_engine() { # run_engine <engine> <fixture> <out-json> <log>
	local engine="$1" fixture="$2" out="$3" log="$4" rc=0
	( env -u APPLICATIONINSIGHTS_CONNECTION_STRING -u TRACE_EXPORT_OTLP_HTTP \
		TRACE_EXPORT_OTLP=1 TRACE_EXPORT_ENGINE="${engine}" \
		"${EXPORTER}" "${fixture}" --dry-run-to-file "${out}" ) > "${log}" 2>&1 || rc=$?
	return "${rc}"
}

# Strip the leading // header comment lines to obtain the JSON envelope array.
envelope_body() { grep -v '^//' "$1"; }

PY_OK=0
if command -v python3 >/dev/null 2>&1; then
	PY_OK=1
fi

# ==============================================================================
# Per-fixture: jq sanity (always), python genuineness + byte-parity (or skip).
# ==============================================================================
for fx in "${CORPUS}"/*.jsonl; do
	name="$(basename "${fx}" .jsonl)"
	jq_out="${TMP_DIR}/${name}.jq.json"
	jq_log="${TMP_DIR}/${name}.jq.log"
	py_out="${TMP_DIR}/${name}.py.json"
	py_log="${TMP_DIR}/${name}.py.log"

	# --- jq engine sanity: exit 0, file written, non-empty valid JSON array ---
	jqrc=0
	run_engine jq "${fx}" "${jq_out}" "${jq_log}" || jqrc=$?
	if [ "${jqrc}" -eq 0 ] && [ -f "${jq_out}" ] \
		&& envelope_body "${jq_out}" | jq -e 'type == "array" and length >= 1' >/dev/null 2>&1; then
		tap_ok "jq engine: ${name} → non-empty valid envelope array"
	else
		tap_not_ok "jq engine: ${name} → non-empty valid envelope array (rc=${jqrc}; $(tr '\n' '|' < "${jq_log}" 2>/dev/null))"
	fi

	# --- python engine: genuineness + byte-identity (HARD when python3 present) ---
	if [ "${PY_OK}" -ne 1 ]; then
		tap_skip "python engine: ${name} genuinely selected (engine=python announced)" "python3 not on PATH"
		tap_skip "python engine: ${name} → byte-identical to jq (cmp -s)" "python3 not on PATH"
		continue
	fi

	pyrc=0
	run_engine python "${fx}" "${py_out}" "${py_log}" || pyrc=$?

	# Genuineness: the python run MUST announce the resolved engine. Absent
	# today (knob ignored) → RED; can only appear once the Python dispatch is
	# real. This is what stops a spurious cmp pass when jq silently ran twice.
	if grep -Eqi 'engine[=: ]+python' "${py_log}"; then
		tap_ok "python engine: ${name} genuinely selected (engine=python announced)"
	else
		tap_not_ok "python engine: ${name} genuinely selected (engine=python announced) — TRACE_EXPORT_ENGINE=python not honored yet"
	fi

	# Byte-parity oracle: the full --dry-run-to-file files must be identical.
	if [ "${pyrc}" -eq 0 ] && [ -f "${py_out}" ] && cmp -s "${jq_out}" "${py_out}"; then
		tap_ok "python engine: ${name} → byte-identical to jq (cmp -s)"
	else
		tap_not_ok "python engine: ${name} → byte-identical to jq (cmp -s) (pyrc=${pyrc}; $(tr '\n' '|' < "${py_log}" 2>/dev/null))"
	fi
done

# ==============================================================================
# Explicit #223 deep-link contract: ai.operation.id == issue-220 on EVERY
# envelope of the issue-bearing fixture, in BOTH engine outputs.
# ==============================================================================
ISSUE_JQ="${TMP_DIR}/07-multi-malformed.jq.json"
if [ -f "${ISSUE_JQ}" ] \
	&& envelope_body "${ISSUE_JQ}" | jq -e 'length >= 1 and all(.[]; .tags["ai.operation.id"] == "issue-'"${ISSUE}"'")' >/dev/null 2>&1; then
	tap_ok "jq engine: issue fixture stamps ai.operation.id == issue-${ISSUE} on every envelope (#223 deep-link)"
else
	tap_not_ok "jq engine: issue fixture stamps ai.operation.id == issue-${ISSUE} on every envelope (#223 deep-link)"
fi

if [ "${PY_OK}" -ne 1 ]; then
	tap_skip "python engine: issue fixture stamps ai.operation.id == issue-${ISSUE} on every envelope (#223 deep-link)" "python3 not on PATH"
else
	ISSUE_PY="${TMP_DIR}/07-multi-malformed.py.json"
	if [ -f "${ISSUE_PY}" ] \
		&& envelope_body "${ISSUE_PY}" | jq -e 'length >= 1 and all(.[]; .tags["ai.operation.id"] == "issue-'"${ISSUE}"'")' >/dev/null 2>&1; then
		tap_ok "python engine: issue fixture stamps ai.operation.id == issue-${ISSUE} on every envelope (#223 deep-link)"
	else
		tap_not_ok "python engine: issue fixture stamps ai.operation.id == issue-${ISSUE} on every envelope (#223 deep-link) — python dispatch/parity missing"
	fi
fi

tap_done
