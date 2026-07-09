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
#   ./scripts/merge-pr.sh --squash --delete-branch   # extra FLAGS pass through to gh pr merge
#
# It takes NO PR number: the PR is resolved from the current worktree branch, so
# a positional arg (e.g. a bare PR number) is rejected to avoid merging the wrong PR.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
gh pr merge "$pr_number" "$@"
TRACE_STAGE="done"
green "✓ PR #${pr_number} merged."
