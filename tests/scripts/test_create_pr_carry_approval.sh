#!/usr/bin/env bash
# test_create_pr_carry_approval.sh — regression sensor for issue #310 feature
# carry-rebase-approval.
#
# Contract under test:
#   After a content-preserving default rebase (same branch diff, new base
#   commit only), create-pr.sh carries the existing approval forward via
#   review-gate.sh carry-rebase-approval so no second manual approve is needed.
#
#   (A) Content-preserving rebase: create-pr.sh exits 0 (PR opened) without
#       a second approve. Marker line 1 becomes the post-rebase HEAD. Exactly
#       one carry-annotated review_gate_approve span exists with the post-rebase
#       SHA and harness.review_gate_carry=patch-id. check-trace-consistency.sh
#       exits 0 (no review_sha_mismatch).
#   (B) Post-rebase diff alteration via create-pr path: a scoped git wrapper
#       delegates the real rebase to the real git, then the wrapper amends the
#       rebased commit before create-pr calls carry. create-pr.sh exits non-zero
#       at the post_sync_gate/authoritative stale check. No PR opens. Marker
#       remains the pre-rebase SHA. No carry span is emitted.
#   (C) Wrong expected pre-rebase SHA: carry-rebase-approval fails even when
#       the current patch-id matches the stored one. Exit non-zero.
#   (D) Legacy/blank stored identity (single-line marker): carry-rebase-approval
#       fails closed (line 2 empty → no stored identity). Exit non-zero.
#   (Dm) Malformed nonblank marker identity: marker line 2 is nonempty but not
#       a valid 40- or 64-char hex string. carry-rebase-approval must refuse
#       without updating the marker or emitting a carry span.
#   (E) CREATE_PR_NO_REWRITE=1 merge path: carry is never attempted; check
#       runs directly with the stale marker → "has not been approved" → exit 1.
#   (F) Merge-history scenario: branch contains a hand-crafted merge commit that
#       introduces an 'evil' file not present in either non-merge parent. approve
#       must write blank identity (merge history is ineligible for carry). A
#       subsequent content-preserving rebase attempt calls carry-rebase-approval
#       and it must fail closed.
#   (M) Mutation witness: patching carry-rebase-approval to always exit 1 makes
#       a content-preserving rebase scenario fail (create-pr.sh exits non-zero
#       because the authoritative check still sees a stale marker). The sensor
#       has real teeth.
#
# Fixture style mirrors test_create_pr_force_reject_fallback.sh:
# real git, real local bare origin, fake gh on isolated PATH.
#
# Exit codes: 0 all assertions hold · 1 a regression.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Restricted bin with a controllable fake gh ------------------------------
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git basename dirname mkdir rm cat sed tr cut grep \
         printf date wc touch awk jq; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")
    [ -f "${GH_STATE:?}" ] || exit 1
    case "$*" in
      *url*)    printf 'https://example.invalid/pr/123\n' ;;
      *number*) printf '123\n' ;;
      *)        printf '123\n' ;;
    esac
    exit 0
    ;;
  "pr create")
    : > "${GH_STATE:?}"
    exit 0
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
chmod +x "${BIN}/gh"

# make_pr_repo <dir> <issue-pad> — feature/issue-<pad>-fixture on a local bare
# origin. The feature commit updates docs/PROGRESS.md so status-doc gate passes
# and adds feature.txt (no conflict with unrelated main changes).
make_pr_repo() {
  local dir="$1" pad="$2"
  mkdir -p "${dir}/scripts" "${dir}/docs"
  cp "${ROOT}/scripts/create-pr.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/review-gate.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/" 2>/dev/null || true
  cp "${ROOT}/scripts/check-trace-consistency.sh" "${dir}/scripts/" 2>/dev/null || true
  cp "${ROOT}/scripts/validate-trace.sh" "${dir}/scripts/" 2>/dev/null || true
  cp "${ROOT}/scripts/issue-lib.sh" "${dir}/scripts/" 2>/dev/null || true
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Progress\n\nbaseline\n' > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  git -C "$dir" add .gitignore README.md docs/PROGRESS.md scripts
  git -C "$dir" commit -q -m initial
  git clone -q --bare "$dir" "${dir}-origin.git"
  git -C "$dir" remote add origin "${dir}-origin.git"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$pad" > "${dir}/docs/PROGRESS.md"
  printf 'feature content\n' > "${dir}/feature.txt"
  git -C "$dir" add docs/PROGRESS.md feature.txt
  git -C "$dir" commit -q -m "issue-${pad}: feature work"
  git -C "$dir" fetch -q origin main
}

