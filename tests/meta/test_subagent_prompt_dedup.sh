#!/usr/bin/env bash
# Regression sensor (issue #202): the four subagent prompts must stay free of the
# intra-file repetition and fabricated worked examples that #202 removed.
#
# Guards:
#   - code-review-subagent: no "Worked example" section headings and none of the
#     fabricated example fixtures — the two output templates specify the format.
#   - planning-subagent: the per-depth prose was merged into ONE depth table
#     (a header row with a "Depth" column) and the file stays within the
#     ~150-line budget (guard at 175).
#   - "you do not call other subagents directly" is stated at most once across
#     the review and generator agents (routing lives once; harness owns the loop).
#   - "blocking findings first" is not restated across the review agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review=".copilot/agents/code-review-subagent.agent.md"
generator=".copilot/agents/generator-subagent.agent.md"
planner=".copilot/agents/planning-subagent.agent.md"

for f in "$review" "$generator" "$planner"; do
	[ -f "$f" ] || note "missing $f"
done

# --- Task 4: code-review worked examples removed ---------------------------
if [ -f "$review" ]; then
	if grep -Eqi '^#+ .*worked example' "$review"; then
		note "$review must not carry 'Worked example' section headings (removed in #202)"
	fi
	if grep -Eqi 'billing-balance|MCP server health' "$review"; then
		note "$review must not reintroduce the fabricated worked-example fixtures"
	fi
fi

# --- Task 3: planning-subagent depth table + line budget -------------------
if [ -f "$planner" ]; then
	grep -Eq '^\|.*Depth.*\|' "$planner" ||
		note "$planner must present the merged depth table (a header row with a Depth column)"
	lines="$(wc -l < "$planner")"
	if [ "$lines" -gt 175 ]; then
		note "$planner must stay within the ~150-line budget (guard 175); has $lines lines"
	fi
fi

# --- Task 2: 'do not call other subagents directly' stated once ------------
# Flatten newlines so a line-wrapped occurrence still counts. grep may match
# zero times, so tolerate its non-zero exit under set -e/pipefail.
count_phrase() {
	tr '\n' ' ' < "$1" | { grep -o 'call other subagents directly' || true; } | wc -l | tr -d ' '
}
total=0
for f in "$review" "$generator"; do
	[ -f "$f" ] && total=$((total + $(count_phrase "$f")))
done
if [ "$total" -gt 1 ]; then
	note "'do not call other subagents directly' must be stated once across the review/test agents; found $total"
fi

# --- Task 2: 'blocking findings first' not restated across the reviewer ----
if [ -f "$review" ]; then
	bf="$(grep -Eci 'blocking.*first|findings first|first.*blocking' "$review" || true)"
	if [ "$bf" -gt 4 ]; then
		note "$review restates 'blocking findings first' too many times ($bf); state the rule once (templates aside)"
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "subagent prompt dedup checks passed"
