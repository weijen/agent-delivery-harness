#!/usr/bin/env bash
# Regression sensor: delivery-economics documentation doctrine (issues #267, #329).
#
# finish-issue.sh auto-stamps a trace-derived delivery-economics block into the
# issue progress.md and appends a machine-readable finish-issue.economics span.
# docs/HARNESS.md must document BOTH — the operator-facing block in the Local
# Tracking section and the span in the Trace emission section — and must state
# the omit-never-fake / n/a honesty rule.
#
# Issue #329 adds the NATIVE-RECORD ECONOMICS JOIN: at closeout the token/model
# economics are joined from the local GitHub Copilot native session records
# (subagent-only `totalTokens` + `model`, plus a windowed AIU delta derived from
# cumulative checkpoints ONLY when they bracket the issue window). The docs must
# state that native-record join doctrine (subagent-only tokens, model values,
# AIU-from-checkpoints-when-bracketed, omit-never-fake) and REFRAME the #163
# pointer: #163's cloud token-capture approach is SUPERSEDED by the native-record
# join (per the #305 direction), no longer "the prerequisite for non-n/a tokens".
# This sensor fails while the documentation is missing and prevents drift.
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

	# 2b. Native-record economics join doctrine (issue #329): the token/model
	#     economics are joined from the local Copilot native session records,
	#     subagent-only, with model values and a bracketed-only AIU delta.
	if ! printf '%s\n' "$local_tracking" | grep -Eqi 'native[ -]record|native Copilot|session records'; then
		note "$harness_doc Local Tracking economics docs must document the native-record token/model join (issue #329)"
	fi
	if ! printf '%s\n' "$local_tracking" | grep -qi 'subagent'; then
		note "$harness_doc Local Tracking economics docs must state the native token join is subagent-only"
	fi
	if ! printf '%s\n' "$local_tracking" | grep -qi 'model'; then
		note "$harness_doc Local Tracking economics docs must state subagent model values flow into economics"
	fi
	if ! printf '%s\n' "$local_tracking" | grep -Eqi 'AIU|checkpoint'; then
		note "$harness_doc Local Tracking economics docs must state AIU is derived from cumulative checkpoints only when they bracket the window"
	fi

	# 3. Trace emission documents the finish-issue.economics span.
	if ! printf '%s\n' "$trace_emission" | grep -q 'finish-issue.economics'; then
		note "$harness_doc Trace emission section must document the finish-issue.economics span"
	fi

	# 3b. Trace emission documents the numeric native_* economics span keys.
	if ! printf '%s\n' "$trace_emission" | grep -q 'native_'; then
		note "$harness_doc Trace emission section must document the harness.economics.native_* span keys (issue #329)"
	fi

	# 4. #163 is REFRAMED (issue #329): its cloud token-capture approach is
	#    SUPERSEDED by the native-record join, not "the prerequisite for non-n/a
	#    tokens". The pointer must still sit next to the economics/token prose.
	if ! grep -q '#163' "$harness_doc"; then
		note "$harness_doc must cross-link #163 as the (superseded) Copilot cloud token-capture path"
	else
		if ! grep -Eqi 'finish-issue\.economics.{0,240}#163|#163.{0,240}finish-issue\.economics|delivery economics.{0,240}#163|#163.{0,240}(token|economics)' "$harness_doc"; then
			note "$harness_doc must tie the #163 pointer to the economics/token-acquisition context"
		fi
		if ! grep -Eqi '#163.{0,240}(supersed|native[ -]record|native Copilot)|(supersed|native[ -]record|native Copilot).{0,240}#163' "$harness_doc"; then
			note "$harness_doc must reframe #163 as SUPERSEDED by the native-record join (issue #329), not the prerequisite for non-n/a tokens"
		fi
	fi
fi

if [ "$fail" -ne 0 ]; then
	echo "FAIL: delivery-economics documentation doctrine incomplete"
	exit 1
fi
echo "delivery-economics documentation doctrine honored"
