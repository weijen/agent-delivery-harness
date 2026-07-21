#!/usr/bin/env bash
# create-pr.sh — sync onto latest main, push, and open the PR.
#
# Codifies the "sync with main before opening the PR" rule as an action instead
# of leaving it to the agent's judgement: a branch cut from a stale base can pass
# local gates yet break against current main (or duplicate a fix already landed).
#
# Usage:
#   ./scripts/create-pr.sh -h|--help          # print this usage and exit 0 —
#                                              # side-effect free: no git/gh call
#   ./scripts/create-pr.sh --title "feat: ..." --body-file body.md
#   ./scripts/create-pr.sh --title "fix: ..."  --body "..."
#   ./scripts/create-pr.sh                       # PR already exists: just re-sync + push
# Any extra args are passed straight through to `gh pr create`.
#
# Steps:
#   1. Refuse on main or a dirty tree.
#   2. Require review approval for the current HEAD before syncing.
#   3. git fetch origin main; rebase HEAD onto origin/main (abort cleanly on conflict) —
#      unless CREATE_PR_NO_REWRITE=1, which skips rebase entirely: open from the
#      current tip when origin/main is already an ancestor of HEAD, or merge
#      origin/main in (abort cleanly on conflict) when a sync is needed.
#   4. Require review approval for the final post-sync HEAD, but only when the
#      sync actually moved HEAD (CREATE_PR_NO_REWRITE=1 with nothing to merge
#      never re-checks — HEAD never changed since the pre-sync approval).
#   5. Push the branch — --force-with-lease after a rebase (the issue branch is
#      yours alone), or a plain push after CREATE_PR_NO_REWRITE=1 (fast-forward-safe
#      by construction: a merge's first parent is the remote's own prior tip).
#   6. Open the PR (gh pr create) if none exists yet, passing through your args.
#
# Exit codes: 0 PR open (or usage printed) · 1 precondition / conflict / PR creation failure

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Help guard (issue #328) --------------------------------------------------
# -h/--help must exit 0 before ANY side effect (review-gate check, git fetch,
# git rebase, git push, gh call, or trace span emission) — scanned across all
# of $@, and placed before the trace-lib.sh guarded-source block below so no
# pr_create span is ever armed for a help request.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/create-pr.sh [--title TITLE] [--body BODY | --body-file FILE] [gh pr create args...]

Sync the current branch onto latest main, push it, and open (or re-sync) its
PR. Any argument other than -h/--help is passed straight through to
`gh pr create` (run `gh pr create --help` for its own flags). With no
PR-creation args and no existing PR, re-run with e.g.
--title "…" --body-file body.md.
EOF
      exit 0
      ;;
  esac
done

# --- Tracing (issue #94, plan D5) --------------------------------------------
# Guarded source: a missing trace-lib.sh must never break PR creation. The
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
      printf 'create-pr: warning: scripts/trace-lib.sh not found — trace spans disabled\n' >&2
      TRACE_NOOP_WARNED=1
    fi
    return 0
  }
  trace_now_ms() { printf '%s000' "$(date +%s 2>/dev/null || printf '0')"; }
  trace_lifecycle_init() { :; }
  trace_lifecycle_arm() { :; }
fi

# Exactly ONE pr_create lifecycle terminal span per invocation via the shared
# EXIT-trap helper (issue #213 P-1, trace_lifecycle_init). TRACE_STAGE names the
# last stage reached (preconditions|review_gate|rebase|post_sync_gate|push|
# pr_create|done) and is surfaced as harness.stage by the attr callback; the
# trap is armed only once past the on-main refusal, where a feature branch —
# and therefore a resolvable issue — exists, so that refusal emits nothing.
TRACE_STAGE=""
pr_number=""
trace__create_pr_attrs() {
  printf 'harness.stage=%s\n' "${TRACE_STAGE}"
  printf 'harness.branch=%s\n' "${branch:-}"
  [ -n "$pr_number" ] && printf 'harness.pr_number=%s\n' "${pr_number}"
}
trace_lifecycle_init pr_create trace__create_pr_attrs

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" = "main" ] || [ "$branch" = "HEAD" ]; then
  red "✗ Refusing to open a PR from '${branch}'. Switch to your feature branch first."
  exit 1
fi
TRACE_STAGE="preconditions"
trace_lifecycle_arm
if [ -n "$(git status --porcelain)" ]; then
  red "✗ Working tree is dirty. Commit or stash before syncing onto main."
  git status --short
  exit 1
