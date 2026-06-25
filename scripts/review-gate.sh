#!/usr/bin/env bash
# review-gate.sh — local HEAD-bound review approval marker.

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./scripts/review-gate.sh approve|check|status-doc

Commands:
  approve     Record the current HEAD as reviewed.
  check       Require the recorded approval to match the current HEAD, and that
              the repo-wide status doc (docs/PROGRESS.md) changed on this branch.
  status-doc  Require docs/PROGRESS.md to have changed in <base>...HEAD.
              Every change must update the repo-wide status doc — there is no
              opt-out. docs/PROGRESS.md is what the next agent reads first.
EOF
}

# status_doc_gate — fail closed unless docs/PROGRESS.md changed on the branch.
#
# The repo-wide, pushed status doc must be updated as part of the branch before a
# PR opens (harness.instructions.md §6) — it is the running log the next agent
# reads first, so every change must touch it. We prove that deterministically by
# diffing it over <base>...HEAD, where <base> is origin/main, else main. There is
# deliberately no override: an opt-out would let the one thing the next agent
# relies on silently rot.
status_doc_gate() {
  local doc="docs/PROGRESS.md"

  local base=""
  # origin/main is the load-bearing base (create-pr.sh fetches it before the
  # post-sync check); local main is only an offline backstop.
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base="origin/main"
  elif git rev-parse --verify -q main >/dev/null 2>&1; then
    base="main"
  fi

  if [ -z "$base" ]; then
    red "✗ status-doc: cannot find a main base (origin/main or main) to diff against."
    echo "  Fetch main so the branch diff can be computed."
    exit 1
  fi

  if git diff --name-only "${base}...HEAD" -- "$doc" | grep -qx "$doc"; then
    green "✓ status-doc: ${doc} updated on this branch (${base}...HEAD)."
    return 0
  fi

  red "✗ status-doc: ${doc} was not updated on this branch (${base}...HEAD)."
  echo "  Update ${doc} with this change's repo-wide status before opening the PR —"
  echo "  it is the running log the next agent reads first, so every change must touch it."
  exit 1
}

repo_root="$(git rev-parse --show-toplevel)"
marker_dir="${repo_root}/.copilot-tracking/review-gate"
marker_file="${marker_dir}/approved-head"
head_sha="$(git rev-parse HEAD)"
command="${1:-}"

case "$command" in
  approve)
    mkdir -p "$marker_dir"
    printf '%s\n' "$head_sha" > "$marker_file"
    green "✓ review approved for current HEAD ${head_sha}"
    ;;
  check)
    if [ ! -f "$marker_file" ]; then
      red "✗ current HEAD has not been approved by the review gate."
      echo "  Run review, resolve findings, then: ./scripts/review-gate.sh approve"
      exit 1
    fi
    approved_sha="$(tr -d '[:space:]' < "$marker_file")"
    if [ "$approved_sha" != "$head_sha" ]; then
      red "✗ current HEAD has not been approved by the review gate."
      echo "  approved: ${approved_sha:-<empty>}"
      echo "  current:  ${head_sha}"
      echo "  Re-run review for the current HEAD, then: ./scripts/review-gate.sh approve"
      exit 1
    fi
    green "✓ review approved for current HEAD ${head_sha}"
    status_doc_gate
    ;;
  status-doc)
    status_doc_gate
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac