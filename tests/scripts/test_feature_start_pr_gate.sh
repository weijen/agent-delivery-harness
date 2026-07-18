#!/usr/bin/env bash
# test_feature_start_pr_gate.sh — PR-path regression sensor for the
# completed-feature selection-evidence gate (issue #291, feature
# gate-blocks-feature-start-missing).
#
# WHAT THIS PINS
# scripts/check-trace-consistency.sh emits, for any passes:true feature that
# lacks a matching per-feature selection span:
#     VIOLATION consistency: feature_start_missing <fid>
# (tests/scripts/test_trace_feature_start_evidence.sh pins the checker rule
# itself: presence-only, no role/order check, waivable by the same governed
# teeth_proof_waiver / deprecated red_first_waiver alias as teeth_proof_missing,
# with key-presence precedence — a malformed canonical key shadows a valid
# legacy one.)
#
# This sensor pins the PR-path obligation raised by issue #291: the existing
# red_first_evidence_gate() in scripts/review-gate.sh (issue #144) hard-blocks
# by default on teeth_proof_missing, but — at authoring time — greps ONLY that
# token, so a feature_start_missing finding is silently ignored and the PR
# path proceeds. This gate must be widened to hard-block on BOTH tokens.
# Concretely:
#   * `review-gate.sh approve` HARD-FAILS (non-zero) and does NOT write
#     .copilot-tracking/review-gate/approved-head when a passes:true feature
#     has a complete red/impl/green triple (so teeth_proof_missing is already
#     satisfied via that unrelated path) but NO matching feature_start span.
#   * `review-gate.sh check` HARD-FAILS under the same gap, even when the
#     approval marker matches HEAD and docs/PROGRESS.md changed (so approval
#     and status-doc would otherwise pass — the feature_start gap is the only
#     variable).
#   * `create-pr.sh` therefore refuses BEFORE calling `gh pr create` (it runs
#     `review-gate.sh check`).
#   * A real matching `conductor feature_start <fid> pass` span (subject to
#     the other existing gate conditions being satisfied) ALLOWS approve,
#     check, AND create-pr.
#   * A valid governed canonical teeth_proof_waiver, OR the deprecated
#     red_first_waiver alias, ALSO allows approve without any feature_start
#     span (the same waiver rescues both obligations).
#   * A MALFORMED canonical teeth_proof_waiver shadows a valid legacy
#     red_first_waiver by key-presence precedence — the feature stays
#     blocked on feature_start_missing even though a valid legacy waiver is
#     also present.
#   * The exact hard token is `feature_start_missing` (asserted literally).
#   * The broader warn-only `trace_gate` path (the `review-gate.sh trace`
#     subcommand, which never calls red_first_evidence_gate) keeps
#     feature_start_missing warn-only by default and only fails when
#     REQUIRE_TRACE_CONSISTENCY=1 promotes it — this sensor pins that the new
#     hard gate does NOT change that existing default.
#
# The sensor asserts PR-path BEHAVIOUR (exit codes + the approved-head marker
# + whether `gh pr create` ran), not the checker internals — those are pinned
# by tests/scripts/test_trace_feature_start_evidence.sh.
#
# FIXTURE SHAPE mirrors tests/scripts/test_red_first_pr_gate.sh exactly: a
# throwaway MAIN repo carrying every lifecycle script at its canonical path
# plus the frozen schema contract and docs/PROGRESS.md; a bare `origin` so
# create-pr can fetch/rebase/push and actually reach `gh pr create` when
# unblocked; a linked issue worktree built by the REAL start-issue.sh
# (SKIP_INIT=1) so the branch is feature/issue-NN-* and the main-root trace
# exists (the gate resolves the issue from that branch). The consistency
# artifact set (progress.md + feature_list.json) is planted at the MAIN root
# issue dir, and agent spans + their matching Action Log bullets are written
# there directly (the dirty_gate_fixture approach) so the trace, progress.md,
# and feature list stay mutually consistent and the ONLY attributable
# violation in the blocking cases is feature_start_missing (teeth_proof is
# always independently satisfied via a complete triple or a waiver, per the
# isolation discipline used by test_trace_feature_start_evidence.sh).
# PATH is pinned to a hermetic bin (symlinked coreutils/git/jq + a fake gh:
# `pr create` logs its args and exits 0, everything else exits 1).
#
# CASES:
#   1 approve_blocks_missing_feature_start   full triple (teeth_proof
#       satisfied), no feature_start span, no waiver -> approve exits
#       non-zero AND approved-head is NOT written; output names the literal
#       feature_start_missing token AND the feature_start remedy
#       (scripts/log-handback.sh), even though teeth-proof is independently
#       satisfied.
#   2 check_blocks_missing_feature_start     same gap, marker==HEAD + docs
#       changed (approval + status-doc satisfied) -> check exits non-zero on
#       feature_start_missing.
#   3 create_pr_inherits_block               same gap -> create-pr exits
#       non-zero and the fake `gh pr create` was NOT called (gh.log empty).
#   4 feature_start_span_allows_full_pr_path  full triple PLUS a matching
#       conductor feature_start span -> approve exits 0 and writes
#       approved-head==HEAD; the immediately following check ALSO exits 0;
#       the immediately following create-pr ALSO exits 0 and `gh pr create`
#       was called.
#   5 canonical_waiver_allows_approve        governed doc-only
#       teeth_proof_waiver, no feature_start span, no triple (only a
#       green_handback span so unverified_feature_pass stays satisfied) ->
#       approve exits 0 and writes approved-head==HEAD.
#   6 legacy_waiver_allows_approve           governed doc-only deprecated
#       red_first_waiver alias, same shape as case 5 -> approve exits 0.
#   7 malformed_canonical_shadows_legacy_blocks  malformed (empty object)
#       teeth_proof_waiver PLUS a VALID legacy red_first_waiver PLUS a full
#       triple (so teeth_proof_missing is satisfied via the triple, isolating
#       this case to feature_start alone), no feature_start span -> approve
#       exits non-zero on feature_start_missing; the valid legacy waiver does
#       NOT rescue it because the malformed canonical key shadows it.
#   8 trace_subcommand_stays_warn_only_by_default  full triple, no
#       feature_start span, `review-gate.sh trace` (isolated from
#       red_first_evidence_gate — the `trace` subcommand never calls it) ->
#       exits 0 by default (warn-only) even though feature_start_missing is
#       present; with REQUIRE_TRACE_CONSISTENCY=1 the SAME invocation exits
#       non-zero (the existing promotion flag still works and this new hard
#       gate did not change that behaviour).
#
# RED status at authoring time: review-gate.sh's red_first_evidence_gate()
# greps ONLY `VIOLATION consistency: teeth_proof_missing`, so a
# feature_start_missing finding is invisible to it — cases 1/2/3 currently
# let the PR path proceed (their non-zero-exit / empty-gh-log / literal-token
# assertions FAIL today). Case 7's block assertion also fails today for the
# same reason. Cases 4/5/6/8 are guard legs that must hold both now and after
# implementation.
#
# Exit codes: 0 feature-start PR-gate contract honored · 1 a contract
# obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/feature-start-pr-gate-$$"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
export TMPDIR="${TMP_DIR}/system-tmp"
mkdir -p "$TMPDIR"
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
    || hard_fail "scripts/${s} not found — required by the feature-start PR-gate fixture"
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
# Fake gh (mirrors tests/scripts/test_trace_create_pr.sh write_fake_gh):
# `pr view` fails (no PR yet) until `pr create` has run and stamped
# $GH_STATE, at which point it answers --json number/url queries so
# create-pr's post-create pr_number resolution succeeds; `pr create` records
# its args to $GH_LOG and stamps $GH_STATE. Cases that never intend to reach
# `gh pr create` (the blocking cases) simply never set GH_STATE/GH_LOG, so
# any accidental call still resolves deterministically (exit 1 / no-op log).
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    if [ -n "${GH_STATE:-}" ] && [ -f "${GH_STATE}" ]; then
      printf '123\n'
      exit 0
    fi
    exit 1
    ;;
  "pr create")
    printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
    [ -n "${GH_STATE:-}" ] && : > "${GH_STATE}"
    exit 0
    ;;
