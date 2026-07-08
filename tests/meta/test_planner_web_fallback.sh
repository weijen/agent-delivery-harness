#!/usr/bin/env bash
# Regression sensor (issue #49; restructured for the depth-table in #202): the
# planning-subagent must permit web research as a GUARDED FALLBACK at `standard`
# (and `deep`) depth, while keeping `quick` depth free of any web research.
#
# The per-depth prose blocks were merged into one depth table plus a single
# shared "Web research" subsection. This sensor no longer parses per-depth
# `### `<name>`` blocks; it checks the shared web-research guardrails exist and
# that the depth table marks `quick` as not using web research.
#
# It fails if a future edit drops the guarded fallback or its guardrails, or if
# it grants `quick` depth a web-research fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

planner=".copilot/agents/planning-subagent.agent.md"
[ -f "$planner" ] || note "missing $planner"

if [ -f "$planner" ]; then
	# --- shared web-research guardrails (standard/deep fallback) --------------
	grep -Eqi 'web research' "$planner" ||
		note "$planner must address web research"
	grep -Eqi 'fallback' "$planner" ||
		note "$planner must allow web research only as a guarded fallback"
	grep -Eqi 'codebase cannot answer|cannot answer a specific' "$planner" ||
		note "$planner must gate the fallback to questions the codebase cannot answer"
	grep -Eqi 'open.?ended' "$planner" ||
		note "$planner must forbid open-ended topic exploration"
	grep -Eqi 'local context' "$planner" ||
		note "$planner must require searching local context first"
	grep -Eqi 'cite the url|cite .*url' "$planner" ||
		note "$planner must require citing the URL when it influenced a decision"
	grep -Eqi 'web/fetch|web/githubRepo' "$planner" ||
		note "$planner must name the web tools it permits"
	grep -Eqi 'open question' "$planner" ||
		note "$planner must still escalate broad gaps as an open question"

	# --- quick depth: still no web research ----------------------------------
	# The depth table marks quick's web cell "not used at this depth" on one row.
	grep -Eqi 'quick.*not used at this depth|not used at this depth.*quick' "$planner" ||
		note "$planner depth table must mark quick depth web research 'not used at this depth'"
	# quick's own table row must not grant a web-research fallback.
	quick_row="$(grep -Ei 'quick.*not used at this depth|not used at this depth.*quick' "$planner" | head -1)"
	if printf '%s' "$quick_row" | grep -qi 'fallback'; then
		note "$planner must NOT grant quick depth a web-research fallback"
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "planner web-fallback checks passed"