# advance_origin_main_unrelated <dir> — push a change to origin main that does
# NOT touch the feature branch files (no conflict, content-preserving rebase).
advance_origin_main_unrelated() {
  local dir="$1"
  local work="${dir}-mainwork"
  git clone -q "${dir}-origin.git" "$work"
  git -C "$work" config user.name "Harness Test"
  git -C "$work" config user.email "harness-test@example.invalid"
  printf 'unrelated main change\n' > "${work}/other.txt"
  git -C "$work" add other.txt
  git -C "$work" commit -q -m "main: unrelated change"
  git -C "$work" push -q origin main
  git -C "$dir" fetch -q origin main
}

# run_cpr <dir> <state-suffix> <out-file> [env=val ...] -- <args...>
run_cpr() {
  local dir="$1" sfx="$2" out="$3"; shift 3
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  (cd "$dir" && env PATH="${BIN}:${PATH}" GH_STATE="${TMP_DIR}/gh-state-${sfx}" "${envs[@]}" \
    ./scripts/create-pr.sh "$@") > "$out" 2>&1
}

# ============================================================================
# (A) Content-preserving rebase: carry succeeds, PR opens first try
# ============================================================================
RA="${TMP_DIR}/ra"
make_pr_repo "$RA" 310

# Approve before the rebase (pre-rebase HEAD is approved with 2-line marker).
(cd "$RA" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh approve) \
  || fail "(A) setup: initial approve failed"
PRE_REBASE_HEAD_A="$(git -C "$RA" rev-parse HEAD)"
MARKER_A="${RA}/.copilot-tracking/review-gate/approved-head"

# Verify initial marker has 2 lines (feature-1 contract).
LINE_COUNT_BEFORE="$(wc -l < "$MARKER_A" | tr -d ' ')"
[ "$LINE_COUNT_BEFORE" = "2" ] \
  || fail "(A) setup: initial marker must have 2 lines (feature-1), got ${LINE_COUNT_BEFORE}"

# Advance origin/main with an unrelated change (content-preserving rebase).
advance_origin_main_unrelated "$RA"

OUT_A="${TMP_DIR}/a.out"
# The carry should work: create-pr.sh must exit 0 without a second approve.
if ! run_cpr "$RA" a "$OUT_A" -- --title "feat: carry" --body "test"; then
  cat "$OUT_A"
  fail "(A) create-pr.sh must exit 0 on content-preserving rebase with carry — no second approve needed"
fi
# The PR must have actually opened (GH_STATE file created by fake gh pr create).
[ -f "${TMP_DIR}/gh-state-a" ] \
  || { cat "$OUT_A"; fail "(A) the PR must open (fake gh pr create must have run)"; }

# Marker line 1 must be the post-rebase HEAD.
POST_REBASE_HEAD_A="$(git -C "$RA" rev-parse HEAD)"
[ "$POST_REBASE_HEAD_A" != "$PRE_REBASE_HEAD_A" ] \
  || fail "(A) HEAD should have moved after rebase (setup: origin/main must have advanced)"
MARKER_LINE1_A="$(sed -n '1p' "$MARKER_A" | tr -d '[:space:]')"
[ "$MARKER_LINE1_A" = "$POST_REBASE_HEAD_A" ] \
  || fail "(A) marker line 1 must be post-rebase HEAD ${POST_REBASE_HEAD_A}, got ${MARKER_LINE1_A}"

