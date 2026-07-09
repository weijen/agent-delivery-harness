#!/usr/bin/env bash
# test_red_first_pr_gate.sh — PR-path regression sensor for the red-first
# evidence gate (issue #144, feature trace-red-first-pr-gate).
#
# WHAT THIS PINS
# The prior feature (trace-red-first-evidence) taught
# scripts/check-trace-consistency.sh to emit
#     VIOLATION consistency: red_first_evidence_missing <fid>
#     VIOLATION consistency: red_first_role_mismatch <fid>
# for any passes:true coded feature that lacks a role-correct, file-ordered
#     test-subagent            red_handback  ->
#     implementation-subagent  impl_handback ->
#     test-subagent            green_handback
# triple (all harness.outcome==pass) and carries no governed red_first_waiver.
#
# This sensor pins the NEXT obligation: the PR path must HARD-BLOCK on that
# specific evidence gap by default, while the broader trace gate
# (validate-trace + other check-trace-consistency findings) stays warn-only.
# Concretely:
#   * `review-gate.sh approve` HARD-FAILS (non-zero) and does NOT write
#     .copilot-tracking/review-gate/approved-head when a passes:true feature
#     lacks red-first evidence and has no valid waiver.
#   * `review-gate.sh check` HARD-FAILS under the same gap, even when the
#     approval marker matches HEAD and docs/PROGRESS.md changed (so approval
#     and status-doc would otherwise pass — the red-first gap is the only
#     variable).
#   * `create-pr.sh` therefore refuses BEFORE calling `gh pr create` (it runs
#     `review-gate.sh check`).
#   * A valid governed red_first_waiver OR a real ordered role-correct triple
#     ALLOWS approve/check (subject to the other existing gate conditions).
#   * An UNRELATED consistency finding (e.g. log_without_span) does NOT block
#     by default — only the red-first obligation blocks.
#
# The sensor asserts PR-path BEHAVIOUR (exit codes + the approved-head marker
# + whether `gh pr create` ran), not the checker internals — those are pinned
# by tests/scripts/test_trace_red_first_evidence.sh.
#
# FIXTURE SHAPE (mirrors tests/scripts/test_trace_gate.sh): a throwaway MAIN
# repo carrying every lifecycle script at its canonical path plus the frozen
# schema contract and docs/PROGRESS.md; a bare `origin` so create-pr can
# fetch/rebase/push and actually reach `gh pr create` when unblocked; a linked
# issue worktree built by the REAL start-issue.sh (SKIP_INIT=1) so the branch
# is feature/issue-NN-* and the main-root trace exists (the gate resolves the
# issue from that branch). The consistency artifact set (progress.md +
# feature_list.json) is planted at the MAIN root issue dir, and agent spans +
# their matching Action Log bullets are written there directly (the
# dirty_gate_fixture approach) so the trace, progress.md, and feature list
# stay mutually consistent and the ONLY attributable finding is red-first.
# PATH is pinned to a hermetic bin (symlinked coreutils/git/jq + a fake gh:
# `pr create` logs its args and exits 0, everything else exits 1).
#
# CASES:
#   1 approve_blocks_missing_red_first  passes:true, no triple, no waiver ->
#       approve exits non-zero AND approved-head is NOT written; output names
#       red-first.
#   2 check_blocks_missing_red_first    same gap, marker==HEAD + docs changed
#       (approval + status-doc satisfied) -> check exits non-zero on red-first.
#   3 create_pr_inherits_block          same gap -> create-pr exits non-zero
#       and the fake `gh pr create` was NOT called (gh.log empty).
#   4 waiver_allows_approve             governed doc-only red_first_waiver, no
#       triple -> approve exits 0 and writes approved-head==HEAD.
#   5 triple_allows_approve             real ordered role-correct triple, no
#       waiver -> approve exits 0 and writes approved-head==HEAD.
#   6 warn_only_unrelated_trace_finding_does_not_block  valid triple PLUS an
#       unrelated log_without_span finding -> approve still exits 0 (only
#       red-first blocks by default).
#
# RED status at authoring time: review-gate.sh runs NO red-first evidence
# check in approve/check, so cases 1/2/3 currently let the PR path proceed —
# those assertions FAIL today. Cases 4/5/6 are guard legs that must hold both
# now and after implementation.
#
# Exit codes: 0 red-first PR-gate contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE \
  REQUIRE_TRACE_CONSISTENCY GH_LOG FORCE DELETE_BRANCH 2>/dev/null || true

