#!/usr/bin/env bash
# Regression sensor: the subagent prompt templates and the harness doctrine must
# route language instruction files by the files being changed (profile-aware),
# not by a hard-coded Python-only rule.
#
# Issue #22 established that a fresh-context subagent does not inherit Copilot
# instruction resolution, so each agent prompt must explicitly require reading the
# applicable instruction files. Issue #36 generalizes that rule across languages:
#
#   - Python diffs still load python.instructions.md (AC#2).
#   - Each agent must describe the generic per-language routing using the
#     <language>.instructions.md pattern, not Python alone (AC#1, AC#6).
#   - Mixed-language diffs load every applicable language instruction plus the
#     core harness and tdd.instructions.md (AC#4).
#   - A missing <language>.instructions.md falls back to the harness contract and the
#     harness contract without inventing conventions (AC#5).
#
# This sensor RED-fails on Python-only routing prose and GREEN-passes once the
# routing is profile-aware.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

plan=".copilot/agents/planning-subagent.agent.md"
impl=".copilot/agents/implementation-subagent.agent.md"
test_agent=".copilot/agents/test-subagent.agent.md"
review=".copilot/agents/code-review-subagent.agent.md"
harness=".copilot/instructions/harness.instructions.md"
py="python.instructions.md"
tdd="tdd.instructions.md"

# Generic per-language routing token (literal "<language>.instructions.md"); the
# presence of this placeholder is what proves routing is profile-aware, not
# Python-only.
generic='<language>.instructions.md'

for f in "$plan" "$impl" "$test_agent" "$review" "$harness"; do
  [ -f "$f" ] || note "missing $f"
done

# Every routing surface (4 agents + harness doctrine) must:
#   (a) describe the generic per-language routing token (AC#1/#6),
#   (b) describe the mixed-language "all applicable" rule (AC#4),
#   (c) describe the missing-file fallback to the harness contract + AGENTS.md conventions (AC#5).
for f in "$plan" "$impl" "$test_agent" "$review" "$harness"; do
  [ -f "$f" ] || continue
  grep -qF "$generic" "$f" || note "$f must route via the generic $generic pattern (not Python-only)"
  grep -qi 'mixed-language' "$f" || note "$f must describe the mixed-language all-applicable rule"
  grep -qi 'harness contract' "$f" || note "$f must describe falling back to the harness contract when an instruction file is missing"
  grep -qi 'AGENTS.md conventions' "$f" || note "$f must name AGENTS.md conventions as the missing-instruction-file fallback"
  grep -Eqi 'fall back|missing|absent|when present' "$f" || note "$f must state the missing-instruction-file fallback condition"
done

# The implementation, test, review, and harness surfaces must keep loading the
# core harness + TDD instructions for mixed diffs (AC#4) ...
for f in "$impl" "$test_agent" "$review" "$harness"; do
  [ -f "$f" ] || continue
  grep -qF "$tdd" "$f" || note "$f must keep $tdd as a required instruction"
done

# ... and Python diffs must still resolve to the Python instruction file (AC#2),
# scoped to .py, on the editing/testing/review surfaces.
for f in "$impl" "$test_agent" "$review"; do
  [ -f "$f" ] || continue
  grep -qF "$py" "$f" || note "$f must still resolve Python diffs to $py (AC#2)"
  grep -Eqi '\.py\b' "$f" || note "$f must still scope the Python case to .py files (AC#2)"
done

# Guard against reintroduction of Python-ONLY routing: any agent that names the
# Python instruction file must also name at least one other built-in language so
# the routing cannot silently collapse back to Python-only.
for f in "$plan" "$impl" "$test_agent" "$review" "$harness"; do
  [ -f "$f" ] || continue
  if grep -qF "$py" "$f"; then
    grep -Eqi '\b(go|node|java|ruby)\b' "$f" ||
      note "$f references Python instructions but names no other language — routing looks Python-only"
  fi
done

# Conductor doctrine must explain that applicable instruction files are passed
# into subagent prompts (per touched-file language).
if [ -f "$harness" ]; then
  grep -Eqi 'subagent prompt|into the subagent|pass(ed|es)? .*instruction|instruction file' "$harness" ||
    note "$harness must explain when/how applicable instruction files are passed into subagent prompts"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "subagent profile-aware instruction checks passed"
