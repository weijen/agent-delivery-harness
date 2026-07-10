#!/usr/bin/env bash
# Regression sensor (issue #46; structural per #273): the tester and reviewer
# templates must encode STRICT, contract-guarding blocking criteria. Structure-
# level: asserts the guarded verdict sections exist (heading anchors) and the
# closed blocking vocabulary is present; wording is free to change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

test_agent=".copilot/agents/test-subagent.agent.md"
review=".copilot/agents/code-review-subagent.agent.md"

for f in "$test_agent" "$review"; do
  [ -f "$f" ] || note "missing $f"
done

# test-subagent -- blocking vocabulary.
if [ -f "$test_agent" ]; then
  grep -qi 'acceptance criteri' "$test_agent" || note "$test_agent must map acceptance criteria to sensors before passes:true"
  grep -Eqi 'missing sensor coverage' "$test_agent" || note "$test_agent must treat missing sensor coverage as blocking"
  grep -Eqi 'happy.?path' "$test_agent" || note "$test_agent must treat happy-path-only coverage as blocking"
  grep -Eqi 'non.?executable|not runnable|non.?runnable' "$test_agent" || note "$test_agent must treat non-executable validation as blocking"
  grep -q 'BLOCKING' "$test_agent" || note "$test_agent must label these gaps as BLOCKING"
  grep -Eqi 'waiv(e|ed|er)' "$test_agent" || note "$test_agent must describe the conductor waiver path"
  grep -q 'Action Log' "$test_agent" || note "$test_agent must require the waiver rationale in the Action Log"
fi

# code-review-subagent -- four-verdict structure (heading anchors) + blocking vocabulary.
if [ -f "$review" ]; then
  grep -Eqi '^### Verdict 1 .* Spec Compliance' "$review" || note "$review must keep Verdict 1 (Spec Compliance) heading"
  grep -Eqi '^### Verdict 2 .* (Sensor Adequacy|Test ?/ ?Sensor Adequacy)' "$review" || note "$review must keep Verdict 2 (Sensor Adequacy) heading"
  grep -Eqi '^### Verdict 3 .* (Code Quality|Maintainab)' "$review" || note "$review must keep Verdict 3 (Code Quality) heading"
  grep -Eqi '^### Verdict 4 .* (Lifecycle|Role.?[Bb]oundary)' "$review" || note "$review must keep Verdict 4 (Lifecycle & Role-Boundary) heading"
  grep -Eqi 'four separate verdict|four .*verdict' "$review" || note "$review must state the verdicts are separate/four"
  grep -Eqi 'actually run' "$review" || note "$review must require checking whether named sensors were actually run"
  grep -qi 'recorded' "$review" || note "$review must require checking whether sensor results are recorded"
  grep -Eqi 'presence.?only' "$review" || note "$review must flag presence-only checks as insufficient"
  grep -qi 'lifecycle order' "$review" || note "$review presence-only flag must name lifecycle ordering"
  grep -Eqi 'hard.?(vs|-).?warn' "$review" || note "$review presence-only flag must name hard-vs-warn exit semantics"
  grep -qi 'worktree cleanup' "$review" || note "$review presence-only flag must name worktree cleanup"
  grep -q 'BLOCKING' "$review" || note "$review must define a BLOCKING severity tier"
  grep -qi 'blocking findings first' "$review" || note "$review must require blocking findings listed first"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "tester/reviewer blocking-criteria checks passed"
