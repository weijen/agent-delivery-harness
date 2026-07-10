#!/usr/bin/env bash
# Regression sensor (issue #265): the review loop must feed empirically
# refuted CRITICAL/MAJOR findings back into the known-false-positive registry.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

instructions=".copilot/instructions/harness.instructions.md"

if [ ! -f "$instructions" ]; then
  note "missing $instructions"
else
  section="$(sed -n '/^#### Grading-driven revision loops/,/^#### Pass the applicable instruction files into subagent prompts/p' "$instructions")"
  section_flat="$(printf '%s\n' "$section" | tr '\n' ' ')"

  if [ -z "$section" ]; then
    note "$instructions must contain the Grading-driven revision loops section"
  fi

  printf '%s\n' "$section" | grep -q '_review-known-false-positives' \
    || note "$instructions review loop must reference _review-known-false-positives"

  if ! printf '%s\n' "$section_flat" | grep -Eiq '((CRITICAL|MAJOR)[^.]{0,200}append[^.]{0,200}(empirically )?refut|append[^.]{0,200}(CRITICAL|MAJOR)[^.]{0,200}(empirically )?refut|append[^.]{0,200}(empirically )?refut[^.]{0,200}(CRITICAL|MAJOR)|(empirically )?refut[^.]{0,200}append[^.]{0,200}(CRITICAL|MAJOR))'; then
    note "$instructions review loop must tell the conductor to append when a CRITICAL/MAJOR finding is empirically refuted"
  fi

  if ! printf '%s\n' "$section_flat" | grep -Eiq '((disproving )?command[^.]{0,240}observed output|observed output[^.]{0,240}(disproving )?command)'; then
    note "$instructions registry entry must carry the actual disproving command and observed output"
  fi

  if ! printf '%s\n' "$section_flat" | grep -Eiq 'omit-never-fake|never invent|real command'; then
    note "$instructions registry entry must apply omit-never-fake / never invent / real command evidence"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "review registry feedback loop sensor FAILED"
  exit 1
fi

echo "review registry feedback loop checks passed"
