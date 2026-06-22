#!/usr/bin/env bash
# Regression sensor: markdownlint must not be described as a REQUIRED harness gate.
# It may remain available as optional docs hygiene, but it must never appear as a
# mandatory pre-commit / end-of-session / pre-PR gate, and any mention elsewhere must
# be clearly framed as optional.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

# 1. The harness doctrine must not reference markdownlint at all — it is not part of
#    the required lifecycle gates.
instructions=".copilot/instructions/harness.instructions.md"
if grep -qi 'markdownlint' "$instructions"; then
	note "$instructions still references markdownlint; remove it from the required harness flow"
fi

# 2. Where markdownlint is still mentioned (README, HARNESS.md), it must never be presented
#    as a required gate. Two concrete "looks required" signals are forbidden:
#      (a) pairing it with shellcheck as a single gate (the exact pattern issue #21 flagged),
#      (b) a bare `markdownlint <glob>.md` command invocation not annotated as optional.
for doc in "docs/HARNESS.md" "README.md"; do
	[ -f "$doc" ] || continue

	if grep -Eqi 'shellcheck[[:space:]]*[+/][[:space:]]*markdownlint|markdownlint[[:space:]]*[+/][[:space:]]*shellcheck' "$doc"; then
		note "$doc pairs markdownlint with shellcheck as one gate; markdownlint is optional, list it separately"
	fi

	while IFS= read -r line; do
		# A markdownlint command that runs it over .md files, with no 'optional' on the line.
		if printf '%s' "$line" | grep -Eqi 'markdownlint[^#]*\.md' &&
			! printf '%s' "$line" | grep -qi 'optional'; then
			note "$doc invokes markdownlint as a gate without an 'optional' annotation: ${line}"
		fi
	done <"$doc"
done

# 3. The devcontainer regression test must not pin markdownlint-cli2 as a REQUIRED tool.
#    markdownlint tooling is optional; it must not be asserted as a mandatory harness pin.
#    (A plain explanatory comment is fine; an active grep assertion is not.)
devcontainer_test="tests/meta/test_devcontainer_pinned.sh"
if [ -f "$devcontainer_test" ] &&
	grep -E '^[^#]*grep' "$devcontainer_test" | grep -qi 'markdownlint'; then
	note "$devcontainer_test still asserts a required markdownlint pin; markdownlint tooling is optional"
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "markdownlint-optional regression checks passed"
