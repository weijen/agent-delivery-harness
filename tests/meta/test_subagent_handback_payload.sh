#!/usr/bin/env bash
# Regression sensor: structured subagent handback payload (issue #95,
# feature subagent-handback-payload, plan Phase 3).
#
# Each of the four subagent prompt files must instruct the subagent to end
# its handback with a structured payload line the conductor can feed to
# scripts/log-handback.sh VERBATIM — pinned to the same shape the helper
# writes into the Action Log:
#
#   [<role>] <step> <feature_id> <outcome> — <summary>
#
# (`<lifecycle_step>` is accepted for `<step>`.) Per file the payload must
# name the role-correct lifecycle step(s) (planning → plan_handback; test →
# red_handback/green_handback; implementation → impl_handback; review →
# review_verdict), the closed outcome enum pass|fail|blocked, a one-line
# summary, and token counts ONLY when the runtime actually displayed them
# (omit, never fake). Distinct from test_agent_span_doctrine.sh: this sensor
# targets the four .agent.md files, not the harness contract.
#
# This sensor fails if any prompt file lacks — or later drops — the payload
# requirement, which would break unambiguous role attribution per span.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

# Pinned payload template (either <step> or <lifecycle_step> spelling).
payload_re='\[<role>\] <(lifecycle_)?step> <feature_id> <outcome> — <summary>'

# check_agent <file> <required step tokens...>
check_agent() {
	local file="$1"; shift
	if [ ! -f "$file" ]; then
		note "missing $file"
		return 0
	fi
	if ! grep -q 'log-handback' "$file"; then
		note "$file must say the payload is fed verbatim to scripts/log-handback.sh by the conductor"
	fi
	if ! grep -Eq "$payload_re" "$file"; then
		note "$file must pin the structured payload line '[<role>] <step> <feature_id> <outcome> — <summary>'"
	fi
	local token
	for token in "$@"; do
		if ! grep -q "$token" "$file"; then
			note "$file must name its role-correct lifecycle step '$token'"
		fi
	done
	if ! grep -Eqi 'pass ?\| ?fail ?\| ?blocked' "$file"; then
		note "$file must name the closed outcome enum pass|fail|blocked for the payload"
	fi
	if ! grep -Eqi 'one-line summary' "$file"; then
		note "$file must require a one-line summary in the payload"
	fi
	if ! grep -Eqi 'token count' "$file"; then
		note "$file must mention token counts in the payload"
	fi
	if ! grep -Eqi 'only (if|when)[^.]{0,160}(display|show|expos)|never (estimate|invent|fake)' "$file"; then
		note "$file must require token counts only when the runtime displayed them (omit, never fake)"
	fi
}

check_agent .copilot/agents/planning-subagent.agent.md plan_handback
check_agent .copilot/agents/test-subagent.agent.md red_handback green_handback
check_agent .copilot/agents/implementation-subagent.agent.md impl_handback
check_agent .copilot/agents/code-review-subagent.agent.md review_verdict

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "subagent handback payload regression checks passed"
