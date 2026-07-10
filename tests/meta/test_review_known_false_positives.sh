#!/usr/bin/env bash
# Regression sensor (issue #265): code review known-false-positive registry
# exists, is seeded, and is consulted before syntax/version-support findings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

registry=".copilot/skills/_review-known-false-positives.md"
agent=".copilot/agents/code-review-subagent.agent.md"

if [ ! -f "$registry" ]; then
  note "$registry must exist"
else
  grep -Eq 'PEP 758' "$registry" \
    || note "$registry must contain a PEP 758 entry"
  grep -Eq 'except A, B|except \(A, B\)|unparenthesized[- ]multi[- ]exception' "$registry" \
    || note "$registry must name the refuted multi-exception except form"
  grep -Eiq 'refuted|false' "$registry" \
    || note "$registry must identify the entry as a known false positive/refuted claim"
  grep -Eq 'python3? -c' "$registry" \
    || note "$registry must include a runnable disproving python -c command"
  grep -Eiq 'append-only|Known False Positives' "$registry" \
    || note "$registry must frame itself as an append-only known-false-positive registry"
fi

if [ ! -f "$agent" ]; then
  note "$agent must exist"
else
  grep -q '_review-known-false-positives' "$agent" \
    || note "$agent must reference _review-known-false-positives"
  grep -Eiq 'consult[^.[:cntrl:]]*(syntax|version-support)|(syntax|version-support)[^.[:cntrl:]]*consult' "$agent" \
    || note "$agent must require consulting the registry before syntax/version-support findings"
fi

if [ "$fail" -ne 0 ]; then
  echo "review-known-false-positives sensor FAILED"
  exit 1
fi
echo "review-known-false-positives checks passed"
