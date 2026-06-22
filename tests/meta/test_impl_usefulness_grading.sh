#!/usr/bin/env bash
# Regression sensor: the four audit skills must document an implementation-
# usefulness grading that is SEPARATE from their severity/classification model,
# with domain-tailored decision labels and a guard that a high usefulness score
# never overrides severity or licenses unsafe deletion / premature abstraction /
# simplifying a justified boundary. The evaluator/reviewer subagents must consume
# that grading.  (Issue #13.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

skills_dir=".copilot/skills"

# 1. Every audit skill documents implementation-usefulness grading and includes a
#    decision field in its report template.
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
  # The grading must be framed as distinct from severity/classification.
  grep -Eqi 'separate from|distinct from|not (a )?(replace|substitute)|in addition to .*severity|alongside .*severity' "$f" ||
    note "$f must state the grading is separate from severity/classification"
  # Domain-tailored decision label present.
  grep -qi "$decision" "$f" || note "$f must include its tailored decision '$decision'"
  # A decision field appears in the report/report-template.
  grep -Eqi 'impl.* decision|implementation decision|usefulness' "$f" ||
    note "$f report template must include an implementation/usefulness decision field"
  # Guard: high usefulness must not override severity or cause unsafe action.
  grep -Eqi 'does not override|must not override|not a severity (override|replacement)|still blocks' "$f" ||
    note "$f must state a high usefulness score does not override blocking severity"
done

# 2. dead-code-detection must protect public APIs / extension points / migrations
#    / generated code / compatibility paths from a "delete now" decision.
dc="${skills_dir}/dead-code-detection/SKILL.md"
if [ -f "$dc" ]; then
  grep -Eqi 'public api|extension point|migration|generated|compat' "$dc" ||
    note "$dc must protect public APIs/extension points/migrations/generated/compat from deletion"
fi

# 3. Evaluator/reviewer subagents consume the grading.
review=".copilot/agents/code-review-subagent.agent.md"
test_agent=".copilot/agents/test-subagent.agent.md"
if [ -f "$review" ]; then
  grep -qi 'implementation-usefulness\|implementation decision' "$review" ||
    note "$review must explain consuming implementation-usefulness decisions"
  grep -Eqi 'CRITICAL|MAJOR|MINOR' "$review" || note "$review must preserve its CRITICAL/MAJOR/MINOR model"
fi
if [ -f "$test_agent" ]; then
  grep -qi 'verification clarity' "$test_agent" ||
    note "$test_agent must use verification clarity when selecting/requiring sensors"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "implementation-usefulness grading checks passed"
