#!/usr/bin/env bash
# test_validate_trace_redaction.sh — regression sensor for the second-line
# redaction audit in scripts/validate-trace.sh (issue #97,
# feature validate-trace-redaction-audit, plan Phase 3 / D4).
#
# trace_redact (scripts/trace-lib.sh) is the first and only line of defense
# against secrets in traces; the validator's audit is the post-hoc check that
# a trace ON DISK is actually clean. Executable spec, pinned here:
#
#   1. Oracle = trace_redact round-trip: any trace line that trace_redact
#      would ALTER is a violation (if redaction would change it, a
#      secret-shaped token survived on disk). The validator reuses the
#      library filter — one redaction policy, never a forked pattern list.
#   2. Finding format, pinned exactly:  VIOLATION line <N>: redaction_leak
#      The finding NEVER echoes the secret content (nor any part of the
#      flagged line's values) — an audit report must not re-leak what it
#      caught. Asserted for both planted secrets on stdout AND stderr.
#   3. A hand-planted synthetic GitHub token (ghp_...) written directly to
#      the trace file, bypassing trace-lib, on an otherwise schema-valid
#      span → exit 1 with the line-numbered redaction_leak finding.
#      Likewise a planted AWS access key id (AKIA...).
#   4. A clean trace produced by the REAL emitter (trace_span writes are
#      already piped through trace_redact) → exit 0 and zero redaction_leak
#      findings: the audit must not false-positive on legitimate emitter
#      output.
#
# Planted lines are schema/type-valid by construction, so any violation on
# them is attributable to the redaction audit alone. Both planted secrets are
# self-checked against the real trace_redact (the round-trip must alter them)
# so the fixtures can never go vacuous if the library patterns drift.
#
# Exit codes: 0 redaction-audit contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
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

# The fixture must control tracing entirely: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the validator and this sensor are jq-driven)"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB}) — trace_redact is the audit oracle"
[ -x "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh not found or not executable (${VALIDATOR}) — the validator core (feature validate-trace-schema-core) must exist before the redaction audit can be specified"

# --- Synthetic secrets (fixture-only, never real credentials) -------------------
# Shapes match trace_redact's patterns: gh[pousr]_ + >=20 [A-Za-z0-9_], and
# AKIA + 16 [0-9A-Z].
GHP_SECRET="ghp_SyntheticFixtureToken0123456789abcd"
AKIA_SECRET="AKIAFIXTURESYNTH0000"

# Round-trip oracle self-check: run a line through the REAL trace_redact in a
# command-substitution subshell (sourcing stays contained) and report whether
# the filter would alter it.
redact_alters_line() {
  local line="$1" out=""
  out="$(
    # shellcheck source=/dev/null
    source "$TRACE_LIB"
    printf '%s\n' "$line" | trace_redact
  )"
  [ "$out" != "$line" ]
}

# Schema/type-valid planted lines: the secret rides free-text string attrs
# (harness.summary / harness.args_summary), exactly where a bypassing writer
# would leak one.
PREFIX='{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}'
GHP_LINE='{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"agent","harness.issue":42,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"red_handback","harness.summary":"pushed with '"$GHP_SECRET"' by mistake"}'
AKIA_LINE='{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"aws","harness.args_summary":"s3 sync using '"$AKIA_SECRET"'"}'

# Fixture self-checks: planted lines are valid JSON AND the oracle would
# alter them (guards against pattern drift making the sensor vacuous).
printf '%s\n' "$GHP_LINE" | jq empty >/dev/null 2>&1 \
  || hard_fail "planted ghp_ fixture line is not valid JSON — sensor bug"
printf '%s\n' "$AKIA_LINE" | jq empty >/dev/null 2>&1 \
  || hard_fail "planted AKIA fixture line is not valid JSON — sensor bug"
redact_alters_line "$GHP_LINE" \
  || hard_fail "trace_redact no longer alters the planted ghp_ line — oracle drift, fixture vacuous"
