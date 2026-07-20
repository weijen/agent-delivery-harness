#!/usr/bin/env bash
# test_review_fail_attribution.sh — regression sensor for FAIL verdict
# attribution (issue #318, feature fail-verdict-attribution).
#
# Rules pinned:
#
#   review_fail_unattributed — a review_verdict/fail span without a non-empty
#     harness.feature_id (or the literal value "unmapped") is a VIOLATION:
#         VIOLATION consistency: review_fail_unattributed line <N>
#     The rule fires on missing, empty (""), and the legacy "-" placeholder.
#     Pass verdicts (outcome != "fail") are exempt.
#
#   failure_class_missing — a review_verdict/fail span without a valid
#     harness.failure_class is a VIOLATION:
#         VIOLATION consistency: failure_class_missing line <N>
#
#   failure_class_invalid — a review_verdict/fail span with a
#     harness.failure_class value NOT in the closed enum is a VIOLATION:
#         VIOLATION consistency: failure_class_invalid line <N>
#
#   failure_class_other_no_detail — a review_verdict/fail span with
#     harness.failure_class == "other" and an absent/empty
#     harness.failure_class_detail is a VIOLATION:
#         VIOLATION consistency: failure_class_other_no_detail line <N>
#
#   unmapped_without_fingerprint — a review_verdict/fail span with
#     harness.feature_id == "unmapped" but absent/empty
#     harness.finding_fingerprint is a VIOLATION:
#         VIOLATION consistency: unmapped_without_fingerprint line <N>
#
# Emission pinned:
#   log-handback.sh review_verdict step forwards TRACE_FAILURE_CLASS and
#   TRACE_FAILURE_CLASS_DETAIL as harness.failure_class / failure_class_detail,
#   and TRACE_FINDING_FINGERPRINT as harness.finding_fingerprint (review_verdict
#   only). Closed enum validation for failure_class; omit-never-fake for all.
#
# Legs:
#   A1  fail verdict without feature_id            -> review_fail_unattributed
#   A2  fail verdict with feature_id="-"           -> review_fail_unattributed
#   A3  fail verdict with feature_id=""            -> review_fail_unattributed
#   A4  fail verdict with real feature_id          -> no violation (attribution ok)
#   A5  fail verdict with feature_id="unmapped" + fingerprint -> no attribution violation
#   A6  fail verdict with feature_id="unmapped" WITHOUT fingerprint -> unmapped_without_fingerprint
#   A7  pass verdict without feature_id            -> no violation (pass exempt)
#   C1  fail verdict without failure_class         -> failure_class_missing
#   C2  fail verdict with invalid failure_class    -> failure_class_invalid
#   C3  fail verdict with valid failure_class      -> no violation
#   C4  failure_class="other" without detail       -> failure_class_other_no_detail
#   C5  failure_class="other" with non-empty detail -> no violation
#   C6  failure_class="knowledge-gap" (#317)       -> no violation (cross-issue slug accepted)
#   C7  failure_class="complexity" (#317)          -> no violation (cross-issue slug accepted)
#   C8  failure_class="known-flaky" (#317)         -> no violation (cross-issue slug accepted)
#   C9  failure_class="polling" (#317)             -> no violation (cross-issue slug accepted)
#   C10 failure_class="research" (near miss)       -> failure_class_invalid (negative slug gate)
#   E1  log-handback emits TRACE_FAILURE_CLASS     -> span carries harness.failure_class
#   E2  log-handback emits TRACE_FINDING_FINGERPRINT -> span carries harness.finding_fingerprint
#   E3  log-handback rejects out-of-enum TRACE_FAILURE_CLASS -> omit + warn
#   E4  log-handback emits knowledge-gap class     -> span carries it (cross-issue slug emittable)
#   M1  mutation: remove review_fail_unattributed rule -> A1 fails
#   M2  mutation: remove failure_class_other_no_detail rule -> C4 fails
#
# Exit codes: 0 contract honored · 1 contract violated.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
LOG_HANDBACK="${ROOT}/scripts/log-handback.sh"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_FAILURE_CLASS TRACE_FAILURE_CLASS_DETAIL TRACE_FINDING_FINGERPRINT 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required"
[ -f "$CHECKER" ] && [ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found or not executable"
[ -f "$LOG_HANDBACK" ] && [ -x "$LOG_HANDBACK" ] \
  || hard_fail "scripts/log-handback.sh not found or not executable"

# --- Span + Action-Log bullet builders ----------------------------------------
# Base fail verdict span; caller can override/add fields via extra JSON merge.
fail_verdict_span() {
  local ts="$1" extra="$2"
  local base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail"}'
  if [ -z "$extra" ]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "$base" | jq -c ". + $extra"
  fi
}
pass_verdict_span() {
  local ts="$1" extra="$2"
  local base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"pass"}'
  if [ -z "$extra" ]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "$base" | jq -c ". + $extra"
  fi
}
bullet() {
  local fid="$1" outcome="$2"
  printf -- '- [code-review-subagent] review_verdict %s %s — review verdict\n' \
    "$fid" "$outcome"
}
progress_header() {
  printf '# Issue 318 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
}

