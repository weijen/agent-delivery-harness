#!/usr/bin/env bash
# Regression sensor (issue #265): code-review-subagent must execute before CRITICAL
# for cannot-run / cannot-parse / crashes claims.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review_agent=".copilot/agents/code-review-subagent.agent.md"

[ -f "$review_agent" ] || note "missing $review_agent"

if [ -f "$review_agent" ]; then
  grep -qF 'Execute-before-CRITICAL' "$review_agent" \
    || note "$review_agent must define a named Execute-before-CRITICAL rule"

  grep -qiF 'executed reproduction' "$review_agent" \
    || note "$review_agent must require an executed reproduction before CRITICAL"
  grep -Eqi 'reviewed HEAD' "$review_agent" \
    || note "$review_agent must require the reproduction to run on the reviewed HEAD"
  grep -Eqi 'command.+observed output|observed output.+command' "$review_agent" \
    || note "$review_agent must require both the command and observed output"

  grep -qiF 'confidence: low' "$review_agent" \
    || note "$review_agent must spell out the downgrade confidence: low"
  grep -Eqi 'MAJOR[^[:cntrl:]]+never CRITICAL|never CRITICAL[^[:cntrl:]]+MAJOR' "$review_agent" \
    || note "$review_agent must say missing executed reproduction is MAJOR, never CRITICAL"

  grep -qiF 'cannot run' "$review_agent" \
    || note "$review_agent must scope the rule to cannot run claims"
  grep -qiF 'cannot parse' "$review_agent" \
    || note "$review_agent must scope the rule to cannot parse claims"
  grep -qiF 'crashes' "$review_agent" \
    || note "$review_agent must scope the rule to crashes claims"
fi

if [ "$fail" -ne 0 ]; then
  echo "review execute-before-CRITICAL sensor FAILED"
  exit 1
fi

echo "review execute-before-CRITICAL checks passed"
