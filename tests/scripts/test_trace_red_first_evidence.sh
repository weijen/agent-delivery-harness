#!/usr/bin/env bash
# test_trace_red_first_evidence.sh — regression sensor for the red-first
# evidence rule of `scripts/check-trace-consistency.sh` (issue #144, feature
# trace-red-first-evidence).
#
# WHAT THIS PINS
# The existing state rule unverified_feature_pass only asks whether a
# passes:true feature has SOME green_handback pass span. Issue #144 raises the
# bar: a completed (passes:true) coded feature must show role-correct,
# file-ordered RED-first evidence — a real
#   test-subagent   red_handback   ->
#   implementation-subagent impl_handback ->
#   test-subagent   green_handback
# sequence for the SAME harness.feature_id, all harness.outcome==pass, in
# TRACE FILE ORDER — OR carry a governed red_first_waiver object on the
# feature entry (kind ∈ {bootstrap, visual-only, doc-only, justified} with a
# non-empty reason). Action Log prose is NOT a waiver; a malformed waiver is
# treated as no waiver; the checker must NOT fabricate/backfill missing spans.
#
# Two new findings are pinned literally so they cannot silently drift:
#     VIOLATION consistency: red_first_evidence_missing <feature_id>
#         no valid ordered role-correct triple AND no governed waiver
#     VIOLATION consistency: red_first_role_mismatch <feature_id>
#         a triple exists but a handback carries the wrong role (e.g. a
#         green_handback attributed to conductor rather than test-subagent)
#
# Findings echo only enum/id values (feature ids), never free text — the house
# report-only contract (exit 0 no findings · 1 findings · 2 usage/env error).
#
# FIXTURE SHAPE (path mode, hermetic, plain non-git dirs — the marker-only
# stance of the checker, mirroring test_trace_consistency_state.sh):
#     <case>/.copilot-tracking/issues/issue-77/{trace.jsonl,progress.md,
#                                               feature_list.json}
#     <case>/.copilot-tracking/review-gate/approved-head
# Every agent span has a matching `## Action Log` bullet and vice versa, roles
# stay in the closed enum, and every passes:true feature that is NOT under a
# waiver keeps a green_handback pass span — so the ONLY rule any leg can
# exercise is the red-first rule. No review_gate_approve or pr_create spans and
# no PR reference in progress.md, so those state rules NOTE-skip (never fire).
#
# CASES (expected findings pinned literally):
#   1 complete_triple_passes      ordered test/impl/test triple -> exit 0, none
#   2 missing_red_fails           impl+green, no red -> red_first_evidence_missing
#   3 missing_impl_fails          red+green, no impl -> red_first_evidence_missing
#   4 wrong_order_fails           green BEFORE impl in file order ->
#                                   red_first_evidence_missing (no ordered triple)
#   5 wrong_green_role_fails      green_handback by conductor ->
#                                   red_first_role_mismatch
#   6 waiver_passes               no triple, governed doc-only waiver -> exit 0
#   7 waiver_malformed_still_fails no triple, invalid-kind waiver ->
#                                   red_first_evidence_missing
#   + false-positive guard        a passes:false feat-b is never flagged
#
# RED status at authoring time: the shipped checker does not enforce red-first
# evidence (it only requires a green_handback). Cases 2/3/4/5/7 therefore fail
# today — the checker exits 0 and never emits the two new findings — so this
# sensor MUST FAIL until the rule is implemented. Cases 1 and 6 are guard legs
# that must hold both now and after implementation.
#
# Exit codes: 0 red-first contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Presence gate / prerequisites -------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -f "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the consistency checker under test is absent"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"

APPROVED_SHA="1111111111111111111111111111111111111111"

# --- Fixture builder ----------------------------------------------------------
# mk_case <name> <feature_list_json_oneline> <span_spec...>
#   span_spec = "role|step|feature|outcome" — emits one agent span (in the
#   given order) AND one matching `## Action Log` bullet, keeping the multiset
#   consistent so only the red-first rule is attributable.
mk_case() {
  local name="$1" feature_json="$2"
  shift 2
  local base="${TMP_DIR}/${name}/.copilot-tracking"
  local idir="${base}/issues/issue-77"
  mkdir -p "$idir" "${base}/review-gate"
  printf '%s\n' "$APPROVED_SHA" > "${base}/review-gate/approved-head"
  printf '%s\n' "$feature_json" > "${idir}/feature_list.json"

  : > "${idir}/trace.jsonl"
  printf '# Issue 77 progress\n\nStatus: fixture.\n\n## Action Log\n\n' \
    > "${idir}/progress.md"

  local spec role step feat outcome ts counter=0
  for spec in "$@"; do
    IFS='|' read -r role step feat outcome <<< "$spec"
    ts="$(printf '2026-07-04T12:00:%02dZ' "$counter")"
    counter=$((counter + 1))
    printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":77,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"%s","harness.lifecycle_step":"%s","harness.feature_id":"%s","harness.outcome":"%s"}\n' \
      "$ts" "$role" "$step" "$feat" "$outcome" >> "${idir}/trace.jsonl"
    printf -- '- [%s] %s %s %s — fixture span\n' \
      "$role" "$step" "$feat" "$outcome" >> "${idir}/progress.md"
  done
}

trace_path() {
  printf '%s' "${TMP_DIR}/$1/.copilot-tracking/issues/issue-77/trace.jsonl"
}

# feat-a is the feature under test; feat-b (passes:false) is the
# false-positive guard and never needs evidence.
FL_A_PASS='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true},{"id":"feat-b","title":"B","passes":false}]}'
FL_A_WAIVER_OK='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"red_first_waiver":{"kind":"doc-only","reason":"docs-only change, no code path touched"}}]}'
FL_A_WAIVER_BAD='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"red_first_waiver":{"kind":"whatever","reason":"x"}}]}'