esac
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
  # feature-start gate does NOT block (attributability for case 3's RED and
  # case 4's allow leg).
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
# the span/bullet multisets consistent (so only feature_start is attributable).
add_span() {
  local idir="$1" issue="$2" role="$3" step="$4" fid="$5" outcome="$6"
  printf '{"schema_version":1,"timestamp":"2026-07-06T12:00:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"%s","harness.lifecycle_step":"%s","harness.feature_id":"%s","harness.outcome":"%s"}\n' \
    "$issue" "$role" "$step" "$fid" "$outcome" >> "${idir}/trace.jsonl"
  printf -- '- [%s] %s %s %s — fixture span\n' \
    "$role" "$step" "$fid" "$outcome" >> "${idir}/progress.md"
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
# status-doc pass and the feature-start gap is the only variable.
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

# feature lists (feat-b, passes:false, is a false-positive guard throughout).
FL_MISSING='{"issue":1,"features":[{"id":"feat-a","title":"A","passes":true},{"id":"feat-b","title":"B","passes":false}]}'
FL_CANON_WAIVER='{"issue":1,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{"kind":"doc-only","reason":"docs-only change, no code path touched"}},{"id":"feat-b","title":"B","passes":false}]}'
FL_LEGACY_WAIVER='{"issue":1,"features":[{"id":"feat-a","title":"A","passes":true,"red_first_waiver":{"kind":"doc-only","reason":"docs-only change, no code path touched"}},{"id":"feat-b","title":"B","passes":false}]}'
# Both waiver keys present: teeth_proof_waiver is MALFORMED (empty object),
# red_first_waiver is a VALID legacy alias. Precedence is by key presence, so
# the malformed new key is selected and refused — the valid legacy key must
# NOT rescue feature_start either (mirrors test_trace_feature_start_evidence.sh
# case 6).
FL_BOTH_WAIVERS_TRAP='{"issue":1,"features":[{"id":"feat-a","title":"A","passes":true,"teeth_proof_waiver":{},"red_first_waiver":{"kind":"doc-only","reason":"valid legacy waiver that must NOT rescue the malformed new key"}},{"id":"feat-b","title":"B","passes":false}]}'

# ============================================================================
# Case 1: approve_blocks_missing_feature_start (issue 80)
# ============================================================================
C1="${TMP_DIR}/c80"; make_fixture "$C1" 80
WT1="${C1}-worktrees/issue-80"; ID1="${C1}/.copilot-tracking/issues/issue-80"
set_fl "$ID1" "$FL_MISSING"
add_span "$ID1" 80 test-subagent red_handback feat-a pass
add_span "$ID1" 80 implementation-subagent impl_handback feat-a pass
add_span "$ID1" 80 test-subagent green_handback feat-a pass
commit_docs "$WT1" "issue-80 feature-start approve leg"
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" != "0" ] \
  || fail "approve_blocks_missing_feature_start: 'review-gate.sh approve' must HARD-FAIL when a passes:true feature has a complete teeth-proof triple but no matching feature_start span, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -f "$(marker_path "$WT1")" ] \
  || fail "approve_blocks_missing_feature_start: the approved-head marker must NOT be written when feature_start evidence is missing (marker present at $(marker_path "$WT1"))"
