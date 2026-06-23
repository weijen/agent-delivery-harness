#!/usr/bin/env bash
# Regression sensor (issue #53): the code-review-subagent must invoke the
# public-exposure-audit skill on pre-commit/pre-PR changes and treat
# customer-supplied material / secrets / cloud IDs / endpoints in pushed or
# soon-to-be-pushed content as BLOCKING findings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review=".copilot/agents/code-review-subagent.agent.md"

if [ ! -f "$review" ]; then
  note "missing $review"
  echo "code-review public-exposure sensor FAILED"
  exit 1
fi

# References the new skill by path and by name.
grep -Eq 'skills/public-exposure-audit/SKILL\.md' "$review" \
  || note "$review must link the public-exposure-audit SKILL.md"
grep -Eq 'public-exposure-audit' "$review" \
  || note "$review must reference public-exposure-audit by name"

# Scopes the check to pre-commit / pre-PR review.
grep -Eiq 'pre-commit' "$review" || note "$review must scope exposure check to pre-commit changes"
grep -Eiq 'pre-PR'     "$review" || note "$review must scope exposure check to pre-PR changes"

# Names the AC#4 review targets.
for target in 'public repo' 'docs' 'prompts' 'skills' 'agents' 'workflows' 'fixtures' 'logs' 'generated'; do
  grep -Eiq "$target" "$review" || note "$review must name review target: $target"
done

# AC#5 — customer-supplied material etc. is BLOCKING in pushed/soon-to-be-pushed content.
grep -Eiq 'raw media|screenshots|decks|exports' "$review" \
  || note "$review must name customer-supplied material (raw media/screenshots/decks/exports) as a blocking class"
grep -Eiq 'tenant|subscription' "$review" || note "$review must name tenant/subscription IDs as a blocking class"
grep -Eiq 'endpoint' "$review"            || note "$review must name resource endpoints as a blocking class"
grep -Eiq 'environment file|\.env'  "$review" || note "$review must name local environment files as a blocking class"
grep -Eiq 'pushed|soon-to-be-pushed' "$review" \
  || note "$review must scope the blocking rule to pushed/soon-to-be-pushed content"

# The exposure rule must be associated with BLOCKING somewhere in the file.
grep -Eq 'BLOCKING' "$review" || note "$review must mark public-exposure findings as BLOCKING"

if [ "$fail" -ne 0 ]; then
  echo "code-review public-exposure sensor FAILED"
  exit 1
fi
echo "code-review public-exposure checks passed"
