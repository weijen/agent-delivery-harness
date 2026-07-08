#!/usr/bin/env bash
# Regression sensor: structured subagent handback payload (issue #95,
# feature subagent-handback-payload; single-sourced by issue #202).
#
# The structured payload line the conductor feeds to scripts/log-handback.sh
# VERBATIM is pinned ONCE, in the harness §3 "Agent-span conventions":
#
#   [<role>] <step> <feature_id> <outcome> — <summary>
#
# (`<lifecycle_step>` is accepted for `<step>`.) The shared spec owns the
# template, the closed outcome enum pass|fail|blocked, the one-line summary
# requirement, and the token-count caveat (omit, never fake). Each of the four
# subagent prompt files keeps only ONE line: it points at the shared spec /
# scripts/log-handback.sh and names its own role-correct lifecycle step(s)
# (planning → plan_handback; test → red_handback/green_handback; implementation
# → impl_handback; review → review_verdict). An agent must NOT re-paste the full
# template, so the spec stays single-source.
#
# This sensor fails if the shared spec loses any pinned element, or if any
# subagent drops its role/step pointer or re-inlines the whole template.
# Distinct from test_agent_span_doctrine.sh: that targets the harness contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

harness=".copilot/instructions/harness.instructions.md"

# Pinned payload template (either <step> or <lifecycle_step> spelling).
payload_re='\[<role>\] <(lifecycle_)?step> <feature_id> <outcome> — <summary>'

# ---------------------------------------------------------------------------
# Shared spec — single source in the harness §3 agent-span conventions.
# ---------------------------------------------------------------------------
if [ ! -f "$harness" ]; then
	note "missing $harness"
else
	grep -Eq "$payload_re" "$harness" ||
		note "$harness must pin the shared payload template '[<role>] <step> <feature_id> <outcome> — <summary>' once"
	grep -q 'log-handback' "$harness" ||
		note "$harness must say the payload line is fed verbatim to scripts/log-handback.sh"
	grep -Eqi 'pass ?\| ?fail ?\| ?blocked' "$harness" ||
		note "$harness must name the closed outcome enum pass|fail|blocked for the payload"
	grep -Eqi 'one-line summary' "$harness" ||
		note "$harness must require a one-line summary in the payload"
	grep -Eqi 'token count' "$harness" ||
		note "$harness must state the token-count caveat for the payload"
	grep -Eqi 'only (if|when)[^.]{0,160}(display|show|expos)|never (estimate|invent|fake)' "$harness" ||
		note "$harness must require token counts only when the runtime displayed them (omit, never fake)"
fi

# check_agent <file> <required step tokens...>
check_agent() {
	local file="$1"; shift
	if [ ! -f "$file" ]; then
		note "missing $file"
		return 0
	fi
	# Points at the shared helper/spec rather than re-pasting the template.
	if ! grep -q 'log-handback' "$file"; then
		note "$file must point its handback payload at scripts/log-handback.sh"
	fi
	if ! grep -q 'harness.instructions.md' "$file"; then
		note "$file must reference the shared payload spec in harness.instructions.md (single source)"
	fi
	# Single-source guard: the full template must NOT be re-inlined in an agent.
	if grep -Eq "$payload_re" "$file"; then
		note "$file must NOT re-paste the full payload template; reference the harness §3 shared spec instead"
	fi
	local token
	for token in "$@"; do
		if ! grep -q "$token" "$file"; then
			note "$file must name its role-correct lifecycle step '$token'"
		fi
	done
}

check_agent .copilot/agents/planning-subagent.agent.md plan_handback
check_agent .copilot/agents/test-subagent.agent.md red_handback green_handback
check_agent .copilot/agents/implementation-subagent.agent.md impl_handback
check_agent .copilot/agents/code-review-subagent.agent.md review_verdict

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "subagent handback payload regression checks passed"
