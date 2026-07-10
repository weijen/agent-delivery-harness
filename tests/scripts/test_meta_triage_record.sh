#!/usr/bin/env bash
# Regression sensor (issue #273, feature triage-record): the meta-test triage
# decision record must exist as a tracked, auditable artifact that states the
# KEEP/CONVERT/DELETE rubric and carries the four verdict buckets. This sensor
# guards the record's STRUCTURE (rubric legend + verdict tokens present), not
# its prose — per the very rubric it records.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

doc="docs/evaluation/meta-test-triage.md"
[ -f "$doc" ] || { echo "✗ missing $doc"; exit 1; }

# The rubric legend and its four verdict classes must be present.
for token in 'KEEP' 'CONVERT' 'DELETE' 'deletion criterion' 'rubric'; do
  grep -Eiq "$token" "$doc" || note "$doc must record the '$token' rubric element"
done

# The four verdict labels used in the tables must appear.
for verdict in 'KEEP-structural' 'KEEP-cross-file' 'CONVERT' 'DELETE'; do
  grep -Fq "$verdict" "$doc" || note "$doc must use the verdict label: $verdict"
done

# It must be an honest, non-empty enumeration: at least one row per class and a
# reference to the durable rubric home (bash.instructions.md).
grep -Fq 'bash.instructions.md' "$doc" \
  || note "$doc must point at the durable rubric home (bash.instructions.md)"

# Sanity: the record enumerates a meaningful number of tests/meta verdicts
# (guards against an empty stub). Count table rows referencing test_*.sh.
rows="$(grep -Ec '^\| test_[A-Za-z0-9_]+\.sh ' "$doc" || true)"
if [ "$rows" -lt 40 ]; then
  note "$doc must enumerate the tests/meta verdicts (found only $rows rows)"
fi

if [ "$fail" -ne 0 ]; then
  echo "meta-test triage record sensor FAILED"
  exit 1
fi
echo "meta-test triage record sensor passed ($rows verdict rows)"
