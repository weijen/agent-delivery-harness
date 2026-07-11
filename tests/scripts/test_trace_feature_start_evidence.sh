#!/usr/bin/env bash
# test_trace_feature_start_evidence.sh — regression sensor for the per-feature
# selection-evidence rule of `scripts/check-trace-consistency.sh` (issue #291,
# feature checker-feature-start-missing).
#
# WHAT THIS PINS
# feature_start is the only per-feature selection-time boundary the trace can
# carry (the conductor's "I picked this feature next" moment, logged via
# `scripts/log-handback.sh conductor feature_start <fid> pass …`). This rule
# raises a NEW hard obligation, independent of the existing teeth-proof /
# red-first contract pinned by tests/scripts/test_trace_red_first_evidence.sh:
#
#   For every passes:true feature, the trace must carry AT LEAST ONE agent
#   span with harness.lifecycle_step == "feature_start" AND
#   harness.feature_id == <the feature's id>. Absent that (no span at all, or
#   only a span for a DIFFERENT feature_id), the checker emits:
#       VIOLATION consistency: feature_start_missing <feature_id>
#
#   A governed waiver rescues the obligation exactly like the teeth-proof
#   rule: a valid canonical teeth_proof_waiver object (kind in the closed set
#   {bootstrap, visual-only, doc-only, justified}, non-empty reason) OR the
#   deprecated red_first_waiver alias waives feature_start_missing too. Key
#   presence precedence is shared with the teeth-proof rule: when BOTH keys
#   are present, teeth_proof_waiver is selected — even when malformed, it
#   SHADOWS a valid legacy red_first_waiver, and the feature stays a
#   violation rather than being rescued by the legacy key.
#
#   This rule is deliberately narrow (issue #291 scope): step + feature_id
#   match ONLY. No role check (any agent role may emit feature_start — role
#   strictness on WHO reported which step is out of scope here, unlike the
#   red-first triple's role-correctness rule). No timestamp/ordering check
#   (unlike the red-first triple, feature_start is not required to precede
#   red_handback/impl_handback/green_handback in file order for this rule).
#   No schema/history logic — presence is the entire test.
#
#   passes:false features are never flagged, regardless of feature_start
#   evidence. An ordered red-first triple (or any other teeth-proof evidence)
#   does NOT, by itself, satisfy feature_start — the two rules are
#   independent and are exercised in isolation from each other in every case
#   below (each fixture supplies exactly one variable: the feature_start
#   evidence), so a case can show `teeth_proof_missing` absent (satisfied via
#   its own path) while `feature_start_missing` is still present, and vice
#   versa.
#
# CASES (expected findings pinned literally):
#   1 span_clean_passes           full red-first triple + matching
#                                  feature_start span for feat-a -> exit 0,
#                                  no feature_start_missing, no
#                                  teeth_proof_missing
#   2 span_missing_fails          full triple, NO feature_start span at all
#                                  -> feature_start_missing feat-a;
#                                  teeth_proof_missing absent (triple already
#                                  satisfies the unrelated rule)
#   3 wrong_fid_fails              full triple + a feature_start span for a
#                                  DIFFERENT feature_id (feat-x) -> still
#                                  feature_start_missing feat-a (a
#                                  differently-fid'd span never satisfies)
#   4 canonical_waiver_clean       valid teeth_proof_waiver, no feature_start
#                                  span, no triple -> exit 0, no
#                                  feature_start_missing (waived same as
#                                  teeth-proof)
#   5 legacy_waiver_clean          valid deprecated red_first_waiver alias, no
#                                  feature_start span, no triple -> exit 0, no
#                                  feature_start_missing
#   6 malformed_canonical_shadows_legacy_fails
#                                  malformed teeth_proof_waiver + a VALID
#                                  legacy red_first_waiver + full triple (so
#                                  teeth_proof_missing is satisfied via the
#                                  triple, isolating this case to
#                                  feature_start alone), no feature_start
#                                  span -> feature_start_missing feat-a (the
#                                  malformed canonical key shadows the valid
#                                  legacy one; the feature is NOT rescued)
#   7 passes_false_untouched       feat-b passes:false only, no spans at all
#                                  -> exit 0, no feature_start_missing ever
#   8 no_feature_list_clean        no feature_list.json sibling at all (full
#                                  triple present in the trace) -> exit 0, no
#                                  feature_start_missing (state rules skip
#                                  entirely without a feature list)
#   9 empty_features_clean         feature_list.json with an empty features
#                                  array -> exit 0, no feature_start_missing
#  + false-positive guard: every case above also carries a passes:false
#    feat-b with no feature_start span of its own; feat-b must never be
#    flagged, in any case.
#
# FIXTURE SHAPE (path mode, hermetic, plain non-git dirs — mirrors
# tests/scripts/test_trace_red_first_evidence.sh):
#     <case>/.copilot-tracking/issues/issue-77/{trace.jsonl,progress.md,
#                                               feature_list.json}
#     <case>/.copilot-tracking/review-gate/approved-head
# Every agent span has a matching `## Action Log` bullet and vice versa
# (log_without_span / span_without_log never fire), every emitted role stays
# in the closed enum (role_attribution_gap never fires), and no
# worktree_create/finish lifecycle spans exist (dark_run always NOTE-skips —
# no TRACE_ALLOW_DARK_RUN override needed). This isolates every assertion to
# feature_start_missing (and, where relevant, teeth_proof_missing as an
# explicit cross-check that the two rules are independent).
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not
# implement the feature_start_missing rule yet — it never emits
# `VIOLATION consistency: feature_start_missing`. This sensor MUST FAIL
# (cases 2, 3, 6 expect the literal finding and exit 1; they currently get
# neither) until the checker is migrated to the issue #291 contract.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
TMP_PARENT="${ROOT}/.copilot-tracking/tmp"
mkdir -p "$TMP_PARENT"
TMP_DIR="$(mktemp -d "${TMP_PARENT}/trace-feature-start.XXXXXX")"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_ALLOW_DARK_RUN 2>/dev/null || true