grep -Fq 'feature_start_missing' "$OUT" \
  || fail "approve_blocks_missing_feature_start: the refusal must name the literal feature_start_missing token (output: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'feature_start_missing feat-a' "$OUT" \
  || fail "approve_blocks_missing_feature_start: the refusal must attribute feature_start_missing to feat-a (output: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'scripts/log-handback.sh' "$OUT" \
  || fail "approve_blocks_missing_feature_start: a pure feature_start_missing refusal (teeth-proof already satisfied via the triple) must still name the feature_start remedy — record a matching feature_start span via scripts/log-handback.sh (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 2: check_blocks_missing_feature_start (issue 81)
# ============================================================================
C2="${TMP_DIR}/c81"; make_fixture "$C2" 81
WT2="${C2}-worktrees/issue-81"; ID2="${C2}/.copilot-tracking/issues/issue-81"
set_fl "$ID2" "$FL_MISSING"
add_span "$ID2" 81 test-subagent red_handback feat-a pass
add_span "$ID2" 81 implementation-subagent impl_handback feat-a pass
add_span "$ID2" 81 test-subagent green_handback feat-a pass
commit_docs "$WT2" "issue-81 feature-start check leg"
set_marker "$WT2"   # approval matches HEAD; status-doc satisfied above
rc="$(run_in "$WT2" "$OUT" -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "check_blocks_missing_feature_start: 'review-gate.sh check' must HARD-FAIL on missing feature_start evidence even when approval and status-doc pass, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'feature_start_missing feat-a' "$OUT" \
  || fail "check_blocks_missing_feature_start: the check refusal must name feature_start_missing feat-a (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 3: create_pr_inherits_block (issue 82)
# ============================================================================
C3="${TMP_DIR}/c82"; make_fixture "$C3" 82
WT3="${C3}-worktrees/issue-82"; ID3="${C3}/.copilot-tracking/issues/issue-82"
set_fl "$ID3" "$FL_MISSING"
add_span "$ID3" 82 test-subagent red_handback feat-a pass
add_span "$ID3" 82 implementation-subagent impl_handback feat-a pass
add_span "$ID3" 82 test-subagent green_handback feat-a pass
commit_docs "$WT3" "issue-82 feature-start create-pr leg"
set_marker "$WT3"
GH_LOG3="${TMP_DIR}/gh-82.log"; : > "$GH_LOG3"
rc="$(run_in "$WT3" "$OUT" GH_LOG="$GH_LOG3" -- ./scripts/create-pr.sh --title t --body b)"
[ "$rc" != "0" ] \
  || fail "create_pr_inherits_block: 'create-pr.sh' must refuse (non-zero) when review-gate check hard-fails on missing feature_start evidence, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -s "$GH_LOG3" ] \
  || fail "create_pr_inherits_block: 'gh pr create' must NOT be called when the feature-start gate blocks (gh.log: $(tr '\n' '|' < "$GH_LOG3"))"

# ============================================================================
# Case 4: feature_start_span_allows_full_pr_path (issue 83)
# ============================================================================
C4="${TMP_DIR}/c83"; make_fixture "$C4" 83
WT4="${C4}-worktrees/issue-83"; ID4="${C4}/.copilot-tracking/issues/issue-83"
set_fl "$ID4" "$FL_MISSING"
add_span "$ID4" 83 conductor feature_start feat-a pass
add_span "$ID4" 83 test-subagent red_handback feat-a pass
add_span "$ID4" 83 implementation-subagent impl_handback feat-a pass
add_span "$ID4" 83 test-subagent green_handback feat-a pass
add_span "$ID4" 83 code-review-subagent review_verdict feat-a pass  # issue #303: verdict gate
commit_docs "$WT4" "issue-83 feature-start allow leg"
rc="$(run_in "$WT4" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "feature_start_span_allows_full_pr_path: a matching feature_start span must ALLOW approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$WT4")" ] \
  || fail "feature_start_span_allows_full_pr_path: approve must write the approved-head marker when feature_start evidence is present"
