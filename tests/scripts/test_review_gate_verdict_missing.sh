#!/usr/bin/env bash
# test_review_gate_verdict_missing.sh — PR-path regression sensor for the
# per-feature review-verdict hard-block (issue #303, feature verdict-missing-gate).
#
# WHAT THIS PINS
# scripts/check-trace-consistency.sh already emits (detection half, prior
# feature verdict-missing-detection):
#     VIOLATION consistency: review_verdict_missing <fid>
# for each passes:true feature that has NO review_verdict agent span, but ONLY
# once the review/approve phase is active (a review_gate_approve span is present
# OR REVIEW_GATE_APPROVE_PHASE=1 is set).
#
# This sensor pins the ENFORCEMENT half: scripts/review-gate.sh must
# HARD-BLOCK BY DEFAULT on that violation — independent of
# REQUIRE_TRACE_CONSISTENCY — exactly like review_reject_cap_gate blocks on
# review_reject_cap_exceeded. The gate must run check-trace-consistency.sh with
# REVIEW_GATE_APPROVE_PHASE=1 exported for that invocation, so the phase is
# active at approve time even though the review_gate_approve span is not written
# until AFTER the gate passes. Concretely:
#   * `review-gate.sh approve` HARD-FAILS (non-zero) and does NOT write
#     .copilot-tracking/review-gate/approved-head when a passes:true feature
#     lacks a review_verdict span; the refusal names the missing per-feature
#     verdict.
#   * `review-gate.sh check` HARD-FAILS under the same finding even when
#     approval + status-doc pass (so the missing verdict is the only variable).
#   * WITH a review_verdict span for that feature the checker emits no
#     review_verdict_missing, so the verdict leg does NOT block: approve exits
#     0, writes the marker, and the verdict message is ABSENT.
#   * When the checker cannot run (no trace -> exit 2), the gate degrades
#     gracefully (returns 0), so approve still exits 0 and writes the marker.
#
# The block is asserted WITHOUT REQUIRE_TRACE_CONSISTENCY=1 to prove the
# block-by-default contract (the warn-only trace gate is governed by that flag;
# this gate is not).
#
# FIXTURE SHAPE (single throwaway git repo, no origin/worktree needed): a repo
# carrying review-gate.sh + its dependencies at their canonical scripts/ path
# plus docs/PROGRESS.md; a local `main` baseline so status_doc_gate has a diff
# base; a feature/issue-NN-* branch so the gate resolves the issue from the
# branch (no TRACE_ISSUE export). The consistency artifact set (trace.jsonl +
# progress.md + feature_list.json) is planted at the main-root issue dir
# (.copilot-tracking/ is gitignored). feat-a is passes:true WITH a governed
# teeth_proof_waiver so the sibling red_first_evidence_gate (teeth_proof_missing
# / feature_start_missing) is already satisfied and the ONLY blocking gate under
# test is the verdict leg. PATH is pinned to a hermetic bin of symlinked
# coreutils/git/jq.
#
# CASES:
#   1 approve_blocks_verdict_missing  passes:true feat-a, no review_verdict span
#       -> approve exits non-zero, approved-head NOT written, output names the
#       missing per-feature verdict. No REQUIRE_TRACE_CONSISTENCY.
#   2 check_blocks_verdict_missing    same fixture, marker==HEAD + docs changed
#       (approval + status-doc satisfied) -> check exits non-zero on the missing
#       verdict. No REQUIRE_TRACE_CONSISTENCY.
#   3 no_block_with_verdict           same fixture PLUS a review_verdict span for
#       feat-a -> review_verdict_missing absent -> approve exits 0, writes
#       approved-head==HEAD, and the verdict-missing message is ABSENT.
#   4 graceful_skip_no_trace          passes:true feat-a but NO trace.jsonl ->
#       check-trace-consistency exits 2 -> the gate degrades to a skip (returns
#       0) -> approve exits 0 and writes the marker (gate does not break).
#
# RED status at authoring time: review-gate.sh has no review_verdict_gate, so
# cases 1 and 2 currently let the PR path proceed (approve exits 0 / check
# passes) when review_verdict_missing is emitted — those assertions FAIL today.
# Cases 3 and 4 are guard legs that must hold both now and after the gate lands.
#
# Exit codes: 0 verdict PR-gate contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_TRACE_CONSISTENCY \
  REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE REVIEW_GATE_APPROVE_PHASE \
  2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (check-trace-consistency and this sensor are jq-driven)"
