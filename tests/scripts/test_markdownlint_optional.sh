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
#    as a required gate. Three "looks required" signals are forbidden unless the same line
#    also frames markdownlint as optional:
#      (a) pairing it with shellcheck as a single gate (the exact pattern issue #21 flagged),
#      (b) a command-style invocation (line begins with the markdownlint command),
#      (c) prose asserting a requirement near markdownlint (required / mandatory / blocking /
#          "do not commit|merge|open").
req_kw='required|requires|mandatory|blocking|do not (commit|merge|open)'
for doc in "docs/HARNESS.md" "README.md"; do
	[ -f "$doc" ] || continue

	if grep -Eqi 'shellcheck[[:space:]]*[+/][[:space:]]*markdownlint|markdownlint[[:space:]]*[+/][[:space:]]*shellcheck' "$doc"; then
		note "$doc pairs markdownlint with shellcheck as one gate; markdownlint is optional, list it separately"
	fi

	while IFS= read -r line; do
		printf '%s' "$line" | grep -qi 'markdownlint' || continue
		# An 'optional' qualifier on the same line clears the line.
		printf '%s' "$line" | grep -qi 'optional' && continue

		# (b) command-style invocation: the line starts with the markdownlint command.
		if printf '%s' "$line" | grep -Eqi '^[[:space:]]*(\$ )?markdownlint([[:space:]]|$)'; then
			note "$doc invokes markdownlint as a gate without an 'optional' annotation: ${line}"
			continue
		fi
		# (c) prose asserting a requirement next to markdownlint.
		if printf '%s' "$line" | grep -Eqi "$req_kw"; then
			note "$doc describes markdownlint as required without an 'optional' qualifier: ${line}"
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
