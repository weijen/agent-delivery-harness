#!/usr/bin/env bash
# test_create_pr_no_rewrite.sh — regression sensor for issue #326 feature
# create-pr-no-rewrite-explicit.
#
# Contract under test:
#   CREATE_PR_NO_REWRITE=1 makes create-pr.sh skip `git rebase` entirely and
#   never rewrite local history:
#
#   (a) No sync needed (origin/main is already an ancestor of HEAD) → open
#       from the current tip: HEAD is unchanged before/after, the PR opens
#       (fake `gh pr create` runs), and the bare origin's ref for the branch
#       ends up equal to the pre-run local HEAD (a plain, non-force push).
#   (b) Sync needed, no conflict → merge origin/main in (never rebase). The
#       new merge HEAD requires a fresh review-gate approval: a first run
#       against the not-yet-approved merge HEAD exits non-zero with the
#       existing "has not been approved" message and pushes nothing. After
#       `review-gate.sh approve`, a second run succeeds: HEAD is a merge
#       commit (two parents) that contains origin/main as an ancestor, no
#       rebase-onto message is printed, the push carries no force flag, and
#       the PR opens.
#   (c) Merge conflict → `git merge origin/main` hits conflicts: the script
#       exits 1, names `git merge origin/main` as the manual recovery
#       command (mirroring the existing rebase-conflict message shape),
#       leaves a clean working tree (the conflicted merge is aborted), and
#       pushes nothing.
#
#   Static assertion: the default (CREATE_PR_NO_REWRITE unset) rebase call
#   stays present in scripts/create-pr.sh — this sensor only adds a branch,
#   it never removes the existing default preference.
#
# Fixture style mirrors test_create_pr_failure.sh / test_trace_create_pr.sh:
# real git, a real local bare `origin`, and a fake `gh` on PATH.
#
# Exit codes: 0 all three scenarios behave as contracted · 1 a regression.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Static assertion: default rebase call must still be present ------------
grep -q 'git rebase origin/main' "${ROOT}/scripts/create-pr.sh" \
  || fail "static: the default (unconditional-preference) 'git rebase origin/main' call must still be present in scripts/create-pr.sh"

# --- Restricted bin with a controllable fake gh ------------------------------
# `pr view` fails until `pr create` has run (state file); once state exists it
# answers number/url queries. `pr create` always succeeds and records the call.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git basename dirname mkdir rm cat sed tr cut grep printf date wc touch; do
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

# make_pr_repo <dir> <issue-pad> — feature/issue-<pad>-fixture on a bare
# origin. The feature commit updates docs/PROGRESS.md (status-doc gate) and
# conflict.txt (merge-conflict raw material, mirroring test_trace_create_pr.sh).
make_pr_repo() {
  local dir="$1" pad="$2"
  mkdir -p "${dir}/scripts" "${dir}/docs"
  cp "${ROOT}/scripts/create-pr.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/review-gate.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/" 2>/dev/null || true
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  printf 'base\n' > "${dir}/conflict.txt"
  git -C "$dir" add .gitignore README.md docs/PROGRESS.md conflict.txt scripts
  git -C "$dir" commit -q -m initial
  git clone -q --bare "$dir" "${dir}-origin.git"
  git -C "$dir" remote add origin "${dir}-origin.git"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$pad" > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs/PROGRESS.md
  git -C "$dir" commit -q -m "issue-${pad}: feature work"
  git -C "$dir" fetch -q origin main
}

# advance_origin_main_unrelated <dir> — push a same-file change to origin's
# main that does NOT collide with the branch's own commit (no conflict).
advance_origin_main_unrelated() {
  local dir="$1"
  local work="${dir}-mainwork"
  git clone -q "${dir}-origin.git" "$work"
  git -C "$work" config user.name "Harness Test"
  git -C "$work" config user.email "harness-test@example.invalid"
  printf 'unrelated\n' > "${work}/other.txt"
  git -C "$work" add other.txt
  git -C "$work" commit -q -m "main: unrelated change"
  git -C "$work" push -q origin main
  git -C "$dir" fetch -q origin main
}

