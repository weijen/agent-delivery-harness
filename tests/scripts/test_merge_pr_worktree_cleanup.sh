#!/usr/bin/env bash
# test_merge_pr_worktree_cleanup.sh — prove scripts/merge-pr.sh --delete-branch
# closes out cleanly from inside an issue worktree, with ZERO manual cleanup,
# even when `main` is checked out by the primary worktree (issue #167).
#
# Root cause being guarded: forwarding `--delete-branch` straight to
# `gh pr merge` makes gh try to switch the current worktree back to `main` so it
# can delete the merged local branch — which fails with
#   fatal: 'main' is already used by worktree at <main-checkout>
# leaving the local branch + worktree behind for the human. The fix strips
# `--delete-branch`/`-d` from the gh pass-through (so the REMOTE merge is never
# coupled to local cleanup) and then, in a decoupled warn-only block, deletes
# the remote branch and the local branch worktree-safely (detach HEAD first,
# then `git branch -D`), never checking out `main`.
#
# gh is faked (deterministic, no network / no real PR); the git repo, remote,
# and linked worktree are REAL so the worktree-safe local delete is exercised
# for real.
#
# Guards are mutation-tested by construction: the happy path asserts the local
# AND remote branch are gone, the primary `main` worktree is untouched, and no
# `already used by worktree` error surfaced; the decouple case asserts a remote
# cleanup failure never fails the merge and never blocks the local delete.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

MERGE_SCRIPT="${ROOT}/scripts/merge-pr.sh"
[ -f "$MERGE_SCRIPT" ] || fail "scripts/merge-pr.sh: No such file"

# Trace isolation (issue #216 pattern): merge-pr.sh emits a pr_merge lifecycle
# span via trace-lib. Keep TRACE_ISSUE unset and run merge-pr.sh from the
# throwaway fixture worktree below so any emitted span pins to THIS fixture's
# main root (its .gitignore'd .copilot-tracking/), never the developer's real
# .copilot-tracking/issues/issue-NN/trace.jsonl.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"

# Fake gh: pr view resolves a number, pr checks is green, pr merge records every
# arg it received to MERGE_SENTINEL (so the test can prove `--delete-branch` was
# stripped from the pass-through while `--squash` survived). No real merge is
# performed, so the local feature branch is left for merge-pr.sh itself to clean.
cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
  "pr view")   echo "${FAKE_PR_NUMBER:-167}"; exit 0 ;;
  "pr checks") printf 'harness-smoke\tpass\t1m\n'; exit 0 ;;
  "pr merge")  printf '%s\n' "$*" >> "${MERGE_SENTINEL:?}"; exit 0 ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${BIN}/gh"

FEATURE_BRANCH="feature/issue-167-worktree-cleanup-fixture"

# build_fixture DEST — a real repo with a bare `origin`, `main` in the primary
# checkout, and FEATURE_BRANCH pushed to origin and checked out in a LINKED
# worktree. Echoes the linked-worktree path on stdout.
build_fixture() {
  local dest="$1"
  local origin="${dest}.origin.git" primary="${dest}/primary" wt="${dest}/wt"
  git init -q --bare "$origin"
  git init -q -b main "$primary"
  (
    cd "$primary"
    git config user.name "Harness Test"
    git config user.email "harness-test@example.invalid"
    git config commit.gpgsign false
    printf '.copilot-tracking/\n' > .gitignore
    printf 'fixture\n' > README.md
    git add .gitignore README.md
    git commit -q -m initial
    git remote add origin "$origin"
    git push -q origin main
    git branch "$FEATURE_BRANCH"
    git push -q origin "$FEATURE_BRANCH"
    git worktree add -q "$wt" "$FEATURE_BRANCH"
  )
  printf '%s' "$wt"
}

