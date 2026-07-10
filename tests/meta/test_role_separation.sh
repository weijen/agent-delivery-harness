#!/usr/bin/env bash
# Regression sensor (issue #25/#78/#80; structural per #273): the NON-DELEGABLE
# role-separation doctrine, the per-feature handoff sequence, the plan->clarify->
# feature_list breakdown flow, and the feature-granularity rule must remain
# documented across the harness docs. Structure-level: this sensor asserts the
# guarded SECTIONS exist (heading anchors) and their closed VOCABULARY is
# present -- wording inside each section is free to change. Renaming/removing a
# guarded section title still fails; rewording a sentence does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

instructions=".copilot/instructions/harness.instructions.md"
harness_doc="docs/HARNESS.md"
planner=".copilot/agents/planning-subagent.agent.md"
agents_md="AGENTS.md"

# 1. harness.instructions.md -- guarded sections exist + closed vocabulary.
if [ -f "$instructions" ]; then
	grep -Eq '^#+ .*non-delegable' "$instructions" \
		|| note "$instructions must keep the non-delegable conductor-role section"
	grep -Eq '^#+ .*[Hh]andoff sequence' "$instructions" \
		|| note "$instructions must keep the per-feature handoff sequence section"
	grep -Eq '^#+ .*What counts as one feature' "$instructions" \
		|| note "$instructions must keep the feature-granularity section"
	for token in 'non-delegable' 'test-subagent' 'implementation-subagent' 'RED' 'GREEN' 'regression_sensor' 'split' 'merge' 'conductor TDD'; do
		grep -q "$token" "$instructions" || note "$instructions role/granularity vocabulary must include '$token'"
	done
	grep -Eqi 'exactly one[^.]*regression_sensor' "$instructions" \
		|| note "$instructions granularity rule must tie one feature to exactly one regression_sensor"
else
	note "missing $instructions"
fi

# 2. docs/HARNESS.md -- echoes the same sections + vocabulary (no drift).
if [ -f "$harness_doc" ]; then
	grep -Eq '^#+ .*non-delegable' "$harness_doc" \
		|| note "$harness_doc must keep the non-delegable conductor-role section"
	grep -Eq '^#+ .*[Bb]reakdown flow' "$harness_doc" \
		|| note "$harness_doc must keep the plan->clarify->feature_list breakdown-flow section"
	grep -Eq '^#+ .*What counts as one feature' "$harness_doc" \
		|| note "$harness_doc must keep the feature-granularity section"
	for token in 'test-subagent' 'implementation-subagent' 'human-input gate' 'regression_sensor'; do
		grep -q "$token" "$harness_doc" || note "$harness_doc handoff/breakdown vocabulary must include '$token'"
	done
else
	note "missing $harness_doc"
fi

# 3. planning-subagent -- surfaces Open Questions, disclaims authoring the breakdown.
if [ -f "$planner" ]; then
	grep -Eqi 'Open Questions|Needs-Human-Input' "$planner" \
		|| note "$planner must require an Open Questions / Needs-Human-Input section"
	grep -q 'feature_list.json' "$planner" \
		|| note "$planner must reference feature_list.json (to disclaim authoring it)"
else
	note "missing $planner"
fi

# 4. AGENTS.md -- points at the single-source granularity rule (short vocab token).
if [ -f "$agents_md" ]; then
	grep -Eqi 'granularity' "$agents_md" \
		|| note "$agents_md must reference the feature-granularity rule (single source of truth)"
else
	note "missing $agents_md"
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "role-separation regression checks passed"
