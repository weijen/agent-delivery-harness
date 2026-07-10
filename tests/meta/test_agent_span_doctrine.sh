#!/usr/bin/env bash
# Regression sensor (issue #95; structural per #273): agent-span doctrine. The
# harness contract states WHEN/HOW the conductor emits agent spans via
# scripts/log-handback.sh (feature_start + the handback steps + deviation), the
# single-source rule (span + derived Action Log line from one invocation), and
# the token-usage omit-never-fake rule; docs/HARNESS.md echoes it. Structure-
# level: asserts the guarded section exists (heading anchor) + closed vocabulary;
# wording is free to change.
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
	# Guarded section exists.
	grep -Eq '^#+ .*Agent-span conventions' "$instructions" \
		|| note "$instructions must keep the Agent-span conventions section"
	# The helper is named inside the per-feature handoff doctrine (§3).
	sec3="$(sed -n '/^## 3\./,/^## 4\./p' "$instructions")"
	printf '%s\n' "$sec3" | grep -q 'log-handback.sh' \
		|| note "$instructions §3 must name scripts/log-handback.sh in the per-feature handoff doctrine"
	# Closed vocabulary: the frozen lifecycle-step tokens.
	for token in plan_handback feature_start red_handback impl_handback green_handback review_verdict deviation; do
		grep -q "$token" "$instructions" || note "$instructions must document the '$token' agent-span convention"
	done
	# Single-source rule + token-usage honesty + token fields.
	grep -q 'single-source' "$instructions" || note "$instructions must state the single-source rule"
	grep -qi 'never estimate' "$instructions" || note "$instructions must state the token-usage omit-never-fake rule"
	grep -Eq 'gen_ai\.usage\.|TRACE_INPUT_TOKENS' "$instructions" \
		|| note "$instructions must name the token-usage fields (gen_ai.usage.* / TRACE_INPUT_TOKENS)"
fi

if [ -f "$harness_doc" ]; then
	grep -q 'log-handback.sh' "$harness_doc" || note "$harness_doc must echo the log-handback.sh agent-span convention"
	grep -qi 'agent span' "$harness_doc" || note "$harness_doc must describe agent spans"
	grep -q 'single-source' "$harness_doc" || note "$harness_doc must echo the single-source rule"
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "agent-span doctrine regression checks passed"
