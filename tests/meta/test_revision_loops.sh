#!/usr/bin/env bash
# Regression sensor: the harness must document conductor-owned, grading-driven
# revision loops — Loop 1 (implementation <-> test) and Loop 2 (review ->
# implementation) — and each subagent's handback/next-steps guidance must support
# routing without collapsing role boundaries or treating the usefulness score as a
# severity override.  (Issue #14.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

h=".copilot/instructions/harness.instructions.md"
impl=".copilot/agents/implementation-subagent.agent.md"
test_a=".copilot/agents/test-subagent.agent.md"
review=".copilot/agents/code-review-subagent.agent.md"

# 1. Harness docs describe both loops, conductor-owned.
if [ -f "$h" ]; then
  grep -qi 'revision loop' "$h" || note "$h must document the grading-driven revision loops"
  grep -Eqi 'implementation *(<->|↔|to|/) *test|implementation ?. ?test loop|loop 1' "$h" ||
    note "$h must describe Loop 1 (implementation <-> test)"
  grep -Eqi 'review *(->|→|to) *implementation|review-to-implementation|loop 2' "$h" ||
    note "$h must describe Loop 2 (review -> implementation)"
  grep -qi 'conductor owns the loop\|conductor-owned\|conductor owns' "$h" ||
    note "$h must state the conductor owns the loop boundary"
  # Retry/stop cap to avoid infinite loops.
  grep -Eqi 'two (failed )?(repair |fix )?attempts|retry limit|stop and ask|infinite loop' "$h" ||
    note "$h must cap repeated failures (retry limit / stop and ask)"
  # Grading is a routing signal, not a severity override.
  grep -Eqi 'not a severity (override|replacement)|does not override|routing signal|not .*severity override' "$h" ||
    note "$h must state the grading is a routing signal, not a severity override"
  # Subagents do not call each other directly.
  grep -Eqi 'not call each other|do not call each other|conductor passes' "$h" ||
    note "$h must state subagents route through the conductor, not each other"
fi

# 2. implementation-subagent handback asks for concrete follow-up context.
if [ -f "$impl" ]; then
  grep -qi 'handback' "$impl" || note "$impl must describe its Handback"
fi

# 3. test-subagent handback distinguishes production defects from verification/sensor defects.
if [ -f "$test_a" ]; then
  grep -Eqi 'production (defect|fix|behavio)' "$test_a" ||
    note "$test_a handback must call out production defects"
  grep -Eqi 'verification (gap|defect)|sensor (gap|defect|is wrong)' "$test_a" ||
    note "$test_a handback must distinguish a verification/sensor gap"
fi

# 4. code-review-subagent next steps route findings to impl / test / conductor.
if [ -f "$review" ]; then
  grep -qi 'implementation-subagent' "$review" || note "$review must route findings to implementation-subagent"
  grep -qi 'test-subagent' "$review" || note "$review must route test-gap findings to test-subagent"
  grep -qi 'conductor' "$review" || note "$review must route decisions to the conductor"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "grading-driven revision loop checks passed"
