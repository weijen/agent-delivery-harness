#!/usr/bin/env bash
# finish-issue.sh — tear down the worktree for an issue after its PR is merged.
#
# Usage:
#   ./scripts/finish-issue.sh 1
#   ./scripts/finish-issue.sh ISSUE=1
#   ./scripts/finish-issue.sh ISSUE=1 SLUG=custom-slug   # if the slug can't be derived
#
# Removes <repo>-worktrees/issue-NN and prunes worktree metadata. By default it
# REFUSES when the worktree has uncommitted changes (override with FORCE=1) and
# leaves the local branch in place (delete it with DELETE_BRANCH=1).
#
# The per-issue .copilot-tracking/issues/issue-NN/ dir is intentionally left
# alone — it is gitignored local history.
#
# Exit codes: 0 cleaned · 1 usage / refused

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

# --- Tracing (issue #94, plan D5) --------------------------------------------
# Guarded source: a missing trace-lib.sh must never break teardown.
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi
if ! declare -F trace_span >/dev/null 2>&1; then
  TRACE_NOOP_WARNED=0
  trace_span() {
    if [ "${TRACE_NOOP_WARNED}" = "0" ]; then
      printf 'finish-issue: warning: scripts/trace-lib.sh not found — trace spans disabled\n' >&2
      TRACE_NOOP_WARNED=1
    fi
    return 0
  }
  trace_now_ms() { printf '%s000' "$(date +%s 2>/dev/null || printf '0')"; }
fi

# Terminal `finish` lifecycle span via a stage-tracked EXIT trap (plan D3).
# It fires AFTER `git worktree remove` — the span survives teardown only
# because trace-lib pins the trace file to the MAIN checkout root (plan D1).
# TRACE_STAGE names the last stage reached (completion_check|trace_gate|
# worktree_remove|branch_delete|done); refusals before the completion check
# emit nothing.
TRACE_STAGE=""
TRACE_T0=0
WORKTREE_REMOVED=false
BRANCH_DELETED=false
trace__finish_exit() {
  local rc=$?
  if [ -n "$TRACE_STAGE" ]; then
    local outcome=pass
    if [ "$rc" -ne 0 ]; then
      outcome=fail
    fi
    trace_span lifecycle \
      "harness.lifecycle_step=finish" \
      "harness.outcome=${outcome}" \
      "harness.exit_status=${rc}" \
      "harness.duration_ms=$(( $(trace_now_ms) - TRACE_T0 ))" \
      "harness.stage=${TRACE_STAGE}" \
      "harness.branch=${BRANCH:-}" \
      "harness.worktree_removed=${WORKTREE_REMOVED}" \
      "harness.branch_deleted=${BRANCH_DELETED}"
  fi
  exit "$rc"
}
trap trace__finish_exit EXIT

# --- Parse args -------------------------------------------------------------
NUM_ARG="" SLUG_ARG=""
for arg in "$@"; do
  case "$arg" in
    SLUG=*) SLUG_ARG="${arg#SLUG=}" ;;
    *)      NUM_ARG="$arg" ;;
  esac
done
if [ -z "$NUM_ARG" ]; then
  red "usage: ./scripts/finish-issue.sh <issue-number> [SLUG=custom-slug] [DELETE_BRANCH=1] [FORCE=1]"
  exit 1
fi
ISSUE_NUM="$(issue_parse_number "$NUM_ARG")"

# finish-issue runs from the main checkout on branch main, so branch/worktree
# issue resolution cannot work — export the parsed number (plan D6).
export TRACE_ISSUE="$ISSUE_NUM"

ROOT="$(issue_repo_root)"
cd "$ROOT"

# Operate from the main checkout — you cannot remove the worktree you stand in.
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  red "✗ run finish-issue.sh from the main checkout, not from a worktree."
  exit 1
fi

resolve_issue_env "$ISSUE_NUM" "$SLUG_ARG"

check_feature_completion() {
  local feature_list="${TRACKING_DIR}/feature_list.json"
  # Closeout stays tolerant of a missing tracking file (it is gitignored local
  # state); the standalone check-feature-list.sh enforces presence when invoked
  # directly. When the file exists, delegate structural + completion validation
  # to the shared sensor so the two paths cannot drift apart.
  if [ ! -f "$feature_list" ]; then
    return 0
  fi
  "${SCRIPT_DIR}/check-feature-list.sh" "$ISSUE_NUM"
}

