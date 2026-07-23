#!/usr/bin/env bash
# test_l0_ci_gate.sh — regression sensor (issue #64, feature f2-l0-ci-gate):
# prove the L0 suite driver `tests/evals/bin/run-l0-suite.sh` runs the L0
# manifests through `tests/evals/bin/run-evals.sh`, emits their case-level
# scorecards, and BLOCKS (exits non-zero) when any case is a blocking failure —
# and that the driver is wired into the harness-smoke CI workflow as a step.
#
# DRIVER CONTRACT pinned here (the implementation satisfies exactly this):
#   run-l0-suite.sh [MANIFEST_DIR]
#     * NO arg  — runs the default L0 set `tests/evals/manifests/scripts/l0-*.json`.
#     * DIR arg — runs that directory's `l0-*.json` manifests (this makes the gate
#                 testable against a temp set of synthetic manifests).
#   For every selected manifest it invokes run-evals.sh and prints the resulting
#   case-level scorecard (or a case-level summary of them) to stdout. It exits 0
#   iff EVERY case is non-blocking (no result has blocking_decision == "block"),
#   and exits non-zero otherwise. The scorecards are the case-level evidence.
#
# Assertions:
#   1. run-l0-suite.sh exists and is executable.
#   2. Default run (no args) over the 5 real L0 manifests exits 0 AND its output
#      carries case-level scorecard evidence for every default L0 capability
#      (each default manifest `.id` appears in the output). All L0 sensors pass
#      today, so the real suite is green.
#   3. BLOCKING PROOF (mutation): a temp dir holding two VALID manifests — one
#      PASS (grader `true`, blocking:true) and one BLOCKING FAIL (grader `false`,
#      blocking:true) — makes the driver EXIT NON-ZERO and emit case-level
#      evidence of the blocked/failed case (`blocking_decision":"block"` or
#      `status":"fail"`). This proves that breaking one L0 capability turns the
#      runner red with case-level evidence, without touching a real harness
#      script.
#   4. `.github/workflows/harness-smoke.yml` invokes the suite driver
#      (`run-l0-suite.sh` appears in the workflow).
#
# RED expectation (before f2-l0-ci-gate lands): the driver and the CI wiring do
# not exist, so assertion 1 and 4 fail (`# ...: run-l0-suite.sh missing/not
# wired`) and assertions 2/3 are reported not-run against the missing driver —
# a real gap, not a sensor bug.
#
# bash-3.2 portable: no mapfile/readarray; while-read / glob loops only. Dogfoods
# the TAP helper (one row per assertion, no fail-fast, exit non-zero iff any fail).
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

command -v jq >/dev/null 2>&1 || {
	printf '# BLOCKING: jq is required but was not found on PATH\n' >&2
	exit 1
}

DRIVER="$ROOT/tests/evals/bin/run-l0-suite.sh"
MANIFEST_DIR="$ROOT/tests/evals/manifests/scripts"
WORKFLOW="$ROOT/.github/workflows/harness-smoke.yml"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# run_driver <args...>: run the suite driver, capturing stdout+stderr into OUT
# and the exit code into RC. The `|| RC=$?` keeps a non-zero exit from aborting
# this sensor under `set -e`, so a blocking (non-zero) run is observable.
OUT=""
RC=0
run_driver() {
	RC=0
	OUT="$(bash "$DRIVER" "$@" 2>&1)" || RC=$?
}

# ---------------------------------------------------------------------------
# Assertion 1 — driver exists and is executable.
# ---------------------------------------------------------------------------
driver_ready=0
if [ -x "$DRIVER" ]; then
	driver_ready=1
	tap_ok "run-l0-suite.sh exists and is executable"
else
	printf '# tests/evals/bin/run-l0-suite.sh missing or not executable (driver not implemented)\n' >&2
	tap_not_ok "run-l0-suite.sh exists and is executable"
fi

