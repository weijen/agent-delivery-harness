#!/usr/bin/env bash
# test_review_gate_patch_id_store.sh — regression sensor for feature
# approve-stores-patch-id (issue #310):
#   Scenario A: approve writes a 2-line marker (line 1 = HEAD SHA,
#               line 2 = stable patch-id hex string, 40 or 64 chars).
#   Scenario B: check passes with a 2-line marker (reads only line 1).
#   Scenario C: backward compat — a legacy single-line marker still passes check.
#   Scenario D: mutation witness — a patched-away patch-id write yields a
#               1-line marker, proving Scenario A's assertion detects the regression.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts review-gate.sh
TMP_DIR="$FIXTURE_TMP_DIR"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

_sfail=0
fail() { printf '# %s\n' "$*" >&2; _sfail=1; }
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

make_commit() {
  local message="$1"
  local tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref refs/heads/feature/review-gate "$commit"
  git reset -q --hard "$commit"
}

# ── Setup ────────────────────────────────────────────────────────────────────

# Fake gh (approve/check do not need gh; included so PATH isolation is complete).
mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 1
GHEOF
chmod +x "${TMP_DIR}/bin/gh"
export PATH="${TMP_DIR}/bin:${PATH}"

# Create a bare origin with a main branch that has docs/PROGRESS.md.
ORIGIN_WORK="$FIXTURE_REPO"
mkdir -p "${ORIGIN_WORK}/docs"
printf '# Progress\n\nbaseline\n' > "${ORIGIN_WORK}/docs/PROGRESS.md"
git -C "$ORIGIN_WORK" add docs/PROGRESS.md
git -C "$ORIGIN_WORK" commit -q -m "add progress baseline"
git clone -q --bare "$ORIGIN_WORK" "${TMP_DIR}/origin.git"
git -C "$ORIGIN_WORK" remote add origin "${TMP_DIR}/origin.git"

# Feature repo on a feature/review-gate branch (no issue-NN slug →
# resolve_issue_number skips gracefully → all trace-based gates skip).
fixture_repo --with-scripts review-gate.sh
REPO="$FIXTURE_REPO"
mkdir -p "${REPO}/docs"

cd "$REPO"
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main

# Establish feature commits on top of origin/main.
# docs/PROGRESS.md must differ from origin/main so status_doc_gate passes.
git reset -q --hard origin/main
printf 'feature work\n' > feature.txt
printf '# Progress\n\npatch-id store implementation\n' > docs/PROGRESS.md
git add .gitignore feature.txt docs/PROGRESS.md
make_commit "first feature commit"

printf 'more feature work\n' >> feature.txt
git add feature.txt
make_commit "second feature commit"

head_sha="$(git rev-parse HEAD)"
marker_dir="${REPO}/.copilot-tracking/review-gate"
marker_file="${marker_dir}/approved-head"
rg="${REPO}/scripts/review-gate.sh"

# ── Scenario A: approve writes a 2-line marker ───────────────────────────────
approve_rc=0
"$rg" approve >"${TMP_DIR}/approve-a.out" 2>&1 || approve_rc=$?

if [ "$approve_rc" -ne 0 ]; then
  fail "approve exited ${approve_rc} — expected 0"
elif [ ! -f "$marker_file" ]; then
  fail "marker file was not created"
else
  line_count="$(wc -l < "$marker_file" | tr -d ' ')"
  line1="$(sed -n '1p' "$marker_file" | tr -d '[:space:]')"
  line2="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"

  if [ "$line_count" -ne 2 ]; then
    fail "expected 2-line marker, got ${line_count} line(s)"
  fi
  if [ "$line1" != "$head_sha" ]; then
    fail "line 1 '${line1}' != HEAD SHA '${head_sha}'"
  fi
  if [ -z "$line2" ]; then
    fail "line 2 (patch-id) must not be empty"
  fi
  if ! printf '%s\n' "$line2" | grep -qE '^[0-9a-f]{40}$|^[0-9a-f]{64}$'; then
    fail "line 2 '${line2}' is not a 40- or 64-char lowercase hex string"
  fi
