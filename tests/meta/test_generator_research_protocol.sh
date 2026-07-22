#!/usr/bin/env bash
# Regression sensor (issue #317): the generator's knowledge-gap route is
# bounded, diagnosis-only, and bound honestly to documented runtime capability.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

generator=".copilot/agents/generator-subagent.agent.md"

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

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "generator research protocol checks passed"
