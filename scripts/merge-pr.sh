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
#   ./scripts/merge-pr.sh                 # gate, then `gh pr merge` with no flags
#   ./scripts/merge-pr.sh --squash --delete-branch   # extra args pass through to gh pr merge
#
# Steps:
#   1. Resolve the PR for the current branch (refuse if none is open).
#   2. Run `gh pr checks` — refuse the merge unless every check concluded green.
#   3. `gh pr merge` (passing through any extra args).
#
# Exit codes: 0 merged · 1 no PR / checks are not green / merge failure
set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# --- 1. Resolve the PR ------------------------------------------------------
pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -z "$pr_number" ]; then
  red "✗ No open PR found for this branch. Open one first: ./scripts/create-pr.sh --title \"…\""
  exit 1
fi

# --- 2. Gate on green CI ----------------------------------------------------
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
bold "==> Merging PR #${pr_number}"
gh pr merge "$pr_number" "$@"
green "✓ PR #${pr_number} merged."
