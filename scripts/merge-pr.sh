#!/usr/bin/env bash
# merge-pr.sh — verify the PR's CI checks concluded green, then merge.
#
# A green remote CI run is a HARD precondition for merge. This script is the one
# place that enforces it: it resolves the PR for the current branch, confirms its
# required checks have concluded successfully, and only then merges. It is
# conductor-invoked — this is NOT GitHub auto-merge, and it never disables a
# required check or merges past a red/pending run.
#
# Usage:
#   ./scripts/merge-pr.sh -h|--help       # print this usage and exit 0 —
#                                          # side-effect free: no gh call, no merge
#   ./scripts/merge-pr.sh                 # gate, then `gh pr merge` with no flags
#   ./scripts/merge-pr.sh --squash --delete-branch   # extra FLAGS pass through to gh pr merge
#
# It takes NO PR number: the PR is resolved from the current worktree branch, so
# a positional arg (e.g. a bare PR number) is rejected to avoid merging the wrong PR.
#
# Steps:
#   1. Resolve the PR for the current branch (refuse if none is open).
#   2. Run `gh pr checks` — refuse the merge unless every check concluded green.
#   3. `gh pr merge` (passing through any extra args EXCEPT --delete-branch/-d).
#   4. If deletion was requested, clean up the branch worktree-safely.
#
# Branch deletion is worktree-safe and decoupled (issue #167): `--delete-branch`
# is NOT forwarded to `gh pr merge`, because gh would try to switch the current
# worktree back to `main` to delete the merged local branch — which fails with
# `'main' is already used by worktree` when the primary worktree owns `main`,
# leaving cleanup for the human. Instead the REMOTE merge runs alone (so its
# success is never coupled to local cleanup), and only after it succeeds does a
# warn-only block delete the remote branch and then the local branch — detaching
# HEAD in the current worktree first so no `main` checkout is ever attempted. A
# cleanup failure warns with a follow-up command; it never fails the merge.
#
# Exit codes: 0 merged · 1 no PR / checks are not green / merge failure. A
#             post-merge cleanup failure warns but keeps exit 0 (the merge won).
set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Help guard (issue #328) --------------------------------------------------
# -h/--help must exit 0 before ANY side effect (PR resolution, `gh pr checks`,
# `gh pr merge`, branch cleanup, or trace span emission) — scanned across all
# of $@, and placed before the trace-lib.sh guarded-source block below (and
# thus before trace_lifecycle_init) so no pr_merge span is ever armed for a
# help request.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/merge-pr.sh [FLAGS...]

Verify the current branch's open PR has green CI checks, then merge it. Takes
NO PR number — the PR is resolved from the current worktree branch. Any
argument other than -h/--help is a pass-through flag forwarded to `gh pr
merge` (run `gh pr merge --help` for its own flag surface), EXCEPT
--delete-branch/-d, which this script handles itself, worktree-safely, after a
successful merge.

Examples:
  ./scripts/merge-pr.sh
  ./scripts/merge-pr.sh --squash --delete-branch
EOF
      exit 0
      ;;
  esac
done

# --- Tracing (issue #94, plan D5) --------------------------------------------
# Guarded source: a missing trace-lib.sh must never break the merge gate. The
# script runs inside the issue worktree, so trace-lib resolves the issue from
# the feature/issue-NN-* branch and pins the trace to the MAIN root (plan D1).
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi
if ! declare -F trace_span >/dev/null 2>&1; then
  TRACE_NOOP_WARNED=0
  trace_span() {
    if [ "${TRACE_NOOP_WARNED}" = "0" ]; then
      printf 'merge-pr: warning: scripts/trace-lib.sh not found — trace spans disabled\n' >&2
      TRACE_NOOP_WARNED=1
    fi
    return 0
  }
  trace_now_ms() { printf '%s000' "$(date +%s 2>/dev/null || printf '0')"; }
  trace_lifecycle_init() { :; }
  trace_lifecycle_arm() { :; }
fi

# Exactly ONE pr_merge lifecycle terminal span per invocation via the shared
# EXIT-trap helper (issue #213 P-1, trace_lifecycle_init). TRACE_STAGE names the
# last stage reached (resolve_pr|ci_checks|merge|done), surfaced as harness.stage
# by the attr callback; the trap is armed only once the stray-positional-arg
# refusal has passed, so that usage refusal emits nothing.
TRACE_STAGE=""
pr_number=""
trace__merge_pr_attrs() {
  printf 'harness.stage=%s\n' "${TRACE_STAGE}"
  [ -n "$pr_number" ] && printf 'harness.pr_number=%s\n' "${pr_number}"
}
trace_lifecycle_init pr_merge trace__merge_pr_attrs

# --- 0. Reject stray positional args ----------------------------------------
# This script resolves the target PR from the CURRENT worktree branch (below),
# so a non-flag positional arg — e.g. a bare PR number like `73` — never selects
# a PR; it would only leak through to `gh pr merge`. Refuse it before any merge
# so a mistaken arg cannot contribute to merging the wrong PR. Only pass-through
# flags (starting with `-`) are allowed.
for arg in "$@"; do
  case "$arg" in
    -*) : ;;  # a flag — forwarded to gh pr merge
    *)
      red "✗ Refusing to run: unexpected positional argument '${arg}'."
      echo "  merge-pr.sh merges the PR for the CURRENT worktree branch; it does not take a PR number."
      echo "  cd into the target issue's worktree and pass only flags, e.g.:"
      echo "    ./scripts/merge-pr.sh --squash --delete-branch"
      exit 1
      ;;
  esac