# Trace assertions: exactly one carry-annotated approve span with post-rebase SHA.
# Trace file is mandatory for the carry contract — it must exist for issue-310-fixture branches.
TRACE_A="${RA}/.copilot-tracking/issues/issue-310/trace.jsonl"
[ -f "$TRACE_A" ] \
  || fail "(A) trace file must exist at ${TRACE_A} — carry contract requires trace emission"
command -v jq >/dev/null 2>&1 || fail "(A) jq required for trace assertions"

# Exactly one carry-annotated span (not zero, not two+).
CARRY_SPAN_COUNT_A="$(jq -rc 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "review_gate_approve" and .["harness.review_gate_carry"] == "patch-id")' "$TRACE_A" | wc -l | tr -d ' ')"
[ "$CARRY_SPAN_COUNT_A" = "1" ] \
  || fail "(A) trace must contain EXACTLY 1 carry-annotated review_gate_approve span, got ${CARRY_SPAN_COUNT_A}"

# That span must have the post-rebase SHA.
CARRY_SHA_A="$(jq -r 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "review_gate_approve" and .["harness.review_gate_carry"] == "patch-id") | .["harness.review_gate_sha"]' "$TRACE_A")"
[ "$CARRY_SHA_A" = "$POST_REBASE_HEAD_A" ] \
  || fail "(A) carry span must carry post-rebase SHA ${POST_REBASE_HEAD_A}, got ${CARRY_SHA_A}"

# check-trace-consistency.sh must exit exactly 0 (no review_sha_mismatch).
if [ -x "${RA}/scripts/check-trace-consistency.sh" ]; then
  CONSISTENCY_OUT="${TMP_DIR}/a-consistency.out"
  CONS_RC=0
  (cd "$RA" && PATH="${BIN}:${PATH}" TRACE_ISSUE=310 ./scripts/check-trace-consistency.sh 310) \
    > "$CONSISTENCY_OUT" 2>&1 || CONS_RC=$?
  if [ "$CONS_RC" != "0" ]; then
    cat "$CONSISTENCY_OUT"
    fail "(A) check-trace-consistency.sh must exit exactly 0; got exit ${CONS_RC}"
  fi
  if [ "$CONS_RC" = "0" ]; then
    grep -q "review_sha_mismatch" "$CONSISTENCY_OUT" \
      && { cat "$CONSISTENCY_OUT"; fail "(A) check-trace-consistency.sh must not report review_sha_mismatch after a carry"; }
  fi
fi

printf 'ok - (A) content-preserving rebase: carry succeeds, PR opens without second approve\n'

# ============================================================================
# (B) Post-rebase diff alteration via create-pr path: carry fails closed
#
# A scoped git wrapper on PATH delegates the real rebase to the real git, then
# amends the rebased commit to add extra content before create-pr calls carry.
# This proves the controlled create-pr path: create-pr.sh exits non-zero at the
# post_sync_gate/authoritative stale check, no PR opens, marker stays pre-rebase,
# and no carry span is emitted.
# ============================================================================
RB="${TMP_DIR}/rb"
make_pr_repo "$RB" 310

(cd "$RB" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh approve) \
  || fail "(B) setup: initial approve failed"
MARKER_LINE1_BEFORE_B="$(sed -n '1p' "${RB}/.copilot-tracking/review-gate/approved-head" | tr -d '[:space:]')"

advance_origin_main_unrelated "$RB"