fi
emit "Scenario A: approve writes 2-line marker (line 1 = HEAD sha, line 2 = patch-id hex)"

# ── Scenario B: check passes with a 2-line marker ────────────────────────────
# Uses the marker written by Scenario A (still current HEAD).
check_b_rc=0
SKIP_CI_GATE=1 "$rg" check >"${TMP_DIR}/check-b.out" 2>&1 || check_b_rc=$?
if [ "$check_b_rc" -ne 0 ]; then
  fail "check failed with 2-line marker (rc=${check_b_rc})"
  cat "${TMP_DIR}/check-b.out" >&2
fi
emit "Scenario B: check passes with 2-line marker (reads only line 1)"

# ── Scenario C: backward compat — single-line marker still passes check ──────
mkdir -p "$marker_dir"
printf '%s\n' "$head_sha" > "$marker_file"   # synthetic legacy format
check_c_rc=0
SKIP_CI_GATE=1 "$rg" check >"${TMP_DIR}/check-c.out" 2>&1 || check_c_rc=$?
if [ "$check_c_rc" -ne 0 ]; then
  fail "check failed with legacy single-line marker (rc=${check_c_rc})"
  cat "${TMP_DIR}/check-c.out" >&2
fi
emit "Scenario C: check passes with legacy single-line marker (backward compatible)"

# ── Scenario D: mutation witness ─────────────────────────────────────────────
# Direct mutation evidence (GREEN phase): a mutant review-gate.sh with the
# patch-id append line removed. The mutant writes only line 1 (HEAD sha);
# Scenario A's 2-line assertion would catch this regression in production.
# This proves the printf append is the load-bearing contract mechanism.
# (Red-first evidence from Scenario A failing pre-implementation already
# satisfies the teeth obligation; this is additional positive mutation proof.)
mutant_rg="${TMP_DIR}/review-gate-mutant.sh"
# Remove the line that appends the patch-id to the marker. The pattern matches
# the literal $marker_file in the script source (\$ → sed escaped dollar sign).
# shellcheck disable=SC2016
sed '/printf.*_patch_id.*>> "\$marker_file"/d' "${ROOT}/scripts/review-gate.sh" > "$mutant_rg"
chmod +x "$mutant_rg"

rm -f "$marker_file"
bash "$mutant_rg" approve >"${TMP_DIR}/mutant-approve.out" 2>&1 || true

if [ ! -f "$marker_file" ]; then
  fail "mutant approve did not create the marker file"
else
  d_line_count="$(wc -l < "$marker_file" | tr -d ' ')"
  d_line2="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"
  if [ "$d_line_count" -ne 1 ] || [ -n "$d_line2" ]; then
    fail "mutant approve wrote ${d_line_count} line(s) with line2='${d_line2}'; expected 1 line and no line 2 — the contract append is missing"
  fi
fi
emit "Scenario D: mutation witness — mutant missing the patch-id append writes a 1-line marker (Scenario A would catch it)"

# ── Scenario E: patch identity is invariant across a content-preserving rebase ─
# Advance origin/main with an unrelated commit, rebase the feature branch onto
# it, and verify that line 2 of the approved-head marker is unchanged.
# This is the core semantic guarantee: patch-id is commit-hash–agnostic.

# Clean up Scenario D's 1-line mutant marker and get a fresh 2-line marker.
rm -f "$marker_file"
e_before_rc=0
"$rg" approve >"${TMP_DIR}/approve-e-before.out" 2>&1 || e_before_rc=$?

if [ "$e_before_rc" -ne 0 ]; then
  fail "Scenario E: pre-rebase approve failed (rc=${e_before_rc})"
  cat "${TMP_DIR}/approve-e-before.out" >&2
elif [ ! -f "$marker_file" ]; then
  fail "Scenario E: pre-rebase approve did not create marker file"
