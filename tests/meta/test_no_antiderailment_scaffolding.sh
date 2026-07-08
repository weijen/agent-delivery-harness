#!/usr/bin/env bash
# Regression sensor (issue #180): audit skills stay free of old anti-derailment
# scaffolding and literal command/regex recipe blocks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

skills_dir=".copilot/skills"

dc="${skills_dir}/dead-code-detection/SKILL.md"
if [ -f "$dc" ]; then
  ! grep -q 'Keep tool execution simple and recoverable' "$dc" || note "$dc still has tool-execution recovery scaffolding"
  grep -qi 'commands that ran' "$dc" || note "$dc lost wording about commands that ran"
  grep -qi 'commands that could not run' "$dc" || note "$dc lost wording about commands that could not run"
  grep -q 'Default to Defer-protect' "$dc" || note "$dc lost the public-API Defer-protect default"
else
  note "missing $dc"
fi

sd="${skills_dir}/sync-docs/SKILL.md"
if [ -f "$sd" ]; then
  ! grep -q 'Useful Inventory Commands' "$sd" || note "$sd still has generic inventory command recipes"
  ! grep -q 'Do not flag examples inside fenced code blocks' "$sd" || note "$sd still has fenced-code false-positive warning"
  grep -q '| Tier | Treatment | Examples |' "$sd" || note "$sd lost the documentation tier table"
  grep -q '| Claim Type | How to Verify |' "$sd" || note "$sd lost the high-rot claim table"
else
  note "missing $sd"
fi

for skill in find-brute-force find-duplicates find-over-design; do
  f="${skills_dir}/${skill}/SKILL.md"
  [ -f "$f" ] || { note "missing $f"; continue; }
  ! grep -q 'HACK|FIXME|XXX' "$f" || note "$f still has literal marker-comment regex alternation"
  ! grep -q 'except:|except Exception' "$f" || note "$f still has literal swallowed-error regex alternation"
  grep -q 'Common Search Seeds' "$f" || note "$f lost Common Search Seeds categories"
  grep -q '| Severity | Criteria |' "$f" || note "$f lost its severity table"
done

if [ "$fail" -ne 0 ]; then
  echo "anti-derailment scaffolding sensor FAILED"
  exit 1
fi

echo "anti-derailment scaffolding checks passed"
