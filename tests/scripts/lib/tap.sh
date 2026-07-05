# shellcheck shell=bash
# Reusable TAP (Test Anything Protocol) emitter for harness shell sensors.
#
# Sourceable library — no shebang, no `set -e` (it inherits the caller's shell).
# Lets a sensor report ONE row per scenario and CONTINUE past a failing scenario
# instead of fail-fast: assertion functions always return 0 so a caller running
# under `set -euo pipefail` is never aborted mid-run. Only `tap_done` reports a
# non-zero status, and only when at least one scenario failed.
#
# API:
#   source tests/scripts/lib/tap.sh
#   tap_ok "<desc>"                  # prints `ok <n> - <desc>`; returns 0
#   tap_not_ok "<desc>"              # prints `not ok <n> - <desc>`; records fail; returns 0
#   tap_is <actual> <expected> "<d>" # ok when equal else not ok; same numbering; returns 0
#   tap_done                         # prints `1..<n>`; returns non-zero iff any failure

# Module-level counters. Sourced once per driver process, so no cross-run reset
# is needed; initialize defensively in case the library is re-sourced.
_TAP_COUNT=0
_TAP_FAILS=0

tap_ok() {
	_TAP_COUNT=$((_TAP_COUNT + 1))
	printf 'ok %d - %s\n' "$_TAP_COUNT" "$1"
	return 0
}

tap_not_ok() {
	_TAP_COUNT=$((_TAP_COUNT + 1))
	_TAP_FAILS=$((_TAP_FAILS + 1))
	printf 'not ok %d - %s\n' "$_TAP_COUNT" "$1"
	return 0
}

tap_is() {
	# actual expected desc
	if [ "$1" = "$2" ]; then
		tap_ok "$3"
	else
		tap_not_ok "$3"
	fi
	return 0
}

tap_done() {
	printf '1..%d\n' "$_TAP_COUNT"
	if [ "$_TAP_FAILS" -ne 0 ]; then
		return 1
	fi
	return 0
}
