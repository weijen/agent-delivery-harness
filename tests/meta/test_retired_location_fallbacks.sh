#!/usr/bin/env bash
# Structural regression sensor for retired location compatibility (issue #423).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
if grep -Eq 'legacy_worktree|-[Ww]orktrees/issue-' scripts/issue-lib.sh; then
  printf 'FAIL: issue-lib.sh retains sibling-worktree resolution\n' >&2
  fail=1
fi
if grep -Eq 'legacy_marker_file|canonical_legacy_marker' scripts/review-gate.sh; then
  printf 'FAIL: review-gate.sh retains shared-marker fallback variables\n' >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
printf 'retired location fallbacks remain absent\n'