else
  e_id_before="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"
  if [ -z "$e_id_before" ]; then
    fail "Scenario E: pre-rebase patch identity must not be blank (origin/main is configured)"
  fi

  # Add an unrelated commit to origin/main (touches a file not in the feature branch).
  printf 'extra origin work\n' > "${ORIGIN_WORK}/docs/EXTRA.md"
  git -C "$ORIGIN_WORK" add docs/EXTRA.md
  git -C "$ORIGIN_WORK" -c user.name="Harness Test" \
    -c user.email="harness-test@example.invalid" \
    commit -q -m "chore: add extra doc (unrelated to feature)"
  git -C "$ORIGIN_WORK" push -q "${TMP_DIR}/origin.git" main:main

  git -C "${TMP_DIR}/repo" fetch -q origin main

  e_rebase_rc=0
  git -C "${TMP_DIR}/repo" -c user.name="Harness Test" \
    -c user.email="harness-test@example.invalid" \
    rebase -q origin/main >"${TMP_DIR}/rebase-e.out" 2>&1 || e_rebase_rc=$?
  if [ "$e_rebase_rc" -ne 0 ]; then
    fail "Scenario E: rebase failed (rc=${e_rebase_rc})"
    cat "${TMP_DIR}/rebase-e.out" >&2
    git -C "${TMP_DIR}/repo" rebase --abort 2>/dev/null || true
  else
    # Re-approve after rebase (HEAD SHA has changed; identity must be unchanged).
    e_after_rc=0
    "$rg" approve >"${TMP_DIR}/approve-e-after.out" 2>&1 || e_after_rc=$?
    if [ "$e_after_rc" -ne 0 ]; then
      fail "Scenario E: post-rebase approve failed (rc=${e_after_rc})"
      cat "${TMP_DIR}/approve-e-after.out" >&2
    elif [ ! -f "$marker_file" ]; then
      fail "Scenario E: post-rebase approve did not create marker file"
    else
      e_id_after="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"
      if [ -z "$e_id_after" ]; then
        fail "Scenario E: post-rebase patch identity must not be blank"
      elif [ "$e_id_before" != "$e_id_after" ]; then
        fail "Scenario E: identity changed across rebase: before='${e_id_before}' after='${e_id_after}'"
      fi
    fi
  fi
fi
emit "Scenario E: patch identity is unchanged across a content-preserving rebase"

# ── Scenario F: empty branch with valid origin/main gets deterministic identity ─
# A branch with zero commits above origin/main must record the deterministic
# empty-stream identity (git hash-object --stdin </dev/null), not a blank line.
# This distinguishes it from the origin-unavailable case (Scenario G).
fixture_repo --with-scripts review-gate.sh
F_REPO="$FIXTURE_REPO"
_saved_dir="$(pwd)"
cd "$F_REPO"
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main
# Reset to exactly origin/main — zero commits above the base.
git reset -q --hard origin/main
git checkout -q -b feature/empty-test

f_approve_rc=0
./scripts/review-gate.sh approve >"${TMP_DIR}/approve-f.out" 2>&1 || f_approve_rc=$?
f_marker="${F_REPO}/.copilot-tracking/review-gate/approved-head"

if [ "$f_approve_rc" -ne 0 ]; then
  fail "Scenario F: approve failed for empty branch (rc=${f_approve_rc})"
  cat "${TMP_DIR}/approve-f.out" >&2
elif [ ! -f "$f_marker" ]; then
  fail "Scenario F: approve did not create marker file for empty branch"
else
  f_line_count="$(wc -l < "$f_marker" | tr -d ' ')"
  f_line2="$(sed -n '2p' "$f_marker" | tr -d '[:space:]')"
  f_expected_empty_id="$(git hash-object --stdin </dev/null 2>/dev/null)" || f_expected_empty_id=""

  if [ "$f_line_count" -ne 2 ]; then
    fail "Scenario F: expected 2-line marker for empty branch, got ${f_line_count} line(s)"
  elif [ -z "$f_line2" ]; then
    fail "Scenario F: line 2 must be the deterministic empty-stream hash, not blank"
  elif [ -n "$f_expected_empty_id" ] && [ "$f_line2" != "$f_expected_empty_id" ]; then
    fail "Scenario F: line 2 '${f_line2}' != expected empty-stream hash '${f_expected_empty_id}'"
  elif ! printf '%s\n' "$f_line2" | grep -qE '^[0-9a-f]{40}$|^[0-9a-f]{64}$'; then
    fail "Scenario F: line 2 '${f_line2}' is not a 40- or 64-char lowercase hex string"
  fi
