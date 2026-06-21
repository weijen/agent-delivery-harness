#!/usr/bin/env bash
# check-pr.sh — watch the CI checks for a PR and surface failures.
#
# Usage:
#   ./check-pr.sh            # the PR for the current branch
#   ./check-pr.sh 42         # an explicit PR number
#
# Behaviour (the post-PR CI loop from harness §6, mechanised):
#   1. Resolve the PR (arg or the current branch's PR).
#   2. Watch its checks to completion (gh pr checks --watch).
#   3. On failure, print the failing run's logs (gh run view --log-failed) so the
#      agent can analyse, fix, re-push, and re-run this script.
#
# Exit codes: 0 all checks green · 1 a check failed / no PR found
#
# This script never merges. Merging stays a deliberate step taken only after this
# reports green (harness §6 — no standing auto-merge).

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

PR_ARG="${1:-}"

# --- Resolve the PR number --------------------------------------------------
if [ -n "$PR_ARG" ]; then
  PR="$PR_ARG"
else
  PR="$(gh pr view --json number -q .number 2>/dev/null || true)"
  if [ -z "$PR" ]; then
    red "✗ No PR found for the current branch. Open one first, or pass a PR number."
    exit 1
  fi
fi

bold "==> Watching CI checks for PR #${PR}"

# --- Watch checks to completion ---------------------------------------------
# `gh pr checks --watch` blocks until every check finishes, exiting non-zero if
# any required check fails.
if gh pr checks "$PR" --watch; then
  green "✓ All required checks passed for PR #${PR}."
  echo "  CI is green — you may now merge (manually; no standing auto-merge)."
  exit 0
fi

# --- A check failed: surface the failing logs -------------------------------
red "✗ CI failed for PR #${PR}."
echo

branch="$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null || true)"
run_id=""
if [ -n "$branch" ]; then
  run_id="$(gh run list --branch "$branch" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
fi

if [ -n "$run_id" ]; then
  bold "==> Failing logs (gh run view ${run_id} --log-failed)"
  gh run view "$run_id" --log-failed || true
  echo
  echo "Full run: $(gh run view "$run_id" --json url -q .url 2>/dev/null || echo "see GitHub Actions")"
else
  echo "Inspect the failing checks on GitHub:"
  gh pr checks "$PR" || true
fi

echo
red "Next: analyse the failure, fix the root cause, commit, push, then re-run ./check-pr.sh ${PR}"
exit 1
