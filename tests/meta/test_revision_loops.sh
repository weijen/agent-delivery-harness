#!/usr/bin/env bash
# Regression sensor (issue #14; structural per #273): the harness must document
# conductor-owned, grading-driven revision loops -- Loop 1 (generator repair)
# and Loop 2 (review -> generator) -- and each subagent's handback/
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
generator=".copilot/agents/generator-subagent.agent.md"
review=".copilot/agents/code-review-subagent.agent.md"

# 1. Harness docs: the revision-loops section exists + closed vocabulary.
if [ -f "$h" ]; then
  grep -Eq '^#+ .*[Rr]evision loops' "$h" || note "$h must keep the grading-driven revision-loops section"
  for token in 'Loop 1' 'Loop 2' 'routing signal' 'severity override' 'retry limit'; do
    grep -q "$token" "$h" || note "$h revision-loops vocabulary must include '$token'"
  done
  # Loop 3 (plan correction) closed vocabulary: lightweight escape hatch for a
  # falsified plan/breakdown/sensor-contract. Structure-level; wording is free.
  for token in 'Loop 3' 'plan correction'; do
    grep -q "$token" "$h" || note "$h must document Loop 3 (plan correction) vocabulary: '$token'"
  done
else
  note "missing $h"
fi

# 1b. Narrative HARNESS.md must also name Loop 3 alongside Loops 1 and 2.
harness_md="docs/HARNESS.md"
if [ -f "$harness_md" ]; then
  grep -q 'Loop 3' "$harness_md" || note "$harness_md must name Loop 3 (plan correction) alongside Loops 1 and 2"
else
  note "missing $harness_md"
fi

# 2. generator-subagent handback distinguishes production defects from verification/sensor gaps.
if [ -f "$generator" ]; then
  grep -qi 'production' "$generator" || note "$generator handback must call out production defects"
  grep -Eqi 'verification|sensor' "$generator" || note "$generator handback must distinguish a verification/sensor gap"
else
  note "missing $generator"
fi

# 3. code-review-subagent routes findings to generator / conductor.
if [ -f "$review" ]; then
  for token in 'generator-subagent' 'conductor'; do
    grep -q "$token" "$review" || note "$review must route findings to '$token'"
  done
else
  note "missing $review"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "grading-driven revision loop checks passed"
