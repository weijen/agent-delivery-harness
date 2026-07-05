#!/usr/bin/env bash
# test_l0_sensors_tap.sh — meta-sensor (issue #63, feature f2-l0-sensors-tap):
# prove the five L0 harness sensors emit PER-SCENARIO TAP via the helper at
# tests/scripts/lib/tap.sh, with NO fail-fast and preserved exit semantics.
#
# The five sensors under conversion (each is self-contained: it builds its own
# temp repo / fake CLIs and needs no arguments or ambient state):
#   1. tests/scripts/test_harness_contract.sh
#   2. tests/scripts/test_lifecycle_order.sh
#   3. tests/scripts/test_review_gate.sh
#   4. tests/scripts/test_feature_list_check.sh
#   5. tests/scripts/test_issue_scaffold.sh
#
# For EACH sensor this meta-sensor runs it, captures stdout + exit code, and
# asserts the stdout is well-formed per-scenario TAP:
#   (1) a plan line matching `^1\.\.[1-9][0-9]*$` (N >= 1) is present;
#   (2) at least one TAP result row (`^(ok|not ok) [0-9]+`) is present;
#   (3) the number of result rows EQUALS N — one row per scenario, plan matches
#       row count;
#   (4) on this clean run every row is `ok` (no `not ok`) AND the sensor exits 0
#       (all scenarios pass => exit 0; exit semantics preserved).
#
# The TAP helper's own emitted format IS the contract. This meta-sensor dogfoods
# the helper: it sources tests/scripts/lib/tap.sh and reports ONE TAP row per
# checked sensor, exiting non-zero iff any sensor is not yet converted.
#
# RED expectation (before f2-l0-sensors-tap lands): the five sensors still use
# the `fail(){ exit 1; }` fail-fast pattern and emit NO TAP, so each fails
# assertion (1) with a `# <sensor>: emits no TAP plan line ...` diagnostic that
# names the offending L0 sensor — a real gap, not a meta-sensor bug.
#
# bash-3.2 portable: no mapfile/readarray; while-read loops only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

LIB="$ROOT/tests/scripts/lib/tap.sh"
if [ ! -f "$LIB" ]; then
	printf '# BLOCKING: TAP helper not found: tests/scripts/lib/tap.sh\n' >&2
	exit 1
fi
# shellcheck source=/dev/null
source "$LIB"

# The five L0 sensors under conversion, one relative path per line.
SENSORS="
tests/scripts/test_harness_contract.sh
tests/scripts/test_lifecycle_order.sh
tests/scripts/test_review_gate.sh
tests/scripts/test_feature_list_check.sh
tests/scripts/test_issue_scaffold.sh
"

# REASON is the out-parameter of check_sensor: empty means the sensor emits
# well-formed per-scenario TAP; non-empty is a diagnostic naming what is wrong.
REASON=""

# check_sensor <relpath>: run the sensor self-contained, capture stdout + exit
# code, and set REASON when the stdout is not well-formed per-scenario TAP (or
# the clean-run all-ok/exit-0 invariant is broken). Always returns 0 so the
# caller under `set -e` continues to the next sensor.
check_sensor() {
	local path="$1"
	local out rc plan_line n rows not_ok
	REASON=""

	if [ ! -f "$path" ]; then
		REASON="sensor file not found"
		return 0
	fi

	# Self-contained: no args, no stdin; TAP is emitted on stdout.
	rc=0
	out="$(bash "$path" 2>/dev/null)" || rc=$?

	# (1) plan line `1..N`, N >= 1.
	plan_line="$(printf '%s\n' "$out" | grep -E '^1\.\.[1-9][0-9]*$' | head -n1 || true)"
	if [ -z "$plan_line" ]; then
		REASON="emits no TAP plan line (^1..N\$); still fail-fast, not TAP-converted"
		return 0
	fi
	n="${plan_line#1..}"

	# (2) at least one TAP result row.
	rows="$(printf '%s\n' "$out" | grep -Ec '^(ok|not ok) [0-9]+' || true)"
	if [ "$rows" -eq 0 ]; then
		REASON="declares plan 1..$n but emits no TAP result rows"
		return 0
	fi

	# (3) one row per scenario: result-row count EQUALS N.
	if [ "$rows" -ne "$n" ]; then
		REASON="plan 1..$n does not match $rows TAP result row(s)"
		return 0
	fi

	# (4) clean run: every row `ok`, and the sensor exits 0 (exit semantics
	# preserved: all scenarios pass => exit 0).
	not_ok="$(printf '%s\n' "$out" | grep -Ec '^not ok [0-9]+' || true)"
	if [ "$not_ok" -ne 0 ]; then
		REASON="clean run reported $not_ok 'not ok' row(s); expected all ok"
		return 0
	fi
	if [ "$rc" -ne 0 ]; then
		REASON="all rows ok but sensor exited $rc; expected exit 0 on all-pass"
		return 0
	fi

	return 0
}

# Iterate via a here-doc (NOT a pipe): the loop stays in the current shell so the
# TAP counters in the sourced helper accumulate across sensors and tap_done sees
# the full 1..5 plan.
while IFS= read -r sensor; do
	[ -n "$sensor" ] || continue
	check_sensor "$sensor"
	if [ -n "$REASON" ]; then
		printf '# %s: %s\n' "$sensor" "$REASON" >&2
		tap_not_ok "$sensor emits per-scenario TAP (1..N, N rows, all ok, exit 0)"
	else
		tap_ok "$sensor emits per-scenario TAP (1..N, N rows, all ok, exit 0)"
	fi
done <<EOF
$SENSORS
EOF

tap_done