# ---------------------------------------------------------------------------
# Assertion 2 — default run is green and emits case-level evidence for every
# default L0 capability (each default manifest `.id` appears in the output).
# ---------------------------------------------------------------------------
if [ "$driver_ready" -eq 1 ]; then
	run_driver
	default_rc="$RC"
	default_out="$OUT"

	missing_ids=""
	seen_any=0
	for m in "$MANIFEST_DIR"/l0-*.json; do
		[ -e "$m" ] || continue
		seen_any=1
		id="$(jq -r '.id // empty' "$m" 2>/dev/null || true)"
		[ -n "$id" ] || continue
		case "$default_out" in
		*"$id"*) ;;
		*) missing_ids="${missing_ids} ${id}" ;;
		esac
	done

	if [ "$seen_any" -eq 0 ]; then
		printf '# no default L0 manifests found under %s\n' "$MANIFEST_DIR" >&2
		tap_not_ok "default run is green and shows case-level evidence for all L0 capabilities"
	elif [ "$default_rc" -ne 0 ]; then
		printf '# default L0 suite run exited %s; expected 0 (all L0 sensors pass today)\n' "$default_rc" >&2
		tap_not_ok "default run is green and shows case-level evidence for all L0 capabilities"
	elif [ -n "$missing_ids" ]; then
		printf '# default run output missing case-level evidence for L0 capabilities:%s\n' "$missing_ids" >&2
		tap_not_ok "default run is green and shows case-level evidence for all L0 capabilities"
	else
		tap_ok "default run is green and shows case-level evidence for all L0 capabilities"
	fi
else
	printf '# skipped default-run check: run-l0-suite.sh not runnable\n' >&2
	tap_not_ok "default run is green and shows case-level evidence for all L0 capabilities"
fi

# ---------------------------------------------------------------------------
# Assertion 3 — BLOCKING PROOF (mutation). A temp set with a PASS manifest and a
# BLOCKING FAIL manifest must make the driver exit non-zero and emit case-level
# evidence of the blocked/failed case.
# ---------------------------------------------------------------------------
cat >"${TMP_DIR}/l0-mut-pass.json" <<'JSON'
{
  "id": "l0-mut-pass",
  "schema_version": 1,
  "target": "tests/meta/test_l0_ci_gate.sh",
  "capability": "Synthetic PASS case for the L0 CI gate mutation proof.",
  "boundary": "script-lifecycle",
  "fixture": { "type": "generated", "builder": "true" },
  "expected_outcome": "pass",
  "grader": { "type": "shell", "command": "true" },
  "blocking": true
}
JSON

cat >"${TMP_DIR}/l0-mut-blockfail.json" <<'JSON'
{
  "id": "l0-mut-blockfail",
  "schema_version": 1,
  "target": "tests/meta/test_l0_ci_gate.sh",
  "capability": "Synthetic BLOCKING FAIL case for the L0 CI gate mutation proof.",
  "boundary": "script-lifecycle",
  "fixture": { "type": "generated", "builder": "true" },
  "expected_outcome": "fail",
  "grader": { "type": "shell", "command": "false" },
  "blocking": true
}
JSON

if [ "$driver_ready" -eq 1 ]; then
	run_driver "$TMP_DIR"
	mut_rc="$RC"
	mut_out="$OUT"

	blocked_evidence=0
	if printf '%s\n' "$mut_out" | grep -Eq '"blocking_decision"[[:space:]]*:[[:space:]]*"block"'; then
		blocked_evidence=1
	elif printf '%s\n' "$mut_out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"fail"'; then
		blocked_evidence=1
	fi

	if [ "$mut_rc" -eq 0 ]; then
		printf '# mutation set (one blocking FAIL manifest) run exited 0; expected non-zero (gate must block)\n' >&2
		tap_not_ok "blocking FAIL manifest makes the driver exit non-zero with case-level evidence"
	elif [ "$blocked_evidence" -ne 1 ]; then
		printf '# mutation run exited non-zero but emitted no case-level blocked/failed evidence\n' >&2
		tap_not_ok "blocking FAIL manifest makes the driver exit non-zero with case-level evidence"
	else
		tap_ok "blocking FAIL manifest makes the driver exit non-zero with case-level evidence"
	fi
else
	printf '# skipped mutation blocking proof: run-l0-suite.sh not runnable\n' >&2
	tap_not_ok "blocking FAIL manifest makes the driver exit non-zero with case-level evidence"
fi

# ---------------------------------------------------------------------------
# Assertion 4 — the suite driver is wired into the harness-smoke CI workflow.
# ---------------------------------------------------------------------------
if [ -f "$WORKFLOW" ] && grep -q 'run-l0-suite.sh' "$WORKFLOW"; then
	tap_ok "harness-smoke.yml invokes run-l0-suite.sh"
else
	printf '# .github/workflows/harness-smoke.yml does not invoke run-l0-suite.sh (CI gate not wired)\n' >&2
	tap_not_ok "harness-smoke.yml invokes run-l0-suite.sh"
fi

tap_done

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