fi
cd "$_saved_dir"
emit "Scenario F: empty branch (zero commits above origin/main) gets deterministic empty-stream identity"

# ── Scenario G: origin/main unavailable — approve succeeds, line 2 is blank ──
# When origin/main cannot be reached, identity is unknown. Approve must still
# succeed (approval is valid), write 2 lines, and record a blank line 2 so that
# carry fails closed later. This case must not be confused with an empty branch
# (Scenario F: empty branch with valid origin/main gets a specific non-blank hash).
fixture_repo --with-scripts review-gate.sh
G_REPO="$FIXTURE_REPO"
cd "$G_REPO"
git checkout -q -b feature/no-origin-test
mkdir -p docs
printf '# Progress\n\nwork without origin\n' > docs/PROGRESS.md
git add docs/PROGRESS.md
git -c user.name="Harness Test" -c user.email="harness-test@example.invalid" \
  commit -q -m "initial commit (no origin configured)"
printf 'more work\n' > work.txt
git add work.txt
git -c user.name="Harness Test" -c user.email="harness-test@example.invalid" \
  commit -q -m "second commit"
# No origin remote configured: git merge-base origin/main HEAD will fail.

g_approve_rc=0
./scripts/review-gate.sh approve >"${TMP_DIR}/approve-g.out" 2>&1 || g_approve_rc=$?
g_marker="${G_REPO}/.copilot-tracking/review-gate/approved-head"
g_head_sha="$(git rev-parse HEAD)"

if [ "$g_approve_rc" -ne 0 ]; then
  fail "Scenario G: approve must succeed even when origin/main is unavailable (rc=${g_approve_rc})"
  cat "${TMP_DIR}/approve-g.out" >&2
elif [ ! -f "$g_marker" ]; then
  fail "Scenario G: approve did not create marker file"
else
  g_line_count="$(wc -l < "$g_marker" | tr -d ' ')"
  g_line1="$(sed -n '1p' "$g_marker" | tr -d '[:space:]')"
  g_line2="$(sed -n '2p' "$g_marker" | tr -d '[:space:]')"

  if [ "$g_line_count" -ne 2 ]; then
    fail "Scenario G: expected 2-line marker, got ${g_line_count} line(s)"
  fi
  if [ "$g_line1" != "$g_head_sha" ]; then
    fail "Scenario G: line 1 '${g_line1}' != HEAD '${g_head_sha}'"
  fi
  if [ -n "$g_line2" ]; then
    fail "Scenario G: line 2 must be blank when origin/main is unavailable, got '${g_line2}'"
  fi
fi
cd "$_saved_dir"
emit "Scenario G: origin/main unavailable — approve succeeds, marker has 2 lines, line 2 is blank"

tap_done

