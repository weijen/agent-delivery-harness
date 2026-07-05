#!/usr/bin/env bash
# Regression sensor (issue #63, feature f1-tap-helper): a reusable, hand-rolled
# TAP (Test Anything Protocol) emitter helper — a sourceable bash library at
# tests/scripts/lib/tap.sh — that lets a sensor report ONE row per scenario and
# CONTINUE past a failing scenario (no fail-fast), exiting non-zero iff any
# scenario failed. This replaces the `set -e` + `fail(){ exit 1; }` fail-fast
# pattern. No bats-core, no external deps.
#
# This sensor is the executable spec for the helper API:
#
#   source tests/scripts/lib/tap.sh   # sourceable; must NOT `exit` on assertion failure
#
#   tap_ok "<desc>"                   # prints `ok <n> - <desc>`; n auto-increments; returns 0
#   tap_not_ok "<desc>"               # prints `not ok <n> - <desc>`; records failure; returns 0
#   tap_is <actual> <expected> "<d>"  # ok when equal, not ok when unequal; same numbering
#   tap_done                          # prints trailing plan `1..<n>`; returns non-zero iff
#                                     # any tap_not_ok/failed tap_is occurred, else 0
#
# The continue-past-failure guarantee is proven structurally: each toy driver
# runs under its own `set -euo pipefail`. If `tap_not_ok` (or a failing `tap_is`)
# returned non-zero, `set -e` would abort the driver at that line and the LATER
# `ok` row would never print. Asserting the later `ok` row therefore proves both
# that the run continued AND that the failing assertion returned 0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
