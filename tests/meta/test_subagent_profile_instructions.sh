#!/usr/bin/env bash
# Regression sensor (issues #22, #36, #182): the profile-aware language-instruction
# routing map is SINGLE-SOURCED in .copilot/instructions/harness.instructions.md.
#
# Issue #22 established that a fresh-context subagent does not inherit Copilot
# instruction resolution, so each agent prompt must explicitly require reading the
# applicable instruction files. Issue #36 generalized the rule across languages.
# Issue #182 removes the ~12-15 line routing map that was copy-pasted into all four
# agents (four of the five mapped files did not exist; the map omitted the two that
# do — bash and terraform-azure) and makes harness.instructions.md the one place the
# map lives. Each agent now carries a one-line REFERENCE to that map, not a copy.
#
# This sensor RED-fails if the full map drifts back into an agent, if the harness
# map loses a required language, or if an agent stops pointing at the single source.
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

generic='<language>.instructions.md'
py="python.instructions.md"
tdd="tdd.instructions.md"

for f in "$plan" "$impl" "$test_agent" "$review" "$harness"; do
  [ -f "$f" ] || note "missing $f"
done

# --- Single source: harness.instructions.md carries the WHOLE routing map ------
if [ -f "$harness" ]; then
  grep -qF "$generic" "$harness" || note "harness map must use the generic $generic token (profile-aware routing)"
  grep -qi 'mixed-language' "$harness" || note "harness map must state the mixed-language all-applicable rule"
  grep -Eqi 'fall back|fallback' "$harness" || note "harness map must state the missing-instruction-file fallback"
  grep -qF "$tdd" "$harness" || note "harness map must keep $tdd as a required instruction"
  grep -qF "$py" "$harness" || note "harness map must resolve Python diffs to $py"
  grep -Eqi '\.py\b' "$harness" || note "harness map must scope the Python case to .py files"
  grep -Eqi '\b(go|node|java|ruby)\b' "$harness" || note "harness map must name languages beyond Python"
  grep -qF 'bash.instructions.md' "$harness" || note "harness map must route shell (.sh) to bash.instructions.md"
  grep -qF 'terraform-azure.instructions.md' "$harness" || note "harness map must route .tf/.bicep to terraform-azure.instructions.md"
  grep -Eqi 'subagent prompt|into the subagent|pass(ed|es)? .*instruction|instruction file' "$harness" ||
    note "harness must explain how applicable instruction files are passed into subagent prompts"
fi

# --- Each agent REFERENCES the single source; it must not re-encode the map -----
for f in "$plan" "$impl" "$test_agent" "$review"; do
  [ -f "$f" ] || continue
  grep -qi 'profile-aware' "$f" || note "$f must frame instruction loading as profile-aware routing"
  grep -qF 'harness.instructions.md' "$f" ||
    note "$f must reference the single-source routing map in harness.instructions.md"
  grep -qF "$generic" "$f" || note "$f must keep the generic $generic token in its one-line reference"
  if grep -qi 'mixed-language' "$f"; then
    note "$f re-encodes the mixed-language rule — that detail belongs only in the harness map (single-source)"
  fi
done

# --- TDD stays binding on the editing/testing/review references -----------------
for f in "$impl" "$test_agent" "$review"; do
  [ -f "$f" ] || continue
  grep -qF "$tdd" "$f" || note "$f must keep $tdd binding in its routing reference"
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "subagent profile-aware routing (single-source) checks passed"