# Create a scoped git wrapper that: runs the real git for everything, but after
# a successful rebase it also amends the HEAD commit to add an extra file. This
# simulates what would happen if something altered the diff after rebase and before carry.
BBIN="${TMP_DIR}/bbin"
mkdir -p "$BBIN"
REAL_GIT="$(command -v git)"
cat > "${BBIN}/git" <<GITSH
#!/usr/bin/env bash
"${REAL_GIT}" "\$@"
rc=\$?
# After a successful rebase, amend HEAD to add extra content (alters patch-id).
if [ "\$rc" = "0" ] && [ "\${1:-}" = "rebase" ]; then
  REPO_DIR="\$(${REAL_GIT} rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "\$REPO_DIR" ]; then
    printf 'extra content that changes the diff\n' > "\${REPO_DIR}/extra_b.txt"
    "${REAL_GIT}" -C "\$REPO_DIR" add extra_b.txt 2>/dev/null || true
    "${REAL_GIT}" -C "\$REPO_DIR" commit --amend --no-edit -q 2>/dev/null || true
  fi
fi
exit \$rc
GITSH
chmod +x "${BBIN}/git"
# Copy other needed tools to BBIN from BIN.
for t in bash sh env basename dirname mkdir rm cat sed tr cut grep printf date wc touch awk jq; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BBIN}/${t}"
done
ln -sf "${BIN}/gh" "${BBIN}/gh"

OUT_B="${TMP_DIR}/b.out"
B_CPR_RC=0
(cd "$RB" && env PATH="${BBIN}:${PATH}" GH_STATE="${TMP_DIR}/gh-state-b" \
  ./scripts/create-pr.sh --title "feat: carry-b" --body "test") \
  > "$OUT_B" 2>&1 || B_CPR_RC=$?

[ "$B_CPR_RC" -ne 0 ] \
  || { cat "$OUT_B"; fail "(B) create-pr.sh must exit non-zero when diff altered after rebase (patch-id mismatch)"; }

# No PR must have opened.
[ ! -f "${TMP_DIR}/gh-state-b" ] \
  || { cat "$OUT_B"; fail "(B) no PR must open when carry fails (diff altered)"; }

# Marker line 1 must remain the pre-rebase SHA (unchanged by failed carry).
MARKER_LINE1_AFTER_B="$(sed -n '1p' "${RB}/.copilot-tracking/review-gate/approved-head" | tr -d '[:space:]')"
[ "$MARKER_LINE1_AFTER_B" = "$MARKER_LINE1_BEFORE_B" ] \
  || fail "(B) marker line 1 must remain pre-rebase SHA ${MARKER_LINE1_BEFORE_B} after failed carry, got ${MARKER_LINE1_AFTER_B}"

# No carry span must be emitted.
TRACE_B="${RB}/.copilot-tracking/issues/issue-310/trace.jsonl"
if [ -f "$TRACE_B" ] && command -v jq >/dev/null 2>&1; then
  CARRY_SPANS_B="$(jq -rc 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "review_gate_approve" and .["harness.review_gate_carry"] == "patch-id")' "$TRACE_B" || true)"
  [ -z "$CARRY_SPANS_B" ] \
    || fail "(B) no carry span must be emitted when carry fails (diff altered)"
fi

printf 'ok - (B) post-rebase diff alteration via create-pr path: carry fails, no PR, marker unchanged, no carry span\n'

# ============================================================================
# (C) Wrong expected pre-rebase SHA: carry fails even when patch-id matches
# ============================================================================
RC_DIR="${TMP_DIR}/rc"
make_pr_repo "$RC_DIR" 310

(cd "$RC_DIR" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh approve) \
  || fail "(C) setup: initial approve failed"

advance_origin_main_unrelated "$RC_DIR"

# Manually rebase (content-preserving — same diff).
(cd "$RC_DIR" && git rebase origin/main) \
  || fail "(C) setup: rebase should succeed"

# Call carry-rebase-approval with a WRONG pre-rebase SHA.
WRONG_SHA="0000000000000000000000000000000000000000"
CARRY_OUT_C="${TMP_DIR}/c-carry.out"
CARRY_RC_C=0
(cd "$RC_DIR" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh carry-rebase-approval "$WRONG_SHA") \
  > "$CARRY_OUT_C" 2>&1 || CARRY_RC_C=$?