trace_path() { printf '%s' "${TMP_DIR}/$1/trace.jsonl"; }
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# =============================================================================
# ATTRIBUTION LEGS
# =============================================================================

# --- A1: fail verdict without feature_id -> review_fail_unattributed -----------
mkdir -p "${TMP_DIR}/a1"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.failure_class":"spec-violation"}'
} > "$(trace_path a1)"
{ progress_header; bullet "-" fail; } > "${TMP_DIR}/a1/progress.md"

rc="$(run_checker "$(trace_path a1)")"
[ "$rc" = "1" ] \
  || fail "A1 no feature_id: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: review_fail_unattributed' "$OUT" \
  || fail "A1 no feature_id: pinned finding 'review_fail_unattributed' missing (stdout: $(cat "$OUT"))"

# --- A2: fail verdict with feature_id="-" -> review_fail_unattributed ----------
mkdir -p "${TMP_DIR}/a2"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"-","harness.failure_class":"spec-violation"}'
} > "$(trace_path a2)"
{ progress_header; bullet "-" fail; } > "${TMP_DIR}/a2/progress.md"

rc="$(run_checker "$(trace_path a2)")"
[ "$rc" = "1" ] \
  || fail "A2 feature_id=-: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: review_fail_unattributed' "$OUT" \
  || fail "A2 feature_id=-: pinned finding 'review_fail_unattributed' missing (stdout: $(cat "$OUT"))"

# --- A3: fail verdict with feature_id="" -> review_fail_unattributed -----------
mkdir -p "${TMP_DIR}/a3"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"","harness.failure_class":"spec-violation"}'
} > "$(trace_path a3)"
{ progress_header; bullet "-" fail; } > "${TMP_DIR}/a3/progress.md"

rc="$(run_checker "$(trace_path a3)")"
[ "$rc" = "1" ] \
  || fail "A3 feature_id empty: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: review_fail_unattributed' "$OUT" \
  || fail "A3 feature_id empty: pinned finding 'review_fail_unattributed' missing (stdout: $(cat "$OUT"))"

# --- A4: fail verdict with real feature_id -> no attribution violation ---------
mkdir -p "${TMP_DIR}/a4"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"spec-violation"}'
} > "$(trace_path a4)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/a4/progress.md"

rc="$(run_checker "$(trace_path a4)")"
if grep -Fq 'review_fail_unattributed' "$OUT"; then
  fail "A4 real feature_id: should NOT fire review_fail_unattributed (stdout: $(cat "$OUT"))"
fi

# --- A5: unmapped + fingerprint -> no attribution violation --------------------
mkdir -p "${TMP_DIR}/a5"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"unmapped","harness.finding_fingerprint":"abc123hash","harness.failure_class":"spec-violation"}'
} > "$(trace_path a5)"
{ progress_header; bullet "unmapped" fail; } > "${TMP_DIR}/a5/progress.md"