fi

# --- 1. Review approval gate ------------------------------------------------
TRACE_STAGE="review_gate"
"$(dirname "${BASH_SOURCE[0]}")/review-gate.sh" check

# --- 2. Sync onto the latest main -------------------------------------------
# CREATE_PR_NO_REWRITE=1 is the explicit, proactive non-rewriting mode (issue
# #326): rebase stays the unconditional DEFAULT preference below; setting the
# flag skips it entirely instead of ever calling `git rebase`.
CREATE_PR_NO_REWRITE="${CREATE_PR_NO_REWRITE:-0}"
TRACE_STAGE="rebase"
sync_mode="rebase"
if [ "$CREATE_PR_NO_REWRITE" = "1" ]; then
  bold "==> CREATE_PR_NO_REWRITE=1 — skipping rebase (non-rewriting mode)"
  git fetch origin main
  if git merge-base --is-ancestor origin/main HEAD; then
    sync_mode="none"
    green "✓ ${branch} already contains latest origin/main ($(git rev-parse --short origin/main)) — opening from current tip"
  elif git merge --no-edit origin/main; then
    sync_mode="merge"
    green "✓ ${branch} merged latest origin/main ($(git rev-parse --short origin/main)) — no history rewritten"
  else
    git merge --abort || true
    red "✗ Merging origin/main hit conflicts (non-rewriting mode)."
    echo "  Resolve them manually:"
    echo "    git merge origin/main   # fix conflicts, git add, git commit"
    echo "  then re-run CREATE_PR_NO_REWRITE=1 ./scripts/create-pr.sh"
    exit 1
  fi
else
  bold "==> Syncing ${branch} onto latest origin/main"
  git fetch origin main
  if ! git rebase origin/main; then
    git rebase --abort || true
    red "✗ Rebase onto origin/main hit conflicts."
    echo "  Resolve them manually:"
    echo "    git rebase origin/main   # fix conflicts, git add, git rebase --continue"
    echo "  then re-run ./scripts/create-pr.sh"
    exit 1
  fi
  green "✓ ${branch} is now on top of origin/main ($(git rev-parse --short origin/main))"
fi

# --- 3. Review approval for the final HEAD ----------------------------------
# Only re-checked when HEAD actually moved: a no-op non-rewriting sync
# (sync_mode=none) never rewrites or advances HEAD, so the pre-sync approval
# above still covers it — re-checking would just repeat the same comparison.
TRACE_STAGE="post_sync_gate"
if [ "$sync_mode" != "none" ]; then
  "$(dirname "${BASH_SOURCE[0]}")/review-gate.sh" check
fi

# --- 4. Push -----------------------------------------------------------------
# --force-with-lease only after a rebase rewrote local history (the issue
# branch is single-owner); a non-rewriting sync (merge, or nothing to sync)
# pushes plain — fast-forward-safe by construction, since a merge's first
# parent is the remote's own prior tip.
TRACE_STAGE="push"
bold "==> Pushing ${branch}"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  if [ "$sync_mode" = "rebase" ]; then
    git push --force-with-lease origin "$branch"
  else
    git push origin "$branch"
  fi
else
  git push -u origin "$branch"
fi
green "✓ Pushed"

# --- 5. Open the PR (if one doesn't already exist) --------------------------
TRACE_STAGE="pr_create"
pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -n "$pr_number" ]; then
  green "✓ PR #${pr_number} already exists — re-synced and pushed."
else
  bold "==> Opening PR"
  if [ "$#" -eq 0 ]; then
    red "✗ No PR exists yet and no gh pr create args were given."
    echo "  Re-run with: ./scripts/create-pr.sh --title \"…\" --body-file body.md"
    exit 1
  fi
  gh pr create "$@" || {
    red "✗ gh pr create failed — the PR was not opened."
    echo "  Check your GitHub auth/network and re-run once resolved:"
    echo "    ./scripts/create-pr.sh --title \"…\" --body-file body.md"
    exit 1
  }
  pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
fi

if [ -z "$pr_number" ]; then
  red "✗ PR opened but its number could not be resolved."
  echo "  Check GitHub manually to confirm the PR state: gh pr view --web"
  exit 1
fi

TRACE_STAGE="done"
green "✓ PR #${pr_number} is open."
