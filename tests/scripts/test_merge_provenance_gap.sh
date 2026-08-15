#!/usr/bin/env bash
# test_merge_provenance_gap.sh — regression sensor for the warn-only
# merge-provenance reconciliation rule (issue #460) in
# scripts/check-trace-consistency.sh.
#
# The rule reconciles first-parent main history after the committed baseline
# (config/harness/merge-audit-base) against pr_merge pass spans and deviation
# spans across ALL issue traces. It is warn-only by construction (#448
# posture): out-of-band merges surface as counted warnings; a retroactive
# deviation span naming >= 12 chars of the SHA clears the warning; a missing
# baseline leaves the rule inert.
#
# Legs (one mutable fixture repo, mutations on copies of the baseline file
# and trace only):
#   A  scripted merge      — the commit named by a pr_merge pass span's
#                            harness.merge_sha produces NO warning
#   B  out-of-band merge   — an unreferenced main commit produces exactly one
#                            WARNING consistency: merge_provenance_gap <sha>
#   C  deviation-covered   — a commit whose 12-char SHA prefix appears in a
#                            deviation span's summary produces NO warning
#   D  counted + non-fatal — the gap warning appears in the tally and the
#                            checker still exits 0 (no violations)
#   E  retroactive clear   — appending a deviation span naming leg-B's SHA
#                            prefix removes the warning
#   F  no baseline         — removing merge-audit-base leaves the rule inert
#   G  invalid baseline    — a non-SHA baseline yields
#                            WARNING consistency: merge_audit_base_invalid
#
# Exit: 0 all legs pass · 1 any obligation missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Fixture repository with a linear main history ---------------------------
FIX="${TMP_DIR}/fixture"
mkdir -p "$FIX"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.email sensor@example.invalid
git -C "$FIX" config user.name "Merge Provenance Sensor"

fix_commit() {
  printf '%s\n' "$1" > "${FIX}/file.txt"
  git -C "$FIX" add file.txt
  git -C "$FIX" commit -q -m "$1"
  git -C "$FIX" rev-parse HEAD
}

SHA_BASE="$(fix_commit baseline)"
SHA_TRACED="$(fix_commit traced-merge)"
SHA_GAP="$(fix_commit out-of-band-merge)"
SHA_DEVIATION="$(fix_commit deviation-covered-merge)"

mkdir -p "${FIX}/config/harness"
printf '%s\n' "$SHA_BASE" > "${FIX}/config/harness/merge-audit-base"

ISSUE_DIR="${FIX}/.copilot-tracking/issues/issue-01"
mkdir -p "$ISSUE_DIR"
printf '# progress\n' > "${ISSUE_DIR}/progress.md"
TRACE="${ISSUE_DIR}/trace.jsonl"
{
  printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-08-15T10:00:00Z\",\"span\":\"lifecycle\",\"harness.issue\":1,\"harness.version\":\"0.0.0-test\",\"span_id\":\"aaaaaaaaaaaaaaaa\",\"harness.commit\":\"abc1234\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"pass\",\"harness.exit_status\":0,\"harness.duration_ms\":10,\"harness.pr_number\":\"1\",\"harness.merge_sha\":\"${SHA_TRACED}\",\"harness.merge_state\":\"MERGED\"}"
  printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-08-15T10:01:00Z\",\"span\":\"agent\",\"harness.issue\":1,\"harness.version\":\"0.0.0-test\",\"span_id\":\"bbbbbbbbbbbbbbbb\",\"harness.commit\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"conductor\",\"harness.lifecycle_step\":\"deviation\",\"harness.feature_id\":\"emergency-merge\",\"harness.outcome\":\"pass\",\"harness.summary\":\"emergency admin merge ${SHA_DEVIATION:0:12} - CI bootstrap deadlock, recorded before merging\"}"
} > "$TRACE"