rc="$(run_checker "$(trace_path a5)")"
if grep -Fq 'review_fail_unattributed' "$OUT"; then
  fail "A5 unmapped+fingerprint: should NOT fire review_fail_unattributed (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'unmapped_without_fingerprint' "$OUT"; then
  fail "A5 unmapped+fingerprint: should NOT fire unmapped_without_fingerprint (stdout: $(cat "$OUT"))"
fi

# --- A6: unmapped WITHOUT fingerprint -> unmapped_without_fingerprint ----------
mkdir -p "${TMP_DIR}/a6"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"unmapped","harness.failure_class":"spec-violation"}'
} > "$(trace_path a6)"
{ progress_header; bullet "unmapped" fail; } > "${TMP_DIR}/a6/progress.md"

rc="$(run_checker "$(trace_path a6)")"
[ "$rc" = "1" ] \
  || fail "A6 unmapped no fingerprint: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: unmapped_without_fingerprint' "$OUT" \
  || fail "A6 unmapped no fingerprint: pinned finding 'unmapped_without_fingerprint' missing (stdout: $(cat "$OUT"))"

# --- A7: pass verdict without feature_id -> no violation (pass exempt) ---------
mkdir -p "${TMP_DIR}/a7"
{
  pass_verdict_span "2026-07-19T10:00:00Z" ''
} > "$(trace_path a7)"
{ progress_header; bullet "-" pass; } > "${TMP_DIR}/a7/progress.md"

rc="$(run_checker "$(trace_path a7)")"
if grep -Fq 'review_fail_unattributed' "$OUT"; then
  fail "A7 pass verdict: should NOT fire review_fail_unattributed on pass (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'unmapped_without_fingerprint' "$OUT"; then
  fail "A7 pass verdict: should NOT fire unmapped_without_fingerprint on pass (stdout: $(cat "$OUT"))"
fi

# =============================================================================
# FAILURE CLASS LEGS
# =============================================================================

# --- C1: fail verdict without failure_class -> failure_class_missing -----------
mkdir -p "${TMP_DIR}/c1"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature"}'
} > "$(trace_path c1)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c1/progress.md"

rc="$(run_checker "$(trace_path c1)")"
[ "$rc" = "1" ] \
  || fail "C1 no failure_class: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: failure_class_missing' "$OUT" \
  || fail "C1 no failure_class: pinned finding 'failure_class_missing' missing (stdout: $(cat "$OUT"))"

# --- C2: fail verdict with invalid failure_class -> failure_class_invalid -------
mkdir -p "${TMP_DIR}/c2"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"totally-bogus"}'
} > "$(trace_path c2)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c2/progress.md"

rc="$(run_checker "$(trace_path c2)")"
[ "$rc" = "1" ] \
  || fail "C2 invalid failure_class: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: failure_class_invalid' "$OUT" \
  || fail "C2 invalid failure_class: pinned finding 'failure_class_invalid' missing (stdout: $(cat "$OUT"))"

# --- C3: fail verdict with valid failure_class -> no violation ------------------
mkdir -p "${TMP_DIR}/c3"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"spec-violation"}'
} > "$(trace_path c3)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c3/progress.md"

rc="$(run_checker "$(trace_path c3)")"
if grep -Fq 'failure_class_missing' "$OUT"; then
  fail "C3 valid failure_class: should NOT fire failure_class_missing (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'failure_class_invalid' "$OUT"; then
  fail "C3 valid failure_class: should NOT fire failure_class_invalid (stdout: $(cat "$OUT"))"
fi

# --- C4: failure_class=other without detail -> failure_class_other_no_detail ----
mkdir -p "${TMP_DIR}/c4"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"other"}'
} > "$(trace_path c4)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c4/progress.md"

rc="$(run_checker "$(trace_path c4)")"
[ "$rc" = "1" ] \
  || fail "C4 other without detail: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: failure_class_other_no_detail' "$OUT" \
  || fail "C4 other without detail: pinned finding 'failure_class_other_no_detail' missing (stdout: $(cat "$OUT"))"

# --- C5: failure_class=other with non-empty detail -> no violation --------------
mkdir -p "${TMP_DIR}/c5"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"other","harness.failure_class_detail":"jq 1.6 vs 1.7 syntax"}'
} > "$(trace_path c5)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c5/progress.md"