# --- Presence gate / prerequisites -------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -f "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the consistency checker under test is absent"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"

APPROVED_SHA="2222222222222222222222222222222222222222"

# --- Fixture builder ----------------------------------------------------------
# mk_case <name> <feature_list_json_oneline> <span_spec...>
#   span_spec = "role|step|feature|outcome" — emits one agent span (in the
#   given order) AND one matching `## Action Log` bullet, keeping the
#   log/span multiset consistent so only the rule under test is attributable.
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
    ts="$(printf '2026-07-11T12:00:%02dZ' "$counter")"
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
feature_list_path() {
  printf '%s' "${TMP_DIR}/$1/.copilot-tracking/issues/issue-77/feature_list.json"
}

# feat-a is the feature under test; feat-b (passes:false) is the
# false-positive guard and never needs feature_start evidence.
FL_PASS='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true},{"id":"feat-b","title":"B","passes":false}]}'
FL_CANON_WAIVER_OK='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{"kind":"doc-only","reason":"docs only, no code path"}},{"id":"feat-b","title":"B","passes":false}]}'
FL_LEGACY_WAIVER_OK='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"red_first_waiver":{"kind":"doc-only","reason":"docs-only change, no code path touched"}},{"id":"feat-b","title":"B","passes":false}]}'
# Both waiver keys present: teeth_proof_waiver is MALFORMED (empty object),
# red_first_waiver is a VALID legacy alias. Precedence is by key presence
# (check-trace-consistency: `if has("teeth_proof_waiver") then … else …`), so
# the malformed new key is selected and refused — the valid legacy key must
# NOT rescue the feature.
FL_BOTH_WAIVERS_TRAP='{"issue":77,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{},"red_first_waiver":{"kind":"doc-only","reason":"valid legacy waiver that must NOT rescue the malformed new key"}},{"id":"feat-b","title":"B","passes":false}]}'
FL_ONLY_B='{"issue":77,"features":[{"id":"feat-b","title":"B","passes":false}]}'
FL_EMPTY='{"issue":77,"features":[]}'

# 1. Matching feature_start span present alongside a full ordered triple.
mk_case span_clean_passes "$FL_PASS" \
  "conductor|feature_start|feat-a|pass" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 2. Full triple (satisfies the UNRELATED teeth-proof rule), but no
