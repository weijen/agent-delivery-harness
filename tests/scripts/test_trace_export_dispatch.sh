#!/usr/bin/env bash
# test_trace_export_dispatch.sh — regression sensor for issue #220, feature
# `trace-export-dispatcher` (plan Phase 4: dispatcher hardening, both-paths
# green + fallback).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/trace-export.sh is the DISPATCHER: it produces the SAME
#   trace-export CLI contract whether the App-Insights / OTLP projections run
#   through the historical jq program or the Python pilot (scripts/trace_tools),
#   selected by TRACE_EXPORT_ENGINE (jq | python | auto). Phase 4 finalises the
#   dispatcher so that:
#
#   A. IDENTICAL OUTPUT across engines — for a representative trace, the
#      --dry-run-to-file (App-Insights envelopes) AND the --dry-run-otlp-to-file
#      (OTLP resourceSpans) bytes are BYTE-IDENTICAL under `jq` and `python`.
#      (The deep byte-parity corpus lives in test_trace_export_python_parity.sh;
#      here we lock the DISPATCH contract, not re-test every corpus row.)
#
#   B. IDENTICAL EXIT CODES across engines — 0 on a clean export, 2 for a usage
#      error (bad invocation), and 1 for the harness.version census-abort (a
#      span missing the queryable dimension). Each code must match under both
#      `jq` and `python`.
#
#   C. jq FALLBACK when Python is absent — with the engine unset/auto AND
#      python3/uv hidden from PATH, the tool falls back to the jq path, still
#      succeeds, announces `engine=jq`, and emits the SAME bytes as the explicit
#      jq engine.
#
#   D. FORCED python with python3 absent does NOT crash — TRACE_EXPORT_ENGINE=
#      python with python3 hidden must warn ("falling back to the jq engine")
#      and degrade to jq (exit 0), per resolve_trace_export_engine.
#
#   E. NEITHER engine available degrades CLEANLY — with BOTH python3 and jq
#      hidden, the exporter must warn/abort clearly (a red "jq is required"
#      message, usage exit 2) and NON-CRASH, writing no dry-run file. This is
#      the trace-subsystem "optional tool absent → clear message, no crash"
#      degradation convention.
#
#   F. DOCUMENTED knob — the usage/help text must document TRACE_EXPORT_ENGINE
#      so operators can discover the jq|python|auto selector (plan Phase 4:
#      "usage note for TRACE_EXPORT_ENGINE"). This is the assertion that is RED
#      today: the dispatcher resolves the knob but never documents it.
#
# GENUINENESS: the fallback/degradation legs run the exporter under a CURATED
# PATH that omits python3/uv (and, for leg E, jq), so the fallback code path is
# actually forced rather than assumed. The engine-selection notice on stderr is
# grepped to prove which engine truly ran.
#
# DEGRADATION of the SENSOR ITSELF: the `python`-engine comparisons depend on
# the OPTIONAL python3 runtime. Matching the jq-missing / uv-missing precedents
# (tests/scripts/test_trace_export_python_parity.sh,
# tests/scripts/test_trace_tools_scaffold.sh), when python3 is absent on the
# host the python-engine legs SKIP with a warning (exit stays 0) while the
# jq-only contract assertions (clean/usage/census exit codes, the neither-engine
# degradation, and the usage documentation) STILL run on every host.
#
# Exit codes: 0 dispatch contract honored (python legs may be skipped) ·
# non-zero iff a required (non-skipped) assertion regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if TOPLEVEL="$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT="${TOPLEVEL}"
fi
EXPORTER="${ROOT}/scripts/trace-export.sh"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# tap_skip — record a SKIPPED assertion (TAP SKIP counts as a pass, run stays
# exit 0) plus a human-facing warning. Matches the repo's "optional tool absent
# => warn and skip, never fail" degradation rule.
tap_skip() {
	printf 'warning: %s (skipping: %s)\n' "$1" "$2" >&2
	tap_ok "$1 # SKIP $2"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Prerequisites -----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
	tap_skip "jq available for envelope validation" "jq not installed"
	tap_done
	exit $?
fi
if [ ! -f "${EXPORTER}" ] || [ ! -x "${EXPORTER}" ]; then
	tap_not_ok "scripts/trace-export.sh exists and is executable"
	tap_done
	exit $?
fi

ISSUE="220"

# --- Representative fixture (compact — parent link + a model span with numeric
#     gen_ai.usage.* so both projections exercise measurements) ---------------
CLEAN="${TMP_DIR}/clean.jsonl"
cat > "${CLEAN}" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanlc01","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:01Z","span":"tool","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spantl01","parent_span_id":"spanlc01","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":1234}
{"schema_version":1,"timestamp":"2026-07-04T10:00:02Z","span":"model","harness.issue":${ISSUE},"harness.version":"abc1234","span_id":"spanmd01","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000,"gen_ai.usage.total_tokens":22000}
JSONL

# --- Census-abort fixture: a valid span that LACKS harness.version (the
#     queryable dimension) → all-or-nothing abort, exit 1 --------------------
NOVER="${TMP_DIR}/nover.jsonl"
cat > "${NOVER}" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":${ISSUE},"span_id":"spanlc01","harness.lifecycle_step":"preflight"}
JSONL

# run_engine — drive one --dry-run seam for one engine over the FULL host PATH.
# Unset ship-triggering env so nothing can POST; opt in with TRACE_EXPORT_OTLP=1
# (the dry-run seam needs no connection string). stdout+stderr → the log so the
# engine notice can be grepped regardless of stream.
run_engine() { # run_engine <engine> <seam-flag> <fixture> <out> <log>
	local engine="$1" flag="$2" fixture="$3" out="$4" log="$5" rc=0
	env -u APPLICATIONINSIGHTS_CONNECTION_STRING -u TRACE_EXPORT_OTLP_HTTP \
		TRACE_EXPORT_OTLP=1 TRACE_EXPORT_ENGINE="${engine}" \
		"${EXPORTER}" "${fixture}" "${flag}" "${out}" > "${log}" 2>&1 || rc=$?
	return "${rc}"
}

# run_engine_bad — drive a BAD invocation (an unknown flag) for one engine; the
# argument parser must reject it with the usage error (exit 2) BEFORE any engine
# work. No output file is expected.
run_engine_bad() { # run_engine_bad <engine> <log>
	local engine="$1" log="$2" rc=0
	env -u APPLICATIONINSIGHTS_CONNECTION_STRING -u TRACE_EXPORT_OTLP_HTTP \
		TRACE_EXPORT_OTLP=1 TRACE_EXPORT_ENGINE="${engine}" \
		"${EXPORTER}" "${CLEAN}" --this-flag-does-not-exist > "${log}" 2>&1 || rc=$?
	return "${rc}"
}

PY_OK=0
if command -v python3 >/dev/null 2>&1; then
	PY_OK=1
fi

# ==============================================================================
# A + B. Byte-identical output AND identical exit codes across engines.
# ==============================================================================
# jq baseline: clean exports for both seams (sanity — runs on every host).
jq_ai="${TMP_DIR}/jq.ai.json"
jq_otlp="${TMP_DIR}/jq.otlp.json"
jq_ai_rc=0
jq_otlp_rc=0
run_engine jq --dry-run-to-file "${CLEAN}" "${jq_ai}" "${TMP_DIR}/jq.ai.log" || jq_ai_rc=$?
run_engine jq --dry-run-otlp-to-file "${CLEAN}" "${jq_otlp}" "${TMP_DIR}/jq.otlp.log" || jq_otlp_rc=$?

if [ "${jq_ai_rc}" -eq 0 ] && [ -s "${jq_ai}" ]; then
	tap_ok "jq engine: clean --dry-run-to-file export (exit 0, non-empty)"
else
	tap_not_ok "jq engine: clean --dry-run-to-file export (rc=${jq_ai_rc}; $(tr '\n' '|' < "${TMP_DIR}/jq.ai.log" 2>/dev/null))"
fi
if [ "${jq_otlp_rc}" -eq 0 ] && [ -s "${jq_otlp}" ]; then
	tap_ok "jq engine: clean --dry-run-otlp-to-file export (exit 0, non-empty)"
else
	tap_not_ok "jq engine: clean --dry-run-otlp-to-file export (rc=${jq_otlp_rc}; $(tr '\n' '|' < "${TMP_DIR}/jq.otlp.log" 2>/dev/null))"
fi

# jq exit codes for the failure modes (baseline, every host).
jq_bad_rc=0
run_engine_bad jq "${TMP_DIR}/jq.bad.log" || jq_bad_rc=$?
tap_is "${jq_bad_rc}" "2" "jq engine: bad invocation → usage error (exit 2)"

jq_nover_rc=0
run_engine jq --dry-run-to-file "${NOVER}" "${TMP_DIR}/jq.nover.json" "${TMP_DIR}/jq.nover.log" || jq_nover_rc=$?
tap_is "${jq_nover_rc}" "1" "jq engine: span missing harness.version → census abort (exit 1)"

if [ "${PY_OK}" -eq 1 ]; then
	# python engine: same three exit codes, and byte-identical seam output.
	py_ai="${TMP_DIR}/py.ai.json"
	py_otlp="${TMP_DIR}/py.otlp.json"
	py_ai_rc=0
	py_otlp_rc=0
	run_engine python --dry-run-to-file "${CLEAN}" "${py_ai}" "${TMP_DIR}/py.ai.log" || py_ai_rc=$?
	run_engine python --dry-run-otlp-to-file "${CLEAN}" "${py_otlp}" "${TMP_DIR}/py.otlp.log" || py_otlp_rc=$?

	# Genuineness: the python runs must announce engine=python (not silently jq).
	if grep -Eiq 'engine[=: ]+python' "${TMP_DIR}/py.ai.log"; then
		tap_ok "python engine: --dry-run-to-file genuinely selected (engine=python announced)"
	else
		tap_not_ok "python engine: --dry-run-to-file genuinely selected (no engine=python notice; $(tr '\n' '|' < "${TMP_DIR}/py.ai.log" 2>/dev/null))"
	fi
	if grep -Eiq 'engine[=: ]+python' "${TMP_DIR}/py.otlp.log"; then
		tap_ok "python engine: --dry-run-otlp-to-file genuinely selected (engine=python announced)"
	else
		tap_not_ok "python engine: --dry-run-otlp-to-file genuinely selected (no engine=python notice; $(tr '\n' '|' < "${TMP_DIR}/py.otlp.log" 2>/dev/null))"
	fi

	# Exit-code parity.
	tap_is "${py_ai_rc}" "${jq_ai_rc}" "exit-code parity: clean --dry-run-to-file (jq=${jq_ai_rc} python=${py_ai_rc})"
	tap_is "${py_otlp_rc}" "${jq_otlp_rc}" "exit-code parity: clean --dry-run-otlp-to-file (jq=${jq_otlp_rc} python=${py_otlp_rc})"

	py_bad_rc=0
	run_engine_bad python "${TMP_DIR}/py.bad.log" || py_bad_rc=$?
	tap_is "${py_bad_rc}" "${jq_bad_rc}" "exit-code parity: bad invocation → usage error (jq=${jq_bad_rc} python=${py_bad_rc})"

	py_nover_rc=0
	run_engine python --dry-run-to-file "${NOVER}" "${TMP_DIR}/py.nover.json" "${TMP_DIR}/py.nover.log" || py_nover_rc=$?
	tap_is "${py_nover_rc}" "${jq_nover_rc}" "exit-code parity: census abort (jq=${jq_nover_rc} python=${py_nover_rc})"

	# Byte-identity of both seams.
	if cmp -s "${jq_ai}" "${py_ai}"; then
		tap_ok "byte-identical --dry-run-to-file output across engines (jq == python)"
	else
		tap_not_ok "byte-identical --dry-run-to-file output across engines (jq != python)"
	fi
	if cmp -s "${jq_otlp}" "${py_otlp}"; then
		tap_ok "byte-identical --dry-run-otlp-to-file output across engines (jq == python)"
	else
		tap_not_ok "byte-identical --dry-run-otlp-to-file output across engines (jq != python)"
	fi
else
	tap_skip "python engine: dispatch parity (exit codes + byte-identical seams)" "python3 not installed"
fi

# ==============================================================================
# C + D + E. Fallback / degradation under a CURATED PATH that hides python3/uv
# (and, for E, jq). Built with symlinks to a generous coreutils set, mirroring
# tests/scripts/test_trace_export_backstop.sh.
# ==============================================================================
BIN="${TMP_DIR}/bin"
mkdir -p "${BIN}"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
	date dirname basename mkdir rm cp mv od cmp touch mktemp id stat find xargs; do
	p="$(command -v "${t}" || true)"
	if [ -n "${p}" ]; then
		ln -sf "${p}" "${BIN}/${t}"
	fi
done

# run_curated — run the exporter under PATH=$BIN (python3/uv already absent from
# it) with an explicit engine value; stdout+stderr → the log.
run_curated() { # run_curated <engine-or-empty> <seam-flag> <out> <log>
	local engine="$1" flag="$2" out="$3" log="$4" rc=0
	if [ -n "${engine}" ]; then
		env -i PATH="${BIN}" TRACE_EXPORT_OTLP=1 TRACE_EXPORT_ENGINE="${engine}" \
			bash "${EXPORTER}" "${CLEAN}" "${flag}" "${out}" > "${log}" 2>&1 || rc=$?
	else
		env -i PATH="${BIN}" TRACE_EXPORT_OTLP=1 \
			bash "${EXPORTER}" "${CLEAN}" "${flag}" "${out}" > "${log}" 2>&1 || rc=$?
	fi
	return "${rc}"
}

# --- C: auto (unset engine), python absent → jq fallback, same bytes as jq ---
fb_out="${TMP_DIR}/fallback.auto.json"
fb_log="${TMP_DIR}/fallback.auto.log"
fb_rc=0
run_curated "" --dry-run-to-file "${fb_out}" "${fb_log}" || fb_rc=$?
if [ "${fb_rc}" -eq 0 ] && grep -Eiq 'engine[=: ]+jq' "${fb_log}"; then
	tap_ok "python absent + engine=auto → jq fallback succeeds and announces engine=jq"
else
	tap_not_ok "python absent + engine=auto → jq fallback succeeds and announces engine=jq (rc=${fb_rc}; $(tr '\n' '|' < "${fb_log}" 2>/dev/null))"
fi
if [ -s "${fb_out}" ] && cmp -s "${jq_ai}" "${fb_out}"; then
	tap_ok "python-absent auto fallback emits the SAME bytes as the explicit jq engine"
else
	tap_not_ok "python-absent auto fallback emits the SAME bytes as the explicit jq engine"
fi

# --- D: forced python, python absent → warn + graceful jq fallback (no crash) -
fp_out="${TMP_DIR}/forced-python.json"
fp_log="${TMP_DIR}/forced-python.log"
fp_rc=0
run_curated python --dry-run-to-file "${fp_out}" "${fp_log}" || fp_rc=$?
if [ "${fp_rc}" -eq 0 ] && grep -Eiq 'falling back to the jq engine' "${fp_log}"; then
	tap_ok "engine=python + python3 absent → warns and falls back to jq (no crash, exit 0)"
else
	tap_not_ok "engine=python + python3 absent → warns and falls back to jq (no crash, exit 0) (rc=${fp_rc}; $(tr '\n' '|' < "${fp_log}" 2>/dev/null))"
fi

# --- E: neither engine (jq + python both absent) → clean degradation --------
rm -f "${BIN}/jq"
ne_out="${TMP_DIR}/neither.json"
ne_log="${TMP_DIR}/neither.log"
ne_rc=0
run_curated "" --dry-run-to-file "${ne_out}" "${ne_log}" || ne_rc=$?
if [ "${ne_rc}" -eq 2 ] && grep -Eiq 'jq is required' "${ne_log}"; then
	tap_ok "neither engine available → clean degradation (clear 'jq is required' message, usage exit 2)"
else
	tap_not_ok "neither engine available → clean degradation (expected exit 2 + 'jq is required', got rc=${ne_rc}; $(tr '\n' '|' < "${ne_log}" 2>/dev/null))"
fi
if [ ! -f "${ne_out}" ]; then
	tap_ok "neither engine available → NON-CRASH, no dry-run file written"
else
	tap_not_ok "neither engine available → a dry-run file was written despite the abort (${ne_out})"
fi

# ==============================================================================
# F. The TRACE_EXPORT_ENGINE selector must be DOCUMENTED in the usage/help text
# (plan Phase 4). RED today: the dispatcher honours the knob but the usage()
# block never mentions it, so operators cannot discover jq|python|auto.
# ==============================================================================
usage_txt="${TMP_DIR}/usage.txt"
env -u APPLICATIONINSIGHTS_CONNECTION_STRING TRACE_EXPORT_OTLP=1 \
	"${EXPORTER}" > "${usage_txt}" 2>&1 || true
if grep -q 'TRACE_EXPORT_ENGINE' "${usage_txt}"; then
	tap_ok "usage/help documents the TRACE_EXPORT_ENGINE selector (jq|python|auto)"
else
	tap_not_ok "usage/help documents the TRACE_EXPORT_ENGINE selector (jq|python|auto) — Phase 4 usage note missing"
fi

tap_done
exit $?
