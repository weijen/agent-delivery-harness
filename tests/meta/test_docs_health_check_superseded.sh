#!/usr/bin/env bash
# Regression sensor (#269 f3): docs/copilot-health-check.md must be clearly
# marked as a superseded historical snapshot while retaining its original
# verdict table verbatim, so readers know it is a point-in-time record and not
# the live state of `.copilot/`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
doc="$repo_root/docs/copilot-health-check.md"

fails=0
note() {
	printf '✗ %s\n' "$1" >&2
	fails=$((fails + 1))
}

[ -f "$doc" ] || {
	note "docs/copilot-health-check.md is missing"
	echo "health-check superseded sensor FAILED" >&2
	exit 1
}

# 1. A superseded banner near the top of the document.
head="$(head -n 15 "$doc")"
printf '%s\n' "$head" | grep -qiE 'superseded' \
	|| note "health-check must carry a 'superseded' banner near the top"
printf '%s\n' "$head" | grep -qiE 'historical snapshot|point-in-time|point in time' \
	|| note "health-check banner must state it is a historical snapshot / point-in-time record"

# 2. The banner must link readers to the live / remediation source of truth.
printf '%s\n' "$head" | grep -qiE '#1[0-9][0-9]|PROGRESS\.md|HARNESS\.md' \
	|| note "health-check banner must link to the shipped remediation (issue refs) or live docs"

# 3. The original verdict table must be retained verbatim.
grep -qF '## Overall verdict' "$doc" \
	|| note "original '## Overall verdict' table heading must be retained"
for row in 'skills/' 'agents/' 'instructions/' 'prompts/'; do
	grep -qF "| \`$row\` |" "$doc" \
		|| note "original verdict row for \`$row\` must be retained verbatim"
done

if [ "$fails" -ne 0 ]; then
	echo "health-check superseded sensor FAILED" >&2
	exit 1
fi
echo "health-check superseded sensor passed"