# Best-effort closeout trace export (issue #144). Ships the issue's spans to
# Azure Monitor ONLY when explicitly configured (opt-in flag + connection
# string). It ALWAYS returns 0: a missing/failing exporter must never change
# finish-issue's exit code or block teardown. It reads the MAIN-checkout trace
# file (which survives worktree removal), so it runs AFTER the worktree is gone.
best_effort_trace_export() {
  [ "${TRACE_EXPORT_OTLP:-}" = "1" ] || return 0
  [ -n "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}" ] || return 0
  if [ ! -x "${SCRIPT_DIR}/trace-export.sh" ]; then
    yellow "⚠ trace export skipped: scripts/trace-export.sh not executable"
    return 0
  fi
  local rc=0
  "${SCRIPT_DIR}/trace-export.sh" "$ISSUE_NUM" || rc=$?
  if [ "$rc" -ne 0 ]; then
    yellow "⚠ trace export failed (exit ${rc}) — continuing teardown (best-effort)"
  else
    green "✓ Exported trace for issue ${ISSUE_NUM}"
  fi
  return 0
}

# The worktree's own checked-out branch is the deterministic source of truth —
# prefer it over a slug recomputed from the (mutable) issue title.
if [ -e "$WORKTREE_DIR" ]; then
  wt_branch="$(git -C "$WORKTREE_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -n "$wt_branch" ] && BRANCH="$wt_branch"
fi

bold "==> Finishing issue ${ISSUE_NUM}"
echo "  branch:   ${BRANCH}"
echo "  worktree: ${WORKTREE_DIR}"

TRACE_T0="$(trace_now_ms)"
TRACE_STAGE="completion_check"
check_feature_completion

# --- Two-phase trace gate (issue #103, feature trace-gate-two-phase) ---------
# Run the trace gate BEFORE teardown, mirroring the REQUIRE_FEATURES_COMPLETE
# pattern: warn-only by default (findings print, teardown proceeds); under
# REQUIRE_TRACE_CONSISTENCY=1 findings turn into a refusal BEFORE
# worktree_remove, leaving the worktree intact. TRACE_ISSUE is already
# exported above, so the gate resolves the right issue from the main
# checkout. A missing review-gate.sh degrades to a warn-and-skip — the gate
# never breaks teardown on a checkout that predates the trace tooling.
TRACE_STAGE="trace_gate"
if [ -x "${SCRIPT_DIR}/review-gate.sh" ]; then
  if ! "${SCRIPT_DIR}/review-gate.sh" trace; then
    if [ "${REQUIRE_TRACE_CONSISTENCY:-0}" = "1" ]; then
      red "✗ trace gate blocked the finish (REQUIRE_TRACE_CONSISTENCY=1)."
      echo "  Resolve the findings above (or unset the flag) and re-run:"
    else
      # Warn-only without the flag, so a non-zero exit here is unexpected
      # (a broken gate, not a policy block) — say so honestly (loop-2 F4).
      red "✗ trace gate failed unexpectedly (it is warn-only without REQUIRE_TRACE_CONSISTENCY=1)."
      echo "  Inspect the output above, then re-run:"
    fi
    echo "    ./scripts/finish-issue.sh ${ISSUE_NUM}"
    echo "  The worktree is left intact."
    exit 1
  fi
else
  yellow "⚠ trace gate skipped: scripts/review-gate.sh not found"
fi

TRACE_STAGE="worktree_remove"
if [ ! -e "$WORKTREE_DIR" ]; then
  green "✓ No worktree at ${WORKTREE_DIR} — nothing to remove."
  git worktree prune
else
  remove_args=()
  [ "${FORCE:-0}" = "1" ] && remove_args+=(--force)
  if ! git worktree remove ${remove_args[@]+"${remove_args[@]}"} "$WORKTREE_DIR" 2>/dev/null; then
    red "✗ Worktree has uncommitted changes (or is locked)."
    echo "  Commit/stash your work, or re-run with FORCE=1 to discard it:"
    echo "    FORCE=1 ./scripts/finish-issue.sh ${ISSUE_NUM}"
    exit 1
  fi
  WORKTREE_REMOVED=true
  green "✓ Removed worktree ${WORKTREE_DIR}"
fi

git worktree prune

# --- Best-effort closeout trace export (issue #144) --------------------------
# After teardown so a failed export can never block worktree removal; gated on
# both config vars so it is a clean no-op unless explicitly opted in.
TRACE_STAGE="trace_export"
best_effort_trace_export

green "✓ Pruned stale worktree metadata"

# --- Optional branch deletion ----------------------------------------------
TRACE_STAGE="branch_delete"
if [ "${DELETE_BRANCH:-0}" = "1" ]; then
  if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    if git branch -d "$BRANCH" 2>/dev/null; then
      BRANCH_DELETED=true
      green "✓ Deleted local branch ${BRANCH}"
    else
      red "✗ Branch ${BRANCH} is not fully merged — not deleting."
      echo "  Force with: git branch -D ${BRANCH}"
      exit 1
    fi
  else
    green "✓ Local branch ${BRANCH} already gone."
  fi
else
  echo
  echo "Local branch ${BRANCH} kept. Delete it with:"
  echo "  DELETE_BRANCH=1 ./scripts/finish-issue.sh ${ISSUE_NUM}"
fi
TRACE_STAGE="done"