[ "$CARRY_RC_C" -ne 0 ] \
  || { cat "$CARRY_OUT_C"; fail "(C) carry-rebase-approval must exit non-zero when expected pre-rebase SHA is wrong"; }

printf 'ok - (C) wrong expected pre-rebase SHA: carry fails regardless of patch-id match\n'

# ============================================================================
# (D) Legacy/blank stored identity (single-line marker): carry fails closed
# ============================================================================
RD="${TMP_DIR}/rd"
make_pr_repo "$RD" 310

# Write a SINGLE-LINE marker (legacy format — no patch-id on line 2).
HEAD_D="$(git -C "$RD" rev-parse HEAD)"
mkdir -p "${RD}/.copilot-tracking/review-gate"
printf '%s\n' "$HEAD_D" > "${RD}/.copilot-tracking/review-gate/approved-head"

advance_origin_main_unrelated "$RD"

# Manually rebase.
(cd "$RD" && git rebase origin/main) \
  || fail "(D) setup: rebase should succeed"

# carry-rebase-approval should fail closed (no stored identity).
CARRY_OUT_D="${TMP_DIR}/d-carry.out"
CARRY_RC_D=0
(cd "$RD" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh carry-rebase-approval "$HEAD_D") \
  > "$CARRY_OUT_D" 2>&1 || CARRY_RC_D=$?
[ "$CARRY_RC_D" -ne 0 ] \
  || { cat "$CARRY_OUT_D"; fail "(D) carry-rebase-approval must exit non-zero with a single-line (legacy) marker"; }

printf 'ok - (D) legacy single-line marker: carry fails closed (no stored identity)\n'

# ============================================================================
# (Dm) Malformed nonblank marker identity: line 2 is nonempty but not valid hex.
#      carry-rebase-approval must refuse without updating the marker or emitting
#      a carry span.
# ============================================================================
RDM="${TMP_DIR}/rdm"
make_pr_repo "$RDM" 310

HEAD_DM="$(git -C "$RDM" rev-parse HEAD)"
mkdir -p "${RDM}/.copilot-tracking/review-gate"
# Write a 2-line marker with a malformed identity on line 2 (not 40 or 64 hex chars).
printf '%s\nNOTAVALIDHASH\n' "$HEAD_DM" > "${RDM}/.copilot-tracking/review-gate/approved-head"

advance_origin_main_unrelated "$RDM"
(cd "$RDM" && git rebase origin/main) \
  || fail "(Dm) setup: rebase should succeed"

CARRY_OUT_DM="${TMP_DIR}/dm-carry.out"
CARRY_RC_DM=0
(cd "$RDM" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh carry-rebase-approval "$HEAD_DM") \
  > "$CARRY_OUT_DM" 2>&1 || CARRY_RC_DM=$?
[ "$CARRY_RC_DM" -ne 0 ] \
  || { cat "$CARRY_OUT_DM"; fail "(Dm) carry-rebase-approval must exit non-zero with a malformed (nonblank non-hex) marker identity"; }

# Marker line 2 must remain unchanged (not overwritten by failed carry).
MARKER_LINE2_DM="$(sed -n '2p' "${RDM}/.copilot-tracking/review-gate/approved-head" | tr -d '[:space:]')"
[ "$MARKER_LINE2_DM" = "NOTAVALIDHASH" ] \
  || fail "(Dm) marker line 2 must remain unchanged (NOTAVALIDHASH) after rejected carry, got '${MARKER_LINE2_DM}'"

# No carry span.
TRACE_DM="${RDM}/.copilot-tracking/issues/issue-310/trace.jsonl"
if [ -f "$TRACE_DM" ] && command -v jq >/dev/null 2>&1; then
  CARRY_SPANS_DM="$(jq -rc 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "review_gate_approve" and .["harness.review_gate_carry"] == "patch-id")' "$TRACE_DM" || true)"
  [ -z "$CARRY_SPANS_DM" ] \
    || fail "(Dm) no carry span must be emitted for a malformed marker identity"
fi