for s in review-gate.sh check-trace-consistency.sh \
         trace-lib.sh issue-lib.sh; do
  [ -x "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found or not executable — required by the verdict PR-gate fixture"
done

# --- Pinned PATH --------------------------------------------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    if [ -n "$p" ]; then
      ln -sf "$p" "${dir}/${t}"
    fi
  done
}
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut \
  grep printf jq date od wc awk sort comm uniq mktemp head tail ls cp mv ln touch \
  uname true false

# --- Fixture builder ----------------------------------------------------------
# make_repo <dir> <issue>: a single git repo carrying review-gate.sh + deps at
# scripts/, a `main` baseline, then a feature/issue-NN-* branch with a
# docs/PROGRESS.md change committed (so status_doc_gate is satisfied on the
# check path). Plants a main-root issue dir with an empty Action Log progress.md
# and a feat-a passes:true feature list carrying a governed teeth_proof_waiver
# (so red_first_evidence_gate is satisfied and the verdict leg is the only
# blocking gate). Per-case setup appends spans/bullets and/or a trace file.
make_repo() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  local s
  for s in review-gate.sh check-trace-consistency.sh \
           trace-lib.sh issue-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add .gitignore README.md docs scripts
  git -C "$dir" commit -q -m initial
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$issue" > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs/PROGRESS.md
  git -C "$dir" commit -q -m "issue-${issue}: progress update"
  local idir="${dir}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$idir"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${idir}/progress.md"
  # feat-a passes:true with a governed teeth_proof_waiver: teeth_proof_missing
  # and feature_start_missing are pre-satisfied, so red_first_evidence_gate
  # passes and the verdict leg is the only blocking gate under test.
  jq -nc --argjson issue "$issue" '
    {issue: $issue,
     features: [{
       id: "feat-a", title: "A", passes: true,
       teeth_proof_waiver: {kind: "justified",
         reason: "fixture waiver so red-first passes and the verdict gate is the only variable"}
     }]}' > "${idir}/feature_list.json"
}

# add_green <idir> <issue> <fid>: append one schema-shaped green_handback agent
# span (clears unverified_feature_pass so review_verdict_missing is the sole
# feature-scoped VIOLATION) plus its matching Action Log bullet.
add_green() {
  local idir="$1" issue="$2" fid="$3"
  printf '{"schema_version":1,"timestamp":"2026-07-18T12:00:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"%s","harness.outcome":"pass"}\n' \
    "$issue" "$fid" >> "${idir}/trace.jsonl"
  printf -- '- [generator-subagent] green_handback %s pass — fixture green\n' \
    "$fid" >> "${idir}/progress.md"
}

# add_verdict <idir> <issue> <fid>: append one schema-shaped review_verdict/pass
# agent span (the per-feature verdict) plus its matching Action Log bullet, so
# review_verdict_missing is NOT emitted for <fid>.
add_verdict() {
  local idir="$1" issue="$2" fid="$3"
  printf '{"schema_version":1,"timestamp":"2026-07-18T12:05:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"pass"}\n' \
    "$issue" "$fid" >> "${idir}/trace.jsonl"
  printf -- '- [code-review-subagent] review_verdict %s pass — fixture verdict\n' \
    "$fid" >> "${idir}/progress.md"
}

# set_marker <dir>: record the current HEAD as review-approved at the main-root
# marker path (single repo, so main root == repo toplevel), so approval +
# status-doc pass on the check path and the missing verdict is the only variable.
set_marker() {
  local dir="$1" mdir="$1/.copilot-tracking/review-gate"
  mkdir -p "$mdir"
  git -C "$dir" rev-parse HEAD > "${mdir}/approved-head"
}