(
cd "$ROOT"
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
  fixture_repo --with-scripts create-pr.sh,review-gate.sh,trace-lib.sh,check-trace-consistency.sh,issue-lib.sh
  git clone -q "$FIXTURE_REPO" "$dir"
  git -C "$dir" remote remove origin
  mkdir -p "${dir}/docs/evaluation"
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/"
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Progress\n\nbaseline\n' > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  git -C "$dir" add docs
  git -C "$dir" commit -q -m "add review fixture"
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
# (Wm) Canonical marker mismatch: carry refused, neither marker updated, no span.
#
# When the main-root marker's line 1 does not equal the expected pre-rebase SHA
# (another issue's approval may be active), carry must refuse without updating
# EITHER marker or emitting a carry span.
# ============================================================================
RWM_MAIN="${TMP_DIR}/rwm_main"
RWM_WT="${TMP_DIR}/rwm_wt"

make_pr_repo "$RWM_MAIN" 310
git -C "$RWM_MAIN" checkout -q main
git -C "$RWM_MAIN" worktree add -q "$RWM_WT" "feature/issue-310-fixture"
ln -sf "${RWM_MAIN}-origin.git" "${RWM_WT}-origin.git"
mkdir -p "${RWM_WT}/.copilot-tracking/issues/issue-310"
printf '# Progress\n\nwork\n' > "${RWM_WT}/.copilot-tracking/issues/issue-310/progress.md"

(cd "$RWM_WT" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh approve) \
  || fail "(Wm) setup: approve from linked worktree failed"
PRE_REBASE_HEAD_WM="$(git -C "$RWM_WT" rev-parse HEAD)"
WT_MARKER_WM="${RWM_WT}/.copilot-tracking/review-gate/approved-head"
MAIN_MARKER_WM="${RWM_MAIN}/.copilot-tracking/review-gate/approved-head"

# Set main-root marker to a DIFFERENT SHA (simulating another issue's active approval).
mkdir -p "$(dirname "$MAIN_MARKER_WM")"
FAKE_SHA_WM="aabbccdd11223344aabbccdd11223344aabbccdd"
printf '%s\n' "$FAKE_SHA_WM" > "$MAIN_MARKER_WM"

# Advance origin/main and manually rebase (so we can call carry directly).
advance_origin_main_unrelated "$RWM_WT"
(cd "$RWM_WT" && git rebase origin/main -q) || fail "(Wm) setup: rebase failed"

# Direct carry call: must refuse (exit non-zero) because canonical marker != expected.
CARRY_OUT_WM="${TMP_DIR}/wm-carry.out"
CARRY_RC_WM=0
(cd "$RWM_WT" && PATH="${BIN}:${PATH}" ./scripts/review-gate.sh carry-rebase-approval "$PRE_REBASE_HEAD_WM") \
  > "$CARRY_OUT_WM" 2>&1 || CARRY_RC_WM=$?
[ "$CARRY_RC_WM" -ne 0 ] \
  || { cat "$CARRY_OUT_WM"; fail "(Wm) carry must refuse when canonical main-root marker SHA != expected pre-rebase SHA"; }

# Worktree marker must be unchanged (still pre-rebase SHA, not post-rebase).
WT_LINE1_WM="$(sed -n '1p' "$WT_MARKER_WM" | tr -d '[:space:]')"
[ "$WT_LINE1_WM" = "$PRE_REBASE_HEAD_WM" ] \
  || fail "(Wm) worktree marker must remain pre-rebase SHA ${PRE_REBASE_HEAD_WM} after refused carry, got ${WT_LINE1_WM}"

# Main-root marker must be unchanged (still the fake SHA, not overwritten).
MAIN_LINE1_WM="$(sed -n '1p' "$MAIN_MARKER_WM" | tr -d '[:space:]')"
[ "$MAIN_LINE1_WM" = "$FAKE_SHA_WM" ] \
  || fail "(Wm) main-root marker must remain '${FAKE_SHA_WM}' after refused carry, got ${MAIN_LINE1_WM}"

# No carry span must have been emitted (EXIT trap skips span on rc != 0).
TRACE_WM="${RWM_MAIN}/.copilot-tracking/issues/issue-310/trace.jsonl"
if [ -f "$TRACE_WM" ] && command -v jq >/dev/null 2>&1; then
  CARRY_COUNT_WM="$(jq -rc 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "review_gate_approve" and .["harness.review_gate_carry"] == "patch-id")' "$TRACE_WM" | wc -l | tr -d ' ')"
  [ "$CARRY_COUNT_WM" = "0" ] \
    || fail "(Wm) no carry span must be emitted when carry is refused, got ${CARRY_COUNT_WM}"
fi

printf 'ok - (Wm) canonical marker mismatch: carry refused, neither marker updated, no carry span\n'
printf '
1..3
all carry-approval scenarios passed
'
)
