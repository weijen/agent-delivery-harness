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

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "markdownlint-optional regression checks passed"
