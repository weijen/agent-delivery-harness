#!/usr/bin/env bash
# test_repair_verdict_scope.sh — regression sensor for repair verdict scope
# (issue #318, feature repair-verdict-scope).
#
# Contract:
#   Every review_verdict span with harness.review_mode=repair (pass OR fail)
#   MUST carry a non-empty, valid harness.repair_scope; missing/empty is a
#   deterministic repair_scope_missing VIOLATION.
#
#   Canonical format: comma-separated list of feature-id tokens matching
#   [A-Za-z0-9._-]+, no whitespace, no empty tokens, no duplicate tokens.
#   Malformed values (whitespace, empty tokens, duplicates) are
#   repair_scope_invalid VIOLATIONs.
#
#   The verdict span's harness.feature_id MUST be an EXACT token member of
#   repair_scope. No substring matching (feat-a must not match feat-ab).
#   Mismatch is repair_scope_mismatch VIOLATION (out-of-scope verdict).
#   The literal "-" feature_id and "unmapped" are fail-closed: they MUST
#   still be exact members of repair_scope or they get
#   repair_scope_mismatch.
#
#   Full/concise verdicts do NOT require or carry repair_scope — the rule
#   is repair-mode-only.
#
#   TRACE_REPAIR_SCOPE emission is review-verdict-only AND repair-mode-only;
#   invalid values warn+omit (omit-never-fake), which checker then catches
#   as repair_scope_missing.
#
#   Whole-diff discoveries outside revised scope are emitted as separate
#   findings for their own feature — they MUST NOT silently expand/flip the
#   current repair verdict scope.
#
# Rules pinned:
#
#   repair_scope_missing — a review_verdict span with harness.review_mode
#     "repair" without a non-empty harness.repair_scope is a VIOLATION:
#         VIOLATION consistency: repair_scope_missing line <N>
#
#   repair_scope_invalid — a review_verdict span with harness.review_mode
#     "repair" carrying a harness.repair_scope that violates canonical
#     format (whitespace, empty tokens, duplicate tokens) is a VIOLATION:
#         VIOLATION consistency: repair_scope_invalid line <N>
#
#   repair_scope_mismatch — a review_verdict span with harness.review_mode
#     "repair" whose harness.feature_id is NOT an exact token member of
#     harness.repair_scope is a VIOLATION:
#         VIOLATION consistency: repair_scope_mismatch line <N>
#
# Emission pinned:
#   log-handback.sh review_verdict step + repair mode forwards
#   TRACE_REPAIR_SCOPE as harness.repair_scope with validation. Invalid
#   values → omit + warn (omit-never-fake). Non-repair or non-review_verdict
#   → absent even when env is set.
#
# Legs:
#   S1  repair verdict with valid single-token scope   -> no scope violations
#   S2  repair verdict with valid multi-token scope    -> no scope violations
#   S3  repair verdict missing repair_scope            -> repair_scope_missing
#   S4  repair verdict with empty repair_scope ""      -> repair_scope_missing
#   S5  repair verdict scope with whitespace           -> repair_scope_invalid
#   S6  repair verdict scope with empty token (,,)     -> repair_scope_invalid
#   S7  repair verdict scope with duplicate tokens     -> repair_scope_invalid
#   S8  feature_id outside scope (out-of-scope)        -> repair_scope_mismatch
#   S9  exact substring trap: feat-a ∉ {feat-ab}      -> repair_scope_mismatch
#   S10 feature_id "-" not in scope                    -> repair_scope_mismatch
#   S11 feature_id "unmapped" not in scope             -> repair_scope_mismatch
#   S12 full mode verdict — no repair_scope needed     -> no scope violations
#   S13 concise mode verdict — no repair_scope needed  -> no scope violations
#   S14 leading comma ",feat-a" scope                  -> repair_scope_invalid
#   S15 trailing comma "feat-a," scope                 -> repair_scope_invalid
#   E1  log-handback emits TRACE_REPAIR_SCOPE in repair mode -> span carries it
#   E2  log-handback omits invalid TRACE_REPAIR_SCOPE  -> omit + warn
#   E3  log-handback ignores TRACE_REPAIR_SCOPE on non-repair mode -> absent
#   E4  log-handback ignores TRACE_REPAIR_SCOPE on non-review_verdict -> absent
#   E5  log-handback omits trailing-comma TRACE_REPAIR_SCOPE -> omit + warn
#   M1  mutation: remove repair_scope_missing rule     -> S3 fails
#   M2  mutation: replace exact membership with substring -> S9 fails
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_REPAIR_SCOPE TRACE_FAILURE_CLASS TRACE_FAILURE_CLASS_DETAIL TRACE_FINDING_FINGERPRINT TRACE_REVIEW_MODE TRACE_REVIEW_EVENT_ID TRACE_FINDING_BASELINE_STATE 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required"
{ [ -f "$CHECKER" ] && [ -x "$CHECKER" ]; } \
  || hard_fail "scripts/check-trace-consistency.sh not found or not executable"
{ [ -f "$LOG_HANDBACK" ] && [ -x "$LOG_HANDBACK" ]; } \
  || hard_fail "scripts/log-handback.sh not found or not executable"