# ---------------------------------------------------------------------------
# Case 1 — happy path: --squash --delete-branch from the linked worktree
# ---------------------------------------------------------------------------
F1="${TMP_DIR}/case1"
WT1="$(build_fixture "$F1")"
PRIMARY1="${F1}/primary"
SENT1="${TMP_DIR}/case1-merge.log"
: > "$SENT1"

ERR1="${TMP_DIR}/case1.err"
rc=0
out="$( (cd "$WT1" && MERGE_SENTINEL="$SENT1" PATH="${BIN}:${PATH}" \
  bash "$MERGE_SCRIPT" --squash --delete-branch) 2>"$ERR1")" || rc=$?
err="$(cat "$ERR1")"

[ "$rc" = "0" ] \
  || fail "closeout from a worktree must exit 0 (rc=${rc}); out=${out}; err=${err}"

# (c) The `main`-owned-by-another-worktree error must never surface.
printf '%s\n%s' "$out" "$err" | grep -Fq 'already used by worktree' \
  && fail "must not attempt to check out 'main' in a worktree another worktree owns"

# (b) Local feature branch is gone from the fixture repo.
if git -C "$PRIMARY1" show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
  fail "local feature branch must be deleted after --delete-branch closeout"
fi

# Remote feature branch is gone (checked via ls-remote from the primary so we
# never operate *inside* the bare repo, which safe.bareRepository would refuse).
remote_heads="$(git -C "$PRIMARY1" ls-remote --heads origin "refs/heads/${FEATURE_BRANCH}" 2>/dev/null || true)"
[ -z "$remote_heads" ] \
  || fail "remote feature branch must be deleted after --delete-branch closeout (still: ${remote_heads})"

# (d) The primary `main` worktree is untouched: still on branch main.
head1="$(git -C "$PRIMARY1" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
[ "$head1" = "main" ] \
  || fail "primary worktree must stay on 'main' (got: ${head1})"

# The remote merge must have been called, but `--delete-branch` must be stripped
# from the gh pass-through (that leg is the root cause); `--squash` must survive.
grep -q -- '--squash' "$SENT1" \
  || fail "gh pr merge must still receive pass-through flags like --squash (got: $(cat "$SENT1"))"
grep -q -- '--delete-branch' "$SENT1" \
  && fail "gh pr merge must NOT receive --delete-branch (the local-delete leg is the bug); got: $(cat "$SENT1")"

# ---------------------------------------------------------------------------
# Case 2 — decouple: a remote-cleanup failure must not fail the merge, and must
# not block the local delete. We drop the `origin` remote after building so the
# remote-branch delete cannot succeed; the merge + local delete must still win.
# ---------------------------------------------------------------------------
F2="${TMP_DIR}/case2"
WT2="$(build_fixture "$F2")"
PRIMARY2="${F2}/primary"
SENT2="${TMP_DIR}/case2-merge.log"
: > "$SENT2"
git -C "$PRIMARY2" remote remove origin
git -C "$WT2" remote remove origin 2>/dev/null || true

ERR2="${TMP_DIR}/case2.err"
rc2=0
out2="$( (cd "$WT2" && MERGE_SENTINEL="$SENT2" PATH="${BIN}:${PATH}" \
  bash "$MERGE_SCRIPT" --squash --delete-branch) 2>"$ERR2")" || rc2=$?
both2="$(printf '%s\n%s' "$out2" "$(cat "$ERR2")")"

[ "$rc2" = "0" ] \
  || fail "a remote-cleanup failure must NOT fail the merge (rc=${rc2}); ${both2}"

# The local delete still happened despite the remote-delete failure.
if git -C "$PRIMARY2" show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
  fail "local branch delete must not be blocked by a failed remote delete"
fi

# The user is warned (never silent) about the cleanup step that could not run.
printf '%s' "$both2" | grep -Eiq 'warn|could not|manually' \
  || fail "a cleanup step that could not run must WARN the user (got: ${both2})"

printf 'merge-pr worktree cleanup passed\n'
