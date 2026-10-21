#!/usr/bin/env bash
# Shared test execution budget. Setup/static phases run outside budget_run.

budget_now_ms() {
	local seconds fraction
	if [ -r /proc/uptime ]; then
		read -r seconds _ </proc/uptime
		fraction="${seconds#*.}000"
		printf '%s\n' "$((10#${seconds%%.*} * 1000 + 10#${fraction:0:3}))"
	else
		perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
			-e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000'
	fi
}

budget_valid() {
	[ -n "${HARNESS_TEST_SESSION:-}" ] && [ -f "$HARNESS_TEST_SESSION/state" ] \
		&& [ ! -L "$HARNESS_TEST_SESSION" ] || {
		printf 'test-budget: missing/invalid shared session\n' >&2
		return 1
	}
}

budget_session() (
	local directory
	if [ -n "${HARNESS_TEST_SESSION:-}" ]; then
		budget_valid || exit 1
		[ ! -f "$HARNESS_TEST_SESSION/timeout" ] || exit 124
		"$@"
		exit $?
	fi
	directory="$(mktemp -d "${TMPDIR:-/tmp}/harness-tests.XXXXXX")" || exit 1
	trap 'rm -rf "$directory"' EXIT
	printf '0 %s 0\n' "$(budget_now_ms)" >"$directory/state"
	HARNESS_TEST_SESSION="$directory" "$@"
)

# Account the union of active intervals under an atomic, bounded lock.
budget_update() {
	local operation="$1" attempts=0 spent last active now delta rc=0
	budget_valid || return 1
	while ! mkdir "$HARNESS_TEST_SESSION/lock" 2>/dev/null; do
		attempts=$((attempts + 1))
		if [ "$attempts" -ge 100 ]; then
			printf 'test-budget: shared accounting lock unavailable\n' >&2
			return 1
		fi
		sleep 0.01
	done
	if ! read -r spent last active <"$HARNESS_TEST_SESSION/state" \
		|| ! [[ "$spent $last $active" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] \
		|| ! now="$(budget_now_ms)"; then
		printf 'test-budget: invalid accounting state or unavailable monotonic clock\n' >&2
		rc=1
	else
		delta=$((now - last))
		if [ "$delta" -lt 0 ]; then
			printf 'test-budget: clock moved backwards\n' >&2
			rc=1
		else
			[ "$active" -eq 0 ] || spent=$((spent + delta))
			case "$operation" in
				start) active=$((active + 1)) ;;
				stop) active=$((active - 1)) ;;
				tick) ;;
				*) rc=1 ;;
			esac
			[ "$active" -ge 0 ] || rc=1
			if [ "$spent" -ge 600000 ]; then
				printf '%s\n' "$spent" >"$HARNESS_TEST_SESSION/timeout"
			fi
			printf '%s %s %s\n' "$spent" "$now" "$active" \
				>"$HARNESS_TEST_SESSION/state.new" \
				&& mv "$HARNESS_TEST_SESSION/state.new" "$HARNESS_TEST_SESSION/state" || rc=1
		fi
	fi
	rmdir "$HARNESS_TEST_SESSION/lock" || rc=1
	[ "$rc" -eq 0 ] || return "$rc"
	[ ! -f "$HARNESS_TEST_SESSION/timeout" ] || return 124
}

budget_phase() {
	if [ -n "${HARNESS_TEST_ACTIVE:-}" ] && [ -f "$HARNESS_TEST_ACTIVE" ]; then
		printf '%s\n' "$1" >"$HARNESS_TEST_ACTIVE"
	fi
}

budget_run() (
	local HARNESS_TEST_ACTIVE="${HARNESS_TEST_ACTIVE:-}"
	local label="$1"; shift
	if [ -z "${HARNESS_TEST_SESSION:-}" ]; then
		budget_session budget_run "$label" "$@"
		exit $?
	fi
	budget_valid || exit 1
	[ ! -f "$HARNESS_TEST_SESSION/timeout" ] || exit 124
	if [ -n "${HARNESS_TEST_ACTIVE:-}" ]; then
		case "$HARNESS_TEST_ACTIVE" in
			"$HARNESS_TEST_SESSION"/active.*)
				[ -f "$HARNESS_TEST_ACTIVE" ] || {
					printf 'test-budget: stale active test context\n' >&2
					exit 1
				}
				"$@"
				exit $? ;;
			*) printf 'test-budget: invalid active test context\n' >&2; exit 1 ;;
		esac
	fi
	budget_update start || exit $?
	HARNESS_TEST_ACTIVE="$(mktemp "$HARNESS_TEST_SESSION/active.XXXXXX")" || exit 1
	export HARNESS_TEST_ACTIVE
	budget_phase "$label"
	local child watcher rc=0 update_rc=0
	# A private job group contains this test and its pipelines, never the caller.
	set -m
	("$@") &
	child=$!
	set +m
	trap 'kill -TERM -- "-$child" 2>/dev/null || true; sleep 1; kill -KILL -- "-$child" 2>/dev/null || true; kill "$watcher" 2>/dev/null || true' INT TERM
	(
		while [ ! -f "$HARNESS_TEST_ACTIVE.done" ]; do
			watch_rc=0
			budget_update tick || watch_rc=$?
			if [ "$watch_rc" -ne 0 ]; then
				if [ "$watch_rc" -ne 124 ]; then
					printf 'test-budget: accounting failure; stopping active tests\n' >&2
					printf 'accounting failure\n' >"$HARNESS_TEST_SESSION/timeout"
				fi
				read -r elapsed _ _ <"$HARNESS_TEST_SESSION/state"
				phase="$(cat "$HARNESS_TEST_ACTIVE")"
				printf 'TIMEOUT elapsed_ms=%s budget=600 phase=%s\n' "$elapsed" "$phase" >&2
				kill -TERM -- "-$child" 2>/dev/null || true
				sleep 1
				kill -KILL -- "-$child" 2>/dev/null || true
				exit 0
			fi
			sleep 0.1
		done
	) &
	watcher=$!
	wait "$child" || rc=$?
	budget_update stop || update_rc=$?
	: >"$HARNESS_TEST_ACTIVE.done"
	wait "$watcher" || true
	rm -f "$HARNESS_TEST_ACTIVE" "$HARNESS_TEST_ACTIVE.done"
	if [ "$update_rc" -ne 0 ]; then
		[ "$update_rc" -ne 124 ] || printf 'TIMEOUT elapsed_ms=%s budget=600 phase=%s\n' \
			"$(cat "$HARNESS_TEST_SESSION/timeout")" "$label" >&2
		exit "$update_rc"
	fi
	exit "$rc"
)
