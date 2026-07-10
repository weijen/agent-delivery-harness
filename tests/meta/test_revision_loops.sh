#!/usr/bin/env bash
# Regression sensor (issue #14; structural per #273): the harness must document
# conductor-owned, grading-driven revision loops -- Loop 1 (implementation <->
# test) and Loop 2 (review -> implementation) -- and each subagent's handback/
# next-steps guidance must support routing without collapsing role boundaries or
# treating the usefulness score as a severity override. Structure-level: asserts
# the guarded section exists (heading anchor) and its closed vocabulary is
# present; wording is free to change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

h=".copilot/instructions/harness.instructions.md"
impl=".copilot/agents/implementation-subagent.agent.md"
test_a=".copilot/agents/test-subagent.agent.md"
review=".copilot/agents/code-review-subagent.agent.md"

# 1. Harness docs: the revision-loops section exists + closed vocabulary.
if [ -f "$h" ]; then
  grep -Eq '^#+ .*[Rr]evision loops' "$h" || note "$h must keep the grading-driven revision-loops section"
  for token in 'Loop 1' 'Loop 2' 'routing signal' 'severity override' 'retry limit'; do
    grep -q "$token" "$h" || note "$h revision-loops vocabulary must include '$token'"
  done
fi

# 2. implementation-subagent handback exists.
if [ -f "$impl" ]; then
  grep -qi 'handback' "$impl" || note "$impl must describe its Handback"
fi

# 3. test-subagent handback distinguishes production defects from verification/sensor gaps.
if [ -f "$test_a" ]; then
  grep -qi 'production' "$test_a" || note "$test_a handback must call out production defects"
  grep -Eqi 'verification|sensor' "$test_a" || note "$test_a handback must distinguish a verification/sensor gap"
fi

# 4. code-review-subagent routes findings to impl / test / conductor.
if [ -f "$review" ]; then
  for token in 'implementation-subagent' 'test-subagent' 'conductor'; do
    grep -q "$token" "$review" || note "$review must route findings to '$token'"
  done
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "grading-driven revision loop checks passed"
