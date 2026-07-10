#!/usr/bin/env bash
# Regression sensor: delivery-economics documentation doctrine (issue #267).
#
# finish-issue.sh auto-stamps a trace-derived delivery-economics block into the
# issue progress.md and appends a machine-readable finish-issue.economics span.
# docs/HARNESS.md must document BOTH — the operator-facing block in the Local
# Tracking section and the span in the Trace emission section — and must state
# the omit-never-fake / n/a honesty rule plus cross-link #163 as the Copilot
# token-acquisition prerequisite for non-n/a token rows. This sensor fails while
# the documentation is missing and prevents drift once it lands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

harness_doc="docs/HARNESS.md"
[ -f "$harness_doc" ] || note "missing $harness_doc"

if [ -f "$harness_doc" ]; then
	# Section slices: Local Tracking (block) and Trace emission (span).
	local_tracking="$(sed -n '/^## Local Tracking/,/^## /p' "$harness_doc")"
	trace_emission="$(sed -n '/^### Trace emission/,/^## /p' "$harness_doc")"

	[ -n "$local_tracking" ] || note "$harness_doc must retain a '## Local Tracking' section"
	[ -n "$trace_emission" ] || note "$harness_doc must retain a '### Trace emission' section"

	# 1. Local Tracking documents the auto-stamped delivery-economics block.
	if ! printf '%s\n' "$local_tracking" | grep -qi 'delivery economics'; then
		note "$harness_doc Local Tracking section must document the auto-stamped delivery economics block"
	fi
	if ! printf '%s\n' "$local_tracking" | grep -qi 'finish-issue'; then
		note "$harness_doc Local Tracking section must state finish-issue.sh stamps the economics block"
	fi
	# Name the block's fields so the docs stay a real contract, not a mention.
	for field in 'wall-clock' 'token' 'review round' 'deviation' 'feature'; do
		if ! printf '%s\n' "$local_tracking" | grep -qi "$field"; then
			note "$harness_doc Local Tracking economics docs must name the '$field' field"
		fi
	done
	# 2. The omit-never-fake / n/a honesty rule must be stated for the block.
	if ! printf '%s\n' "$local_tracking" | grep -Eqi 'omit-never-fake|n/a|never (fabricat|invent)'; then
		note "$harness_doc Local Tracking economics docs must state the omit-never-fake / n/a honesty rule"
	fi

	# 3. Trace emission documents the finish-issue.economics span.
	if ! printf '%s\n' "$trace_emission" | grep -q 'finish-issue.economics'; then
		note "$harness_doc Trace emission section must document the finish-issue.economics span"
	fi

	# 4. #163 is cross-linked as the token-acquisition prerequisite for non-n/a
	#    token rows. The pointer must sit next to the economics/token prose.
	if ! grep -q '#163' "$harness_doc"; then
		note "$harness_doc must cross-link #163 as the Copilot token-acquisition prerequisite"
	else
		if ! grep -Eqi 'finish-issue\.economics.{0,240}#163|#163.{0,240}finish-issue\.economics|delivery economics.{0,240}#163|#163.{0,240}(token|economics)' "$harness_doc"; then
			note "$harness_doc must tie the #163 pointer to the economics/token-acquisition context"
		fi
	fi
fi

if [ "$fail" -ne 0 ]; then
	echo "FAIL: delivery-economics documentation doctrine incomplete"
	exit 1
fi
echo "delivery-economics documentation doctrine honored"