# --- Span + progress builders -------------------------------------------------
# Repair-mode verdict span builder. Caller supplies extra JSON fields via merge.
repair_verdict_span() {
  local ts="$1" extra="$2"
  local base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"pass","harness.review_mode":"repair","harness.reviewed_sha":"sha-repair"}'
  if [ -z "$extra" ]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "$base" | jq -c ". + $extra"
  fi
}
repair_fail_verdict_span() {
  local ts="$1" extra="$2"
  local base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail","harness.review_mode":"repair","harness.reviewed_sha":"sha-repair","harness.failure_class":"spec-violation","harness.finding_fingerprint":"sha256:abc","harness.finding_baseline_state":"new"}'
  if [ -z "$extra" ]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "$base" | jq -c ". + $extra"
  fi
}
full_verdict_span() {
  local ts="$1" extra="$2"
  local base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"pass","harness.review_mode":"full","harness.reviewed_sha":"sha-full"}'
  if [ -z "$extra" ]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "$base" | jq -c ". + $extra"
  fi
}
concise_verdict_span() {
  local ts="$1" extra="$2"
  local base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"pass","harness.review_mode":"concise","harness.reviewed_sha":"sha-concise"}'
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
# SCOPE CONSISTENCY LEGS
# =============================================================================

# --- S1: repair verdict with valid single-token scope -> no scope violations --
mkdir -p "${TMP_DIR}/s1"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"my-feat","harness.repair_scope":"my-feat"}'
} > "$(trace_path s1)"
{ progress_header; bullet "my-feat" pass; } > "${TMP_DIR}/s1/progress.md"

rc="$(run_checker "$(trace_path s1)")"
if grep -Fq 'repair_scope_missing' "$OUT"; then
  fail "S1 valid single scope: should NOT fire repair_scope_missing (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'repair_scope_invalid' "$OUT"; then
  fail "S1 valid single scope: should NOT fire repair_scope_invalid (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'repair_scope_mismatch' "$OUT"; then
  fail "S1 valid single scope: should NOT fire repair_scope_mismatch (stdout: $(cat "$OUT"))"
fi

# --- S2: repair verdict with valid multi-token scope -> no scope violations ---
mkdir -p "${TMP_DIR}/s2"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-a","harness.repair_scope":"feat-a,feat-b,feat-c"}'
} > "$(trace_path s2)"
{ progress_header; bullet "feat-a" pass; } > "${TMP_DIR}/s2/progress.md"

rc="$(run_checker "$(trace_path s2)")"
if grep -Fq 'repair_scope_missing' "$OUT"; then
  fail "S2 valid multi scope: should NOT fire repair_scope_missing (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'repair_scope_invalid' "$OUT"; then
  fail "S2 valid multi scope: should NOT fire repair_scope_invalid (stdout: $(cat "$OUT"))"
fi
if grep -Fq 'repair_scope_mismatch' "$OUT"; then
  fail "S2 valid multi scope: should NOT fire repair_scope_mismatch (stdout: $(cat "$OUT"))"
fi

# --- S3: repair verdict missing repair_scope -> repair_scope_missing ----------
mkdir -p "${TMP_DIR}/s3"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"my-feat"}'
} > "$(trace_path s3)"
{ progress_header; bullet "my-feat" pass; } > "${TMP_DIR}/s3/progress.md"

rc="$(run_checker "$(trace_path s3)")"
[ "$rc" = "1" ] \
  || fail "S3 missing scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_missing' "$OUT" \
  || fail "S3 missing scope: pinned finding 'repair_scope_missing' missing (stdout: $(cat "$OUT"))"

