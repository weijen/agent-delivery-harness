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

ROOT="$(issue_repo_root)"
cd "$ROOT"

# Operate from the main checkout — you cannot remove the worktree you stand in.
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  red "✗ run finish-issue.sh from the main checkout, not from a worktree."
  exit 1
fi

resolve_issue_env "$ISSUE_NUM" "$SLUG_ARG"

check_feature_completion() {
  local feature_list incomplete_count
  feature_list="${TRACKING_DIR}/feature_list.json"
  if [ ! -f "$feature_list" ]; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    yellow "  ! jq not installed — skipping feature completion check"
    return 0
  fi
  incomplete_count="$(jq '[.features[]? | select(.passes != true)] | length' "$feature_list")"
  if [ "$incomplete_count" -gt 0 ]; then
    if [ "${REQUIRE_FEATURES_COMPLETE:-0}" = "1" ]; then
      red "✗ ${incomplete_count} incomplete feature_list items remain."
      echo "  Set each completed feature to passes:true before finishing, or unset REQUIRE_FEATURES_COMPLETE for warning mode."
      exit 1
    fi
    yellow "  ! ${incomplete_count} incomplete feature_list items remain (warning only)."
    echo "    → Set REQUIRE_FEATURES_COMPLETE=1 to make this a hard gate."
  fi
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

check_feature_completion

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
  green "✓ Removed worktree ${WORKTREE_DIR}"
fi

git worktree prune
green "✓ Pruned stale worktree metadata"

# --- Optional branch deletion ----------------------------------------------
if [ "${DELETE_BRANCH:-0}" = "1" ]; then
  if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    if git branch -d "$BRANCH" 2>/dev/null; then
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
