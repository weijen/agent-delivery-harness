#!/usr/bin/env bash
# Regression sensor (issue #179): shared audit-skill conventions stay extracted
# from the four audit skills that previously carried duplicate boilerplate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

shared=".copilot/skills/_audit-conventions.md"
skills_dir=".copilot/skills"
audit_skills=(find-brute-force find-duplicates find-over-design dead-code-detection)

[ -f "$shared" ] || note "missing $shared"
if [ -f "$shared" ]; then
  first_line="$(sed -n '1p' "$shared")"
  [ "$first_line" != '---' ] || note "$shared must not have YAML frontmatter"
fi

for skill in "${audit_skills[@]}"; do
  f="${skills_dir}/${skill}/SKILL.md"
  [ -f "$f" ] || { note "missing $f"; continue; }
  grep -q '_audit-conventions.md' "$f" || note "$f must reference _audit-conventions.md"
  if grep -Eq 'Score every .* on five dimensions|High / Medium / Low' "$f"; then
    note "$f still contains the old 5-dimension H/M/L grading matrix"
  fi
done

for skill in find-brute-force find-duplicates find-over-design; do
  f="${skills_dir}/${skill}/SKILL.md"
  [ -f "$f" ] || continue
  if grep -Eq '^## Remediation Plan Template|^# Plan: ' "$f"; then
    note "$f still contains a remediation plan template block"
  fi
done

dc="${skills_dir}/dead-code-detection/SKILL.md"
if [ -f "$dc" ]; then
  grep -q 'Default to Defer-protect' "$dc" || note "$dc lost the public-API Defer-protect default"
  grep -q 'public APIs, exported' "$dc" || note "$dc lost the public/exported API protection wording"
fi

if [ "$fail" -ne 0 ]; then
  echo "audit-conventions shared sensor FAILED"
  exit 1
fi

echo "audit-conventions shared checks passed"
