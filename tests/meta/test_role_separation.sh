#!/usr/bin/env bash
# Regression sensor: the harness docs must state the NON-DELEGABLE role-separation
# rule — when the issue workflow is active, the conductor must not directly write
# tests/sensors or production implementation for feature work. They must also
# describe the per-feature handoff sequence and require the Action Log to
# distinguish conductor actions from subagent handbacks.
#
# This sensor fails if any of those guarantees is dropped from the harness docs,
# so a future edit cannot silently weaken the role separation that issue #25
# established.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

instructions=".copilot/instructions/harness.instructions.md"
harness_doc="docs/HARNESS.md"

[ -f "$instructions" ] || note "missing $instructions"

# 1. Explicit non-delegable rule: the conductor must NOT directly do
#    test/sensor or production implementation work for feature work.
if [ -f "$instructions" ]; then
	if ! grep -qi 'must not' "$instructions" ||
		! grep -Eqi 'conductor (must not|does not|never)' "$instructions"; then
		note "$instructions must state the conductor MUST NOT directly do feature work"
	fi
	# The forbidden-action wording must name both test/sensor work and
	# production implementation as non-delegable for the conductor.
	if ! grep -Eqi 'non-delegable|not delegable|cannot be delegated' "$instructions"; then
		note "$instructions must label the conductor's forbidden feature work as non-delegable"
	fi
	if ! grep -Eqi 'write (tests|sensors)|test.?writing|sensor implementation' "$instructions"; then
		note "$instructions must name test/sensor writing as conductor-forbidden"
	fi
	if ! grep -Eqi 'production implementation|production code|production assets' "$instructions"; then
		note "$instructions must name production implementation as conductor-forbidden"
	fi
	# 2. The per-feature handoff sequence must be documented:
	#    conductor selects -> test-subagent RED -> implementation-subagent ->
	#    test-subagent GREEN -> conductor commits/pushes.
	for token in 'select' 'test-subagent' 'implementation-subagent' 'RED' 'GREEN'; do
		if ! grep -qi "$token" "$instructions"; then
			note "$instructions handoff sequence must mention '$token'"
		fi
	done
	# 3. The Action Log must distinguish conductor actions from subagent
	#    handbacks; a log that only says "conductor TDD" is non-compliant.
	if ! grep -qi 'conductor TDD' "$instructions"; then
		note "$instructions must call out that a log saying only 'conductor TDD' is non-compliant"
	fi
	if ! grep -Eqi 'distinguish .*conductor|conductor .*from .*subagent|subagent handbacks' "$instructions"; then
		note "$instructions Action Log rule must distinguish conductor actions from subagent handbacks"
	fi
fi

# 4. The human-readable lifecycle doc must echo the non-delegable handoff so the
#    two docs cannot drift apart.
if [ -f "$harness_doc" ]; then
	if ! grep -Eqi 'non-delegable|must not directly' "$harness_doc"; then
		note "$harness_doc must describe the non-delegable conductor role separation"
	fi
	for token in 'test-subagent' 'implementation-subagent'; do
		grep -qi "$token" "$harness_doc" ||
			note "$harness_doc must mention '$token' in the handoff sequence"
	done
fi

# 5. The plan -> clarify -> feature_list breakdown flow must be explicit (issue
#    #78): the planning-subagent surfaces Open Questions and never authors the
#    breakdown, and the lifecycle doc names the conductor as the breakdown owner
#    with the plan -> human-input gate -> breakdown ordering.
planner=".copilot/agents/planning-subagent.agent.md"
[ -f "$planner" ] || note "missing $planner"
if [ -f "$planner" ]; then
	# The planner must require an explicit Open Questions / Needs-Human-Input section.
	if ! grep -Eqi 'Open Questions|Needs-Human-Input' "$planner"; then
		note "$planner must require an Open Questions / Needs-Human-Input section"
	fi
	# The planner must reference, and explicitly disclaim authoring, feature_list.json.
	if ! grep -qi 'feature_list.json' "$planner"; then
		note "$planner must reference feature_list.json to disclaim authoring it"
	fi
	if ! grep -Eqi '(do(es)? not|never|must not)[^.]{0,40}author[^.]{0,40}feature_list' "$planner"; then
		note "$planner must state it does NOT author feature_list.json (the conductor owns the breakdown)"
	fi
fi

if [ -f "$harness_doc" ]; then
	# The lifecycle doc must name the conductor as the breakdown owner, show the
	# plan -> human-input gate -> breakdown ordering, and describe the gate.
	if ! grep -Eqi 'human-input gate' "$harness_doc"; then
		note "$harness_doc must describe the human-input gate before the breakdown"
	fi
	if ! grep -Eqi 'conductor authors' "$harness_doc"; then
		note "$harness_doc must name the conductor as the feature_list.json breakdown owner"
	fi
	# Anchor one assertion to the dedicated breakdown-flow subsection so the prose
	# (not just the mermaid node) cannot be quietly removed.
	if ! grep -Eqi 'plan .* clarify .* feature_list' "$harness_doc"; then
		note "$harness_doc must document the plan -> clarify -> feature_list breakdown flow"
	fi
fi

# 6. The feature-granularity rule (issue #80): the conductor doctrine must define,
#    in one place, what counts as ONE feature_list feature — the sensor-addressable
#    split/merge rule — and HARNESS.md + AGENTS.md must echo the same rule so the
#    three docs cannot drift apart.
agents_md="AGENTS.md"
[ -f "$agents_md" ] || note "missing $agents_md"

if [ -f "$instructions" ]; then
	if ! grep -Eqi 'what counts as one feature' "$instructions"; then
		note "$instructions must define 'what counts as one feature' (the granularity rule)"
	fi
	# Core rule: one acceptance criterion provable by exactly one regression_sensor.
	# Anchor to the phrase so the check tracks the granularity section, not stray
	# occurrences of those words elsewhere in the doc.
	if ! grep -Eqi 'exactly one[^.]*regression_sensor' "$instructions"; then
		note "$instructions granularity rule must tie one feature to exactly one regression_sensor"
	fi
	# Split/merge guidance must both be present.
	if ! grep -qi 'split' "$instructions" || ! grep -qi 'merge' "$instructions"; then
		note "$instructions granularity rule must give the split and merge guidance"
	fi
fi

if [ -f "$harness_doc" ]; then
	if ! grep -Eqi 'what counts as one feature' "$harness_doc"; then
		note "$harness_doc must echo the 'what counts as one feature' granularity rule"
	fi
	if ! grep -Eqi 'exactly one[^.]*regression_sensor' "$harness_doc"; then
		note "$harness_doc must echo that one feature maps to exactly one regression_sensor"
	fi
fi

if [ -f "$agents_md" ]; then
	# Rule 8 (or nearby) must reference the granularity rule so the golden rules
	# point at the single source of truth instead of restating a drifting copy.
	if ! grep -Eqi 'what counts as one feature|granularity' "$agents_md"; then
		note "$agents_md must reference the feature-granularity rule (single source of truth)"
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "role-separation regression checks passed"