# 1. Complete ordered role-correct triple.
mk_case complete_triple_passes "$FL_A_PASS" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 2. impl + green, red_handback absent (green keeps unverified_feature_pass
#    satisfied so ONLY red-first can fire).
mk_case missing_red_fails "$FL_A_PASS" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 3. red + green, impl_handback absent.
mk_case missing_impl_fails "$FL_A_PASS" \
  "test-subagent|red_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 4. All three present but green BEFORE impl in file order (no ordered triple).
mk_case wrong_order_fails "$FL_A_PASS" \
  "test-subagent|red_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass"

# 5. Ordered triple but green_handback attributed to conductor (wrong role).
mk_case wrong_green_role_fails "$FL_A_PASS" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "conductor|green_handback|feat-a|pass"

# 6. Governed waiver, no triple (green keeps unverified_feature_pass satisfied).
mk_case waiver_passes "$FL_A_WAIVER_OK" \
  "test-subagent|green_handback|feat-a|pass"

# 7. Malformed waiver (invalid kind), no triple — treated as no waiver.
mk_case waiver_malformed_still_fails "$FL_A_WAIVER_BAD" \
  "test-subagent|green_handback|feat-a|pass"

# Fixture self-check: every trace line parses (a malformed fixture would make
# findings unattributable).
for c in complete_triple_passes missing_red_fails missing_impl_fails \
         wrong_order_fails wrong_green_role_fails waiver_passes \
         waiver_malformed_still_fails; do
  jq empty "$(trace_path "$c")" >/dev/null 2>&1 \
    || hard_fail "fixture ${c}: trace.jsonl does not parse — sensor bug"
done

# --- Checker run helper -------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- 1. complete_triple_passes -> exit 0, no red-first violation --------------
rc="$(run_checker "$(trace_path complete_triple_passes)")"
[ "$rc" = "0" ] \
  || fail "complete_triple_passes: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -Eq 'VIOLATION consistency: red_first_(evidence_missing|role_mismatch)' "$OUT"; then
  fail "complete_triple_passes: a valid ordered role-correct triple must not raise a red-first violation (stdout: $(tr '\n' '|' < "$OUT"))"
fi
# False-positive guard: the passes:false feat-b is never flagged.
if grep -Eq 'VIOLATION consistency: red_first_(evidence_missing|role_mismatch) feat-b' "$OUT"; then
  fail "complete_triple_passes: a passes:false feature must never be flagged by the red-first rule (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 2. missing_red_fails -> red_first_evidence_missing feat-a ----------------
rc="$(run_checker "$(trace_path missing_red_fails)")"
[ "$rc" = "1" ] \
  || fail "missing_red_fails: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: red_first_evidence_missing feat-a' "$OUT" \
  || fail "missing_red_fails: pinned finding 'VIOLATION consistency: red_first_evidence_missing feat-a' missing — a green_handback alone is not red-first evidence (stdout: $(tr '\n' '|' < "$OUT"))"

# --- 3. missing_impl_fails -> red_first_evidence_missing feat-a ---------------
rc="$(run_checker "$(trace_path missing_impl_fails)")"
[ "$rc" = "1" ] \
  || fail "missing_impl_fails: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: red_first_evidence_missing feat-a' "$OUT" \
  || fail "missing_impl_fails: pinned finding 'VIOLATION consistency: red_first_evidence_missing feat-a' missing — no implementation-subagent impl_handback (stdout: $(tr '\n' '|' < "$OUT"))"

# --- 4. wrong_order_fails -> red_first_evidence_missing feat-a ----------------
rc="$(run_checker "$(trace_path wrong_order_fails)")"
[ "$rc" = "1" ] \
  || fail "wrong_order_fails: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: red_first_evidence_missing feat-a' "$OUT" \
  || fail "wrong_order_fails: pinned finding 'VIOLATION consistency: red_first_evidence_missing feat-a' missing — green before impl is not an ordered red->impl->green triple (stdout: $(tr '\n' '|' < "$OUT"))"

# --- 5. wrong_green_role_fails -> red_first_role_mismatch feat-a --------------
rc="$(run_checker "$(trace_path wrong_green_role_fails)")"
[ "$rc" = "1" ] \
  || fail "wrong_green_role_fails: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: red_first_role_mismatch feat-a' "$OUT" \
  || fail "wrong_green_role_fails: pinned finding 'VIOLATION consistency: red_first_role_mismatch feat-a' missing — a green_handback attributed to conductor is a role violation (stdout: $(tr '\n' '|' < "$OUT"))"

# --- 6. waiver_passes -> exit 0, no red-first violation -----------------------
rc="$(run_checker "$(trace_path waiver_passes)")"
[ "$rc" = "0" ] \
  || fail "waiver_passes: a governed doc-only red_first_waiver must allow a pass — expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -Eq 'VIOLATION consistency: red_first_(evidence_missing|role_mismatch)' "$OUT"; then
  fail "waiver_passes: a valid governed waiver must suppress the red-first violation (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 7. waiver_malformed_still_fails -> red_first_evidence_missing feat-a -----
rc="$(run_checker "$(trace_path waiver_malformed_still_fails)")"
[ "$rc" = "1" ] \
  || fail "waiver_malformed_still_fails: a malformed waiver (invalid kind) is not a governed waiver — expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: red_first_evidence_missing feat-a' "$OUT" \
  || fail "waiver_malformed_still_fails: pinned finding 'VIOLATION consistency: red_first_evidence_missing feat-a' missing — a malformed waiver must be treated as no waiver (stdout: $(tr '\n' '|' < "$OUT"))"

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-red-first-evidence contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-red-first-evidence contract honored\n'
