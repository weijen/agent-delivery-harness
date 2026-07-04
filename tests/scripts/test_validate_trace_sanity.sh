#!/usr/bin/env bash
# test_validate_trace_sanity.sh — regression sensor for the #94-review sanity
# carry-overs (issue #97, feature validate-trace-sanity-flags, plan Phase 4 /
# D8 + D9).
#
# Executable spec, three legs:
#
#   LEG 1 (D8, emitter side): check-feature-list.sh's jq-less early-exit path
#     ("skipping feature-list check", exit 0) is a pass-shaped outcome with no
#     validation behind it. Its EXIT-trap tool span must carry
#     harness.warning=jq_skipped. When jq is truly absent the real trace-lib
#     drops the span (it requires jq), so the wiring is proven with a STUB
#     scripts/trace-lib.sh that records trace_span argv to a file — the
#     fixture pattern of test_trace_check_feature_list.sh. The script's
#     user-visible behavior (skip warning text, exit 0) must stay unchanged.
#
#   LEG 2 (validator side): a trace containing a check-feature-list TOOL span
#     with harness.outcome=pass AND harness.warning=jq_skipped gets a WARNING
#     — warnings are NOT violations, exit stays 0. Finding format pinned:
#         WARNING line <N>: jq_skipped_pass
#     on stdout, line-numbered like violation findings.
#
#   LEG 3 (D9, location sanity): in path mode, a trace whose location does
#     not match .copilot-tracking/issues/issue-NN/trace.jsonl gets
#         WARNING: unexpected trace location
#     (whole-file finding, exit unaffected); the same content AT a
#     contract-shaped location gets no such warning.
#
# RED status at authoring time (validator core/completeness/redaction GREEN):
#   RED: leg 1 (harness.warning=jq_skipped not attached today), leg 2 warning
#     line (absent today), leg 3 positive warning (absent today).
#   Already-passing guards: exit-0 semantics on all legs, zero VIOLATIONs for
#     warning-only traces, no location warning at the contract path,
#     unchanged check-feature-list skip message. These pin that implementing
#     the warnings must not turn them into violations or alter behavior.
#
# Exit codes: 0 sanity-flag contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
CHECK_FL="${ROOT}/scripts/check-feature-list.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
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

# The fixtures must control everything: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required by this sensor (the jq-LESS leg builds its own jq-free PATH)"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found (${CONTRACT})"
[ -f "$CHECK_FL" ] \
  || hard_fail "scripts/check-feature-list.sh not found (${CHECK_FL})"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -x "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh not found or not executable (${VALIDATOR}) — earlier #97 features must exist before the sanity flags can be specified"

# ==============================================================================
# LEG 1 — check-feature-list.sh jq-less path attaches harness.warning=jq_skipped
# ==============================================================================
# Fixture repo with a STUB trace-lib.sh that records trace_span argv (the real
# lib needs jq, which this leg deliberately removes from PATH).
R1="${TMP_DIR}/r1"
mkdir -p "${R1}/scripts"
cp "$CHECK_FL" "${R1}/scripts/check-feature-list.sh"
cp "$ISSUE_LIB" "${R1}/scripts/issue-lib.sh"
ARGV_LOG="${TMP_DIR}/trace_span_argv.log"
cat > "${R1}/scripts/trace-lib.sh" <<'STUB'
# Stub trace-lib for the jq-less leg: record trace_span argv, never write a
# real span (the real library requires jq and would drop it anyway).
trace_span() {
  printf '%s\n' "$*" >> "${TRACE_ARGV_LOG:?}"
  return 0
}
trace_now_ms() {
  printf '1000'
}
STUB
git -C "$R1" init -q -b main
git -C "$R1" config user.name "Harness Test"
git -C "$R1" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${R1}/README.md"
git -C "$R1" add -A
git -C "$R1" commit -q -m initial

# Pinned PATH WITHOUT jq (everything else check-feature-list needs pre-jq).
BIN_NOJQ="${TMP_DIR}/bin-nojq"
mkdir -p "$BIN_NOJQ"
for t in bash sh env git basename dirname mkdir rm cat sed tr cut grep printf date od wc; do
  p="$(command -v "$t" || true)"
  if [ -n "$p" ]; then
    ln -sf "$p" "${BIN_NOJQ}/${t}"
  fi
done
[ -x "${BIN_NOJQ}/git" ] \
  || hard_fail "could not build the jq-free PATH fixture (git missing)"

