#!/usr/bin/env bash
# test_trace_consistency_state.sh — regression sensor for the cross-state
# consistency rules (issue #103, feature trace-consistency-state, plan
# Phase 3) of `scripts/check-trace-consistency.sh <issue-number|trace-path>`
# (report-only, exit 0 no findings · 1 findings · 2 usage/environment error;
# CLI + core rules pinned by tests/scripts/test_trace_consistency_core.sh).
#
# Artifact resolution in path mode, pinned here: progress.md and
# feature_list.json are SIBLINGS of the named trace.jsonl; when the trace
# lives at a contract-shaped path <root>/.copilot-tracking/issues/issue-NN/
# trace.jsonl, the review-gate marker is
# <root>/.copilot-tracking/review-gate/approved-head. All fixtures here are
# PLAIN directories — deliberately NOT git repos — which mechanically pins
# the marker-only stance of review_sha_mismatch (plan Open Question 2,
# resolved marker-only): the checker may not shell out to `git rev-parse
# HEAD` (there is no repo) nor the network, and must still work.
#
# Rules pinned (finding formats frozen; findings echo enum values,
# feature ids, SHAs, and PR numbers only — never free text; plan decision 6):
#
#   unverified_feature_pass — every passes:true entry in feature_list.json
#     must be backed by an agent span with
#     harness.lifecycle_step=="green_handback", matching harness.feature_id,
#     and harness.outcome=="pass" (completion without evidence otherwise).
#         VIOLATION consistency: unverified_feature_pass <feature_id>
#
#   review_sha_mismatch — the review_gate_approve span's
#     harness.review_gate_sha must equal the content of the approved-head
#     marker file. MARKER-ONLY: no live-HEAD leg, no gh/network.
#         VIOLATION consistency: review_sha_mismatch
#
#   pr_mismatch — scan-and-skip (plan Open Question 1, option (a) pinned):
#     when progress.md carries a GitHub PR reference (…/pull/<N>) AND the
#     trace carries a pr_create span with harness.pr_number, the numbers
#     must agree:
#         VIOLATION consistency: pr_mismatch
#     When progress.md has NO mechanical PR reference the check is SKIPPED
#     with a NOTE naming the rule (never a violation, exit unaffected):
#         NOTE: pr_mismatch check skipped (no PR reference in progress.md)
#     is pinned loosely as: a line matching ^NOTE:.*pr_mismatch.
#
# Legs:
#   S1 complete consistent fixture (verified passes:true, matching SHA,
#      matching PR, core-consistent Action Log) -> exit 0, zero VIOLATIONs.
#   S2 passes:true feature with NO green_handback span -> exit 1 + pinned
#      unverified_feature_pass naming THAT feature id only (the span-backed
#      feature stays clean — false-positive guard).
#   S3 review_gate_approve SHA != approved-head content -> exit 1 + pinned
#      review_sha_mismatch. (S1 is the equal->clean side.)
#   S4 progress.md PR number != pr_create span harness.pr_number -> exit 1 +
#      pinned pr_mismatch. (S1 is the match->clean side.)
#   S5 progress.md with NO PR reference -> NOTE naming pr_mismatch, no
#      pr_mismatch VIOLATION, exit 0 (everything else consistent).
#
# Every mutated fixture stays CORE-consistent (agent spans paired with
# Action Log bullets, in-enum roles) so state findings are attributable to
# the state rules alone and clean legs can assert exit 0.
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not
# exist — every leg fails at the presence gate.
#
# Exit codes: 0 state-rules contract honored · 1 a contract obligation regressed.

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

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -f "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the consistency checker for feature trace-consistency-state (issue #103 Phase 3) is not implemented yet"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"

# --- Fixture builder --------------------------------------------------------------
# Contract-shaped PLAIN directory (no git): <case>/.copilot-tracking/
#   issues/issue-77/{trace.jsonl,progress.md,feature_list.json}
#   review-gate/approved-head
APPROVED_SHA="1111111111111111111111111111111111111111"
OTHER_SHA="2222222222222222222222222222222222222222"