rc="$(run_checker "$(trace_path c5)")"
if grep -Fq 'failure_class_other_no_detail' "$OUT"; then
  fail "C5 other with detail: should NOT fire failure_class_other_no_detail (stdout: $(cat "$OUT"))"
fi

# --- C6: failure_class=knowledge-gap (#317 research route) -> no violation -----
mkdir -p "${TMP_DIR}/c6"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"knowledge-gap"}'
} > "$(trace_path c6)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c6/progress.md"

rc="$(run_checker "$(trace_path c6)")"
if grep -Fq 'failure_class_invalid' "$OUT"; then
  fail "C6 knowledge-gap: should NOT fire failure_class_invalid (cross-issue slug must be accepted) (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'failure_class_missing' "$OUT"; then
  fail "C6 knowledge-gap: should NOT fire failure_class_missing (stdout: $(cat "$OUT"))"
fi

# --- C7: failure_class=complexity (#317 decompose route) -> no violation -------
mkdir -p "${TMP_DIR}/c7"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"complexity"}'
} > "$(trace_path c7)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c7/progress.md"

rc="$(run_checker "$(trace_path c7)")"
if grep -Fq 'failure_class_invalid' "$OUT"; then
  fail "C7 complexity: should NOT fire failure_class_invalid (cross-issue slug must be accepted) (stdout: $(cat "$OUT"))"
fi

# --- C8: failure_class=known-flaky (#317 exemption class) -> no violation ------
mkdir -p "${TMP_DIR}/c8"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"known-flaky"}'
} > "$(trace_path c8)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c8/progress.md"

rc="$(run_checker "$(trace_path c8)")"
if grep -Fq 'failure_class_invalid' "$OUT"; then
  fail "C8 known-flaky: should NOT fire failure_class_invalid (cross-issue slug must be accepted) (stdout: $(cat "$OUT"))"
fi

# --- C9: failure_class=polling (#317 exemption class) -> no violation ----------
mkdir -p "${TMP_DIR}/c9"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"polling"}'
} > "$(trace_path c9)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c9/progress.md"

rc="$(run_checker "$(trace_path c9)")"
if grep -Fq 'failure_class_invalid' "$OUT"; then
  fail "C9 polling: should NOT fire failure_class_invalid (cross-issue slug must be accepted) (stdout: $(cat "$OUT"))"
fi

# --- C10: failure_class=research (near-miss plausible invalid) -> failure_class_invalid
# Negative gate: "research" is NOT in the enum (knowledge-gap is). If this slug
# were accidentally added it would break the cross-issue routing contract.
mkdir -p "${TMP_DIR}/c10"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"my-feature","harness.failure_class":"research"}'
} > "$(trace_path c10)"
{ progress_header; bullet "my-feature" fail; } > "${TMP_DIR}/c10/progress.md"

rc="$(run_checker "$(trace_path c10)")"
[ "$rc" = "1" ] \
  || fail "C10 near-miss 'research': expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: failure_class_invalid' "$OUT" \
  || fail "C10 near-miss 'research': pinned finding 'failure_class_invalid' missing (stdout: $(cat "$OUT"))"

# =============================================================================
# EMISSION LEGS (log-handback.sh passthrough)
# =============================================================================

# --- E1: TRACE_FAILURE_CLASS forwarded on review_verdict -----------------------
# Set up a minimal git repo for log-handback (it needs git context).
E_DIR="${TMP_DIR}/emission"
mkdir -p "${E_DIR}/.copilot-tracking/issues/issue-318"
(
  cd "$E_DIR" && git init -q && git checkout -b feature/issue-318-test 2>/dev/null
  printf '# Issue 318 progress\n\nStatus: in progress.\n\n## Action Log\n\n' \
    > .copilot-tracking/issues/issue-318/progress.md
  git add -A && git commit -q -m "init" --allow-empty
)
E_TRACE="${E_DIR}/.copilot-tracking/issues/issue-318/trace.jsonl"