run_checker() {
  # Fills CHECKER_OUT / CHECKER_RC in the parent shell (no subshell capture)
  # without tripping set -e.
  CHECKER_RC=0
  CHECKER_OUT="$("$CHECKER" "$TRACE" 2>&1)" || CHECKER_RC=$?
}

# --- Legs A/B/C/D on the primary fixture -------------------------------------
run_checker
out="$CHECKER_OUT"

gap_lines="$(grep -c 'WARNING consistency: merge_provenance_gap' <<<"$out" || true)"
[ "$gap_lines" = "1" ] \
  || fail "A/B: expected exactly one merge_provenance_gap warning, got ${gap_lines}: $(grep 'merge_provenance_gap' <<<"$out" | tr '\n' ' ')"
grep -q "WARNING consistency: merge_provenance_gap ${SHA_GAP}" <<<"$out" \
  || fail "B: the out-of-band commit ${SHA_GAP} must be named in the warning"
grep -q "merge_provenance_gap ${SHA_TRACED}" <<<"$out" \
  && fail "A: the pr_merge-referenced commit must not warn"
grep -q "merge_provenance_gap ${SHA_DEVIATION}" <<<"$out" \
  && fail "C: the deviation-covered commit must not warn"
grep -Eq '[1-9][0-9]* warning' <<<"$out" \
  || fail "D: the gap must be counted in the report tally"
grep -q ' 0 violation(s)' <<<"$out" \
  || fail "D: fixture must stay violation-free so the warn-only claim is provable"
[ "$CHECKER_RC" = "0" ] \
  || fail "D: warn-only rule must not fail the checker (exit ${CHECKER_RC})"

# --- Leg E: retroactive deviation span clears the warning ---------------------
cp "$TRACE" "${TMP_DIR}/trace.pre-retroactive"
printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-08-15T11:00:00Z\",\"span\":\"agent\",\"harness.issue\":1,\"harness.version\":\"0.0.0-test\",\"span_id\":\"cccccccccccccccc\",\"harness.commit\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"conductor\",\"harness.lifecycle_step\":\"deviation\",\"harness.feature_id\":\"emergency-merge\",\"harness.outcome\":\"pass\",\"harness.summary\":\"retroactive record for out-of-band merge ${SHA_GAP:0:12}\"}" >> "$TRACE"
run_checker
out="$CHECKER_OUT"
grep -q 'merge_provenance_gap' <<<"$out" \
  && fail "E: retroactive deviation span must clear the gap warning"
[ "$CHECKER_RC" = "0" ] || fail "E: checker must stay green (exit ${CHECKER_RC})"
cp "${TMP_DIR}/trace.pre-retroactive" "$TRACE"

# --- Leg F: no baseline file -> rule inert ------------------------------------
mv "${FIX}/config/harness/merge-audit-base" "${TMP_DIR}/merge-audit-base.keep"
run_checker
out="$CHECKER_OUT"
grep -q 'merge_provenance_gap\|merge_audit_base_invalid' <<<"$out" \
  && fail "F: without a baseline the rule must stay inert"
mv "${TMP_DIR}/merge-audit-base.keep" "${FIX}/config/harness/merge-audit-base"

# --- Leg G: invalid baseline -> flagged, no gap walk --------------------------
printf 'not-a-sha\n' > "${FIX}/config/harness/merge-audit-base"
run_checker
out="$CHECKER_OUT"
grep -q 'WARNING consistency: merge_audit_base_invalid' <<<"$out" \
  || fail "G: an invalid baseline must be flagged"
grep -q 'merge_provenance_gap' <<<"$out" \
  && fail "G: an invalid baseline must not produce gap warnings"
printf '%s\n' "$SHA_BASE" > "${FIX}/config/harness/merge-audit-base"

if [ "$fails" -ne 0 ]; then
  printf '\n%d merge-provenance obligation(s) failed.\n' "$fails" >&2
  exit 1
fi
printf 'merge-provenance reconciliation honored (scripted silent, gap warned, deviation cleared, opt-in respected)\n'
