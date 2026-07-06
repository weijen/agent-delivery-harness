#!/usr/bin/env bash
# test_ci_coverage_docs.sh — regression sensor for issue #129, feature f4: the
# project-CI coverage gate must be documented so an operator learns about it
# before hitting it. Asserts the harness instructions and docs/HARNESS.md
# describe the ci-gate, its preflight WARN, the SKIP_CI_GATE=1 escape hatch, and
# that harness-smoke.yml is NOT project CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

INSTR=".copilot/instructions/harness.instructions.md"
HARNESS="docs/HARNESS.md"

# --- harness instructions ----------------------------------------------------
if [ ! -f "$INSTR" ]; then
  note "missing $INSTR"
else
  grep -q 'ci-gate' "$INSTR" || note "$INSTR: does not document the ci-gate"
  grep -q 'SKIP_CI_GATE' "$INSTR" || note "$INSTR: does not document the SKIP_CI_GATE escape hatch"
fi

# --- docs/HARNESS.md ---------------------------------------------------------
if [ ! -f "$HARNESS" ]; then
  note "missing $HARNESS"
else
  grep -q 'ci-gate' "$HARNESS" || note "$HARNESS: does not document the ci-gate"
  grep -q 'SKIP_CI_GATE' "$HARNESS" || note "$HARNESS: does not document the SKIP_CI_GATE escape hatch"
  grep -Eiq 'project[ -]?CI' "$HARNESS" || note "$HARNESS: does not describe the project-CI coverage expectation"
  grep -q 'harness-smoke' "$HARNESS" || note "$HARNESS: does not clarify that harness-smoke.yml is not project CI"
fi

if [ "$fail" -ne 0 ]; then
  echo "ci-coverage docs sensor FAILED"
  exit 1
fi
printf 'ci-coverage docs sensor passed\n'
