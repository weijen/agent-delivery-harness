#!/usr/bin/env bash
# review-gate.sh — local HEAD-bound review approval marker.

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./scripts/review-gate.sh approve|check

Commands:
  approve   Record the current HEAD as reviewed.
  check     Require the recorded approval to match the current HEAD.
EOF
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
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac