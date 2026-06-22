#!/usr/bin/env bash
# Regression sensor: the subagent prompt templates must make the Python/TDD
# instruction files part of the subagent contract, not just conductor context.
#
# Issue #22: a fresh-context subagent does not inherit Copilot instruction
# resolution, so each agent prompt must explicitly require reading/following the
# applicable instruction files when it touches Python.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

impl=".copilot/agents/implementation-subagent.agent.md"
test_agent=".copilot/agents/test-subagent.agent.md"
review=".copilot/agents/code-review-subagent.agent.md"
harness=".copilot/instructions/harness.instructions.md"
py="python.instructions.md"
tdd="tdd.instructions.md"

for f in "$impl" "$test_agent" "$review" "$harness"; do
  [ -f "$f" ] || note "missing $f"
done

# implementation-subagent must require the Python instructions before editing .py.
if [ -f "$impl" ]; then
  grep -q "$py" "$impl" || note "$impl must reference $py"
  grep -Eqi '\.py\b' "$impl" || note "$impl must scope the Python requirement to .py files"
fi

# test-subagent must require BOTH Python and TDD instructions before Python tests.
if [ -f "$test_agent" ]; then
  grep -q "$py" "$test_agent" || note "$test_agent must reference $py"
  grep -q "$tdd" "$test_agent" || note "$test_agent must reference $tdd"
  grep -Eqi '\.py\b' "$test_agent" || note "$test_agent must scope the requirement to Python tests/.py files"
fi

# code-review-subagent must treat Python/TDD instructions as part of the review
# contract when the diff touches .py files.
if [ -f "$review" ]; then
  grep -q "$py" "$review" || note "$review must reference $py as a review contract for Python diffs"
  grep -q "$tdd" "$review" || note "$review must reference $tdd as a review contract for Python diffs"
  grep -Eqi '\.py\b' "$review" || note "$review must scope the Python/TDD review contract to .py files"
fi

# Conductor guidance must document passing applicable instruction files into
# subagent prompts.
if [ -f "$harness" ]; then
  grep -q "$py" "$harness" || note "$harness must document passing $py into subagent prompts"
  grep -Eqi 'subagent prompt|into the subagent|pass(ed|es)? .*instruction|instruction file' "$harness" ||
    note "$harness must explain when/how applicable instruction files are passed into subagent prompts"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "subagent Python/TDD instruction checks passed"
