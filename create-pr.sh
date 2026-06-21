#!/usr/bin/env bash
# create-pr.sh — sync onto latest main, push, and open the PR.
#
# Codifies the "sync with main before opening the PR" rule as an action instead
# of leaving it to the agent's judgement: a branch cut from a stale base can pass
# local gates yet break against current main (or duplicate a fix already landed).
#
# Usage:
#   ./create-pr.sh --title "feat: ..." --body-file body.md
#   ./create-pr.sh --title "fix: ..."  --body "..."
#   ./create-pr.sh                       # PR already exists: just re-sync + push + watch
# Any extra args are passed straight through to `gh pr create`.
#
# Steps:
#   1. Refuse on main or a dirty tree.
#   2. git fetch origin main; rebase HEAD onto origin/main (abort cleanly on conflict).
#   3. Push the rebased branch (--force-with-lease — the issue branch is yours alone).
#   4. Open the PR (gh pr create) if none exists yet, passing through your args.
#
# Exit codes: 0 PR open · 1 precondition / conflict / PR creation failure

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" = "main" ] || [ "$branch" = "HEAD" ]; then
  red "✗ Refusing to open a PR from '${branch}'. Switch to your feature branch first."
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  red "✗ Working tree is dirty. Commit or stash before syncing onto main."
  git status --short
  exit 1
fi

# --- 1. Sync onto the latest main -------------------------------------------
bold "==> Syncing ${branch} onto latest origin/main"
git fetch origin main
if ! git rebase origin/main; then
  git rebase --abort || true
  red "✗ Rebase onto origin/main hit conflicts."
  echo "  Resolve them manually:"
  echo "    git rebase origin/main   # fix conflicts, git add, git rebase --continue"
  echo "  then re-run ./create-pr.sh"
  exit 1
fi
green "✓ ${branch} is now on top of origin/main ($(git rev-parse --short origin/main))"

# --- 2. Push (the issue branch is single-owner; rebase rewrote local history) -
bold "==> Pushing ${branch}"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git push --force-with-lease origin "$branch"
else
  git push -u origin "$branch"
fi
green "✓ Pushed"

# --- 3. Open the PR (if one doesn't already exist) --------------------------
pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -n "$pr_number" ]; then
  green "✓ PR #${pr_number} already exists — re-synced and pushed."
else
  bold "==> Opening PR"
  if [ "$#" -eq 0 ]; then
    red "✗ No PR exists yet and no gh pr create args were given."
    echo "  Re-run with: ./create-pr.sh --title \"…\" --body-file body.md"
    exit 1
  fi
  gh pr create "$@"
  pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
fi

green "✓ PR #${pr_number} is open."