# --- Presence gate / prerequisites -------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the gate and this sensor are jq-driven)"
[ -f "$SCHEMA" ] \
  || hard_fail "trace schema contract not found (${SCHEMA})"
for s in review-gate.sh create-pr.sh check-trace-consistency.sh validate-trace.sh \
         trace-lib.sh issue-lib.sh start-issue.sh finish-issue.sh \
         check-feature-list.sh log-handback.sh; do
  [ -f "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found — required by the red-first PR-gate fixture"
  [ -x "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} exists but is not executable (${ROOT}/scripts/${s})"
done

# --- Pinned PATH + fake gh (network-free, login-free) ---------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut \
  grep printf jq date od wc awk sort comm uniq mktemp head tail ls cp mv ln touch \
  uname true false
# Fake gh: `pr create` records its args to $GH_LOG and succeeds; `pr view`
# (and anything else) exits 1 so create-pr treats it as "no PR yet".
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
  exit 0
fi
exit 1
SH
chmod +x "${BIN}/gh"

# --- Fixture builders ----------------------------------------------------------
# make_fixture <dir> <issue>: MAIN repo (lifecycle scripts + schema at
# canonical paths) + a bare origin + a worktree built by the REAL
# start-issue.sh, then a clean main-root consistency artifact set (progress.md
# with an empty Action Log + feat-a passes:false) planted at the main-root
# issue dir. Per-case setup replaces feature_list.json and appends spans.
make_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  local s
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh \
           review-gate.sh create-pr.sh log-handback.sh trace-lib.sh \
           validate-trace.sh check-trace-consistency.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "$SCHEMA" "${dir}/docs/evaluation/trace-schema.v1.json"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add .gitignore README.md docs scripts
  git -C "$dir" commit -q -m initial
  # Bare origin so create-pr's fetch/rebase/push reach `gh pr create` when the
  # red-first gate does NOT block (attributability for case 3's RED).
  git init -q --bare "${dir}.origin.git"
  git -C "$dir" remote add origin "${dir}.origin.git"
  git -C "$dir" push -q origin main
  git -C "$dir" fetch -q origin
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out" >&2; hard_fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}-worktrees/issue-${pad}" ] \
    || hard_fail "setup: worktree for issue ${issue} was not created"
  [ -f "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl" ] \
    || hard_fail "setup: start-issue emitted no main-root trace for issue ${issue}"
  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  printf '{"issue":%s,"features":[{"id":"feat-a","title":"A","passes":false}]}\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

# set_fl <idir> <json>: replace the main-root feature_list.json.
set_fl() { printf '%s\n' "$2" > "${1}/feature_list.json"; }

# add_span <idir> <issue> <role> <step> <fid> <outcome>: append one schema-valid
# agent span to the main-root trace AND its matching Action Log bullet, keeping
# the span/bullet multisets consistent (so only red-first is attributable).
# File append order == trace order == the red-first ordering the checker reads.
add_span() {
  local idir="$1" issue="$2" role="$3" step="$4" fid="$5" outcome="$6"
  printf '{"schema_version":1,"timestamp":"2026-07-06T12:00:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"%s","harness.lifecycle_step":"%s","harness.feature_id":"%s","harness.outcome":"%s"}\n' \
    "$issue" "$role" "$step" "$fid" "$outcome" >> "${idir}/trace.jsonl"
  printf -- '- [%s] %s %s %s — fixture span\n' \
    "$role" "$step" "$fid" "$outcome" >> "${idir}/progress.md"
}

# add_bullet_only <idir> <role> <step> <fid> <outcome>: an Action Log bullet
# with NO matching agent span -> an unrelated log_without_span consistency
# finding (used to prove the gate blocks ONLY on red-first by default).
add_bullet_only() {
  printf -- '- [%s] %s %s %s — hand claim, no span\n' \
    "$2" "$3" "$4" "$5" >> "${1}/progress.md"
}

# commit_docs <worktree> <line>: change docs/PROGRESS.md on the branch and
# commit, so the status-doc gate is satisfied (never the blocker).
commit_docs() {
  printf '\n%s\n' "$2" >> "${1}/docs/PROGRESS.md"
  git -C "$1" add docs/PROGRESS.md
  git -C "$1" commit -q -m "docs update"
}

# set_marker <worktree>: record the current HEAD as review-approved at the
# worktree-local marker path (where review-gate.sh reads it), so approval +
# status-doc pass and the red-first gap is the only variable.
set_marker() {
  local wt="$1" mdir="$1/.copilot-tracking/review-gate"
  mkdir -p "$mdir"
  git -C "$wt" rev-parse HEAD > "${mdir}/approved-head"
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

# feature lists (the checker ignores .issue; feat-b is a false-positive guard).
FL_MISSING='{"issue":1,"features":[{"id":"feat-a","title":"A","passes":true},{"id":"feat-b","title":"B","passes":false}]}'
FL_WAIVER='{"issue":1,"features":[{"id":"feat-a","title":"A","passes":true,"red_first_waiver":{"kind":"doc-only","reason":"docs-only change, no code path touched"}},{"id":"feat-b","title":"B","passes":false}]}'

# ============================================================================
# Case 1: approve_blocks_missing_red_first (issue 70)
# ============================================================================
C1="${TMP_DIR}/c70"; make_fixture "$C1" 70
WT1="${C1}-worktrees/issue-70"; ID1="${C1}/.copilot-tracking/issues/issue-70"
set_fl "$ID1" "$FL_MISSING"
add_span "$ID1" 70 implementation-subagent impl_handback feat-a pass
add_span "$ID1" 70 test-subagent green_handback feat-a pass
commit_docs "$WT1" "issue-70 red-first approve leg"
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" != "0" ] \
  || fail "approve_blocks_missing_red_first: 'review-gate.sh approve' must HARD-FAIL when a passes:true feature lacks red-first evidence and has no waiver, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -f "$(marker_path "$WT1")" ] \
  || fail "approve_blocks_missing_red_first: the approved-head marker must NOT be written when red-first evidence is missing (marker present at $(marker_path "$WT1"))"
grep -Eiq 'red[_-]first' "$OUT" \
  || fail "approve_blocks_missing_red_first: the refusal must name the red-first evidence obligation (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 2: check_blocks_missing_red_first (issue 71)
# ============================================================================
C2="${TMP_DIR}/c71"; make_fixture "$C2" 71
WT2="${C2}-worktrees/issue-71"; ID2="${C2}/.copilot-tracking/issues/issue-71"
set_fl "$ID2" "$FL_MISSING"
add_span "$ID2" 71 implementation-subagent impl_handback feat-a pass
add_span "$ID2" 71 test-subagent green_handback feat-a pass
commit_docs "$WT2" "issue-71 red-first check leg"
set_marker "$WT2"   # approval matches HEAD; status-doc satisfied above
rc="$(run_in "$WT2" "$OUT" -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "check_blocks_missing_red_first: 'review-gate.sh check' must HARD-FAIL on missing red-first evidence even when approval and status-doc pass, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'red[_-]first' "$OUT" \
  || fail "check_blocks_missing_red_first: the check refusal must name the red-first evidence obligation (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 3: create_pr_inherits_block (issue 72)
# ============================================================================
C3="${TMP_DIR}/c72"; make_fixture "$C3" 72
WT3="${C3}-worktrees/issue-72"; ID3="${C3}/.copilot-tracking/issues/issue-72"
set_fl "$ID3" "$FL_MISSING"
add_span "$ID3" 72 implementation-subagent impl_handback feat-a pass
add_span "$ID3" 72 test-subagent green_handback feat-a pass
commit_docs "$WT3" "issue-72 red-first create-pr leg"
set_marker "$WT3"
GH_LOG3="${TMP_DIR}/gh-72.log"; : > "$GH_LOG3"
rc="$(run_in "$WT3" "$OUT" GH_LOG="$GH_LOG3" -- ./scripts/create-pr.sh --title t --body b)"
[ "$rc" != "0" ] \
  || fail "create_pr_inherits_block: 'create-pr.sh' must refuse (non-zero) when review-gate check hard-fails on missing red-first, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -s "$GH_LOG3" ] \
  || fail "create_pr_inherits_block: 'gh pr create' must NOT be called when the red-first gate blocks (gh.log: $(tr '\n' '|' < "$GH_LOG3"))"

# ============================================================================
# Case 4: waiver_allows_approve (issue 73)
# ============================================================================
C4="${TMP_DIR}/c73"; make_fixture "$C4" 73
WT4="${C4}-worktrees/issue-73"; ID4="${C4}/.copilot-tracking/issues/issue-73"
set_fl "$ID4" "$FL_WAIVER"
add_span "$ID4" 73 test-subagent green_handback feat-a pass  # satisfies unverified_feature_pass
commit_docs "$WT4" "issue-73 waiver approve leg"
rc="$(run_in "$WT4" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "waiver_allows_approve: a governed red_first_waiver must ALLOW approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$WT4")" ] \
  || fail "waiver_allows_approve: approve must write the approved-head marker when a valid waiver is present"
