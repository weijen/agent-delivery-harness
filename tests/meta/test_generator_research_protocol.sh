#!/usr/bin/env bash
# Regression sensor (issue #317): the generator's knowledge-gap route is
# bounded, diagnosis-only, and bound honestly to documented runtime capability.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

generator=".copilot/agents/generator-subagent.agent.md"
copilot_adapter="docs/runtime-adapters/github-copilot.md"
claude_adapter="docs/runtime-adapters/claude-code.md"

section="$(
	awk '
		/^## Bounded Research Protocol$/ { capture=1; next }
		capture && /^## / { exit }
		capture { print }
	' "$generator"
)"
frontmatter="$(
	awk '
		NR == 1 && $0 == "---" { capture=1; next }
		capture && $0 == "---" { exit }
		capture { print }
	' "$generator"
)"

[ -n "$section" ] || note "$generator must define a Bounded Research Protocol section"

for token in \
	"knowledge-gap" \
	"local" \
	"one external research action" \
	"5 minutes" \
	"one fetched document" \
	"diagnosis" \
	"constraints" \
	"source notes" \
	"untrusted" \
	"locally authored" \
	"RED" \
	"GREEN" \
	"teeth_proof" \
	"research-requested" \
	"red_handback" \
	"impl_handback" \
	"green_handback"; do
	printf '%s\n' "$section" | grep -Fq "$token" \
		|| note "$generator research protocol must include '$token'"
done

printf '%s\n' "$section" | grep -Eqi 'isolated (generator|subagent) context' \
	|| note "$generator must prefer an isolated generator/subagent research context"
printf '%s\n' "$section" | grep -Eqi 'never (paste|copy).*fetched code' \
	|| note "$generator must prohibit pasting fetched code"
printf '%s\n' "$frontmatter" | grep -Eq "(^|[[:space:],[])['\"]?web/fetch['\"]?([][:space:],]|$)" \
	|| note "$generator custom-agent tools must include the verified web/fetch binding"
printf '%s\n' "$frontmatter" | grep -Eq "(^|[[:space:],[])['\"]?web/githubRepo['\"]?([][:space:],]|$)" \
	|| note "$generator custom-agent tools must include the verified web/githubRepo binding"

for adapter in "$copilot_adapter" "$claude_adapter"; do
	grep -Eq '^## Generator research capability$' "$adapter" \
		|| note "$adapter must define a Generator research capability section"
	grep -Eqi 'verified|unavailable|unknown' "$adapter" \
		|| note "$adapter must label its research capability as verified, unavailable, or unknown"
	grep -Fq '5 minutes' "$adapter" \
		|| note "$adapter must state the five-minute research budget"
	grep -Fq 'one fetched document' "$adapter" \
		|| note "$adapter must state the one-document fetch budget"
done

grep -Fq 'web/fetch' "$copilot_adapter" \
	|| note "$copilot_adapter must name the verified custom-agent fetch binding"
grep -Fq 'web/githubRepo' "$copilot_adapter" \
	|| note "$copilot_adapter must name the verified custom-agent repository binding"
grep -Eqi 'unavailable|unknown|not verified' "$claude_adapter" \
	|| note "$claude_adapter must fail closed instead of assuming a Claude web binding"
grep -Fq 'research-requested' "$claude_adapter" \
	|| note "$claude_adapter must document the no-web research-requested route"

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "generator research protocol checks passed"