if [ -f "$(marker_path "$WT4")" ]; then
  [ "$(tr -d '[:space:]' < "$(marker_path "$WT4")")" = "$(git -C "$WT4" rev-parse HEAD)" ] \
    || fail "feature_start_span_allows_full_pr_path: the approved-head marker must equal the current HEAD"
fi
rc="$(run_in "$WT4" "$OUT" -- ./scripts/review-gate.sh check)"
[ "$rc" = "0" ] \
  || fail "feature_start_span_allows_full_pr_path: 'review-gate.sh check' must ALSO pass once feature_start evidence is present — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
GH_LOG4="${TMP_DIR}/gh-83.log"; : > "$GH_LOG4"
GH_STATE4="${TMP_DIR}/gh-83.state"; rm -f "$GH_STATE4"
rc="$(run_in "$WT4" "$OUT" GH_LOG="$GH_LOG4" GH_STATE="$GH_STATE4" -- ./scripts/create-pr.sh --title t --body b)"
[ "$rc" = "0" ] \
  || fail "feature_start_span_allows_full_pr_path: 'create-pr.sh' must ALSO succeed once feature_start evidence is present — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -s "$GH_LOG4" ] \
  || fail "feature_start_span_allows_full_pr_path: 'gh pr create' must be called once the feature-start gate no longer blocks (gh.log empty)"

# ============================================================================
# Case 5: canonical_waiver_allows_approve (issue 84)
# ============================================================================
C5="${TMP_DIR}/c84"; make_fixture "$C5" 84
WT5="${C5}-worktrees/issue-84"; ID5="${C5}/.copilot-tracking/issues/issue-84"
set_fl "$ID5" "$FL_CANON_WAIVER"
add_span "$ID5" 84 test-subagent green_handback feat-a pass  # satisfies unverified_feature_pass
add_span "$ID5" 84 code-review-subagent review_verdict feat-a pass  # issue #303: verdict gate
commit_docs "$WT5" "issue-84 canonical waiver approve leg"
rc="$(run_in "$WT5" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "canonical_waiver_allows_approve: a governed teeth_proof_waiver must ALLOW approve without any feature_start span — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$WT5")" ] \
  || fail "canonical_waiver_allows_approve: approve must write the approved-head marker when a valid canonical waiver is present"
if [ -f "$(marker_path "$WT5")" ]; then
  [ "$(tr -d '[:space:]' < "$(marker_path "$WT5")")" = "$(git -C "$WT5" rev-parse HEAD)" ] \
    || fail "canonical_waiver_allows_approve: the approved-head marker must equal the current HEAD"
