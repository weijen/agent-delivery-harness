#!/usr/bin/env bash
# test_run_evals_not_run.sh — regression sensor for feature f2-not-run-handling
# (issue #62): when a manifest's grader DEPENDENCY is unavailable — the grader
# command's executable does not exist on PATH — the eval runner
# `tests/evals/bin/run-evals.sh <manifest.json>` must classify the case as an
# environment problem, NOT a target failure.
#
# ---------------------------------------------------------------------------
# Missing-dependency signal PINNED by this sensor
# ---------------------------------------------------------------------------
# The distinguishing signal is: the FIRST WORD of `grader.command` is not
# resolvable via `command -v` (equivalently, running the grader yields exit 127,
# "command not found"). An unresolvable grader executable means the eval could
# not be *run* — the target under evaluation never got a verdict — so the outcome
# is an environment/infrastructure problem, distinct from a grader that runs and
# reports the target failing.
#
# Required classification (per docs/evaluation/l0-solution/spec.md
# § "Scorecard Schema"):
#   * status       ∈ {not_run, infrastructure_error}   (NOT "fail")
#   * failure_type == "environment_missing"            (NOT "target_failure")
# The runner must STILL emit a schema-valid JSON scorecard on stdout — it must
# not crash with a raw shell error or empty output.
#
# ---------------------------------------------------------------------------
# RED expectation
# ---------------------------------------------------------------------------
# The current runner (feature f1) runs `bash -c "$grader_cmd"` and maps ANY
# non-zero exit to status "fail" + failure_type "target_failure". A missing
# executable exits 127, so today the runner emits fail/target_failure. This
# sensor's classification assertions therefore FAIL RED with the exact mismatch
# (got status=fail / failure_type=target_failure, expected a not_run-class
# status + environment_missing). That is the intended RED signal for the
# implementation-subagent, not a sensor bug: the "valid JSON scorecard" rows are
# expected to already pass, isolating the missing-classification behavior.
#
# Exit codes: 0 runner classifies a missing grader dependency correctly · 1 a
#             contract obligation regressed (or the RED gate: runner missing).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="${ROOT}/tests/evals/bin/run-evals.sh"
VALIDATOR="${ROOT}/tests/evals/bin/validate-manifest.sh"

# shellcheck source=/dev/null
. "${ROOT}/tests/scripts/lib/tap.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A grader executable name engineered to be absent from any real PATH. The
# sensor asserts its absence below before relying on it (a sensor-bug guard).
MISSING_TOOL="harness_nonexistent_grader_zzq9"

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (this sensor builds a manifest and parses the scorecard with jq)"

# --- RED gate ------------------------------------------------------------------
# The runner under test must exist and be executable before its behavior can be
# specified. (Feature f1 already provides it; this guards against a broken tree.)
[ -f "$RUNNER" ] \
  || hard_fail "tests/evals/bin/run-evals.sh not found (${RUNNER}) — the eval runner (issue #62) is not present"
[ -x "$RUNNER" ] \
  || hard_fail "tests/evals/bin/run-evals.sh exists but is not executable (${RUNNER})"

# The manifest validator (issue #61) is a hard dependency: this sensor proves
# its fixture is schema-valid before feeding it to the runner, so a runner
# misclassification is never confounded by an invalid manifest.
[ -x "$VALIDATOR" ] \
  || hard_fail "tests/evals/bin/validate-manifest.sh not found or not executable (${VALIDATOR}) — required to prove this sensor's manifest is valid"

# --- Sensor-bug guard: the "missing" tool must truly be missing -----------------
# If some environment actually provides MISSING_TOOL, the whole premise collapses
# and any RED/GREEN result would be meaningless. Hard-fail rather than emit a
# misleading verdict.
if command -v "$MISSING_TOOL" >/dev/null 2>&1; then
  hard_fail "grader tool '${MISSING_TOOL}' unexpectedly resolves on PATH — this sensor requires it to be ABSENT to model an unavailable grader dependency"
fi

# --- Inline manifest: valid per the #61 schema, absent grader dependency --------
# The manifest is a well-formed, schema-valid eval case (verified below with
# validate-manifest.sh) whose grader.command invokes MISSING_TOOL. Its first word
# does not resolve via `command -v`, so the grader dependency is unavailable and
# the case cannot be run to a target verdict.
MISSING_MANIFEST="${TMP_DIR}/missing-grader.json"
cat > "$MISSING_MANIFEST" <<JSON
{
  "id": "l0-runner-selftest-missing-grader",
  "schema_version": 1,
  "target": "tests/evals/bin/run-evals.sh",
  "capability": "runner_reports_environment_missing_for_absent_grader_dependency",
  "boundary": "script-lifecycle",
  "fixture": {
    "type": "generated",
    "builder": "true"
  },
  "expected_outcome": "pass",
  "grader": {
    "type": "shell",
    "command": "${MISSING_TOOL} --run"
  },
  "blocking": true
}
JSON

