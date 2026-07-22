#!/usr/bin/env bash
# Regression sensor (issue #156): the code-review-subagent prompt must require
# a Trace / Process Evidence section that separates process evidence from code
# correctness and treats trace discipline violations as blocking review findings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review=".copilot/agents/code-review-subagent.agent.md"

if [ ! -f "$review" ]; then
  note "missing $review"
  echo "code-review trace-evidence sensor FAILED"
  exit 1
fi

section="$({ awk '
  /Trace \/ Process Evidence/ { in_section=1 }
  in_section { print }
  in_section && /^##[[:space:]]+/ && !/Trace \/ Process Evidence/ { exit }
' "$review" || true; } )"

assert_file() {
  local pattern="$1"
  local message="$2"
  grep -Eiq "$pattern" "$review" || note "$message"
}

assert_section() {
  local pattern="$1"
  local message="$2"
  local normalized_section
  normalized_section="$(printf '%s\n' "$section" | tr '\n' ' ')"
  if ! grep -Eiq "$pattern" <<<"$normalized_section"; then
    note "$message"
  fi
}

# 1. Required section heading.
assert_file 'Trace / Process Evidence' "$review must include a Trace / Process Evidence section"

# 2. Local trace artifacts to locate/read.
assert_section 'trace\.jsonl' "$review Trace / Process Evidence section must name trace.jsonl"
assert_section 'trace-summary\.json' "$review Trace / Process Evidence section must name trace-summary.json"

# 3. Trace tooling to run when a local trace exists.
assert_section 'check-trace-consistency\.sh' "$review Trace / Process Evidence section must name check-trace-consistency.sh"

# 4. Trace coverage reporting semantics.
assert_section 'has_tool_spans' "$review Trace / Process Evidence section must report has_tool_spans"
assert_section 'instrumentation.*absent|absent.*instrumentation' "$review Trace / Process Evidence section must state false means instrumentation absent"
assert_section 'tokens' "$review Trace / Process Evidence section must report token coverage"
assert_section 'unavailable' "$review Trace / Process Evidence section must define unavailable token semantics"
assert_section 'schema' "$review Trace / Process Evidence section must mention schema validation"

# 5. Evidence-authority split.
assert_section 'authoritative' "$review Trace / Process Evidence section must identify authoritative evidence"
assert_section 'corroborat' "$review Trace / Process Evidence section must identify corroborating evidence"
assert_section 'tool[ -]?span|tool span' "$review Trace / Process Evidence section must distinguish tool spans"
assert_section 'agent[ -]?span|agent span|agent' "$review Trace / Process Evidence section must distinguish agent spans"

# 6. RED/implementation/GREEN ordering and waiver handling.
assert_section 'red_handback' "$review Trace / Process Evidence section must require red_handback evidence"
assert_section 'impl_handback' "$review Trace / Process Evidence section must require impl_handback evidence"
assert_section 'green_handback' "$review Trace / Process Evidence section must require green_handback evidence"
assert_section 'waiv' "$review Trace / Process Evidence section must cover waivers"
assert_section 'red_reentry' "$review Trace / Process Evidence section must cover red_reentry"

# 7. Role attribution and unavailable evidence handling.
assert_section 'test-subagent' "$review Trace / Process Evidence section must attribute test-subagent evidence"
assert_section 'implementation-subagent' "$review Trace / Process Evidence section must attribute implementation-subagent evidence"
assert_section 'trace evidence unavailable' "$review Trace / Process Evidence section must use the phrase trace evidence unavailable"

# 8. Blocking process violations and review finding terms.
assert_section 'teeth_proof_missing' "$review Trace / Process Evidence section must name teeth_proof_missing"
assert_section 'red_first_profile_mismatch' "$review Trace / Process Evidence section must name red_first_profile_mismatch"
assert_section 'deviation' "$review Trace / Process Evidence section must surface deviations as review findings"
assert_section 'loop' "$review Trace / Process Evidence section must surface loop findings"
assert_section 'BLOCKING' "$review Trace / Process Evidence section must mark process violations BLOCKING"

# 9. Process discipline is separate from implementation correctness.
assert_section 'does not prove|not prove' "$review Trace / Process Evidence section must state trace discipline does not prove correctness"
assert_section 'process violation' "$review Trace / Process Evidence section must state clean code does not excuse process violations"

# 10. Process violations feed into verdict.
assert_section 'NEEDS_REVISION|BLOCKED|verdict' "$review Trace / Process Evidence section must tie process violations to NEEDS_REVISION/verdict/BLOCKED"

# 11. Log-detail citation for BLOCKING/CRITICAL process findings (issue #221).
assert_section 'log\.jsonl' "$review Trace / Process Evidence section must name log.jsonl"
assert_section 'payload' "$review Trace / Process Evidence section must require citing the log failure payload (actual failing output)"
assert_section 'failure record|failing output|failure detail|failure payload' "$review Trace / Process Evidence section must require citing the log failure record detail rather than only the span summary"
assert_section 'log evidence unavailable' "$review Trace / Process Evidence section must use the exact absence phrase log evidence unavailable"
assert_section 'log evidence unavailable[^.]*never inferred|log evidence unavailable[^.]*not inferred' "$review Trace / Process Evidence section must state log evidence unavailable is never inferred as pass"

if [ "$fail" -ne 0 ]; then
  echo "code-review trace-evidence sensor FAILED"
  exit 1
fi
echo "code-review trace-evidence checks passed"