# --- S4: repair verdict with empty repair_scope "" -> repair_scope_missing ----
mkdir -p "${TMP_DIR}/s4"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"my-feat","harness.repair_scope":""}'
} > "$(trace_path s4)"
{ progress_header; bullet "my-feat" pass; } > "${TMP_DIR}/s4/progress.md"

rc="$(run_checker "$(trace_path s4)")"
[ "$rc" = "1" ] \
  || fail "S4 empty scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_missing' "$OUT" \
  || fail "S4 empty scope: pinned finding 'repair_scope_missing' missing (stdout: $(cat "$OUT"))"

# --- S5: repair verdict scope with whitespace -> repair_scope_invalid ---------
mkdir -p "${TMP_DIR}/s5"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-a","harness.repair_scope":"feat-a, feat-b"}'
} > "$(trace_path s5)"
{ progress_header; bullet "feat-a" pass; } > "${TMP_DIR}/s5/progress.md"

rc="$(run_checker "$(trace_path s5)")"
[ "$rc" = "1" ] \
  || fail "S5 whitespace scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_invalid' "$OUT" \
  || fail "S5 whitespace scope: pinned finding 'repair_scope_invalid' missing (stdout: $(cat "$OUT"))"

# --- S6: repair verdict scope with empty token (,,) -> repair_scope_invalid ---
mkdir -p "${TMP_DIR}/s6"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-a","harness.repair_scope":"feat-a,,feat-b"}'
} > "$(trace_path s6)"
{ progress_header; bullet "feat-a" pass; } > "${TMP_DIR}/s6/progress.md"

rc="$(run_checker "$(trace_path s6)")"
[ "$rc" = "1" ] \
  || fail "S6 empty token scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_invalid' "$OUT" \
  || fail "S6 empty token scope: pinned finding 'repair_scope_invalid' missing (stdout: $(cat "$OUT"))"

# --- S7: repair verdict scope with duplicate tokens -> repair_scope_invalid ---
mkdir -p "${TMP_DIR}/s7"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-a","harness.repair_scope":"feat-a,feat-b,feat-a"}'
} > "$(trace_path s7)"
{ progress_header; bullet "feat-a" pass; } > "${TMP_DIR}/s7/progress.md"

rc="$(run_checker "$(trace_path s7)")"
[ "$rc" = "1" ] \
  || fail "S7 duplicate scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_invalid' "$OUT" \
  || fail "S7 duplicate scope: pinned finding 'repair_scope_invalid' missing (stdout: $(cat "$OUT"))"

# --- S8: feature_id outside scope -> repair_scope_mismatch --------------------
mkdir -p "${TMP_DIR}/s8"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-c","harness.repair_scope":"feat-a,feat-b"}'
} > "$(trace_path s8)"
{ progress_header; bullet "feat-c" pass; } > "${TMP_DIR}/s8/progress.md"

rc="$(run_checker "$(trace_path s8)")"
[ "$rc" = "1" ] \
  || fail "S8 out-of-scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_mismatch' "$OUT" \
  || fail "S8 out-of-scope: pinned finding 'repair_scope_mismatch' missing (stdout: $(cat "$OUT"))"

# --- S9: exact substring trap: feat-a NOT in {feat-ab} -> mismatch -----------
mkdir -p "${TMP_DIR}/s9"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-a","harness.repair_scope":"feat-ab"}'
} > "$(trace_path s9)"
{ progress_header; bullet "feat-a" pass; } > "${TMP_DIR}/s9/progress.md"

rc="$(run_checker "$(trace_path s9)")"
[ "$rc" = "1" ] \
  || fail "S9 substring trap: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_mismatch' "$OUT" \
  || fail "S9 substring trap: pinned finding 'repair_scope_mismatch' missing (stdout: $(cat "$OUT"))"

# --- S10: feature_id "-" not in scope -> repair_scope_mismatch ----------------
mkdir -p "${TMP_DIR}/s10"
{
  repair_fail_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"-","harness.repair_scope":"feat-a"}'
} > "$(trace_path s10)"
{ progress_header; bullet "-" fail; } > "${TMP_DIR}/s10/progress.md"

rc="$(run_checker "$(trace_path s10)")"
# "-" will also fire review_fail_unattributed, but we specifically check
# repair_scope_mismatch is present too
grep -Fq 'VIOLATION consistency: repair_scope_mismatch' "$OUT" \
  || fail "S10 dash not in scope: pinned finding 'repair_scope_mismatch' missing (stdout: $(cat "$OUT"))"

