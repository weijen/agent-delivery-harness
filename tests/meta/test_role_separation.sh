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

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "role-separation regression checks passed"
