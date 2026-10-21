#!/usr/bin/env bash
# One miniature suite for the shared deadline, not a 10-minute sleep.
# shellcheck disable=SC2030,SC2031 # Assertions run inside the session's subshell.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'test-budget: %s\n' "$*" >&2; exit 1; }
[ -f "$ROOT/scripts/lib/test-budget-lib.sh" ] || fail "shared budget implementation missing"
# shellcheck source=scripts/lib/test-budget-lib.sh
source "$ROOT/scripts/lib/test-budget-lib.sh"
# These fixtures own their artificial clock/state; the outer runner still times us.
unset HARNESS_TEST_SESSION HARNESS_TEST_ACTIVE

success() {
	budget_run first true
	sleep 0.05 # an excluded phase does not spend test time
	budget_run second true
}
budget_session success >"$TMP/success" 2>&1 || fail "within-budget phases failed"

aggregate() {
	budget_run first true
	# Internal fixture seam: near-exhausted state, never a production timeout flag.
	read -r _ last active <"$HARNESS_TEST_SESSION/state"
	printf '599900 %s %s\n' "$last" "$active" >"$HARNESS_TEST_SESSION/state"
	if budget_run second sleep 0.3; then fail "second phase exceeded budget but passed"; fi
	budget_run third touch "$TMP/later"
}
rc=0
budget_session aggregate >"$TMP/aggregate" 2>&1 || rc=$?
[ "$rc" = 124 ] || fail "aggregate exhaustion must be timeout, got $rc"
[ ! -f "$TMP/later" ] || fail "work continued after exhaustion"
grep -Eq 'TIMEOUT.*budget=600.*phase=second' "$TMP/aggregate" || fail "timeout lacks budget/phase"

cleanup() {
	read -r _ last active <"$HARNESS_TEST_SESSION/state"
	printf '599900 %s %s\n' "$last" "$active" >"$HARNESS_TEST_SESSION/state"
	# shellcheck disable=SC2016 # Expansion belongs to the test child.
	budget_run stubborn bash -c 'trap "" TERM; echo "$$" >"$1"; sleep 30 & echo "$!" >>"$1"; wait' _ "$TMP/pids"
}
rc=0
budget_session cleanup >"$TMP/cleanup" 2>&1 || rc=$?
[ "$rc" = 124 ] || fail "ignored termination became success"
while read -r pid; do
	if kill -0 "$pid" 2>/dev/null; then
		state="$(ps -o stat= -p "$pid")"
		[[ "$state" = Z* ]] || fail "spawned process survived: $pid"
	fi
done <"$TMP/pids"

nested() {
	budget_run outer budget_run inner true
	read -r spent _ active <"$HARNESS_TEST_SESSION/state"
	[ "$active" = 0 ] && [ "$spent" -lt 1000 ] || fail "nested runner double-counted"
}
budget_session nested >"$TMP/nested" 2>&1 || fail "nested session failed"

parallel() {
	# Deterministic clock seam proves union accounting without timing thresholds.
	printf '0\n' >"$TMP/clock"
	budget_now_ms() { cat "$TMP/clock"; }
	printf '0 0 0\n' >"$HARNESS_TEST_SESSION/state"
	budget_update start
	printf '100\n' >"$TMP/clock"
	budget_update start
	printf '200\n' >"$TMP/clock"
	budget_update stop
	printf '300\n' >"$TMP/clock"
	budget_update stop
	read -r spent _ active <"$HARNESS_TEST_SESSION/state"
	[ "$active" = 0 ] && [ "$spent" = 300 ] || fail "parallel phases were summed"
	printf '10000\n' >"$TMP/clock"
	budget_update start
	budget_update stop
	read -r spent _ _ <"$HARNESS_TEST_SESSION/state"
	[ "$spent" = 300 ] || fail "excluded idle/setup interval consumed budget"
}
budget_session parallel >"$TMP/parallel" 2>&1 || { cat "$TMP/parallel" >&2; fail "parallel accounting failed"; }
printf 'PASS: shared deadline, aggregate exhaustion and bounded cleanup\n'