rc=0
(
  cd "$R1"
  PATH="$BIN_NOJQ" TRACE_ARGV_LOG="$ARGV_LOG" \
    ./scripts/check-feature-list.sh 50 SLUG=x
) > "${TMP_DIR}/leg1.out" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "leg1: jq-less check-feature-list.sh must still exit 0 (skip is non-blocking, behavior unchanged), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/leg1.out")"
grep -q "skipping feature-list check" "${TMP_DIR}/leg1.out" \
  || fail "leg1: jq-less skip warning text must be unchanged"
[ -f "$ARGV_LOG" ] \
  || fail "leg1: stub trace_span was never called — the jq-less path lost its EXIT-trap tool span"
if [ -f "$ARGV_LOG" ]; then
  [ "$(wc -l < "$ARGV_LOG" | tr -d '[:space:]')" = "1" ] \
    || fail "leg1: exactly ONE trace_span call expected on the jq-less path, got $(wc -l < "$ARGV_LOG" | tr -d '[:space:]')"
  grep -q 'gen_ai.tool.name=check-feature-list' "$ARGV_LOG" \
    || fail "leg1: recorded span argv must name the tool check-feature-list"
  grep -q 'harness.outcome=pass' "$ARGV_LOG" \
    || fail "leg1: the jq-less skip is a pass-shaped outcome (exit 0) — span must carry harness.outcome=pass"
  grep -q 'harness.warning=jq_skipped' "$ARGV_LOG" \
    || fail "leg1: jq-less pass span must carry harness.warning=jq_skipped (D8 — a pass with no validation behind it must say so); recorded argv: $(tr '\n' '|' < "$ARGV_LOG")"
fi

# ==============================================================================
# Validator legs — run helper (real validator, path mode)
# ==============================================================================
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_validator() {
  local vrc=0
  "$VALIDATOR" "$@" >"$OUT" 2>"$ERR" || vrc=$?
  printf '%s' "$vrc"
}

PREFIX='{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}'
JQ_SKIPPED_SPAN='{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"check-feature-list","harness.outcome":"pass","harness.warning":"jq_skipped","harness.require_complete":"0"}'

# ==============================================================================
# LEG 2 — jq_skipped pass span → WARNING line <N>: jq_skipped_pass, exit 0
# ==============================================================================
LEG2="${TMP_DIR}/jq_skipped_pass.jsonl"
printf '%s\n%s\n' "$PREFIX" "$JQ_SKIPPED_SPAN" > "$LEG2"
jq empty "$LEG2" >/dev/null 2>&1 \
  || hard_fail "leg2 fixture is not valid JSONL — sensor bug"

rc="$(run_validator "$LEG2")"
[ "$rc" = "0" ] \
  || fail "leg2: warnings are NOT violations — exit must stay 0 for a trace whose only flag is a jq_skipped pass span, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'WARNING line 2: jq_skipped_pass' "$OUT" \
  || fail "leg2: report must carry exactly 'WARNING line 2: jq_skipped_pass' for a pass-outcome check-feature-list span with harness.warning=jq_skipped (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION' "$OUT" "$ERR"; then
  fail "leg2: a jq_skipped pass span must never be reported as a VIOLATION"
fi

# ==============================================================================
# LEG 3 — location sanity (D9): non-contract path warns, contract path doesn't
# ==============================================================================
ELSEWHERE="${TMP_DIR}/elsewhere/mytrace.jsonl"
mkdir -p "$(dirname "$ELSEWHERE")"
printf '%s\n' "$PREFIX" > "$ELSEWHERE"

rc="$(run_validator "$ELSEWHERE")"
[ "$rc" = "0" ] \
  || fail "leg3: a location warning must not affect the exit code — valid trace at a non-contract path must exit 0, got ${rc}"
grep -Fq 'WARNING: unexpected trace location' "$OUT" \
  || fail "leg3: report must carry 'WARNING: unexpected trace location' for a trace outside .copilot-tracking/issues/issue-NN/trace.jsonl (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION' "$OUT" "$ERR"; then
  fail "leg3: an unexpected location is a WARNING, never a VIOLATION"
fi

CONTRACT_SHAPED="${TMP_DIR}/fakehome/.copilot-tracking/issues/issue-42/trace.jsonl"
mkdir -p "$(dirname "$CONTRACT_SHAPED")"
printf '%s\n' "$PREFIX" > "$CONTRACT_SHAPED"

rc="$(run_validator "$CONTRACT_SHAPED")"
[ "$rc" = "0" ] \
  || fail "leg3: valid trace at a contract-shaped path must exit 0, got ${rc}"
if grep -q 'unexpected trace location' "$OUT" "$ERR"; then
  fail "leg3: a trace AT .copilot-tracking/issues/issue-NN/trace.jsonl must NOT get the location warning (over-warning would train people to ignore it)"
fi

# --- Result -----------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d validate-trace sanity-flag contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'validate-trace sanity-flags contract honored\n'
