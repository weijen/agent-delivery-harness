#!/usr/bin/env bash
# Regression sensor: teeth_proof doctrine for executable feature evidence.
#
# The harness doctrine must define the closed teeth_proof kind-set, bind
# recording to the evaluator's passes:true flip, and echo the same contract in
# the test-subagent agent contract and lifecycle docs. This sensor fails while
# the doctrine is unwritten and prevents future drift once it is added.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

instructions=".copilot/instructions/harness.instructions.md"
test_agent=".copilot/agents/test-subagent.agent.md"
harness_doc="docs/HARNESS.md"
agents_doc="AGENTS.md"

[ -f "$instructions" ] || note "missing $instructions"
[ -f "$test_agent" ] || note "missing $test_agent"
[ -f "$harness_doc" ] || note "missing $harness_doc"

if [ -f "$instructions" ]; then
	# 1. The instructions must define the closed teeth_proof kind-set.
	for token in teeth_proof red_first mutation negative_fixture; do
		if ! grep -q "$token" "$instructions"; then
			note "$instructions must document the teeth_proof kind-set token '$token'"
		fi
	done

	# 2. §3 owns the per-feature TEST-SUBAGENT/evaluator handoff doctrine, so
	#    teeth_proof recording must be stated there, not only elsewhere.
	sec3="$(sed -n '/^## 3\./,/^## 4\./p' "$instructions")"
	if ! printf '%s\n' "$sec3" | grep -q 'teeth_proof'; then
		note "$instructions §3 must state that the TEST-SUBAGENT records teeth_proof"
	fi
	if ! printf '%s\n' "$sec3" | grep -Eqi 'teeth_proof[^.]{0,240}test-subagent|test-subagent[^.]{0,240}teeth_proof'; then
		note "$instructions §3 must bind teeth_proof recording to test-subagent/evaluator work"
	fi

	# 3. Recording teeth_proof is part of the evidence for the passes:true flip.
	if ! printf '%s\n' "$sec3" | grep -Eqi 'teeth_proof[^.]{0,240}passes:true|passes:true[^.]{0,240}teeth_proof'; then
		note "$instructions §3 must tie teeth_proof recording to the passes:true flip"
	fi
fi

if [ -f "$test_agent" ]; then
	# 4. The evaluator contract must name the field and all closed kind values.
	for token in teeth_proof red_first mutation negative_fixture; do
		if ! grep -q "$token" "$test_agent"; then
			note "$test_agent must document the teeth_proof contract token '$token'"
		fi
	done
	if ! grep -q 'passes:true' "$test_agent"; then
		note "$test_agent must mention passes:true alongside teeth_proof recording"
	fi
	if ! grep -Eqi 'teeth_proof[^.]{0,240}passes:true|passes:true[^.]{0,240}teeth_proof' "$test_agent"; then
		note "$test_agent must instruct recording teeth_proof alongside the passes:true flip"
	fi
fi

if [ -f "$harness_doc" ]; then
	# 5. The human-readable lifecycle doc must echo the teeth_proof contract.
	for token in teeth_proof red_first mutation negative_fixture; do
		if ! grep -q "$token" "$harness_doc"; then
			note "$harness_doc must document the teeth_proof doctrine token '$token'"
		fi
	done

	# 6. The #264 docs update must rename the red-first section to the
	#    sensor teeth-proof obligation, document waiver migration, and use
	#    the current gate tokens.
	if ! grep -Fq '### Sensor teeth-proof obligation' "$harness_doc"; then
		note "$harness_doc must contain the renamed '### Sensor teeth-proof obligation' heading"
	fi
	if grep -Fq 'Red-first evidence obligation' "$harness_doc"; then
		note "$harness_doc must not retain the old 'Red-first evidence obligation' heading"
	fi
	if ! grep -Fq 'red_first_waiver' "$harness_doc"; then
		note "$harness_doc must document the red_first_waiver compatibility token"
	fi
	if ! grep -Fq 'teeth_proof_waiver' "$harness_doc"; then
		note "$harness_doc must document the teeth_proof_waiver token"
	fi
	if ! grep -Eiq '(deprecat|migrat|alias)' "$harness_doc"; then
		note "$harness_doc must include a waiver migration/deprecation/alias cue"
	fi
	if ! grep -Fq 'teeth_proof_missing' "$harness_doc"; then
		note "$harness_doc must reference the teeth_proof_missing gate token"
	fi
	if ! grep -Fq 'red_first_ordering_absent' "$harness_doc"; then
		note "$harness_doc must reference the red_first_ordering_absent gate token"
	fi
	if grep -Fq 'red_first_evidence_missing' "$harness_doc"; then
		note "$harness_doc must not reference retired gate token red_first_evidence_missing"
	fi
	if grep -Fq 'red_first_role_mismatch' "$harness_doc"; then
		note "$harness_doc must not reference retired gate token red_first_role_mismatch"
	fi
fi

if [ -f "$agents_doc" ]; then
	rule2="$(awk 'capture && /^[[:space:]]*3\. / { exit } /^[[:space:]]*2\. / { capture=1 } capture { print }' "$agents_doc")"
	if [ -z "$rule2" ]; then
		note "$agents_doc must contain golden rule 2"
	else
		if ! printf '%s\n' "$rule2" | grep -Eiq 'TDD'; then
			note "$agents_doc golden rule 2 must keep TDD as the default discipline"
		fi
		if ! printf '%s\n' "$rule2" | grep -Eiq 'teeth'; then
			note "$agents_doc golden rule 2 must state that the gate checks sensor teeth"
		fi
		if ! printf '%s\n' "$rule2" | grep -Eiq 'prov[a-z]* (it|the sensor)?[^.]{0,60}fail|able to fail|can fail'; then
			note "$agents_doc golden rule 2 must state a sensor fail-ability cue"
		fi
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "teeth_proof doctrine regression checks passed"