redact_alters_line "$AKIA_LINE" \
  || hard_fail "trace_redact no longer alters the planted AKIA line — oracle drift, fixture vacuous"
if redact_alters_line "$PREFIX"; then
  hard_fail "trace_redact alters the clean prefix line — fixture would false-positive, sensor bug"
fi

CASES="${TMP_DIR}/cases"
mkdir -p "$CASES"
printf '%s\n%s\n' "$PREFIX" "$GHP_LINE" > "${CASES}/planted_ghp.jsonl"
printf '%s\n%s\n' "$PREFIX" "$AKIA_LINE" > "${CASES}/planted_akia.jsonl"

# --- Clean trace built BY THE REAL EMITTER --------------------------------------
# trace_span pipes every serialized line through trace_redact on write, so
# genuine emitter output must never trip the audit.
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "$FIX"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name "Harness Test"
git -C "$FIX" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${FIX}/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m initial
(
  cd "$FIX"
  export TRACE_ISSUE=55
  # shellcheck source=/dev/null
  source "$TRACE_LIB"
  trace_span lifecycle "harness.lifecycle_step=preflight" \
    "harness.exit_status=0" "harness.duration_ms=42"
  trace_span tool "gen_ai.tool.name=git" "harness.outcome=pass"
  trace_span agent "gen_ai.operation.name=invoke_agent" \
    "gen_ai.agent.name=test-subagent" "harness.lifecycle_step=red_handback" \
    "harness.feature_id=validate-trace-redaction-audit" "harness.outcome=pass"
) || hard_fail "building the real-emitter clean trace failed"
CLEAN_TRACE="${FIX}/.copilot-tracking/issues/issue-55/trace.jsonl"
[ -f "$CLEAN_TRACE" ] \
  || hard_fail "real emitter did not create ${CLEAN_TRACE} — fixture broken"
[ "$(wc -l < "$CLEAN_TRACE" | tr -d '[:space:]')" = "3" ] \
  || hard_fail "expected 3 real-emitter spans in the clean trace — fixture broken"

# --- Validator run helper --------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_validator() {
  local rc=0
  "$VALIDATOR" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- 1. Planted ghp_ token: flagged by line number, secret never echoed ----------
rc="$(run_validator "${CASES}/planted_ghp.jsonl")"
[ "$rc" = "1" ] \
  || fail "planted ghp_ token: expected exit 1 (redaction leak), got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION line 2: redaction_leak' "$OUT" \
  || fail "planted ghp_ token: report must carry exactly 'VIOLATION line 2: redaction_leak' (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -qF -- "$GHP_SECRET" "$OUT" "$ERR"; then
  fail "planted ghp_ token: the audit report ECHOED the secret — findings must carry line numbers and rule names only"
fi

# --- 2. Planted AKIA key: same contract -------------------------------------------
rc="$(run_validator "${CASES}/planted_akia.jsonl")"
[ "$rc" = "1" ] \
  || fail "planted AKIA key: expected exit 1 (redaction leak), got ${rc}"
grep -Fq 'VIOLATION line 2: redaction_leak' "$OUT" \
  || fail "planted AKIA key: report must carry exactly 'VIOLATION line 2: redaction_leak' (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -qF -- "$AKIA_SECRET" "$OUT" "$ERR"; then
  fail "planted AKIA key: the audit report ECHOED the secret"
fi

# --- 3. Clean real-emitter trace: zero redaction findings --------------------------
rc="$(run_validator "$CLEAN_TRACE")"
[ "$rc" = "0" ] \
  || fail "clean real-emitter trace: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -q 'redaction_leak' "$OUT" "$ERR"; then
  fail "clean real-emitter trace: audit must not false-positive on already-redacted emitter output"
fi

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d validate-trace redaction-audit contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'validate-trace redaction-audit contract honored\n'