if [ -f "$(marker_path "$WT4")" ]; then
  [ "$(tr -d '[:space:]' < "$(marker_path "$WT4")")" = "$(git -C "$WT4" rev-parse HEAD)" ] \
    || fail "waiver_allows_approve: the approved-head marker must equal the current HEAD"
fi

# ============================================================================
# Case 5: triple_allows_approve (issue 74)
# ============================================================================
C5="${TMP_DIR}/c74"; make_fixture "$C5" 74
WT5="${C5}-worktrees/issue-74"; ID5="${C5}/.copilot-tracking/issues/issue-74"
set_fl "$ID5" "$FL_MISSING"   # passes:true, no waiver — evidence comes from the trace
add_span "$ID5" 74 test-subagent red_handback feat-a pass
add_span "$ID5" 74 implementation-subagent impl_handback feat-a pass
add_span "$ID5" 74 test-subagent green_handback feat-a pass
commit_docs "$WT5" "issue-74 triple approve leg"
rc="$(run_in "$WT5" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "triple_allows_approve: a real role-correct ordered red-first triple must ALLOW approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$WT5")" ] \
  || fail "triple_allows_approve: approve must write the approved-head marker when an ordered role-correct triple is present"
if [ -f "$(marker_path "$WT5")" ]; then
  [ "$(tr -d '[:space:]' < "$(marker_path "$WT5")")" = "$(git -C "$WT5" rev-parse HEAD)" ] \
    || fail "triple_allows_approve: the approved-head marker must equal the current HEAD"
fi

# ============================================================================
# Case 6: warn_only_unrelated_trace_finding_does_not_block (issue 75)
# ============================================================================
C6="${TMP_DIR}/c75"; make_fixture "$C6" 75
WT6="${C6}-worktrees/issue-75"; ID6="${C6}/.copilot-tracking/issues/issue-75"
set_fl "$ID6" "$FL_MISSING"   # passes:true feat-a, backed by a real triple below
add_span "$ID6" 75 test-subagent red_handback feat-a pass
add_span "$ID6" 75 implementation-subagent impl_handback feat-a pass
add_span "$ID6" 75 test-subagent green_handback feat-a pass
# An unrelated consistency finding (a hand bullet with no matching span).
add_bullet_only "$ID6" conductor feature_start feat-a pass
commit_docs "$WT6" "issue-75 warn-only guard leg"
rc="$(run_in "$WT6" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "warn_only_unrelated_trace_finding_does_not_block: red-first evidence is present, so an unrelated consistency finding (log_without_span) must NOT block approve by default — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$WT6")" ] \
  || fail "warn_only_unrelated_trace_finding_does_not_block: approve must write the approved-head marker (only red-first blocks by default)"

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d red-first PR-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'red-first PR-gate contract honored\n'
