#!/usr/bin/env bash
# Regression sensor (issue #285 item 6): the code-review-subagent contract must
# instruct the reviewer to verify that a file/record deliverable SURVIVES the
# full lifecycle (e.g. worktree teardown), not merely that it is emitted. This
# closes the root cause shared by #285 items 1 and 2 (an artifact emitted to a
# soon-to-be-deleted worktree). Structure-level: assert the guarded file exists
# and its test-adequacy checklist names the survival requirement; wording is
# free to change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review=".copilot/agents/code-review-subagent.agent.md"

if [ -f "$review" ]; then
  # The checklist must pair "survive" with a lifecycle/teardown notion so a
  # presence-only "artifact is emitted" check is called out as insufficient.
  if grep -Eqi 'surviv' "$review" \
     && grep -Eqi 'lifecycle|teardown|worktree' "$review"; then
    grep -Eqi 'surviv.*(lifecycle|teardown|worktree)|(lifecycle|teardown|worktree).*surviv' "$review" \
      || note "$review must tie artifact survival to the full lifecycle in one checklist point"
  else
    note "$review must require verifying a file/record deliverable SURVIVES the full lifecycle (e.g. worktree teardown), not merely that it is emitted"
  fi
else
  note "missing $review"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "code-review artifact-survival checklist present"
