#!/usr/bin/env bash
# Regression sensor (issue #296): one generator profile owns the complete
# per-feature cycle, and active lifecycle entrypoints route through that role.
# This is a structural/cross-file contract: headings and closed vocabulary may
# remain stable while surrounding prose is free to change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

generator=".copilot/agents/generator-subagent.agent.md"
retired_profiles=(
	.copilot/agents/implementation-subagent.agent.md
	.copilot/agents/test-subagent.agent.md
)
active_entrypoints=(
	.copilot/instructions/harness.instructions.md
	.copilot/instructions/workflow-tiers.instructions.md
	.copilot/prompts/session-ritual.prompt.md
	AGENTS.md
	docs/HARNESS.md
)

if [ ! -f "$generator" ]; then
	note "missing $generator"
else
	frontmatter="$(awk 'NR == 1 && $0 == "---" { capture=1; next } capture && $0 == "---" { exit } capture { print }' "$generator")"
	workflow="$(awk '/^## (Required Steps|Workflow)$/ { capture=1; next } capture && /^## / { exit } capture { print }' "$generator")"

	printf '%s\n' "$frontmatter" | grep -Eq '^name:[[:space:]]*generator-subagent$' \
		|| note "$generator frontmatter must declare name: generator-subagent"
	for tool in read edit search execute; do
		printf '%s\n' "$frontmatter" | grep -Eq "(^|[[:space:],[])${tool}([][:space:],]|$)" \
			|| note "$generator tools must include '$tool'"
	done

	for heading in 'Scope Rules' 'Workflow|Required Steps' 'Output Format|Response Format'; do
		grep -Eq "^## (${heading})$" "$generator" \
			|| note "$generator must keep a structural heading matching '$heading'"
	done
	for token in tests production regression_sensor e2e_sensor teeth_proof passes:true product-quality; do
		grep -qi "$token" "$generator" \
			|| note "$generator authority vocabulary must include '$token'"
	done
	for step in red_handback impl_handback green_handback; do
		grep -q "$step" "$generator" \
			|| note "$generator must emit the existing lifecycle step '$step'"
	done

	red_line="$(printf '%s\n' "$workflow" | grep -n -m 1 -E '\bRED\b' | cut -d: -f1 || true)"
	implementation_line="$(printf '%s\n' "$workflow" | grep -n -m 1 -E '[Ii]mplement' | cut -d: -f1 || true)"
	green_line="$(printf '%s\n' "$workflow" | grep -n -m 1 -E '\bGREEN\b' | cut -d: -f1 || true)"
	if [ -z "$red_line" ] || [ -z "$implementation_line" ] || [ -z "$green_line" ]; then
		note "$generator workflow must contain RED, implementation, and GREEN phases"
	elif ! [ "$red_line" -lt "$implementation_line" ] || ! [ "$implementation_line" -lt "$green_line" ]; then
		note "$generator workflow must order RED before implementation before GREEN"
	fi
fi

for profile in "${retired_profiles[@]}"; do
	[ ! -e "$profile" ] || note "retired active profile must be absent: $profile"
done

for entrypoint in "${active_entrypoints[@]}"; do
	if [ ! -f "$entrypoint" ]; then
		note "missing active lifecycle entrypoint $entrypoint"
		continue
	fi
	grep -q 'generator-subagent' "$entrypoint" \
		|| note "$entrypoint must route feature work through generator-subagent"
	for retired_role in implementation-subagent test-subagent; do
		if grep -q "$retired_role" "$entrypoint"; then
			note "$entrypoint must not invoke retired role '$retired_role'"
		fi
	done
done

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "generator role contract checks passed"