fi

# ============================================================================
# Case 6: legacy_waiver_allows_approve (issue 85)
# ============================================================================
C6="${TMP_DIR}/c85"; make_fixture "$C6" 85
WT6="${C6}-worktrees/issue-85"; ID6="${C6}/.copilot-tracking/issues/issue-85"
set_fl "$ID6" "$FL_LEGACY_WAIVER"
add_span "$ID6" 85 test-subagent green_handback feat-a pass  # satisfies unverified_feature_pass
add_span "$ID6" 85 code-review-subagent review_verdict feat-a pass  # issue #303: verdict gate
commit_docs "$WT6" "issue-85 legacy waiver approve leg"
rc="$(run_in "$WT6" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "legacy_waiver_allows_approve: a governed deprecated red_first_waiver alias must ALLOW approve without any feature_start span — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$WT6")" ] \
  || fail "legacy_waiver_allows_approve: approve must write the approved-head marker when a valid legacy waiver is present"
if [ -f "$(marker_path "$WT6")" ]; then
  [ "$(tr -d '[:space:]' < "$(marker_path "$WT6")")" = "$(git -C "$WT6" rev-parse HEAD)" ] \
    || fail "legacy_waiver_allows_approve: the approved-head marker must equal the current HEAD"
fi

# ============================================================================
# Case 7: malformed_canonical_shadows_legacy_blocks (issue 86)
# ============================================================================
C7="${TMP_DIR}/c86"; make_fixture "$C7" 86
WT7="${C7}-worktrees/issue-86"; ID7="${C7}/.copilot-tracking/issues/issue-86"
set_fl "$ID7" "$FL_BOTH_WAIVERS_TRAP"
add_span "$ID7" 86 test-subagent red_handback feat-a pass
add_span "$ID7" 86 implementation-subagent impl_handback feat-a pass
add_span "$ID7" 86 test-subagent green_handback feat-a pass
commit_docs "$WT7" "issue-86 malformed-shadows-legacy leg"
rc="$(run_in "$WT7" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" != "0" ] \
  || fail "malformed_canonical_shadows_legacy_blocks: a malformed teeth_proof_waiver must shadow (not defer to) a valid legacy red_first_waiver, so approve must still HARD-FAIL on feature_start_missing — expected non-zero, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -f "$(marker_path "$WT7")" ] \
  || fail "malformed_canonical_shadows_legacy_blocks: the approved-head marker must NOT be written (marker present at $(marker_path "$WT7"))"
grep -Fq 'feature_start_missing feat-a' "$OUT" \
  || fail "malformed_canonical_shadows_legacy_blocks: the refusal must name feature_start_missing feat-a (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 8: trace_subcommand_stays_warn_only_by_default (issue 87)
# ============================================================================
C8="${TMP_DIR}/c87"; make_fixture "$C8" 87
WT8="${C8}-worktrees/issue-87"; ID8="${C8}/.copilot-tracking/issues/issue-87"
set_fl "$ID8" "$FL_MISSING"
add_span "$ID8" 87 test-subagent red_handback feat-a pass
add_span "$ID8" 87 implementation-subagent impl_handback feat-a pass
add_span "$ID8" 87 test-subagent green_handback feat-a pass
commit_docs "$WT8" "issue-87 trace-subcommand warn-only leg"
# The `trace` subcommand never calls red_first_evidence_gate — it only runs
# the warn-only trace_gate. This isolates the assertion: the NEW hard gate on
# feature_start_missing must not change trace_gate's existing default.
rc="$(run_in "$WT8" "$OUT" -- ./scripts/review-gate.sh trace)"
[ "$rc" = "0" ] \
  || fail "trace_subcommand_stays_warn_only_by_default: 'review-gate.sh trace' must stay warn-only by default even with feature_start_missing present — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'feature_start_missing feat-a' "$OUT" \
  || fail "trace_subcommand_stays_warn_only_by_default: the warn-only trace gate must still surface the feature_start_missing finding (output: $(tr '\n' '|' < "$OUT"))"
rc="$(run_in "$WT8" "$OUT" REQUIRE_TRACE_CONSISTENCY=1 -- ./scripts/review-gate.sh trace)"
[ "$rc" != "0" ] \
  || fail "trace_subcommand_stays_warn_only_by_default: REQUIRE_TRACE_CONSISTENCY=1 must still promote the SAME finding to a hard failure — expected non-zero, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d feature-start PR-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'feature-start PR-gate contract honored\n'
