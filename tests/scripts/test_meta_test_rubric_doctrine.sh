#!/usr/bin/env bash
# Regression sensor (issue #273, feature rubric-doctrine): the KEEP/CONVERT/DELETE
# meta-test rubric must be recorded in the testing-conventions doctrine so future
# meta-tests are born structural. Structure-level: asserts the rubric section
# exists (heading anchor) and its closed vocabulary is present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

doc=".copilot/instructions/bash.instructions.md"
[ -f "$doc" ] || { echo "✗ missing $doc"; exit 1; }

# The rubric section exists (heading anchor).
grep -Eqi '^#+ .*meta-test' "$doc" \
  || note "$doc must keep a meta-test rubric section (heading)"

# Closed vocabulary: the three verdict classes + the deletion criterion.
for token in 'KEEP' 'CONVERT' 'DELETE' 'structural' 'phrase-pinning'; do
  grep -Fq "$token" "$doc" || note "$doc meta-test rubric must state '$token'"
done

# It must reference the auditable triage record.
grep -Fq 'meta-test-triage.md' "$doc" \
  || note "$doc must point at the triage decision record (docs/evaluation/meta-test-triage.md)"

if [ "$fail" -ne 0 ]; then
  echo "meta-test rubric doctrine sensor FAILED"
  exit 1
fi
echo "meta-test rubric doctrine sensor passed"