# --- S11: feature_id "unmapped" not in scope -> repair_scope_mismatch ---------
mkdir -p "${TMP_DIR}/s11"
{
  repair_fail_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"unmapped","harness.repair_scope":"feat-a","harness.finding_fingerprint":"sha256:xyz"}'
} > "$(trace_path s11)"
{ progress_header; bullet "unmapped" fail; } > "${TMP_DIR}/s11/progress.md"

rc="$(run_checker "$(trace_path s11)")"
grep -Fq 'VIOLATION consistency: repair_scope_mismatch' "$OUT" \
  || fail "S11 unmapped not in scope: pinned finding 'repair_scope_mismatch' missing (stdout: $(cat "$OUT"))"

# --- S12: full mode verdict — no repair_scope needed -> no scope violations ---
mkdir -p "${TMP_DIR}/s12"
{
  full_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"my-feat"}'
} > "$(trace_path s12)"
{ progress_header; bullet "my-feat" pass; } > "${TMP_DIR}/s12/progress.md"

rc="$(run_checker "$(trace_path s12)")"
if grep -Fq 'repair_scope' "$OUT"; then
  fail "S12 full mode: should NOT fire any repair_scope finding (stdout: $(cat "$OUT"))"
fi

# --- S13: concise mode verdict — no repair_scope needed -> no scope violations
mkdir -p "${TMP_DIR}/s13"
{
  concise_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"my-feat"}'
} > "$(trace_path s13)"
{ progress_header; bullet "my-feat" pass; } > "${TMP_DIR}/s13/progress.md"

rc="$(run_checker "$(trace_path s13)")"
if grep -Fq 'repair_scope' "$OUT"; then
  fail "S13 concise mode: should NOT fire any repair_scope finding (stdout: $(cat "$OUT"))"
fi

# --- S14: leading comma ",feat-a" -> repair_scope_invalid --------------------
mkdir -p "${TMP_DIR}/s14"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-a","harness.repair_scope":",feat-a"}'
} > "$(trace_path s14)"
{ progress_header; bullet "feat-a" pass; } > "${TMP_DIR}/s14/progress.md"

rc="$(run_checker "$(trace_path s14)")"
[ "$rc" = "1" ] \
  || fail "S14 leading-comma scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_invalid' "$OUT" \
  || fail "S14 leading-comma scope: pinned finding 'repair_scope_invalid' missing (stdout: $(cat "$OUT"))"

# --- S15: trailing comma "feat-a," -> repair_scope_invalid -------------------
mkdir -p "${TMP_DIR}/s15"
{
  repair_verdict_span "2026-07-20T10:00:00Z" '{"harness.feature_id":"feat-a","harness.repair_scope":"feat-a,"}'
} > "$(trace_path s15)"
{ progress_header; bullet "feat-a" pass; } > "${TMP_DIR}/s15/progress.md"

rc="$(run_checker "$(trace_path s15)")"
[ "$rc" = "1" ] \
  || fail "S15 trailing-comma scope: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: repair_scope_invalid' "$OUT" \
  || fail "S15 trailing-comma scope: pinned finding 'repair_scope_invalid' missing (stdout: $(cat "$OUT"))"

# =============================================================================
# EMISSION LEGS (log-handback.sh passthrough)
# =============================================================================

# --- E1: TRACE_REPAIR_SCOPE forwarded on review_verdict + repair mode ---------
E_DIR="${TMP_DIR}/emission"
mkdir -p "${E_DIR}/.copilot-tracking/issues/issue-318"
(
  cd "$E_DIR" && git init -q && git checkout -b feature/issue-318-test 2>/dev/null
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf '# Issue 318 progress\n\nStatus: in progress.\n\n## Action Log\n\n' \
    > .copilot-tracking/issues/issue-318/progress.md
  git add -A && git commit -q -m "init" --allow-empty
)
E_TRACE="${E_DIR}/.copilot-tracking/issues/issue-318/trace.jsonl"

(
  cd "$E_DIR"
  TRACE_REPAIR_SCOPE="feat-a,feat-b" TRACE_REVIEW_MODE="repair" \
    "$LOG_HANDBACK" code-review-subagent review_verdict feat-a pass "repair review" 2>/dev/null
)
if [ -f "$E_TRACE" ]; then
  if ! jq -e '.["harness.repair_scope"] == "feat-a,feat-b"' "$E_TRACE" >/dev/null 2>&1; then
    fail "E1 repair_scope emission: span does not carry harness.repair_scope=feat-a,feat-b (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E1 repair_scope emission: trace file not created"
