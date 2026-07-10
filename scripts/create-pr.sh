#!/usr/bin/env bash
# create-pr.sh — sync onto latest main, push, and open the PR.
#
# Codifies the "sync with main before opening the PR" rule as an action instead
# of leaving it to the agent's judgement: a branch cut from a stale base can pass
# local gates yet break against current main (or duplicate a fix already landed).
#
# Usage:
#   ./scripts/create-pr.sh --title "feat: ..." --body-file body.md
#   ./scripts/create-pr.sh --title "fix: ..."  --body "..."
#   ./scripts/create-pr.sh                       # PR already exists: just re-sync + push
# Any extra args are passed straight through to `gh pr create`.
#
# Steps:
#   1. Refuse on main or a dirty tree.
#   2. Require review approval for the current HEAD before syncing.
#   3. git fetch origin main; rebase HEAD onto origin/main (abort cleanly on conflict).
#   4. Require review approval for the final post-sync HEAD.
#   5. Push the rebased branch (--force-with-lease — the issue branch is yours alone).
#   6. Open the PR (gh pr create) if none exists yet, passing through your args.
#
# Exit codes: 0 PR open · 1 precondition / conflict / PR creation failure

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
TRACE_STAGE="rebase"
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

# --- 3. Review approval for the final HEAD ----------------------------------
TRACE_STAGE="post_sync_gate"
"$(dirname "${BASH_SOURCE[0]}")/review-gate.sh" check

# --- 4. Push (the issue branch is single-owner; rebase rewrote local history) -
TRACE_STAGE="push"
bold "==> Pushing ${branch}"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git push --force-with-lease origin "$branch"
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
  gh pr create "$@"
  pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
fi

# --- 6. Optional mid-issue log export (issue #220) --------------------------
# The closeout log ship (best_effort_log_export in finish-lib.sh) only fires at
# teardown. This is an EARLIER, opt-in ship: when a PR is opened, push the
# issue's logs to Azure Monitor so they are available before finish-issue runs.
# It is behind its OWN flag and requires the connection secret too, and is
# strictly best-effort — a missing or failing exporter must never break PR
# creation (mirrors the guarded trace-lib source above).
if [ "${CREATE_PR_LOG_EXPORT:-}" = "1" ] \
  && [ -n "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}" ]; then
  ISSUE_NUM=""
  if [[ "$branch" =~ ^feature/issue-([0-9]+)- ]]; then
    ISSUE_NUM="$((10#${BASH_REMATCH[1]}))"
  fi
  if [ -z "$ISSUE_NUM" ]; then
    red "⚠ log export skipped: cannot resolve issue number from branch '${branch}'"
  elif [ ! -x "${SCRIPT_DIR}/log-export.sh" ]; then
    red "⚠ log export skipped: scripts/log-export.sh not executable"
  else
    if "${SCRIPT_DIR}/log-export.sh" "$ISSUE_NUM"; then
      green "✓ Exported log for issue ${ISSUE_NUM}"
    else
      red "⚠ log export failed — continuing (best-effort, PR creation not blocked)"
    fi
  fi
fi

TRACE_STAGE="done"
green "✓ PR #${pr_number} is open."