# Sanity: the manifest must be parseable JSON and schema-valid, else the runner
# scenario below is junk (a sensor bug, not a runner regression).
jq -e . "$MISSING_MANIFEST" >/dev/null \
  || hard_fail "missing-grader manifest fixture is not valid JSON — sensor bug, fix the heredoc"
"$VALIDATOR" "$MISSING_MANIFEST" >/dev/null 2>&1 \
  || hard_fail "missing-grader manifest fixture is not schema-valid per validate-manifest.sh — sensor bug"

# --- Run the runner ------------------------------------------------------------
# Capture the scorecard on stdout to a file, decoupled from the exit status: the
# runner MUST emit the scorecard regardless of the case's blocking decision.
SCORECARD="${TMP_DIR}/missing-grader-scorecard.json"
rc=0
"$RUNNER" "$MISSING_MANIFEST" >"$SCORECARD" 2>"${TMP_DIR}/runner.err" || rc=$?
# rc is intentionally not pinned by this sensor; retained for debugging context.
printf '%s' "$rc" >"${TMP_DIR}/runner.rc"

# assert_jq <file> <jq-filter> <desc>: one TAP row; ok iff the filter is truthy.
assert_jq() {
  local file="$1" filter="$2" desc="$3"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    tap_ok "$desc"
  else
    tap_not_ok "$desc"
  fi
}

# --- Assertion 1: the runner did not crash — valid JSON scorecard on stdout -----
# (Expected to PASS today: f1 already emits a scorecard even on grader failure.)
if jq -e . "$SCORECARD" >/dev/null 2>&1; then
  tap_ok "missing-grader: runner emits a valid JSON scorecard on stdout (no raw shell error / empty output)"
else
  tap_not_ok "missing-grader: runner emits a valid JSON scorecard on stdout (got: $(head -c 400 "$SCORECARD" 2>/dev/null))"
fi

# The classification asserts below read a single results row; surface the actual
# values so a RED failure line shows got-vs-expected without extra digging.
actual_status="$(jq -r '.results[0].status // "<none>"' "$SCORECARD" 2>/dev/null || echo '<unparseable>')"
actual_failure_type="$(jq -r '.results[0].failure_type // "<null>"' "$SCORECARD" 2>/dev/null || echo '<unparseable>')"
actual_blocking_decision="$(jq -r '.results[0].blocking_decision // "<none>"' "$SCORECARD" 2>/dev/null || echo '<unparseable>')"

# --- Assertion 2: status is a not_run-class status, NOT "fail" ------------------
assert_jq "$SCORECARD" \
  'any(.results[]; .status == "not_run" or .status == "infrastructure_error")' \
  "missing-grader: results row status ∈ {not_run, infrastructure_error} (expected; actual='${actual_status}')"

assert_jq "$SCORECARD" \
  'all(.results[]; .status != "fail")' \
  "missing-grader: no results row has status == fail (target-failure misclassification; actual='${actual_status}')"

# --- Assertion 3: failure_type is environment_missing, NOT target_failure -------
assert_jq "$SCORECARD" \
  'any(.results[]; .failure_type == "environment_missing")' \
  "missing-grader: results row failure_type == environment_missing (expected; actual='${actual_failure_type}')"

assert_jq "$SCORECARD" \
  'all(.results[]; .failure_type != "target_failure")' \
  "missing-grader: no results row has failure_type == target_failure (misclassification; actual='${actual_failure_type}')"

# --- Assertion 4: a blocking not_run case is NOT a Tier A block ------------------
# The manifest carries blocking:true, but a not_run/environment_missing outcome
# is explicitly "not a Tier A failure" (docs/evaluation/l0-solution/spec.md
# § "Runtime Profiles": "Missing Azure configuration yields not_run with
# failure_type: environment_missing, not a Tier A failure"). An environment
# problem must therefore NOT escalate to blocking_decision "block"; the correct
# non-blocking decision is "warn". The current runner maps any blocking:true row
# that is not "pass" to "block", so it emits "block" here — FAILS RED with the
# exact got-vs-expected mismatch below.
assert_jq "$SCORECARD" \
  '.results[0].blocking_decision == "warn"' \
  "missing-grader: blocking not_run row uses blocking_decision == warn, not Tier A block (expected warn; actual='${actual_blocking_decision}')"

# --- Verdict -------------------------------------------------------------------
tap_done