printf 'ok - (Dm) malformed nonblank marker identity: carry refuses, marker unchanged, no carry span\n'

# ============================================================================
# (E) CREATE_PR_NO_REWRITE=1 merge path: carry never attempted, fresh approve required
# ============================================================================
RE="${TMP_DIR}/re"
make_pr_repo "$RE" 310

(cd "$RE" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh approve) \
  || fail "(E) setup: initial approve failed"

advance_origin_main_unrelated "$RE"

OUT_E="${TMP_DIR}/e.out"
# CREATE_PR_NO_REWRITE=1 → merge path → stale marker → check fails.
if run_cpr "$RE" e "$OUT_E" CREATE_PR_NO_REWRITE=1 -- --title t --body b; then
  cat "$OUT_E"
  fail "(E) create-pr.sh with CREATE_PR_NO_REWRITE=1 must exit non-zero — merge requires fresh approval"
fi
grep -q "has not been approved" "$OUT_E" \
  || { cat "$OUT_E"; fail "(E) must print 'has not been approved' message (stale marker, no carry on merge path)"; }

printf 'ok - (E) CREATE_PR_NO_REWRITE=1 merge path: carry not attempted, fresh approval required\n'

# ============================================================================
# (F) Merge-history scenario: approve writes blank identity; carry fails closed.
#
# Branch contains a hand-crafted merge commit that introduces an 'evil' file
# not present in either non-merge parent. Default rebase flattens the
# non-merge first-parent patch stream and drops the merge-only content, so
# carrying approval across a rebase would silently misrepresent what was
# reviewed. approve must write a blank identity (line 2 empty); carry must
# refuse with exit non-zero.
# ============================================================================
RF="${TMP_DIR}/rf"
mkdir -p "${RF}/scripts" "${RF}/docs"
cp "${ROOT}/scripts/create-pr.sh" "${RF}/scripts/"
cp "${ROOT}/scripts/review-gate.sh" "${RF}/scripts/"
cp "${ROOT}/scripts/trace-lib.sh" "${RF}/scripts/" 2>/dev/null || true

git -C "$RF" init -q -b main
git -C "$RF" config user.name "Harness Test"
git -C "$RF" config user.email "harness-test@example.invalid"
git -C "$RF" config commit.gpgsign false
printf '.copilot-tracking/\n' > "${RF}/.gitignore"
printf 'fixture\n' > "${RF}/README.md"
printf '# Progress\n\nbaseline\n' > "${RF}/docs/PROGRESS.md"
git -C "$RF" add .gitignore README.md docs/PROGRESS.md scripts
git -C "$RF" commit -q -m initial
git clone -q --bare "$RF" "${RF}-origin.git"
git -C "$RF" remote add origin "${RF}-origin.git"

# feature branch: one normal commit
git -C "$RF" checkout -q -b "feature/issue-310-fixture"
printf '# Progress\n\nissue-310 work\n' > "${RF}/docs/PROGRESS.md"
printf 'feature content\n' > "${RF}/feature.txt"
git -C "$RF" add docs/PROGRESS.md feature.txt
git -C "$RF" commit -q -m "issue-310: feature work"

# Create a side branch from main with a commit, then merge it back into
# feature, introducing an 'evil' file only in the merge commit.
git -C "$RF" checkout -q main
printf 'side content\n' > "${RF}/side.txt"
git -C "$RF" add side.txt
git -C "$RF" commit -q -m "side: branch content"
SIDE_SHA_F="$(git -C "$RF" rev-parse HEAD)"

git -C "$RF" checkout -q "feature/issue-310-fixture"
# Merge the side branch: merge commit will include side.txt but also add evil.txt.
git -C "$RF" merge -q --no-ff "$SIDE_SHA_F" -m "merge: side branch into feature"
# Amend the merge commit to add evil.txt (content only in merge, not in any non-merge parent).
printf 'evil content only in merge commit\n' > "${RF}/evil.txt"
git -C "$RF" add evil.txt
git -C "$RF" commit --amend --no-edit -q

