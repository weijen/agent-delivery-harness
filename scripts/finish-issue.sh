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
  trace_lifecycle_init() { :; }
  trace_lifecycle_arm() { :; }
fi

# --- Closeout helpers (issue #215, scripts-portfolio P-4) --------------------
# The best-effort export/reconstruct/hygiene helpers and the two-phase trace
# gate live in finish-lib.sh so this script stays a thin teardown orchestrator.
# Guarded source: a missing finish-lib.sh must never break teardown — fall back
# to no-op helpers (the optional closeout steps are skipped and the gate lets
# teardown proceed, exactly as when their underlying tooling is absent).
if [ -f "${SCRIPT_DIR}/finish-lib.sh" ]; then
  # shellcheck source=scripts/finish-lib.sh
  source "${SCRIPT_DIR}/finish-lib.sh"
fi
if ! declare -F finish_trace_gate >/dev/null 2>&1; then
  printf 'finish-issue: warning: scripts/finish-lib.sh not found — closeout helpers disabled\n' >&2
  finish_trace_gate() { return 0; }
  best_effort_trace_export() { return 0; }
  best_effort_trace_reconstruct() { return 0; }
  best_effort_state_hygiene() { return 0; }
fi

# Terminal `finish` lifecycle span via the shared EXIT-trap helper (issue #213
# P-1, trace_lifecycle_init). It fires AFTER `git worktree remove` — the span
# survives teardown only because trace-lib pins the trace file to the MAIN
# checkout root (plan D1). TRACE_STAGE names the last stage reached
# (completion_check|trace_gate|worktree_remove|branch_delete|done), surfaced as
# harness.stage by the attr callback; refusals before arming emit nothing.
TRACE_STAGE=""
WORKTREE_REMOVED=false
BRANCH_DELETED=false
trace__finish_attrs() {
  printf 'harness.stage=%s\n' "${TRACE_STAGE}"
  printf 'harness.branch=%s\n' "${BRANCH:-}"
  printf 'harness.worktree_removed=%s\n' "${WORKTREE_REMOVED}"
  printf 'harness.branch_deleted=%s\n' "${BRANCH_DELETED}"
}
trace_lifecycle_init finish trace__finish_attrs

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

# The worktree's own checked-out branch is the deterministic source of truth —
# prefer it over a slug recomputed from the (mutable) issue title.
if [ -e "$WORKTREE_DIR" ]; then
  wt_branch="$(git -C "$WORKTREE_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -n "$wt_branch" ] && BRANCH="$wt_branch"
fi

bold "==> Finishing issue ${ISSUE_NUM}"
echo "  branch:   ${BRANCH}"
echo "  worktree: ${WORKTREE_DIR}"

TRACE_STAGE="completion_check"
trace_lifecycle_arm
check_feature_completion

# Two-phase trace gate (issue #103) — run BEFORE teardown so that under
# REQUIRE_TRACE_CONSISTENCY=1 findings refuse the finish while the worktree is
# still intact. See finish-lib.sh for the full doctrine; it returns 1 to block.
TRACE_STAGE="trace_gate"
if ! finish_trace_gate; then
  exit 1
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

# --- Best-effort closeout trace reconstruction (issue #149) ------------------
# Local-only, no-secret step: run unconditionally after teardown so a failed
# reconstruction can never block worktree removal. The reconstruct script
# no-ops when the transcript dir is absent.
TRACE_STAGE="trace_reconstruct"
best_effort_trace_reconstruct

# --- Best-effort closeout state hygiene (issue #175) -------------------------
TRACE_STAGE="state_hygiene"
best_effort_state_hygiene

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
