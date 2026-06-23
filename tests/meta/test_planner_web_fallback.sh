#!/usr/bin/env bash
# Regression sensor (issue #49): the planning-subagent must permit web research
# as a GUARDED FALLBACK at `standard` depth, while keeping `quick` depth free of
# any web research.
#
# This sensor fails if a future edit drops the standard-depth fallback or its
# guardrails, or if it leaks web research into the quick depth.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

planner=".copilot/agents/planning-subagent.agent.md"
[ -f "$planner" ] || note "missing $planner"

# section <name> — print the body of the "### `<name>`" depth block, up to the
# next "### " heading.
section() {
  awk -v want="$1" '
    /^### / {
      inblk = ($0 ~ "`" want "`")
      next
    }
    inblk { print }
  ' "$planner"
}

if [ -f "$planner" ]; then
  quick="$(section quick)"
  standard="$(section standard)"

  [ -n "$quick" ]    || note "could not extract the quick depth section from $planner"
  [ -n "$standard" ] || note "could not extract the standard depth section from $planner"

  # --- standard: guarded web fallback is now allowed -----------------------
  if printf '%s' "$standard" | grep -Eqi 'web research'; then :; else
    note "standard section must address web research"
  fi
  printf '%s' "$standard" | grep -Eqi 'fallback' ||
    note "standard section must allow web research as a fallback"
  printf '%s' "$standard" | grep -Eqi 'codebase cannot answer|cannot answer a specific' ||
    note "standard section must gate the fallback to questions the codebase cannot answer"
  printf '%s' "$standard" | grep -Eqi 'open.?ended' ||
    note "standard section must forbid open-ended topic exploration"
  printf '%s' "$standard" | grep -Eqi 'local context' ||
    note "standard section must require searching local context first"
  printf '%s' "$standard" | grep -Eqi 'cite the url|cite .*url' ||
    note "standard section must require citing the URL when it influenced a decision"
  printf '%s' "$standard" | grep -Eqi 'web/fetch|web/githubRepo' ||
    note "standard section must name the web tools it permits"
  # The standard fallback must not silently swallow broad gaps: a broad/unfamiliar
  # topic still escalates to an open question rather than open-ended browsing.
  printf '%s' "$standard" | grep -Eqi 'open question' ||
    note "standard section must still escalate broad gaps as an open question"

  # --- quick: still no web research ----------------------------------------
  printf '%s' "$quick" | grep -Eqi 'not used at this depth' ||
    note "quick section must still state web research is not used at this depth"
  if printf '%s' "$quick" | grep -Eqi '\bfallback\b'; then
    note "quick section must NOT permit a web-research fallback"
  fi
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "planner web-fallback checks passed"
