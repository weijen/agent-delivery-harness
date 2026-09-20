#!/usr/bin/env bash
# harness-sensor-stage: boundary
# TAP reporting contracts. Evaluation driver behavior is covered by
# tests/scripts/test_l0_suite_contract.sh using miniature recording graders.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

(
cd "$ROOT"

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
tests/scripts/validation/test_review_gate.sh
tests/scripts/validation/test_feature_list_check.sh
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
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

LIB="$ROOT/tests/scripts/lib/tap.sh"

# RED anchor: the helper library must exist and be sourceable. Reported clearly
# and early so a missing implementation cannot masquerade as a driver bug.
if [ ! -f "$LIB" ]; then
	note "helper library not found: tests/scripts/lib/tap.sh (implementation missing)"
	exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_eq() { # actual expected desc
	if [ "$1" != "$2" ]; then
		note "$3: expected [$2], got [$1]"
	fi
}
assert_zero() { # rc desc
	if [ "$1" -ne 0 ]; then
		note "$2: expected exit 0, got $1"
	fi
}
assert_nonzero() { # rc desc
	if [ "$1" -eq 0 ]; then
		note "$2: expected non-zero exit, got 0"
	fi
}

# ---------------------------------------------------------------------------
# Toy driver 1 — PASS, FAIL, PASS. Proves per-scenario rows, continue-past-
# failure, the trailing plan line, and a non-zero final status.
# ---------------------------------------------------------------------------
mixed="${TMP_DIR}/driver_mixed.sh"
cat >"$mixed" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$1"
tap_ok "first scenario passes"
tap_not_ok "second scenario fails"
tap_ok "third scenario passes"
tap_done
DRIVER

mixed_rc=0
mixed_out="$(bash "$mixed" "$LIB")" || mixed_rc=$?

# bash-3.2 portable line split (no mapfile/readarray). A `<<<` here-string
# appends a trailing newline, so this reads exactly the rows mapfile -t would.
mixed_lines=()
while IFS= read -r line; do
	mixed_lines+=("$line")
done <<<"$mixed_out"

assert_eq "${mixed_lines[0]:-}" "ok 1 - first scenario passes" \
	"mixed line 1 (first PASS row)"
assert_eq "${mixed_lines[1]:-}" "not ok 2 - second scenario fails" \
	"mixed line 2 (FAIL row did not abort the run)"
assert_eq "${mixed_lines[2]:-}" "ok 3 - third scenario passes" \
	"mixed line 3 (continue-past-failure)"
assert_eq "${mixed_lines[3]:-}" "1..3" \
	"mixed plan line (trailing 1..3)"
assert_nonzero "$mixed_rc" "mixed run exit status (one scenario failed)"

# ---------------------------------------------------------------------------
# Toy driver 2 — all pass. Proves a clean run exits 0.
# ---------------------------------------------------------------------------
allpass="${TMP_DIR}/driver_allpass.sh"
cat >"$allpass" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$1"
tap_ok "first scenario passes"
tap_ok "second scenario passes"
tap_done
DRIVER

allpass_rc=0
allpass_out="$(bash "$allpass" "$LIB")" || allpass_rc=$?

allpass_lines=()
while IFS= read -r line; do
	allpass_lines+=("$line")
done <<<"$allpass_out"

assert_eq "${allpass_lines[0]:-}" "ok 1 - first scenario passes" \
	"all-pass line 1"
assert_eq "${allpass_lines[1]:-}" "ok 2 - second scenario passes" \
	"all-pass line 2"
assert_eq "${allpass_lines[2]:-}" "1..2" \
	"all-pass plan line (trailing 1..2)"
assert_zero "$allpass_rc" "all-pass run exit status (no scenario failed)"

# ---------------------------------------------------------------------------
# Toy driver 3 — tap_is convenience. Equal -> ok, unequal -> not ok, shared
# numbering, an unequal comparison makes the final status non-zero.
# ---------------------------------------------------------------------------
isdriver="${TMP_DIR}/driver_is.sh"
cat >"$isdriver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$1"
tap_is foo foo "equal values report ok"
tap_is foo bar "unequal values report not ok"
tap_done
DRIVER

is_rc=0
is_out="$(bash "$isdriver" "$LIB")" || is_rc=$?

is_lines=()
while IFS= read -r line; do
	is_lines+=("$line")
done <<<"$is_out"

assert_eq "${is_lines[0]:-}" "ok 1 - equal values report ok" \
	"tap_is line 1 (equal -> ok)"
assert_eq "${is_lines[1]:-}" "not ok 2 - unequal values report not ok" \
	"tap_is line 2 (unequal -> not ok)"
assert_eq "${is_lines[2]:-}" "1..2" \
	"tap_is plan line (trailing 1..2)"
assert_nonzero "$is_rc" "tap_is run exit status (one comparison unequal)"

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "tap helper sensor passed"
)
