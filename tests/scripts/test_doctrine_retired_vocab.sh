#!/usr/bin/env bash
# test_doctrine_retired_vocab.sh — regression sensor for issue #424: the
# always-injected doctrine surface must not teach retired concepts or false
# mechanics as current.
#
# Rule: a forbidden term may appear ONLY on a line that also carries an
# explicit retirement/historical marker (retired, historical, legacy, removed,
# the retiring issue number, or the role-label caveat). Anything else is the
# #424 failure mode: doctrine teaching a mechanism the scripts refuse or
# ignore. This deliberately checks LINES, not sections — cheap, deterministic,
# and it caught every one of the 2026-08-16 audit's vocabulary findings.
#
# Surface: AGENTS.md, all instruction files, the reviewer contract, prompts,
# docs/HARNESS.md, docs/getting-started.md.
#
# Exit: 0 clean · 1 any unannotated retired term.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

DOCTRINE_FILES=(
  "AGENTS.md"
  ".copilot/instructions/harness.instructions.md"
  ".copilot/instructions/workflow-tiers.instructions.md"
  ".copilot/instructions/bash.instructions.md"
  ".copilot/instructions/python.instructions.md"
  ".copilot/instructions/tdd.instructions.md"
  ".copilot/instructions/terraform-azure.instructions.md"
  ".copilot/agents/code-review-subagent.agent.md"
  ".copilot/prompts/session-ritual.prompt.md"
  ".copilot/prompts/audit-sweep.prompt.md"
  "docs/HARNESS.md"
  "docs/getting-started.md"
)

# Lines carrying any of these markers are explicitly-historical mentions and
# exempt (the retirement issue numbers double as markers).
ALLOW='retired|historical|legacy|removed|role label|#33[0-9]|#350|#352|#419|#424'

# term<TAB>reason — reason echoed on failure so the fix is self-describing.
TERMS=$(cat <<'LIST'
teeth-proof	#334 retired the teeth-proof step
teeth_proof	#334 retired the teeth_proof field (historical reads only)
Loop 2	Loop-1/2 vocabulary is defined nowhere in current doctrine (#303)
Loop-2	Loop-1/2 vocabulary is defined nowhere in current doctrine (#303)
TRACE_SENSOR_SCOPE	no script reads it (#352 retired green-handback plumbing)
TRACE_SENSOR_COUNT	no script reads it (#352 retired green-handback plumbing)
trace-summary.json	reporter retired in #419
kind: hard	the contract field is 'mode:', not 'kind:'
every commit, every PR	per-commit review duty retired (#352); review runs once at issue completion
You are the conductor	#352: single delivering agent
The conductor invokes subagents	#352: the only subagent invocation is the end-of-issue review
delivering conductor	#352: say 'delivering agent'
LIST
)

for rel in "${DOCTRINE_FILES[@]}"; do
  file="${ROOT}/${rel}"
  [ -f "$file" ] || { fail "doctrine surface file missing: ${rel}"; continue; }
  while IFS=$'\t' read -r term reason; do
    [ -n "$term" ] || continue
    hits="$(grep -nF "$term" "$file" | grep -EIiv "$ALLOW" || true)"
    if [ -n "$hits" ]; then
      fail "${rel}: unannotated retired term '${term}' (${reason}): $(head -1 <<<"$hits" | cut -c1-140)"
    fi
  done <<< "$TERMS"
done

# The re-anchor meta test must pin the LIVE env-var family, not the retired one.
REANCHOR_TEST="${ROOT}/tests/meta/test_post_compaction_reanchor.sh"
grep -q 'TRACE_FAILURE_CLASS' "$REANCHOR_TEST" \
  || fail "post-compaction re-anchor meta test no longer pins the live TRACE_FAILURE_CLASS term"
grep -q 'TRACE_SENSOR_SCOPE' "$REANCHOR_TEST" \
  && fail "post-compaction re-anchor meta test still pins the retired TRACE_SENSOR_SCOPE term"

if [ "$fails" -ne 0 ]; then
  printf '\n%d retired-vocabulary obligation(s) failed.\n' "$fails" >&2
  exit 1
fi
printf 'doctrine surface free of unannotated retired vocabulary (%d files, %d terms)\n' \
  "${#DOCTRINE_FILES[@]}" "$(grep -c '	' <<< "$TERMS")"