#    feature_start span anywhere in the trace.
mk_case span_missing_fails "$FL_PASS" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 3. A feature_start span exists, but for a DIFFERENT feature_id — never
#    satisfies feat-a's obligation.
mk_case wrong_fid_fails "$FL_PASS" \
  "conductor|feature_start|feat-x|pass" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 4. Governed canonical waiver, no feature_start span, no triple (only a
#    green_handback pass span so the UNRELATED unverified_feature_pass rule
#    stays satisfied).
mk_case canonical_waiver_clean "$FL_CANON_WAIVER_OK" \
  "test-subagent|green_handback|feat-a|pass"

# 5. Governed deprecated legacy alias waiver, same shape as case 4.
mk_case legacy_waiver_clean "$FL_LEGACY_WAIVER_OK" \
  "test-subagent|green_handback|feat-a|pass"

# 6. Malformed canonical waiver shadows a valid legacy waiver; a full triple
#    isolates the case to feature_start alone (teeth_proof_missing is
#    already satisfied via the triple, not via any waiver).
mk_case malformed_canonical_shadows_legacy_fails "$FL_BOTH_WAIVERS_TRAP" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"

# 7. Only a passes:false feature exists; no spans at all.
mk_case passes_false_untouched "$FL_ONLY_B"

# 8. No feature_list.json sibling at all — state rules skip entirely.
mk_case no_feature_list_clean "$FL_PASS" \
  "test-subagent|red_handback|feat-a|pass" \
  "implementation-subagent|impl_handback|feat-a|pass" \
  "test-subagent|green_handback|feat-a|pass"
rm -f "$(feature_list_path no_feature_list_clean)"

# 9. feature_list.json present but with an empty features array.
mk_case empty_features_clean "$FL_EMPTY"

# Fixture self-check: every trace line parses (a malformed fixture would make
# findings unattributable).
for c in span_clean_passes span_missing_fails wrong_fid_fails \
         canonical_waiver_clean legacy_waiver_clean \
         malformed_canonical_shadows_legacy_fails passes_false_untouched \
         no_feature_list_clean empty_features_clean; do
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
assert_no_feat_b_start_flag() {
  local case_name="$1"
  assert_absent "$case_name" 'feature_start_missing feat-b'
}

# --- 1. span_clean_passes -> exit 0, no findings ------------------------------
rc="$(run_checker "$(trace_path span_clean_passes)")"
[ "$rc" = "0" ] \
  || fail "span_clean_passes: expected exit 0, got ${rc} (stdout: $(stdout_oneline) stderr: $(stderr_oneline))"
assert_absent span_clean_passes 'VIOLATION consistency: feature_start_missing'
assert_absent span_clean_passes 'VIOLATION consistency: teeth_proof_missing'
assert_no_feat_b_start_flag span_clean_passes

# --- 2. span_missing_fails -> feature_start_missing, teeth_proof unaffected --
rc="$(run_checker "$(trace_path span_missing_fails)")"
[ "$rc" = "1" ] \
  || fail "span_missing_fails: expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present span_missing_fails 'VIOLATION consistency: feature_start_missing feat-a'
assert_absent span_missing_fails 'VIOLATION consistency: teeth_proof_missing'
assert_no_feat_b_start_flag span_missing_fails

# --- 3. wrong_fid_fails -> feature_start_missing (mismatched fid never counts)
rc="$(run_checker "$(trace_path wrong_fid_fails)")"
[ "$rc" = "1" ] \
  || fail "wrong_fid_fails: expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present wrong_fid_fails 'VIOLATION consistency: feature_start_missing feat-a'
assert_absent wrong_fid_fails 'VIOLATION consistency: teeth_proof_missing'
assert_no_feat_b_start_flag wrong_fid_fails

# --- 4. canonical_waiver_clean -> exit 0, waived exactly like teeth-proof ----
rc="$(run_checker "$(trace_path canonical_waiver_clean)")"
[ "$rc" = "0" ] \
  || fail "canonical_waiver_clean: a governed teeth_proof_waiver must waive feature_start too — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent canonical_waiver_clean 'VIOLATION consistency: feature_start_missing'
assert_absent canonical_waiver_clean 'VIOLATION consistency: teeth_proof_missing'
assert_no_feat_b_start_flag canonical_waiver_clean

# --- 5. legacy_waiver_clean -> exit 0, deprecated alias also waives ----------
rc="$(run_checker "$(trace_path legacy_waiver_clean)")"
[ "$rc" = "0" ] \
  || fail "legacy_waiver_clean: a governed deprecated red_first_waiver alias must waive feature_start too — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent legacy_waiver_clean 'VIOLATION consistency: feature_start_missing'
assert_absent legacy_waiver_clean 'VIOLATION consistency: teeth_proof_missing'
assert_no_feat_b_start_flag legacy_waiver_clean

# --- 6. malformed_canonical_shadows_legacy_fails -> feature_start_missing ----
# Precedence is by key presence, so the malformed teeth_proof_waiver shadows
# a valid legacy red_first_waiver; the feature is NOT rescued. The full
# triple keeps teeth_proof_missing satisfied via its own (unrelated) path, so
# this case isolates the assertion to feature_start alone.
rc="$(run_checker "$(trace_path malformed_canonical_shadows_legacy_fails)")"
[ "$rc" = "1" ] \
  || fail "malformed_canonical_shadows_legacy_fails: a malformed teeth_proof_waiver must shadow (not defer to) a valid legacy red_first_waiver — expected exit 1, got ${rc} (stdout: $(stdout_oneline))"
assert_present malformed_canonical_shadows_legacy_fails 'VIOLATION consistency: feature_start_missing feat-a'
assert_absent malformed_canonical_shadows_legacy_fails 'VIOLATION consistency: teeth_proof_missing'
assert_no_feat_b_start_flag malformed_canonical_shadows_legacy_fails

# --- 7. passes_false_untouched -> exit 0, never flagged ----------------------
rc="$(run_checker "$(trace_path passes_false_untouched)")"
[ "$rc" = "0" ] \
  || fail "passes_false_untouched: a passes:false feature must never require feature_start evidence — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent passes_false_untouched 'VIOLATION consistency: feature_start_missing'

# --- 8. no_feature_list_clean -> exit 0, state rules skip entirely ----------
rc="$(run_checker "$(trace_path no_feature_list_clean)")"
[ "$rc" = "0" ] \
  || fail "no_feature_list_clean: without feature_list.json the state rules must skip entirely — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent no_feature_list_clean 'VIOLATION consistency: feature_start_missing'

# --- 9. empty_features_clean -> exit 0, nothing to require -------------------
rc="$(run_checker "$(trace_path empty_features_clean)")"
[ "$rc" = "0" ] \
  || fail "empty_features_clean: an empty features array has nothing to require — expected exit 0, got ${rc} (stdout: $(stdout_oneline))"
assert_absent empty_features_clean 'VIOLATION consistency: feature_start_missing'

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d checker-feature-start-missing contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'checker-feature-start-missing contract honored\n'
