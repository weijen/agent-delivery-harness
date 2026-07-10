#!/usr/bin/env bash
# Regression sensor (issue #269): the README and AGENTS harness-smoke summaries
# must describe the checks the workflow actually runs — not just the shell sensor
# suite. .github/workflows/harness-smoke.yml is the authority: it sets up uv,
# runs the Python profile gates (ruff/mypy/pytest), and runs the L0 suite gate.
# This sensor fails while either summary omits uv setup, the Python profile
# gates, or the L0 suite gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

workflow=".github/workflows/harness-smoke.yml"
[ -f "$workflow" ] || note "missing $workflow"

# Guard: the authority workflow really does carry these steps, so the docs are
# describing something real (fails loudly if the workflow is refactored away).
if [ -f "$workflow" ]; then
	grep -q 'uv sync' "$workflow" || note "$workflow no longer runs 'uv sync' — update this sensor's authority"
	grep -q 'Python profile gates' "$workflow" || note "$workflow no longer has the 'Python profile gates' step — update this sensor's authority"
	grep -q 'run-l0-suite.sh' "$workflow" || note "$workflow no longer runs the L0 suite — update this sensor's authority"
fi

check_doc() {
	local doc="$1"
	[ -f "$doc" ] || { note "missing $doc"; return; }
	# Isolate the harness-smoke paragraph so a stray token elsewhere cannot
	# satisfy the check.
	local para
	para="$(grep -iA8 'harness-smoke' "$doc" || true)"
	[ -n "$para" ] || { note "$doc has no harness-smoke summary paragraph"; return; }
	# Flatten line wraps so a token split across a newline (e.g. "the L0\n
	# evaluation suite gate") is still matched.
	para="$(printf '%s' "$para" | tr '\n' ' ')"

	printf '%s\n' "$para" | grep -qiE '\buv\b' \
		|| note "$doc harness-smoke summary must mention uv setup/sync"
	printf '%s\n' "$para" | grep -qiE 'profile gate|ruff|mypy|pytest' \
		|| note "$doc harness-smoke summary must mention the Python profile gates (ruff/mypy/pytest)"
	printf '%s\n' "$para" | grep -qiE 'L0([[:space:]]+[a-z]+){0,3}[[:space:]]+(suite|gate)' \
		|| note "$doc harness-smoke summary must mention the L0 suite gate"
}

check_doc "README.md"
check_doc "AGENTS.md"

if [ "$fail" -ne 0 ]; then
	echo "README/AGENTS harness-smoke coverage sensor FAILED"
	exit 1
fi
printf 'README/AGENTS harness-smoke coverage sensor passed\n'
