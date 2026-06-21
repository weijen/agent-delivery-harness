#!/usr/bin/env bash
# issue-lib.sh — single source of truth for per-issue naming used by the
# worktree harness (start-issue.sh / finish-issue.sh).
#
# It defines, for a given issue number:
#   ISSUE_NUM      raw issue number (e.g. 31)
#   ISSUE_PAD      zero-padded to 2 digits, wider numbers untouched (e.g. 07, 31, 105)
#   ISSUE_SLUG     lowercase-hyphenated slug derived from the GitHub issue title
#   BRANCH         feature/issue-<PAD>-<SLUG>
#   WORKTREE_DIR   <main-parent>/<main-name>-worktrees/issue-<PAD>
#   TRACKING_DIR   <WORKTREE_DIR>/.copilot-tracking/issues/issue-<PAD>
#
# All paths are anchored to the MAIN checkout (resolved via the shared git
# common dir) so naming is identical whether you invoke from the main checkout
# or a linked worktree.
#
# Source it; do not execute it directly.

set -euo pipefail

# Absolute path of the main checkout's working tree (the one holding .git/),
# even when called from inside a linked worktree.
issue_main_root() {
  local common
  common="$(git rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *)  common="$(pwd)/$common" ;;
  esac
  (cd "$(dirname "$common")" && pwd)
}

# Backwards-compatible alias used by the entry scripts to locate the main root.
issue_repo_root() { issue_main_root; }

# Strip an optional ISSUE= prefix and validate a positive integer.
issue_parse_number() {
  local raw="${1:-}"
  raw="${raw#ISSUE=}"
  if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "error: expected an issue number (e.g. 31 or ISSUE=31), got '${1:-}'" >&2
    return 1
  fi
  printf '%s' "$raw"
}

# Derive a slug from the GitHub issue title via gh. Falls back to "issue-N"
# when the title cannot be fetched (offline / not found).
issue_derive_slug() {
  local num="$1" title slug
  title="$(gh issue view "$num" --json title -q .title 2>/dev/null || true)"
  if [ -z "$title" ]; then
    printf 'issue-%s' "$num"
    return 0
  fi
  slug="$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40 \
    | sed -E 's/-+$//')"
  [ -n "$slug" ] && printf '%s' "$slug" || printf 'issue-%s' "$num"
}

# Populate the ISSUE_* / BRANCH / *_DIR variables for the given issue number.
# Usage: resolve_issue_env <number> [explicit-slug]
resolve_issue_env() {
  local num="$1" explicit_slug="${2:-}"
  local root parent reponame
  root="$(issue_main_root)"
  parent="$(dirname "$root")"
  reponame="$(basename "$root")"

  ISSUE_NUM="$num"
  ISSUE_PAD="$(printf '%02d' "$num")"
  if [ -n "$explicit_slug" ]; then
    ISSUE_SLUG="$explicit_slug"
  else
    ISSUE_SLUG="$(issue_derive_slug "$num")"
  fi
  BRANCH="feature/issue-${ISSUE_PAD}-${ISSUE_SLUG}"
  WORKTREE_DIR="${parent}/${reponame}-worktrees/issue-${ISSUE_PAD}"
  TRACKING_DIR="${WORKTREE_DIR}/.copilot-tracking/issues/issue-${ISSUE_PAD}"
  export ISSUE_NUM ISSUE_PAD ISSUE_SLUG BRANCH WORKTREE_DIR TRACKING_DIR
}