# advance_origin_main_conflicting <dir> — push a conflicting change to
# origin's main (same line of conflict.txt the branch's commit did not
# touch, but the shared base did — a genuine 3-way merge conflict).
advance_origin_main_conflicting() {
  local dir="$1"
  local work="${dir}-mainwork"
  git clone -q "${dir}-origin.git" "$work"
  git -C "$work" config user.name "Harness Test"
  git -C "$work" config user.email "harness-test@example.invalid"
  printf 'mainline\n' > "${work}/conflict.txt"
  git -C "$work" add conflict.txt
  git -C "$work" commit -q -m "main: conflicting change"
  git -C "$work" push -q origin main
  git -C "$dir" fetch -q origin main
}

# run_cpr <dir> <state-suffix> <out-file> [env=val ...] -- <args...>
run_cpr() {
  local dir="$1" sfx="$2" out="$3"; shift 3
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  (cd "$dir" && env PATH="$BIN" GH_STATE="${TMP_DIR}/gh-state-${sfx}" "${envs[@]}" \
    ./scripts/create-pr.sh "$@") > "$out" 2>&1
}

# ============================================================================
# (a) No sync needed — CREATE_PR_NO_REWRITE=1 opens from the current tip
# ============================================================================
RA="${TMP_DIR}/ra"
make_pr_repo "$RA" 326
(cd "$RA" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(a) setup: approve failed"
HEAD_BEFORE_A="$(git -C "$RA" rev-parse HEAD)"
OUT_A="${TMP_DIR}/a.out"
run_cpr "$RA" a "$OUT_A" CREATE_PR_NO_REWRITE=1 -- --title t --body b \
  || { cat "$OUT_A"; fail "(a) create-pr.sh must exit 0 when no sync is needed"; }
HEAD_AFTER_A="$(git -C "$RA" rev-parse HEAD)"
[ "$HEAD_BEFORE_A" = "$HEAD_AFTER_A" ] \
  || fail "(a) HEAD must be unchanged (no rebase invoked) — before=${HEAD_BEFORE_A} after=${HEAD_AFTER_A}"
grep -q "is now on top of origin/main" "$OUT_A" \
  && fail "(a) the default rebase-success message must not print — git rebase must never be invoked in CREATE_PR_NO_REWRITE=1 mode: $(cat "$OUT_A")"
grep -q "PR #123 is open" "$OUT_A" \
  || { cat "$OUT_A"; fail "(a) the PR must open (fake gh pr create must have run)"; }
ORIGIN_REF_A="$(git --git-dir="${RA}-origin.git" rev-parse "refs/heads/feature/issue-326-fixture")"
[ "$ORIGIN_REF_A" = "$HEAD_BEFORE_A" ] \
  || fail "(a) origin's branch ref must equal the pre-run local HEAD (plain non-force push) — origin=${ORIGIN_REF_A} expected=${HEAD_BEFORE_A}"

# ============================================================================
# (b) Sync needed, no conflict — merges origin/main, never rebases
# ============================================================================
RB="${TMP_DIR}/rb"
make_pr_repo "$RB" 327
advance_origin_main_unrelated "$RB"
(cd "$RB" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(b) setup: approve failed"
OUT_B1="${TMP_DIR}/b1.out"
if run_cpr "$RB" b1 "$OUT_B1" CREATE_PR_NO_REWRITE=1 -- --title t --body b; then
  cat "$OUT_B1"; fail "(b) first run: create-pr.sh must exit non-zero — the new merge HEAD is not yet approved"
fi
grep -q "has not been approved" "$OUT_B1" \
  || { cat "$OUT_B1"; fail "(b) first run: must print the existing 'has not been approved' message unchanged"; }
git -C "$RB" ls-remote --heads origin "feature/issue-327-fixture" | grep -q . \
  && fail "(b) first run: nothing may be pushed before the merge HEAD is approved"
grep -q "is now on top of origin/main" "$OUT_B1" \
  && fail "(b) first run: the default rebase-success message must not print — git rebase must never be invoked in CREATE_PR_NO_REWRITE=1 mode: $(cat "$OUT_B1")"
HEAD_AFTER_MERGE_B="$(git -C "$RB" rev-parse HEAD)"
PARENT_COUNT_B="$(git -C "$RB" show -s --format='%P' HEAD | wc -w | tr -d '[:space:]')"
[ "$PARENT_COUNT_B" = "2" ] \
  || fail "(b) after the first run HEAD must already be a merge commit (two parents), got ${PARENT_COUNT_B}"
git -C "$RB" merge-base --is-ancestor origin/main HEAD \
  || fail "(b) after the first run origin/main must be an ancestor of the merge HEAD"

(cd "$RB" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(b) setup: approve of the merge HEAD failed"
OUT_B2="${TMP_DIR}/b2.out"
run_cpr "$RB" b2 "$OUT_B2" CREATE_PR_NO_REWRITE=1 -- --title t --body b \
  || { cat "$OUT_B2"; fail "(b) second run: create-pr.sh must exit 0 once the merge HEAD is approved"; }
[ "$(git -C "$RB" rev-parse HEAD)" = "$HEAD_AFTER_MERGE_B" ] \
  || fail "(b) second run: HEAD must not move again (still the same merge commit, never rebased)"
grep -q "is now on top of origin/main" "$OUT_B2" \
  && fail "(b) second run: the default rebase-success message must not print — git rebase must never be invoked in CREATE_PR_NO_REWRITE=1 mode: $(cat "$OUT_B2")"
grep -q "PR #123 is open" "$OUT_B2" \
  || { cat "$OUT_B2"; fail "(b) second run: the PR must open (fake gh pr create must have run)"; }
ORIGIN_REF_B="$(git --git-dir="${RB}-origin.git" rev-parse "refs/heads/feature/issue-327-fixture")"
[ "$ORIGIN_REF_B" = "$HEAD_AFTER_MERGE_B" ] \
  || fail "(b) second run: origin's branch ref must equal the merge HEAD (plain non-force push) — origin=${ORIGIN_REF_B} expected=${HEAD_AFTER_MERGE_B}"

# ============================================================================
# (c) Merge conflict — aborts cleanly, no force, nothing pushed
# ============================================================================
RC="${TMP_DIR}/rc"
make_pr_repo "$RC" 328
printf 'feature\n' > "${RC}/conflict.txt"
git -C "$RC" add conflict.txt
git -C "$RC" commit -q -m "issue-328: touch conflict.txt on the branch"
advance_origin_main_conflicting "$RC"
(cd "$RC" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(c) setup: approve failed"
OUT_C="${TMP_DIR}/c.out"
if run_cpr "$RC" c "$OUT_C" CREATE_PR_NO_REWRITE=1 -- --title t --body b; then
  cat "$OUT_C"; fail "(c) create-pr.sh must exit non-zero on a merge conflict"
fi
grep -q "hit conflicts" "$OUT_C" \
  || { cat "$OUT_C"; fail "(c) must print a 'hit conflicts' message (mirroring the rebase-conflict shape)"; }
grep -q "git merge origin/main" "$OUT_C" \
  || { cat "$OUT_C"; fail "(c) must name 'git merge origin/main' as the manual recovery command"; }
[ -z "$(git -C "$RC" status --porcelain)" ] \
  || fail "(c) working tree must be clean afterward (the conflicted merge must be aborted): $(git -C "$RC" status --porcelain)"
git -C "$RC" ls-remote --heads origin "feature/issue-328-fixture" | grep -q . \
  && fail "(c) nothing may be pushed on a merge conflict"

printf 'create-pr no-rewrite sensor passed\n'
