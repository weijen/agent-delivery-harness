#!/usr/bin/env bash
# Regression sensor: agent-span doctrine (issue #95, feature
# doctrine-agent-span-conventions, plan Phase 2 / D6-D7).
#
# The harness contract must state WHEN and HOW the conductor emits agent
# spans: it invokes scripts/log-handback.sh at feature selection
# (feature_start), at every subagent handback (plan_handback, red_handback,
# impl_handback, green_handback, review_verdict), and for stop/report/recover
# deviations (deviation, outcome blocked). The single-source rule (one
# invocation writes the span first, then the derived Action Log line — never
# hand-author the pair) and the token-usage omit-never-fake rule must be
# written down, and docs/HARNESS.md must echo the convention so the two docs
# cannot drift apart (mirrors test_role_separation.sh).
#
# This sensor fails if any of those doctrine guarantees is missing or later
# dropped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

instructions=".copilot/instructions/harness.instructions.md"
harness_doc="docs/HARNESS.md"

[ -f "$instructions" ] || note "missing $instructions"
[ -f "$harness_doc" ] || note "missing $harness_doc"

if [ -f "$instructions" ]; then
	# 1. The helper must be named inside §3 (the per-feature TDD/handoff
	#    section), not just anywhere in the file: the convention belongs to
	#    the handoff sequence the conductor executes.
	sec3="$(sed -n '/^## 3\./,/^## 4\./p' "$instructions")"
	if ! printf '%s\n' "$sec3" | grep -q 'log-handback\.sh'; then
		note "$instructions §3 must name scripts/log-handback.sh in the per-feature handoff doctrine"
	fi

	# 2. The CONDUCTOR is the emission point: conductor and log-handback.sh
	#    must be bound in one statement.
	if ! grep -Eqi 'conductor[^.]{0,200}log-handback\.sh|log-handback\.sh[^.]{0,200}conductor' "$instructions"; then
		note "$instructions must state that the CONDUCTOR invokes scripts/log-handback.sh"
	fi

	# 3. Every required handback has a convention: all seven lifecycle-step
	#    tokens from the frozen #92 enum subset must appear.
	for token in plan_handback feature_start red_handback impl_handback green_handback review_verdict deviation; do
		if ! grep -q "$token" "$instructions"; then
			note "$instructions must document the '$token' agent-span convention"
		fi
	done

	# 4. Feature selection is recorded as feature_start.
	if ! grep -Eqi '(select|selection|selects)[^.]{0,200}feature_start|feature_start[^.]{0,200}(select|selection|selects)' "$instructions"; then
		note "$instructions must tie feature selection to the feature_start agent span"
	fi

	# 5. Single-source rule: span and Action Log line come from the SAME
	#    invocation, span written first, and the pair is never hand-authored.
	if ! grep -Eqi 'single.?source|same (invocation|event|arguments|argv|command)' "$instructions"; then
		note "$instructions must state the single-source rule (span + Action Log line from the same invocation)"
	fi
	if ! grep -Eqi 'span[^.]{0,80}first[^.]{0,120}(then|before)[^.]{0,120}(action log|log line)|writes the span first' "$instructions"; then
		note "$instructions must pin the write order: the span first, then the Action Log line"
	fi
	if ! grep -Eqi '(never|not|don.t)[^.]{0,80}hand.?(author|writ)' "$instructions"; then
		note "$instructions must forbid hand-authoring the span/Action Log pair separately"
	fi

	# 6. Deviations: the stop/report/recover doctrine must route through the
	#    helper with the deviation step and blocked outcome.
	if ! grep -Eqi 'deviation[^.]{0,240}log-handback|log-handback[^.]{0,240}deviation' "$instructions"; then
		note "$instructions must record stop/report/recover deviations via log-handback.sh (deviation step)"
	fi
	if ! grep -Eqi 'deviation[^.]{0,200}blocked|blocked[^.]{0,200}deviation' "$instructions"; then
		note "$instructions must pair the deviation step with the blocked outcome"
	fi

	# 7. Token usage: omit, never fake — counts only when the runtime
	#    actually exposed them.
	if ! grep -Eqi 'never (estimate|invent|fake)' "$instructions"; then
		note "$instructions must state the token-usage omit-never-fake rule (never estimate or invent counts)"
	fi
	if ! grep -Eq 'gen_ai\.usage\.|TRACE_INPUT_TOKENS' "$instructions"; then
		note "$instructions must name the token-usage fields (gen_ai.usage.* / TRACE_INPUT_TOKENS passthrough)"
	fi
fi

# 8. The human-readable lifecycle doc must echo the convention so the two
#    docs cannot drift apart (same pattern as the role-separation sensor).
if [ -f "$harness_doc" ]; then
	if ! grep -q 'log-handback\.sh' "$harness_doc"; then
		note "$harness_doc must echo the log-handback.sh agent-span convention"
	fi
	if ! grep -Eqi 'agent span' "$harness_doc"; then
		note "$harness_doc must describe agent spans for conductor decisions and subagent handbacks"
	fi
	if ! grep -Eqi 'single.?source|same (invocation|event|arguments|argv|command)' "$harness_doc"; then
		note "$harness_doc must echo the single-source rule (span + Action Log line from one invocation)"
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "agent-span doctrine regression checks passed"
