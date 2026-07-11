#!/usr/bin/env bash
# test_trace_red_first_evidence.sh — regression sensor for the completed-feature
# teeth-proof rule of `scripts/check-trace-consistency.sh` (issue #264, feature
# checker-teeth-proof-satisfies).
#
# WHAT THIS PINS
# The state rule unverified_feature_pass only asks whether a passes:true feature
# has SOME green_handback pass span. Issue #264 raises the completed-feature
# contract: for every passes:true feature, proof is satisfied by exactly one of:
#   * a governed teeth_proof_waiver object (kind ∈ {bootstrap, visual-only,
#     doc-only, justified} and non-empty reason), with deprecated alias
#     red_first_waiver still accepted,
#   * a role-correct, file-ordered RED-first triple for the SAME
#     harness.feature_id, all harness.outcome==pass:
#       test-subagent red_handback -> implementation-subagent impl_handback ->
#       test-subagent green_handback,
#   * a governed teeth_proof object (kind ∈ {red_first, mutation,
#     negative_fixture} and non-empty evidence string).
#
# A valid waiver is fully satisfied and emits no warning. The canonical waiver
# key is teeth_proof_waiver; red_first_waiver is a deprecated accepted alias. A
# malformed waiver object is refused and does not waive. A valid ordered triple
# is fully satisfied and emits no warning. A valid teeth_proof without a waiver
# or triple satisfies the hard proof requirement but must keep warn-only context
# that ordering was not proven. A passes:true feature with none of the three
# emits both the hard violation and the warn-only ordering context. passes:false
# features are never flagged. When BOTH waiver keys are present, teeth_proof_waiver
# takes precedence by key presence — even a malformed teeth_proof_waiver shadows a
# valid legacy red_first_waiver (the feature then VIOLATES rather than being
# rescued by the legacy key).
#
# Two issue #264 findings are pinned literally so they cannot silently drift:
#     VIOLATION consistency: teeth_proof_missing <feature_id>
#         no governed waiver, no role-correct ordered triple, and no valid
#         teeth_proof object
#     WARNING consistency: red_first_ordering_absent <feature_id>
#         no role-correct ordered triple; advisory only and must not affect exit
#
# The old findings are retired and must never be emitted:
#     red_first_evidence_missing
#     red_first_role_mismatch
#
# Findings echo only enum/id values (feature ids), never free text — the house
# report-only contract (exit 0 no violations · 1 violations · 2 usage/env error).
# WARNING lines never change the exit code.
#
# FIXTURE SHAPE (path mode, hermetic, plain non-git dirs — the marker-only
# stance of the checker, mirroring test_trace_consistency_state.sh):
#     <case>/.copilot-tracking/issues/issue-77/{trace.jsonl,progress.md,
#                                               feature_list.json}
#     <case>/.copilot-tracking/review-gate/approved-head
# Every agent span has a matching `## Action Log` bullet and vice versa, roles
# stay in the closed enum, and every passes:true feature keeps a green_handback
# pass span — so the ONLY hard rule any leg can exercise is the teeth-proof rule.
# If both waiver keys are present, teeth_proof_waiver takes precedence. No
# review_gate_approve or pr_create spans and no PR reference in progress.md,
# so those state rules NOTE-skip (never fire).
#
# CASES (expected findings pinned literally):
#   1 complete_triple_passes       ordered test/impl/test triple -> exit 0, no
#                                  teeth_proof_missing, no ordering warning,
#                                  no retired tokens
#   2 missing_red_fails            impl+green, no red -> teeth_proof_missing +
#                                  red_first_ordering_absent
#   3 missing_impl_fails           red+green, no impl -> teeth_proof_missing +
#                                  red_first_ordering_absent
#   4 wrong_order_fails            green BEFORE impl in file order ->
#                                  teeth_proof_missing + ordering warning
#   5 wrong_green_role_fails       green_handback by conductor ->
#                                  teeth_proof_missing + ordering warning;
#                                  no retired role_mismatch token
#   6 waiver_passes                governed doc-only red_first_waiver deprecated
#                                  alias -> exit 0, no violation, no warning
#   7 waiver_malformed_still_fails invalid-kind red_first_waiver ->
#                                  teeth_proof_missing + ordering warning
#   8 teeth_proof_waiver_passes    governed doc-only teeth_proof_waiver ->
#                                  exit 0, no teeth_proof_missing
#   9 teeth_proof_waiver_malformed_still_fails empty teeth_proof_waiver ->
#                                  teeth_proof_missing + ordering warning
#  10 teeth_proof_only_passes      valid teeth_proof only -> exit 0, no
#                                  teeth_proof_missing, ordering warning present
#  11 teeth_proof_malformed_fails  malformed teeth_proof -> exit 1,
#                                  teeth_proof_missing
#  12 both_waivers_teeth_wins      valid teeth_proof_waiver + valid legacy
#                                  red_first_waiver -> exit 0 (new key wins)
#  13 both_waivers_malformed_teeth_shadows_legacy malformed teeth_proof_waiver
#                                  shadows a VALID legacy red_first_waiver ->
#                                  exit 1, teeth_proof_missing (the #275 trap)
#   + false-positive guard         a passes:false feat-b is never flagged
#
# RED status at authoring time: the shipped checker still emits the retired
# red_first_evidence_missing/red_first_role_mismatch findings and does not emit
# teeth_proof_missing/red_first_ordering_absent. This sensor MUST FAIL until the
# checker is migrated to the issue #264 contract.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
TMP_PARENT="${ROOT}/.copilot-tracking/tmp"
mkdir -p "$TMP_PARENT"
TMP_DIR="$(mktemp -d "${TMP_PARENT}/trace-red-first.XXXXXX")"
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
#   consistent so only the teeth-proof/red-first rule is attributable.
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
FL_A_TEETH_WAIVER_OK='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{"kind":"doc-only","reason":"docs only, no code path"}}]}'
FL_A_TEETH_WAIVER_BAD='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{}}]}'
# Both waiver keys present. Precedence: teeth_proof_waiver wins by KEY PRESENCE
# (check-trace-consistency: `if has("teeth_proof_waiver") then … else …`).
#   _BOTH_OK   — valid teeth_proof_waiver + valid legacy red_first_waiver → waived.
#   _BOTH_TRAP — MALFORMED teeth_proof_waiver shadows a VALID legacy
#                red_first_waiver → the new key is selected, refused, and the
#                feature flips to VIOLATION (the trap the #275 alias introduced).
FL_A_BOTH_WAIVERS_OK='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{"kind":"doc-only","reason":"docs only, no code path"},"red_first_waiver":{"kind":"doc-only","reason":"legacy alias also present"}}]}'
FL_A_BOTH_WAIVERS_TRAP='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{},"red_first_waiver":{"kind":"doc-only","reason":"valid legacy waiver that must NOT rescue the malformed new key"}}]}'
FL_A_TEETH_OK='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof":{"kind":"red_first","evidence":"sensor X failed before impl at abc123"}},{"id":"feat-b","title":"B","passes":false}]}'
FL_A_TEETH_BAD='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof":{"kind":"nonsense","evidence":""}}]}'

