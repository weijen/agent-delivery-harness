#!/usr/bin/env bash
# test_review_gate_reject_cap.sh — PR-path regression sensor for the
# review-rejection cap hard-block (issue #300, feature review-reject-cap-gate).
#
# WHAT THIS PINS
# scripts/check-trace-consistency.sh already emits (detection half, prior
# feature review-reject-cap-detect):
#     VIOLATION consistency: review_reject_cap_exceeded <fid>
# when a single harness.feature_id accumulates >=3 agent spans with
# harness.lifecycle_step==review_verdict and harness.outcome==fail.
#
# This sensor pins the ENFORCEMENT half: scripts/review-gate.sh must
# HARD-BLOCK BY DEFAULT on that violation — independent of
# REQUIRE_TRACE_CONSISTENCY — exactly like red_first_evidence_gate blocks on
# teeth_proof_missing. Concretely:
#   * `review-gate.sh approve` HARD-FAILS (non-zero) and does NOT write
#     .copilot-tracking/review-gate/approved-head when a feature hit the
#     3-rejection cap; the refusal names the reject cap / stop-and-handback.
#   * `review-gate.sh check` HARD-FAILS under the same finding even when
#     approval + status-doc pass (so the reject cap is the only variable).
#   * With FEWER than 3 rejections for every feature the checker emits no
#     review_reject_cap_exceeded, so the reject-cap leg does NOT block:
#     approve exits 0, writes the marker, and the reject-cap message is ABSENT.
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
# (.copilot-tracking/ is gitignored). feat-a is passes:false so the ONLY
# blocking gate under test is the reject-cap leg (red_first_evidence_gate
# never requires evidence for a passes:false feature). PATH is pinned to a
# hermetic bin of symlinked coreutils/git/jq.
#
# CASES:
#   1 approve_blocks_reject_cap   3 review_verdict/fail spans for feat-a ->
#       approve exits non-zero, approved-head NOT written, output names the
#       reject cap + stop-and-handback. No REQUIRE_TRACE_CONSISTENCY.
#   2 check_blocks_reject_cap     same 3-rejection trace, marker==HEAD + docs
#       changed (approval + status-doc satisfied) -> check exits non-zero on
#       the reject cap. No REQUIRE_TRACE_CONSISTENCY.
#   3 no_block_below_cap          2 review_verdict/fail spans for feat-a ->
#       reject-cap absent -> approve exits 0, writes approved-head==HEAD, and
#       the reject-cap message is ABSENT.
#
# RED status at authoring time: review-gate.sh has no review_reject_cap_gate,
# so cases 1 and 2 currently let the PR path proceed (approve exits 0 / check
# passes) when review_reject_cap_exceeded is emitted — those assertions FAIL
# today. Case 3 is a guard leg that must hold both now and after the gate lands.
#
# Exit codes: 0 reject-cap PR-gate contract honored · 1 a contract obligation regressed.

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
  REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE 2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (check-trace-consistency and this sensor are jq-driven)"
for s in review-gate.sh check-trace-consistency.sh validate-trace.sh \
         trace-lib.sh issue-lib.sh; do
  [ -x "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found or not executable — required by the reject-cap PR-gate fixture"
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
# and a feat-a passes:false feature list. Per-case setup appends spans/bullets.
make_repo() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts" "${dir}/docs"
  local s
  for s in review-gate.sh check-trace-consistency.sh validate-trace.sh \
           trace-lib.sh issue-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
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
  printf '{"issue":%s,"features":[{"id":"feat-a","title":"A","passes":false}]}\n' "$issue" \
    > "${idir}/feature_list.json"
}

# add_reject <idir> <issue> <fid>: append one schema-shaped review_verdict/fail
# agent span to the main-root trace AND its matching Action Log bullet, so the
# span/bullet multisets stay consistent and the reject cap is the only signal.
add_reject() {
  local idir="$1" issue="$2" fid="$3"
  printf '{"schema_version":1,"timestamp":"2026-07-18T12:00:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"fail"}\n' \
    "$issue" "$fid" >> "${idir}/trace.jsonl"
  printf -- '- [code-review-subagent] review_verdict %s fail — fixture rejection\n' \
    "$fid" >> "${idir}/progress.md"
}

# set_marker <dir>: record the current HEAD as review-approved at the main-root
# marker path (single repo, so main root == repo toplevel), so approval +
# status-doc pass on the check path and the reject cap is the only variable.
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
# Case 1: approve_blocks_reject_cap (issue 30)
# ============================================================================
C1="${TMP_DIR}/c30"; make_repo "$C1" 30
ID1="${C1}/.copilot-tracking/issues/issue-30"
add_reject "$ID1" 30 feat-a
add_reject "$ID1" 30 feat-a
add_reject "$ID1" 30 feat-a
rc="$(run_in "$C1" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" != "0" ] \
  || fail "approve_blocks_reject_cap: 'review-gate.sh approve' must HARD-FAIL when a feature hit the 3-rejection cap, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -f "$(marker_path "$C1")" ] \
  || fail "approve_blocks_reject_cap: the approved-head marker must NOT be written when the reject cap is exceeded (marker present at $(marker_path "$C1"))"
grep -Eiq 'reject' "$OUT" \
  || fail "approve_blocks_reject_cap: the refusal must name the review-rejection cap (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'stop|hand[ -]?back|human' "$OUT" \
  || fail "approve_blocks_reject_cap: the refusal must state the issue STOPS and hands back to the human (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 2: check_blocks_reject_cap (issue 31)
# ============================================================================
C2="${TMP_DIR}/c31"; make_repo "$C2" 31
ID2="${C2}/.copilot-tracking/issues/issue-31"
add_reject "$ID2" 31 feat-a
add_reject "$ID2" 31 feat-a
add_reject "$ID2" 31 feat-a
set_marker "$C2"   # approval matches HEAD; status-doc satisfied by make_repo
rc="$(run_in "$C2" "$OUT" SKIP_CI_GATE=1 -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "check_blocks_reject_cap: 'review-gate.sh check' must HARD-FAIL on the reject cap even when approval and status-doc pass, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'reject' "$OUT" \
  || fail "check_blocks_reject_cap: the check refusal must name the review-rejection cap (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 3: no_block_below_cap (issue 32)
# ============================================================================
C3="${TMP_DIR}/c32"; make_repo "$C3" 32
ID3="${C3}/.copilot-tracking/issues/issue-32"
add_reject "$ID3" 32 feat-a
add_reject "$ID3" 32 feat-a
rc="$(run_in "$C3" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "no_block_below_cap: with only 2 rejections the reject-cap leg must NOT block approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$C3")" ] \
  || fail "no_block_below_cap: approve must write the approved-head marker when the reject cap is not exceeded"
if [ -f "$(marker_path "$C3")" ]; then
  [ "$(tr -d '[:space:]' < "$(marker_path "$C3")")" = "$(git -C "$C3" rev-parse HEAD)" ] \
    || fail "no_block_below_cap: the approved-head marker must equal the current HEAD"
fi
if grep -Eiq 'reject.{0,20}cap|rejection cap' "$OUT"; then
  fail "no_block_below_cap: the reject-cap refusal message must be ABSENT below the cap (output: $(tr '\n' '|' < "$OUT"))"
fi

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d reject-cap PR-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'reject-cap PR-gate contract honored\n'