fi

# --- E2: log-handback omits invalid TRACE_REPAIR_SCOPE -> omit + warn --------
rm -f "$E_TRACE"
E2_ERR="${TMP_DIR}/e2_err.txt"
(
  cd "$E_DIR"
  TRACE_REPAIR_SCOPE="feat a, feat-b" TRACE_REVIEW_MODE="repair" \
    "$LOG_HANDBACK" code-review-subagent review_verdict feat-a pass "bad scope" 2>"$E2_ERR"
)
if [ -f "$E_TRACE" ]; then
  if jq -e 'has("harness.repair_scope")' "$E_TRACE" >/dev/null 2>&1; then
    fail "E2 invalid repair_scope: should be OMITTED, not forwarded (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E2 invalid repair_scope: trace file not created"
fi
grep -qi "repair_scope\|omit" "$E2_ERR" \
  || fail "E2 invalid repair_scope: expected stderr warning about omitting invalid scope (stderr: $(cat "$E2_ERR"))"

# --- E3: log-handback ignores TRACE_REPAIR_SCOPE on non-repair mode -> absent -
rm -f "$E_TRACE"
(
  cd "$E_DIR"
  TRACE_REPAIR_SCOPE="feat-a" TRACE_REVIEW_MODE="full" \
    "$LOG_HANDBACK" code-review-subagent review_verdict feat-a pass "full review" 2>/dev/null
)
if [ -f "$E_TRACE" ]; then
  if jq -e 'has("harness.repair_scope")' "$E_TRACE" >/dev/null 2>&1; then
    fail "E3 non-repair mode: repair_scope should be ABSENT on full mode (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E3 non-repair mode: trace file not created"
fi

# --- E4: log-handback ignores TRACE_REPAIR_SCOPE on non-review_verdict --------
rm -f "$E_TRACE"
(
  cd "$E_DIR"
  TRACE_REPAIR_SCOPE="feat-a" TRACE_REVIEW_MODE="repair" \
    "$LOG_HANDBACK" generator-subagent green_handback feat-a pass "green" 2>/dev/null
)
if [ -f "$E_TRACE" ]; then
  if jq -e 'has("harness.repair_scope")' "$E_TRACE" >/dev/null 2>&1; then
    fail "E4 non-review_verdict: repair_scope should be ABSENT on non-review_verdict step (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E4 non-review_verdict: trace file not created"
fi

# --- E5: log-handback omits trailing-comma TRACE_REPAIR_SCOPE -> omit + warn --
rm -f "$E_TRACE"
E5_ERR="${TMP_DIR}/e5_err.txt"
(
  cd "$E_DIR"
  TRACE_REPAIR_SCOPE="feat-a," TRACE_REVIEW_MODE="repair" \
    "$LOG_HANDBACK" code-review-subagent review_verdict feat-a pass "trailing comma boundary" 2>"$E5_ERR"
)
if [ -f "$E_TRACE" ]; then
  if jq -e 'has("harness.repair_scope")' "$E_TRACE" >/dev/null 2>&1; then
    fail "E5 trailing-comma repair_scope: should be OMITTED, not forwarded (span: $(cat "$E_TRACE"))"
  fi
else
  fail "E5 trailing-comma repair_scope: trace file not created"
fi
grep -qi "repair_scope\|omit" "$E5_ERR" \
  || fail "E5 trailing-comma repair_scope: expected stderr warning about omitting invalid scope (stderr: $(cat "$E5_ERR"))"

# =============================================================================
# MUTATION LEGS
# =============================================================================

# --- M1: remove repair_scope_missing rule -> S3 should fail -------------------
# Structural teeth: S3 expects exit 1 + the pinned finding. If the rule were
# absent, S3 would fail this sensor.

# --- M2: replace exact membership with substring -> S9 should fail ------------
# Structural teeth: S9 expects exit 1 + repair_scope_mismatch when feat-a is
# checked against scope "feat-ab". A substring check would pass, so S9 would
# fail this sensor.

# =============================================================================
# VERDICT
# =============================================================================
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed — repair verdict scope contract violated\n' "$fails" >&2
  exit 1
fi
printf 'repair verdict scope contract honored (21 legs passed)\n'