# 1. Complete ordered role-correct triple. A feature_start span is included
#    so this exit-0 fixture also satisfies the independent issue #291
#    feature_start_missing obligation (see
#    tests/scripts/test_trace_feature_start_evidence.sh) — otherwise a
#    genuinely clean red-first triple would be flipped to exit 1 by an
#    unrelated rule.
mk_case complete_triple_passes "$FL_A_PASS" \
  "conductor|feature_start|feat-a|pass" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 2. impl + green, red_handback absent (green keeps unverified_feature_pass
#    satisfied so ONLY teeth-proof/red-first can fire).
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

# 5. Ordered triple by step, but green_handback attributed to conductor.
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

# 8. Governed teeth_proof_waiver, no triple and no teeth_proof — treated as a
#    valid waiver.
mk_case teeth_proof_waiver_passes "$FL_A_TEETH_WAIVER_OK" \
  "test-subagent|green_handback|feat-a|pass"

# 9. Malformed teeth_proof_waiver, no triple and no teeth_proof — refused and
#    treated as no waiver.
mk_case teeth_proof_waiver_malformed_still_fails "$FL_A_TEETH_WAIVER_BAD" \
  "test-subagent|green_handback|feat-a|pass"

# 10. Valid teeth_proof, no triple — hard pass with warn-only ordering
#     context. A feature_start span is included so this exit-0 fixture also
#     satisfies the independent issue #291 feature_start_missing obligation.
mk_case teeth_proof_only_passes "$FL_A_TEETH_OK" \
  "conductor|feature_start|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 11. Malformed teeth_proof, no triple — treated as no teeth_proof.
mk_case teeth_proof_malformed_fails "$FL_A_TEETH_BAD" \
  "test-subagent|green_handback|feat-a|pass"

# 12. Both waiver keys present and BOTH valid — teeth_proof_waiver takes
#     precedence; still a valid waiver, so exit 0, no violation.
mk_case both_waivers_teeth_wins "$FL_A_BOTH_WAIVERS_OK" \
  "test-subagent|green_handback|feat-a|pass"

# 13. TRAP: malformed teeth_proof_waiver shadows a VALID legacy red_first_waiver.
#     Precedence is by key presence, so the malformed new key is selected and
#     refused — the legacy waiver does NOT rescue it and the feature is a
#     VIOLATION.
mk_case both_waivers_malformed_teeth_shadows_legacy "$FL_A_BOTH_WAIVERS_TRAP" \
  "test-subagent|green_handback|feat-a|pass"

# Fixture self-check: every trace line parses (a malformed fixture would make
# findings unattributable).
for c in complete_triple_passes missing_red_fails missing_impl_fails \
         wrong_order_fails wrong_green_role_fails waiver_passes \
         waiver_malformed_still_fails teeth_proof_waiver_passes \
         teeth_proof_waiver_malformed_still_fails teeth_proof_only_passes \
         teeth_proof_malformed_fails both_waivers_teeth_wins \
         both_waivers_malformed_teeth_shadows_legacy; do
  jq empty "$(trace_path "$c")" >/dev/null 2>&1 \
    || hard_fail "fixture ${c}: trace.jsonl does not parse — sensor bug"
done

# --- Checker run/assert helpers ----------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}
stdout_oneline() {
  tr '\n' '|' < "$OUT"
}
stderr_oneline() {
  tr '\n' '|' < "$ERR"
}
assert_present() {
  local case_name="$1" token="$2"
  grep -Fq "$token" "$OUT" \
    || fail "${case_name}: expected literal '${token}' missing (stdout: $(stdout_oneline))"
}
assert_absent() {
  local case_name="$1" token="$2"
  if grep -Fq "$token" "$OUT"; then
    fail "${case_name}: unexpected literal '${token}' emitted (stdout: $(stdout_oneline))"
  fi
}
assert_no_retired_tokens() {
  local case_name="$1"
  assert_absent "$case_name" 'red_first_evidence_missing'
  assert_absent "$case_name" 'red_first_role_mismatch'
}
assert_no_feat_b_tooth_flag() {
  local case_name="$1"
  assert_absent "$case_name" 'teeth_proof_missing feat-b'
}

# --- 1. complete_triple_passes -> exit 0, no findings/warnings ----------------
rc="$(run_checker "$(trace_path complete_triple_passes)")"
[ "$rc" = "0" ] \
  || fail "complete_triple_passes: expected exit 0, got ${rc} (stdout: $(stdout_oneline) stderr: $(stderr_oneline))"
assert_absent complete_triple_passes 'VIOLATION consistency: teeth_proof_missing'
assert_absent complete_triple_passes 'WARNING consistency: red_first_ordering_absent'
assert_no_retired_tokens complete_triple_passes
assert_no_feat_b_tooth_flag complete_triple_passes

# --- 2. missing_red_fails -> teeth_proof_missing + ordering warning -----------
rc="$(run_checker "$(trace_path missing_red_fails)")"
[ "$rc" = "1" ] \
  || fail "missing_red_fails: expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present missing_red_fails 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_present missing_red_fails 'WARNING consistency: red_first_ordering_absent feat-a'
assert_no_retired_tokens missing_red_fails
assert_no_feat_b_tooth_flag missing_red_fails

# --- 3. missing_impl_fails -> teeth_proof_missing + ordering warning ----------
rc="$(run_checker "$(trace_path missing_impl_fails)")"
[ "$rc" = "1" ] \
  || fail "missing_impl_fails: expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present missing_impl_fails 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_present missing_impl_fails 'WARNING consistency: red_first_ordering_absent feat-a'
assert_no_retired_tokens missing_impl_fails
assert_no_feat_b_tooth_flag missing_impl_fails

# --- 4. wrong_order_fails -> teeth_proof_missing + ordering warning -----------
rc="$(run_checker "$(trace_path wrong_order_fails)")"
[ "$rc" = "1" ] \
  || fail "wrong_order_fails: expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present wrong_order_fails 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_present wrong_order_fails 'WARNING consistency: red_first_ordering_absent feat-a'
assert_no_retired_tokens wrong_order_fails
assert_no_feat_b_tooth_flag wrong_order_fails

# --- 5. wrong_green_role_fails -> teeth_proof_missing + ordering warning ------
rc="$(run_checker "$(trace_path wrong_green_role_fails)")"
[ "$rc" = "1" ] \
  || fail "wrong_green_role_fails: expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present wrong_green_role_fails 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_present wrong_green_role_fails 'WARNING consistency: red_first_ordering_absent feat-a'
assert_absent wrong_green_role_fails 'red_first_role_mismatch'
assert_no_retired_tokens wrong_green_role_fails
assert_no_feat_b_tooth_flag wrong_green_role_fails

# --- 6. waiver_passes -> exit 0, no violation/warning -------------------------
rc="$(run_checker "$(trace_path waiver_passes)")"
[ "$rc" = "0" ] \
  || fail "waiver_passes: a governed doc-only red_first_waiver must allow a pass — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent waiver_passes 'VIOLATION consistency: teeth_proof_missing'
assert_absent waiver_passes 'WARNING consistency: red_first_ordering_absent'
assert_no_retired_tokens waiver_passes

# --- 7. waiver_malformed_still_fails -> teeth_proof_missing + warning ---------
rc="$(run_checker "$(trace_path waiver_malformed_still_fails)")"
[ "$rc" = "1" ] \
  || fail "waiver_malformed_still_fails: a malformed waiver is not governed — expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present waiver_malformed_still_fails 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_present waiver_malformed_still_fails 'WARNING consistency: red_first_ordering_absent feat-a'
assert_no_retired_tokens waiver_malformed_still_fails

# --- 8. teeth_proof_waiver_passes -> exit 0, no violation/warning -------------
rc="$(run_checker "$(trace_path teeth_proof_waiver_passes)")"
[ "$rc" = "0" ] \
  || fail "teeth_proof_waiver_passes: a governed doc-only teeth_proof_waiver must allow a pass — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent teeth_proof_waiver_passes 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_absent teeth_proof_waiver_passes 'WARNING consistency: red_first_ordering_absent feat-a'
assert_no_retired_tokens teeth_proof_waiver_passes

# --- 9. teeth_proof_waiver_malformed_still_fails -> missing + warning ---------
rc="$(run_checker "$(trace_path teeth_proof_waiver_malformed_still_fails)")"
[ "$rc" = "1" ] \
  || fail "teeth_proof_waiver_malformed_still_fails: an empty teeth_proof_waiver is not governed — expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present teeth_proof_waiver_malformed_still_fails 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_present teeth_proof_waiver_malformed_still_fails 'WARNING consistency: red_first_ordering_absent feat-a'
assert_no_retired_tokens teeth_proof_waiver_malformed_still_fails

# --- 10. teeth_proof_only_passes -> exit 0, warning only ----------------------
rc="$(run_checker "$(trace_path teeth_proof_only_passes)")"
[ "$rc" = "0" ] \
  || fail "teeth_proof_only_passes: valid teeth_proof must satisfy the hard contract — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent teeth_proof_only_passes 'VIOLATION consistency: teeth_proof_missing'
assert_present teeth_proof_only_passes 'WARNING consistency: red_first_ordering_absent feat-a'
assert_no_retired_tokens teeth_proof_only_passes
assert_no_feat_b_tooth_flag teeth_proof_only_passes

# --- 11. teeth_proof_malformed_fails -> teeth_proof_missing -------------------
rc="$(run_checker "$(trace_path teeth_proof_malformed_fails)")"
[ "$rc" = "1" ] \
  || fail "teeth_proof_malformed_fails: malformed teeth_proof is not proof — expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present teeth_proof_malformed_fails 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_no_retired_tokens teeth_proof_malformed_fails

# --- 12. both_waivers_teeth_wins -> exit 0 (valid teeth_proof_waiver wins) ----
rc="$(run_checker "$(trace_path both_waivers_teeth_wins)")"
[ "$rc" = "0" ] \
  || fail "both_waivers_teeth_wins: a valid teeth_proof_waiver must waive even when a legacy red_first_waiver is also present — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent both_waivers_teeth_wins 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_no_retired_tokens both_waivers_teeth_wins

# --- 13. TRAP: malformed teeth_proof_waiver shadows a valid legacy waiver -----
# Precedence is by key presence, so the malformed new key is selected and
# refused; the valid legacy red_first_waiver must NOT rescue it.
rc="$(run_checker "$(trace_path both_waivers_malformed_teeth_shadows_legacy)")"
[ "$rc" = "1" ] \
  || fail "both_waivers_malformed_teeth_shadows_legacy: a malformed teeth_proof_waiver must shadow (not defer to) a valid legacy red_first_waiver — expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present both_waivers_malformed_teeth_shadows_legacy 'VIOLATION consistency: teeth_proof_missing feat-a'
assert_no_retired_tokens both_waivers_malformed_teeth_shadows_legacy

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d checker-teeth-proof-satisfies contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'checker-teeth-proof-satisfies contract honored\n'