# mk_state_case <name> <feature_list_passes_b> <marker_sha> <pr_in_progress>
#   feature_list_passes_b: true|false — passes flag for feat-b (feat-a is
#     always passes:true and always span-backed)
#   pr_in_progress: match|mismatch|absent
mk_state_case() {
  local name="$1" passes_b="$2" marker_sha="$3" pr_mode="$4"
  local dir="${TMP_DIR}/${name}/.copilot-tracking"
  mkdir -p "${dir}/issues/issue-77" "${dir}/review-gate"
  printf '%s\n' "$marker_sha" > "${dir}/review-gate/approved-head"

  cat > "${dir}/issues/issue-77/feature_list.json" <<JSON
{
  "issue": 77,
  "features": [
    { "id": "feat-a", "title": "backed feature", "passes": true },
    { "id": "feat-b", "title": "maybe-unbacked feature", "passes": ${passes_b} }
  ]
}
JSON

  # Trace: green_handback agent span for feat-a (evidence), the approve span
  # (SHA always the APPROVED one — mismatch is induced via the MARKER so the
  # span side stays constant), and the pr_create span with pr_number 123.
  cat > "${dir}/issues/issue-77/trace.jsonl" <<TRACE
{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"agent","harness.issue":77,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"feat-a","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"lifecycle","harness.issue":77,"harness.version":"abc1234","harness.lifecycle_step":"review_gate_approve","harness.review_gate_sha":"${APPROVED_SHA}"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:02Z","span":"lifecycle","harness.issue":77,"harness.version":"abc1234","harness.lifecycle_step":"pr_create","harness.outcome":"pass","harness.pr_number":"123"}
TRACE

  # progress.md: core-consistent Action Log bullet for the agent span, plus
  # the PR reference per mode.
  {
    printf '# Issue 77 progress\n\nStatus: closing out.\n\n'
    case "$pr_mode" in
      match)    printf 'PR: https://github.com/acme/widgets/pull/123\n\n' ;;
      mismatch) printf 'PR: https://github.com/acme/widgets/pull/999\n\n' ;;
      absent)   : ;;
      *) hard_fail "mk_state_case: unknown pr_mode '${pr_mode}' — sensor bug" ;;
    esac
    printf '## Action Log\n\n'
    printf -- '- [test-subagent] green_handback feat-a pass — verified feat-a GREEN\n'
  } > "${dir}/issues/issue-77/progress.md"
}

trace_path() {
  printf '%s' "${TMP_DIR}/$1/.copilot-tracking/issues/issue-77/trace.jsonl"
}

mk_state_case s1 false "$APPROVED_SHA" match
mk_state_case s2 true  "$APPROVED_SHA" match
mk_state_case s3 false "$OTHER_SHA"    match
mk_state_case s4 false "$APPROVED_SHA" mismatch
mk_state_case s5 false "$APPROVED_SHA" absent

# Fixture self-check: every trace line parses (a malformed fixture would
# make findings unattributable).
for c in s1 s2 s3 s4 s5; do
  jq empty "$(trace_path "$c")" >/dev/null 2>&1 \
    || hard_fail "fixture ${c}: trace.jsonl does not parse — sensor bug"
done

# --- Checker run helper ------------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- S1. Complete consistent fixture -> exit 0, zero VIOLATIONs --------------------
rc="$(run_checker "$(trace_path s1)")"
[ "$rc" = "0" ] \
  || fail "S1 complete fixture: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -q '^VIOLATION ' "$OUT"; then
  fail "S1 complete fixture: zero VIOLATION findings expected (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- S2. passes:true with no green_handback span -> unverified_feature_pass --------
rc="$(run_checker "$(trace_path s2)")"
[ "$rc" = "1" ] \
  || fail "S2 unverified pass: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: unverified_feature_pass feat-b' "$OUT" \
  || fail "S2 unverified pass: pinned finding 'VIOLATION consistency: unverified_feature_pass feat-b' missing (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -Fq 'unverified_feature_pass feat-a' "$OUT"; then
  fail "S2 unverified pass: feat-a IS span-backed and must not be flagged — false positive (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- S3. approve span SHA != approved-head marker -> review_sha_mismatch -----------
rc="$(run_checker "$(trace_path s3)")"
[ "$rc" = "1" ] \
  || fail "S3 sha mismatch: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: review_sha_mismatch' "$OUT" \
  || fail "S3 sha mismatch: pinned finding 'VIOLATION consistency: review_sha_mismatch' missing (stdout: $(tr '\n' '|' < "$OUT"))"

# --- S4. progress PR number != pr_create span pr_number -> pr_mismatch -------------
rc="$(run_checker "$(trace_path s4)")"
[ "$rc" = "1" ] \
  || fail "S4 pr mismatch: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: pr_mismatch' "$OUT" \
  || fail "S4 pr mismatch: pinned finding 'VIOLATION consistency: pr_mismatch' missing (stdout: $(tr '\n' '|' < "$OUT"))"

# --- S5. No PR reference in progress.md -> NOTE skip, never a violation ------------
rc="$(run_checker "$(trace_path s5)")"
[ "$rc" = "0" ] \
  || fail "S5 absent PR: expected exit 0 (skip is not a finding), got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Eq '^NOTE:.*pr_mismatch' "$OUT" \
  || fail "S5 absent PR: a NOTE line naming pr_mismatch is required (scan-and-skip pinned; stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION consistency: pr_mismatch' "$OUT"; then
  fail "S5 absent PR: skip must NEVER be reported as a pr_mismatch violation (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-consistency-state contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-consistency-state contract honored\n'