marker_path() { printf '%s' "${1}/.copilot-tracking/review-gate/approved-head"; }

run_in() { # run_in <dir> <out> <env...> -- <cmd...>
  local dir="$1" out="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local rc=0
  (cd "$dir" && env PATH="$BIN" ${envs[@]+"${envs[@]}"} "$@") > "$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

OUT="${TMP_DIR}/out.txt"

# ============================================================================
# Case 1: approve_blocks_verdict_missing (issue 40)
# ============================================================================
C1="${TMP_DIR}/c40"; make_repo "$C1" 40
ID1="${C1}/.copilot-tracking/issues/issue-40"
add_green "$ID1" 40 feat-a
rc="$(run_in "$C1" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" != "0" ] \
  || fail "approve_blocks_verdict_missing: 'review-gate.sh approve' must HARD-FAIL when a passes:true feature lacks a review_verdict span, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -f "$(marker_path "$C1")" ] \
  || fail "approve_blocks_verdict_missing: the approved-head marker must NOT be written when a per-feature verdict is missing (marker present at $(marker_path "$C1"))"
grep -Eiq 'verdict' "$OUT" \
  || fail "approve_blocks_verdict_missing: the refusal must name the missing per-feature review verdict (output: $(tr '\n' '|' < "$OUT"))"
grep -Eq 'feat-a' "$OUT" \
  || fail "approve_blocks_verdict_missing: the refusal must name the feature (feat-a) whose verdict is missing (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 2: check_blocks_verdict_missing (issue 41)
# ============================================================================
C2="${TMP_DIR}/c41"; make_repo "$C2" 41
ID2="${C2}/.copilot-tracking/issues/issue-41"
add_green "$ID2" 41 feat-a
set_marker "$C2"   # approval matches HEAD; status-doc satisfied by make_repo
rc="$(run_in "$C2" "$OUT" SKIP_CI_GATE=1 -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "check_blocks_verdict_missing: 'review-gate.sh check' must HARD-FAIL on the missing verdict even when approval and status-doc pass, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'verdict' "$OUT" \
  || fail "check_blocks_verdict_missing: the check refusal must name the missing per-feature review verdict (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 3: no_block_with_verdict (issue 42)
# ============================================================================
C3="${TMP_DIR}/c42"; make_repo "$C3" 42
ID3="${C3}/.copilot-tracking/issues/issue-42"
add_green "$ID3" 42 feat-a
add_verdict "$ID3" 42 feat-a
rc="$(run_in "$C3" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "no_block_with_verdict: with a review_verdict span present the verdict leg must NOT block approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$C3")" ] \
  || fail "no_block_with_verdict: approve must write the approved-head marker when the per-feature verdict is present"
if [ -f "$(marker_path "$C3")" ]; then
  [ "$(head -n1 "$(marker_path "$C3")" | tr -d '[:space:]')" = "$(git -C "$C3" rev-parse HEAD)" ] \
    || fail "no_block_with_verdict: the approved-head marker must equal the current HEAD"
fi
if grep -Eiq 'review_verdict_missing|missing.{0,20}verdict|verdict.{0,20}missing' "$OUT"; then
  fail "no_block_with_verdict: the verdict-missing refusal message must be ABSENT when the verdict is present (output: $(tr '\n' '|' < "$OUT"))"
fi

# ============================================================================
# Case 4: graceful_skip_no_trace (issue 43)
# ============================================================================
# feat-a is passes:true but NO trace.jsonl is planted, so
# check-trace-consistency exits 2 (checker could not run). The verdict gate
# must degrade to a skip (return 0) rather than break the gate, so approve
# still proceeds and writes the marker.
C4="${TMP_DIR}/c43"; make_repo "$C4" 43
rc="$(run_in "$C4" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "graceful_skip_no_trace: with no trace the verdict gate must degrade to a skip (return 0), not break approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$C4")" ] \
  || fail "graceful_skip_no_trace: approve must write the approved-head marker when the verdict gate skips gracefully"

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d verdict PR-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'verdict PR-gate contract honored\n'
