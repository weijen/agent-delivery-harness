#!/usr/bin/env bash
# Regression sensor (issue #200): the workflow-doctrine instruction files must
# not carry the stale Taskfile-based issue lifecycle (C-3) nor emphasis-by-
# repetition of the stop/retry/feedback rules and the non-delegable block (C-4).
#
# This sensor fails if the pruned residue reappears, while still requiring the
# real rules to be present (so pruning cannot silently drop a rule).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

wt=".copilot/instructions/workflow-tiers.instructions.md"
harness=".copilot/instructions/harness.instructions.md"

fail=0
note() { echo "✗ $*"; fail=1; }

[ -f "$wt" ] || { echo "✗ missing $wt"; exit 1; }
[ -f "$harness" ] || { echo "✗ missing $harness"; exit 1; }

count() { grep -cF "$1" "$2" || true; }

# --- C-3: no stale Taskfile-based issue lifecycle prescriptions ---------------
# This repo's harness is script-based; a prescriptive `task preflight` /
# `task init-issue ISSUE=` / `task finish-issue` lifecycle describes a Taskfile
# that does not exist and invites hunting for commands.
for phrase in "task preflight" "task init-issue ISSUE=" "task finish-issue"; do
  if [ "$(count "$phrase" "$wt")" -ne 0 ]; then
    note "$wt must not prescribe the stale Taskfile lifecycle command '$phrase' (issue #200 C-3)"
  fi
done
if grep -qF "Optional: Issue-driven harness (when the host repo provides it)" "$wt"; then
  note "$wt must not keep the stale 'Optional: Issue-driven harness' Taskfile section (issue #200 C-3)"
fi

# --- C-4: stop/retry/feedback rules stated once, not repeated -----------------
# Each rule must appear exactly once (present, but not duplicated across the
# Mid-pipeline / When-to-Stop / Important-Rules sections).
retry_ct="$(count "more than twice" "$wt")"
if [ "$retry_ct" -eq 0 ]; then
  note "$wt must keep the 'retry no more than twice' stop rule"
elif [ "$retry_ct" -gt 1 ]; then
  note "$wt must state the 'retry no more than twice' rule once, not $retry_ct times (issue #200 C-4)"
fi
soften_ct="$(count "summarise or soften" "$wt")"
if [ "$soften_ct" -eq 0 ]; then
  note "$wt must keep the 'include the full feedback — don't summarise or soften' rule"
elif [ "$soften_ct" -gt 1 ]; then
  note "$wt must state the 'don't summarise or soften' rule once, not $soften_ct times (issue #200 C-4)"
fi

# --- C-4: non-delegable block stated once, not padded by restatement ----------
# The redundant re-encodings ("In plain terms: …", "Specifically, the conductor
# …", "The conductor does not implement … never writes …") are removed; the
# firm rule + the bullet list remain.
for phrase in "In plain terms" "Specifically, the conductor"; do
  if [ "$(count "$phrase" "$harness")" -ne 0 ]; then
    note "$harness must not restate the non-delegable rule via '$phrase …' (issue #200 C-4)"
  fi
done
# The rule itself must survive the pruning.
grep -Eqi 'non-delegable' "$harness" ||
  note "$harness must keep the non-delegable conductor boundary"
grep -Eqi 'conductor must not' "$harness" ||
  note "$harness must keep a firm 'conductor must not' statement"

[ "$fail" -eq 0 ] || exit 1
echo "✓ instruction files carry no stale Taskfile lifecycle or duplicated doctrine"