git -C "$RF" fetch -q origin main

# approve must write blank identity (merge history → return 1 from _patch_id_for_branch).
APPROVE_OUT_F="${TMP_DIR}/f-approve.out"
APPROVE_RC_F=0
(cd "$RF" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh approve) \
  > "$APPROVE_OUT_F" 2>&1 || APPROVE_RC_F=$?
[ "$APPROVE_RC_F" = "0" ] \
  || { cat "$APPROVE_OUT_F"; fail "(F) approve must exit exactly 0 for merge-history branch; got exit ${APPROVE_RC_F}"; }
MARKER_F="${RF}/.copilot-tracking/review-gate/approved-head"
[ -f "$MARKER_F" ] || fail "(F) approve must write marker even on merge-history branch"
MARKER_LINE2_F="$(sed -n '2p' "$MARKER_F" | tr -d '[:space:]')"
[ -z "$MARKER_LINE2_F" ] \
  || fail "(F) approve must write blank identity (line 2 empty) for merge-history branch, got '${MARKER_LINE2_F}'"

PRE_REBASE_HEAD_F="$(git -C "$RF" rev-parse HEAD)"

# After approve, simulate carry attempt (carry must fail closed on blank identity).
advance_origin_main_unrelated "$RF"
(cd "$RF" && git rebase origin/main) \
  || fail "(F) setup: rebase should succeed (no conflict in feature.txt vs other.txt)"

CARRY_OUT_F="${TMP_DIR}/f-carry.out"
CARRY_RC_F=0
(cd "$RF" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh carry-rebase-approval "$PRE_REBASE_HEAD_F") \
  > "$CARRY_OUT_F" 2>&1 || CARRY_RC_F=$?
[ "$CARRY_RC_F" -ne 0 ] \
  || { cat "$CARRY_OUT_F"; fail "(F) carry-rebase-approval must fail closed for a branch with merge-history (blank identity)"; }

printf 'ok - (F) merge-history: approve writes blank identity; carry-rebase-approval fails closed\n'

# ============================================================================
# (M) Mutation witness: disabling carry causes (A)-like scenario to fail
# ============================================================================
RM="${TMP_DIR}/rm"
make_pr_repo "$RM" 310

(cd "$RM" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh approve) \
  || fail "(M) setup: initial approve failed"

advance_origin_main_unrelated "$RM"

# Patch review-gate.sh in the mutation repo: make carry-rebase-approval always
# exit 1. The mutation must be committed so create-pr.sh sees a clean working tree.
sed 's/TRACE_CMD="carry-rebase-approval"/TRACE_CMD="carry-rebase-approval"\n    exit 1  # MUTATION: always fail carry/' \
  "${RM}/scripts/review-gate.sh" > "${RM}/scripts/review-gate.sh.mut"
mv "${RM}/scripts/review-gate.sh.mut" "${RM}/scripts/review-gate.sh"
chmod +x "${RM}/scripts/review-gate.sh"
git -C "$RM" add scripts/review-gate.sh
git -C "$RM" commit -q -m "mutation: disable carry-rebase-approval"

OUT_M="${TMP_DIR}/m.out"
# With carry disabled, create-pr.sh must exit non-zero (no second approve given).
M_CPR_RC=0
run_cpr "$RM" m "$OUT_M" -- --title t --body b || M_CPR_RC=$?
[ "$M_CPR_RC" -ne 0 ] \
  || { cat "$OUT_M"; fail "(M) mutation witness FAILED: disabling carry must make create-pr.sh exit non-zero — this regression sensor has lost its teeth"; }
grep -q "has not been approved" "$OUT_M" \
  || { cat "$OUT_M"; fail "(M) mutation: must fail at the review gate with 'has not been approved' when carry is disabled"; }

printf 'ok - (M) mutation witness: disabling carry causes content-preserving rebase to fail without second approve\n'

printf '\n1..8\nall carry-approval scenarios passed\n'