done

# --- 0b. Split off branch-deletion from the gh pass-through (issue #167) -----
# `--delete-branch`/`-d` is NOT forwarded to `gh pr merge`: gh would try to
# switch the current worktree back to `main` to delete the merged local branch,
# which fails when the primary worktree owns `main`. We keep every OTHER flag as
# the gh pass-through and perform the deletion ourselves, worktree-safely, only
# after the remote merge has succeeded (§4).
DELETE_BRANCH_REQUESTED=0
MERGE_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --delete-branch | --delete-branch=* | -d) DELETE_BRANCH_REQUESTED=1 ;;
    *) MERGE_FLAGS+=("$arg") ;;
  esac
done

# --- 1. Resolve the PR ------------------------------------------------------
TRACE_STAGE="resolve_pr"
trace_lifecycle_arm
pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -z "$pr_number" ]; then
  red "✗ No open PR found for this branch. Open one first: ./scripts/create-pr.sh --title \"…\""
  exit 1
fi

# --- 2. Gate on green CI ----------------------------------------------------
TRACE_STAGE="ci_checks"
bold "==> Verifying CI checks for PR #${pr_number}"
checks_out="$(gh pr checks "$pr_number" 2>&1)" && checks_rc=0 || checks_rc=$?
if [ "$checks_rc" -ne 0 ]; then
  printf '%s\n' "$checks_out"
  red "✗ Refusing to merge PR #${pr_number}: required CI checks are not green (still pending or failing)."
  echo "  Wait for the harness CI run to conclude green, then re-run ./scripts/merge-pr.sh."
  exit 1
fi
# A zero exit with no reported checks is NOT green — `gh pr checks` exits 0 when a
# PR has no check runs at all (e.g. the workflow never registered). Refuse so the
# gate cannot be bypassed by an absent CI run.
if [ -z "${checks_out//[[:space:]]/}" ]; then
  red "✗ Refusing to merge PR #${pr_number}: no CI checks were reported, so the checks are not green."
  echo "  Ensure the harness CI workflow ran on this PR before merging."
  exit 1
fi
green "✓ CI checks are green for PR #${pr_number}"

# --- 3. Merge ---------------------------------------------------------------
TRACE_STAGE="merge"
bold "==> Merging PR #${pr_number}"
gh pr merge "$pr_number" ${MERGE_FLAGS[@]+"${MERGE_FLAGS[@]}"}
TRACE_STAGE="done"
green "✓ PR #${pr_number} merged."

# --- 4. Worktree-safe, decoupled branch cleanup (issue #167) ----------------
# Reached ONLY after a successful merge, so remote-merge success is never masked
# by a local-cleanup failure. Each step warns (never `exit`s) and prints a
# follow-up command; a failure here keeps the overall exit at 0. We temporarily
# lift `set -e` so a single failed cleanup git call cannot abort the block.
if [ "$DELETE_BRANCH_REQUESTED" = "1" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    yellow "! Skipping branch cleanup: current worktree HEAD is not on a named branch."
  else
    bold "==> Cleaning up branch ${branch} (worktree-safe)"
    set +e

    # Remote branch: gh may have server-side auto-deleted the head on merge; if
    # not, delete it here. A failure (branch already gone, protected, offline)
    # only warns — it never blocks the local delete or fails the merge.
    if push_err="$(git push origin --delete "$branch" 2>&1)"; then
      green "✓ Deleted remote branch ${branch}"
    else
      yellow "! Could not delete remote branch ${branch}: ${push_err}"
      echo "  If it lingers, remove it with: git push origin --delete ${branch}"
    fi

    # Local branch: detach the CURRENT worktree's HEAD FIRST so the branch is no
    # longer checked out anywhere, then force-delete it. This never checks out
    # `main`, so it cannot collide with the primary worktree that owns `main`.
    # The worktree is left in a safe detached state (finish-issue removes it).
    if git checkout --detach --quiet 2>/dev/null; then
      if git branch -D "$branch" >/dev/null 2>&1; then
        green "✓ Deleted local branch ${branch} (worktree now detached)"
      else
        yellow "! Could not delete local branch ${branch}."
        echo "  Delete it from the main checkout with: git branch -D ${branch}"
      fi
    else
      yellow "! Could not detach HEAD to delete local branch ${branch} safely."
      echo "  From the main checkout run: git branch -D ${branch}"
    fi

    set -e
  fi
fi
