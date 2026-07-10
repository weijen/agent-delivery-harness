#!/usr/bin/env bash
# Regression sensor (issue #13; structural per #273): the four audit skills must
# document an implementation-usefulness grading SEPARATE from severity, with
# domain-tailored decision labels and a guard that a high usefulness score never
# overrides blocking severity. Evaluator/reviewer subagents consume it.
# Structure-level: asserts the guarded section exists (heading anchor) + closed
# vocabulary; wording is free to change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

skills_dir=".copilot/skills"

# The guarded section exists in at least the skills that carry the heading.
grep -Eq '^#+ .*Implementation-Usefulness' "${skills_dir}/find-over-design/SKILL.md" \
  || note "find-over-design/SKILL.md must keep the Implementation-Usefulness section"

for skill in find-brute-force find-duplicates find-over-design dead-code-detection; do
  f="${skills_dir}/${skill}/SKILL.md"
  [ -f "$f" ] || { note "missing $f"; continue; }
  case "$skill" in
    find-brute-force)    decision='Fix now' ;;
    find-duplicates)     decision='Fix now' ;;
    find-over-design)    decision='Simplify now' ;;
    dead-code-detection) decision='Delete now' ;;
  esac
  grep -qi 'implementation-usefulness' "$f" || note "$f must document implementation-usefulness grading"
  grep -Eqi 'separate from|distinct from' "$f" || note "$f must state the grading is separate from severity"
  grep -qi "$decision" "$f" || note "$f must include its tailored decision '$decision'"
  grep -qi 'usefulness' "$f" || note "$f report template must include a usefulness decision field"
  grep -Eqi 'does not override|still blocks' "$f" || note "$f must state a high usefulness score does not override blocking severity"
done

dc="${skills_dir}/dead-code-detection/SKILL.md"
if [ -f "$dc" ]; then
  grep -Eqi 'public api|extension point|migration|generated|compat' "$dc" \
    || note "$dc must protect public APIs/extension points/migrations/generated/compat from deletion"
fi

review=".copilot/agents/code-review-subagent.agent.md"
test_agent=".copilot/agents/test-subagent.agent.md"
if [ -f "$review" ]; then
  grep -Eqi 'implementation-usefulness|implementation decision' "$review" || note "$review must consume implementation-usefulness decisions"
  grep -Eqi 'CRITICAL|MAJOR|MINOR' "$review" || note "$review must preserve its CRITICAL/MAJOR/MINOR model"
fi
if [ -f "$test_agent" ]; then
  grep -qi 'verification clarity' "$test_agent" || note "$test_agent must use verification clarity when selecting sensors"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "implementation-usefulness grading checks passed"
