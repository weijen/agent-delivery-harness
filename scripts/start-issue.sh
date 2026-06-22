#!/usr/bin/env bash
# start-issue.sh — begin work on a GitHub issue in an isolated git worktree.
#
# Usage:
#   ./scripts/start-issue.sh 1
#   ./scripts/start-issue.sh ISSUE=1
#   ./scripts/start-issue.sh ISSUE=1 SLUG=custom-slug
#
# Flow (the harness start-of-session ritual, mechanised):
#   1. Run ./scripts/init.sh; ABORT if the environment is not green. A worktree is only
#      created on top of a healthy environment. (Set SKIP_INIT=1 to bypass — for
#      scripted tests only; it defeats the purpose otherwise.)
#   2. Derive a slug from the issue title (gh) → branch feature/issue-NN-<slug>.
#   3. Create a worktree at <repo>-worktrees/issue-NN on that branch (off main).
#   4. Scaffold .copilot-tracking/issues/issue-NN/ (feature_list.json, progress.md)
#      if missing.
#   5. Print the cd path + next steps. Idempotent: never clobbers an existing
#      worktree or branch.
#
# Exit codes: 0 ready · 1 usage / precondition failure

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

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
  red "usage: ./scripts/start-issue.sh <issue-number> [SLUG=custom-slug]"
  exit 1
fi
ISSUE_NUM="$(issue_parse_number "$NUM_ARG")"

ROOT="$(issue_repo_root)"
cd "$ROOT"

# Refuse to run from inside a linked worktree — start-issue operates on main.
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  red "✗ run start-issue.sh from the main checkout, not from a worktree."
  exit 1
fi

# --- 1. Preflight (init.sh) -------------------------------------------------
if [ "${SKIP_INIT:-0}" = "1" ]; then
  bold "==> Skipping init.sh (SKIP_INIT=1)"
else
  bold "==> Running preflight (./scripts/init.sh)"
  if ! "${ROOT}/scripts/init.sh"; then
    red "✗ Preflight failed — fix the environment before starting an issue."
    exit 1
  fi
fi

# --- 2. Resolve naming ------------------------------------------------------
resolve_issue_env "$ISSUE_NUM" "$SLUG_ARG"
bold "==> Issue ${ISSUE_NUM}"
echo "  branch:   ${BRANCH}"
echo "  worktree: ${WORKTREE_DIR}"

# --- 3. Create worktree + branch (non-destructive) --------------------------
if [ -e "$WORKTREE_DIR" ]; then
  green "✓ Worktree already exists — reusing it (no changes made)."
  echo
  echo "  cd ${WORKTREE_DIR}"
  exit 0
fi

base_ref=main
if git show-ref --verify --quiet refs/remotes/origin/main; then
  base_ref=origin/main
fi

if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  echo "  branch ${BRANCH} already exists — attaching worktree to it."
  git worktree add "$WORKTREE_DIR" "$BRANCH"
else
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "$base_ref"
fi
green "✓ Worktree created at ${WORKTREE_DIR} (base: ${base_ref})"

# --- 4. Scaffold per-issue tracking (gitignored) ----------------------------
if [ ! -d "$TRACKING_DIR" ]; then
  mkdir -p "$TRACKING_DIR"
  cat > "${TRACKING_DIR}/feature_list.json" <<JSON
{
  "issue": ${ISSUE_NUM},
  "title": "$(gh issue view "$ISSUE_NUM" --json title -q .title 2>/dev/null || echo "issue ${ISSUE_NUM}")",
  "branch": "${BRANCH}",
  "feature_schema": {
    "id": "string",
    "title": "string",
    "steps": [],
    "passes": false,
    "regression_sensor": null,
    "e2e_sensor": null,
    "blocked_on": null,
    "verification": null
  },
  "features": []
}
JSON
  cat > "${TRACKING_DIR}/progress.md" <<MD
# Issue ${ISSUE_NUM} progress

Status: not started.

- Branch: \`${BRANCH}\`
- Worktree: \`${WORKTREE_DIR}\`

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._

Populate \`feature_list.json\` with the feature breakdown, then work one
\`passes:false\` item at a time (see harness §3).
MD
  green "✓ Scaffolded ${TRACKING_DIR#"$WORKTREE_DIR"/} (feature_list.json, progress.md)"
else
  green "✓ Tracking dir already present — left untouched."
fi

# --- 5. Next steps ----------------------------------------------------------
echo
bold "Ready. Start working in the worktree:"
echo "  cd ${WORKTREE_DIR}"
echo "  gh issue view ${ISSUE_NUM} --comments   # single source of truth"
echo "  # edit ${TRACKING_DIR#"$WORKTREE_DIR"/}/feature_list.json, then pick one passes:false feature"