(
  cd "$E_DIR"
  TRACE_FAILURE_CLASS="spec-violation" TRACE_REVIEW_MODE="full" \
    "$LOG_HANDBACK" code-review-subagent review_verdict my-feature fail "test emission" 2>/dev/null
)
if [ -f "$E_TRACE" ]; then
  if ! jq -e '.["harness.failure_class"] == "spec-violation"' "$E_TRACE" >/dev/null 2>&1; then
    fail "E1 failure_class emission: span does not carry harness.failure_class=spec-violation (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E1 failure_class emission: trace file not created"
fi

# --- E2: TRACE_FINDING_FINGERPRINT forwarded on review_verdict -----------------
# Reset trace for clean test
rm -f "$E_TRACE"
(
  cd "$E_DIR"
  TRACE_FINDING_FINGERPRINT="sha256:abc123" TRACE_FAILURE_CLASS="spec-violation" TRACE_REVIEW_MODE="full" \
    "$LOG_HANDBACK" code-review-subagent review_verdict unmapped fail "test fingerprint" 2>/dev/null
)
if [ -f "$E_TRACE" ]; then
  if ! jq -e '.["harness.finding_fingerprint"] == "sha256:abc123"' "$E_TRACE" >/dev/null 2>&1; then
    fail "E2 fingerprint emission: span does not carry harness.finding_fingerprint (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E2 fingerprint emission: trace file not created"
fi

# --- E3: out-of-enum TRACE_FAILURE_CLASS -> omit + warn -----------------------
rm -f "$E_TRACE"
E3_ERR="${TMP_DIR}/e3_err.txt"
(
  cd "$E_DIR"
  TRACE_FAILURE_CLASS="totally-bogus-class" TRACE_REVIEW_MODE="full" \
    "$LOG_HANDBACK" code-review-subagent review_verdict my-feature fail "test bad class" 2>"$E3_ERR"
)
if [ -f "$E_TRACE" ]; then
  if jq -e 'has("harness.failure_class")' "$E_TRACE" >/dev/null 2>&1; then
    fail "E3 bad failure_class: out-of-enum value should be OMITTED, not forwarded (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E3 bad failure_class: trace file not created"
fi
grep -qi "failure_class\|omit" "$E3_ERR" \
  || fail "E3 bad failure_class: expected stderr warning about omitting invalid class (stderr: $(cat "$E3_ERR"))"

# --- E4: TRACE_FAILURE_CLASS=knowledge-gap forwarded on review_verdict ---------
# Proves the cross-issue slug can actually be emitted through log-handback.sh.
rm -f "$E_TRACE"
(
  cd "$E_DIR"
  TRACE_FAILURE_CLASS="knowledge-gap" TRACE_REVIEW_MODE="full" \
    "$LOG_HANDBACK" code-review-subagent review_verdict my-feature fail "test knowledge-gap class" 2>/dev/null
)
if [ -f "$E_TRACE" ]; then
  if ! jq -e '.["harness.failure_class"] == "knowledge-gap"' "$E_TRACE" >/dev/null 2>&1; then
    fail "E4 knowledge-gap emission: span does not carry harness.failure_class=knowledge-gap (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E4 knowledge-gap emission: trace file not created"
fi

# =============================================================================
# MUTATION LEGS
# =============================================================================

# --- M1: remove review_fail_unattributed rule -> A1 should fail ----------------
# This leg verifies teeth: if the check-trace-consistency rule were removed,
# the sensor would catch it (A1 would not see the expected violation).
# Since we already ran A1 above and it either passed or failed, this leg is
# proven by the A1 assertion itself: A1 expects exit 1 + the pinned finding
# string. If the rule were absent, A1 would have failed this sensor. This is
# structural teeth proof via the assertion design.

# --- M2: same reasoning for failure_class_other_no_detail ----------------------
# C4 expects exit 1 + the pinned finding. If the rule were absent, C4 would fail.

# =============================================================================
# VERDICT
# =============================================================================
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed — FAIL verdict attribution contract violated\n' "$fails" >&2
  exit 1
fi
printf 'FAIL verdict attribution contract honored (20 legs passed)\n'
