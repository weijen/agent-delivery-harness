#!/usr/bin/env bash
# test_run_evals_scorecard.sh — regression sensor for feature f1-runner-scorecard
# (issue #62): the eval runner `tests/evals/bin/run-evals.sh <manifest.json>`
# reads a selected manifest, runs its grader, and emits a schema-valid,
# case-level scorecard per docs/evaluation/l0-solution/spec.md § "Scorecard
# Schema".
#
# ---------------------------------------------------------------------------
# Runner invocation contract PINNED by this sensor
# ---------------------------------------------------------------------------
#   Invocation : run-evals.sh <manifest-path>
#                (one manifest path argument; absolute paths accepted)
#   Output     : the scorecard JSON is written to STDOUT (the cleanest, most
#                parseable channel; no scorecard file is required for this
#                sensor). The runner MAY additionally persist under
#                tests/evals/scorecards/, but stdout is the asserted surface.
#   Exit code  : NOT pinned by this sensor. A blocking case failure may make
#                the runner exit non-zero; the runner MUST still emit the
#                scorecard to stdout regardless of the case's pass/fail
#                blocking decision. This sensor captures stdout independently of
#                the exit status and asserts on the scorecard content, so it
#                does not over-constrain the runner's exit semantics (those are
#                a separate blocking-decision concern).
#   Grader     : the runner runs `manifest.grader.command`. Exit 0 -> the target
#                behaved as graded -> status "pass". Non-zero -> the target
#                failed the grader -> status "fail" + failure_type
#                "target_failure".
#
# ---------------------------------------------------------------------------
# Executable spec asserted here
# ---------------------------------------------------------------------------
# Against a trivially PASSING manifest (grader command `true`) and a trivially
# FAILING manifest (grader command `false`) — both valid per the #61 manifest
# schema (verified inline with validate-manifest.sh) — the emitted scorecard:
#   * is valid JSON carrying the required top-level fields: schema_version,
#     run_id, commit_sha, runtime, runner_version, tool_versions, redaction,
#     results, aggregates;
#   * sets redaction.checked == true;
#   * sets runtime to one of local | github-pr | github-actions |
#     azure-l1-nightly;
#   * populates tool_versions.bash and tool_versions.git with non-empty strings;
#   * PASS manifest -> a results row with status == "pass";
#   * FAIL manifest -> a results row with status == "fail" AND failure_type ==
#     "target_failure";
#   * keeps aggregates internally consistent: total_cases == |results|,
#     passed == |rows with status pass|, failed == |rows with status fail|.
#
# The two content scenarios are reported as independent TAP rows (dogfooding
# tests/scripts/lib/tap.sh) so one failing assertion does not mask the others.
# Fixtures are generated inline into a throwaway temp dir; nothing is committed
# and nothing touches the developer's real checkout.
#
# RED expectation: tests/evals/bin/run-evals.sh does not exist yet, so this
# sensor hard-fails at the RED gate below naming the missing runner. That is the
# intended RED signal for the implementation-subagent, not a sensor bug.
#
# Exit codes: 0 runner contract honored · 1 a contract obligation regressed (or
#             the RED gate: runner missing).

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

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (this sensor builds manifests and parses scorecards with jq)"

# --- RED gate ------------------------------------------------------------------
# The runner under test must exist and be executable before any behavior can be
# specified against it. This is the RED failure the implementation-subagent
# turns green.
[ -f "$RUNNER" ] \
  || hard_fail "tests/evals/bin/run-evals.sh not found (${RUNNER}) — the eval runner for feature f1-runner-scorecard (issue #62) is not implemented yet"
[ -x "$RUNNER" ] \
  || hard_fail "tests/evals/bin/run-evals.sh exists but is not executable (${RUNNER})"

# The manifest validator (feature f2 of issue #61) is a hard dependency: this
# sensor proves its own fixtures are schema-valid before feeding them to the
# runner, so a runner failure is never confounded by an invalid manifest.
[ -x "$VALIDATOR" ] \
  || hard_fail "tests/evals/bin/validate-manifest.sh not found or not executable (${VALIDATOR}) — required to prove this sensor's manifests are valid"

# --- Inline manifests (both valid per the #61 schema) --------------------------
# A generated fixture with builder `true` (exits 0, no fixture failure) and a
# shell grader. The PASS and FAIL manifests differ ONLY in grader.command:
# `true` (exit 0 -> status pass) vs `false` (non-zero -> status fail +
# failure_type target_failure). expected_outcome is the declared ground truth
# the grader is meant to satisfy; the FAIL manifest's grader deliberately does
# not, forcing a target_failure.
PASS_MANIFEST="${TMP_DIR}/pass.json"
cat > "$PASS_MANIFEST" <<'JSON'
{
  "id": "l0-runner-selftest-pass",
  "schema_version": 1,
  "target": "tests/evals/bin/run-evals.sh",
  "capability": "runner_emits_pass_row_for_passing_grader",
  "boundary": "script-lifecycle",
  "fixture": {
    "type": "generated",
    "builder": "true"
  },
  "expected_outcome": "pass",
  "grader": {
    "type": "shell",
    "command": "true"
  },
  "blocking": true
}
JSON

FAIL_MANIFEST="${TMP_DIR}/fail.json"
cat > "$FAIL_MANIFEST" <<'JSON'
{
  "id": "l0-runner-selftest-fail",
  "schema_version": 1,
  "target": "tests/evals/bin/run-evals.sh",
  "capability": "runner_emits_target_failure_row_for_failing_grader",
  "boundary": "script-lifecycle",
  "fixture": {
    "type": "generated",
    "builder": "true"
  },
  "expected_outcome": "pass",
  "grader": {
    "type": "shell",
    "command": "false"
  },
  "blocking": true
}
JSON

# Sanity: both manifests must be parseable JSON and schema-valid, else the
# runner scenarios below are junk (a sensor bug, not a runner regression).
jq -e . "$PASS_MANIFEST" >/dev/null \
  || hard_fail "PASS manifest fixture is not valid JSON — sensor bug, fix the heredoc"
jq -e . "$FAIL_MANIFEST" >/dev/null \
  || hard_fail "FAIL manifest fixture is not valid JSON — sensor bug, fix the heredoc"
"$VALIDATOR" "$PASS_MANIFEST" >/dev/null 2>&1 \
  || hard_fail "PASS manifest fixture is not schema-valid per validate-manifest.sh — sensor bug"
"$VALIDATOR" "$FAIL_MANIFEST" >/dev/null 2>&1 \
  || hard_fail "FAIL manifest fixture is not schema-valid per validate-manifest.sh — sensor bug"

# --- Runner run helper ---------------------------------------------------------
# Captures the scorecard on stdout to a file, decoupled from the exit status
# (which this sensor does not pin: a blocking fail may exit non-zero yet must
# still emit the scorecard). Returns nothing; the scorecard file is the surface.
run_runner() {
  # $1: manifest path · $2: scorecard output file
  local rc=0
  "$RUNNER" "$1" >"$2" 2>"${TMP_DIR}/runner.err" || rc=$?
  # rc is intentionally unused for assertions; kept for debugging context.
  printf '%s' "$rc" >"${TMP_DIR}/runner.rc"
}

# assert_jq <file> <jq-filter> <desc>: one TAP row; ok iff the filter is truthy
# (jq -e: exit 0 when the last output is not false/null).
assert_jq() {
  local file="$1" filter="$2" desc="$3"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    tap_ok "$desc"
  else
    tap_not_ok "$desc"
  fi
}

# --- Scenario: PASS manifest ---------------------------------------------------
PASS_CARD="${TMP_DIR}/pass-scorecard.json"
run_runner "$PASS_MANIFEST" "$PASS_CARD"

if jq -e . "$PASS_CARD" >/dev/null 2>&1; then
  tap_ok "pass-manifest: runner emits valid JSON scorecard on stdout"
else
  tap_not_ok "pass-manifest: runner emits valid JSON scorecard on stdout (got: $(head -c 400 "$PASS_CARD" 2>/dev/null))"
fi

# Required top-level fields present and non-null.
assert_jq "$PASS_CARD" '.schema_version != null'  "pass-manifest: scorecard has schema_version"
assert_jq "$PASS_CARD" '.run_id != null'          "pass-manifest: scorecard has run_id"
assert_jq "$PASS_CARD" '.commit_sha != null and (.commit_sha | type == "string") and (.commit_sha | length > 0)' \
  "pass-manifest: scorecard has non-empty commit_sha"
assert_jq "$PASS_CARD" '.runner_version != null'  "pass-manifest: scorecard has runner_version"
assert_jq "$PASS_CARD" '(.results | type) == "array"'     "pass-manifest: scorecard has results array"
assert_jq "$PASS_CARD" '(.aggregates | type) == "object"' "pass-manifest: scorecard has aggregates object"

# redaction gate self-declares as checked.
assert_jq "$PASS_CARD" '.redaction.checked == true' "pass-manifest: redaction.checked == true"

# runtime is one of the allowed profile tokens.
assert_jq "$PASS_CARD" \
  '.runtime | IN("local", "github-pr", "github-actions", "azure-l1-nightly")' \
  "pass-manifest: runtime is one of local/github-pr/github-actions/azure-l1-nightly"

# tool_versions carries non-empty bash and git strings.
assert_jq "$PASS_CARD" '.tool_versions.bash | (type == "string") and (length > 0)' \
  "pass-manifest: tool_versions.bash is a non-empty string"
assert_jq "$PASS_CARD" '.tool_versions.git | (type == "string") and (length > 0)' \
  "pass-manifest: tool_versions.git is a non-empty string"

# The passing grader yields a results row with status pass.
assert_jq "$PASS_CARD" 'any(.results[]; .status == "pass")' \
  "pass-manifest: a results row has status == pass"

# Aggregates are internally consistent with the results rows.
assert_jq "$PASS_CARD" '.aggregates.total_cases == (.results | length)' \
  "pass-manifest: aggregates.total_cases == count(results)"
assert_jq "$PASS_CARD" '.aggregates.passed == ([.results[] | select(.status == "pass")] | length)' \
  "pass-manifest: aggregates.passed == count(status==pass)"
assert_jq "$PASS_CARD" '.aggregates.failed == ([.results[] | select(.status == "fail")] | length)' \
  "pass-manifest: aggregates.failed == count(status==fail)"

# --- Scenario: FAIL manifest ---------------------------------------------------
FAIL_CARD="${TMP_DIR}/fail-scorecard.json"
run_runner "$FAIL_MANIFEST" "$FAIL_CARD"

if jq -e . "$FAIL_CARD" >/dev/null 2>&1; then
  tap_ok "fail-manifest: runner emits valid JSON scorecard on stdout"
else
  tap_not_ok "fail-manifest: runner emits valid JSON scorecard on stdout (got: $(head -c 400 "$FAIL_CARD" 2>/dev/null))"
fi

# The failing grader yields a target_failure row (status fail + failure_type).
assert_jq "$FAIL_CARD" 'any(.results[]; .status == "fail" and .failure_type == "target_failure")' \
  "fail-manifest: a results row has status == fail AND failure_type == target_failure"

# Aggregates reflect the failure and stay internally consistent.
assert_jq "$FAIL_CARD" '.aggregates.failed >= 1' \
  "fail-manifest: aggregates.failed >= 1"
assert_jq "$FAIL_CARD" '.aggregates.total_cases == (.results | length)' \
  "fail-manifest: aggregates.total_cases == count(results)"
assert_jq "$FAIL_CARD" '.aggregates.failed == ([.results[] | select(.status == "fail")] | length)' \
  "fail-manifest: aggregates.failed == count(status==fail)"
assert_jq "$FAIL_CARD" '.redaction.checked == true' \
  "fail-manifest: redaction.checked == true"

# --- Verdict -------------------------------------------------------------------
tap_done

(
cd "$ROOT"

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
)

(
cd "$ROOT"

RUNNER="${ROOT}/tests/evals/bin/run-evals.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (this sensor builds an eval manifest with jq and reads the scorecard)"

[ -f "$RUNNER" ] \
  || hard_fail "tests/evals/bin/run-evals.sh not found (${RUNNER}) — the L0 eval runner is not present"
[ -x "$RUNNER" ] \
  || hard_fail "tests/evals/bin/run-evals.sh exists but is not executable (${RUNNER})"

# --- The FAKE secret (never a real credential) ---------------------------------
# Shape-valid GitHub PAT the repo redactor recognizes; the visible word FAKE
# plus zeros makes it obviously non-real. 40 chars after `ghp_` satisfy the
# {20,} redaction rule.
SECRET='ghp_FAKE0000000000000000000000000000000000'

# --- A VALID manifest whose grader emits the secret ----------------------------
# The grader's first token is `printf` (resolves on PATH, so the runner does not
# short-circuit to not_run/environment_missing). It prints the fake secret as
# captured evidence and exits non-zero so the case is a graded failure whose
# evidence the redaction gate must scrub.
GRADER_CMD="printf 'grader emitted token=%s\\n' '${SECRET}'; exit 3"

MANIFEST="${TMP_DIR}/redaction-case.json"
jq -n --arg cmd "$GRADER_CMD" '{
  id: "l0-redaction-gate-secret-in-evidence",
  schema_version: 1,
  target: "tests/evals/bin/run-evals.sh",
  capability: "redacts_secret_in_grader_evidence",
  boundary: "script-lifecycle",
  fixture: {
    type: "generated",
    builder: "tests/scripts/test_run_evals_redaction.sh"
  },
  expected_outcome: "reject",
  grader: {
    type: "shell",
    command: $cmd
  },
  blocking: true
}' > "$MANIFEST"

# Sanity: the manifest we just built must itself be valid JSON, else the run is
# meaningless.
jq -e . "$MANIFEST" >/dev/null \
  || hard_fail "generated manifest is not valid JSON — sensor bug, fix the jq builder"

# --- Run the runner, capturing stdout, stderr, and exit separately -------------
OUT="${TMP_DIR}/scorecard.json"
ERR="${TMP_DIR}/runner.err"
rc=0
"$RUNNER" "$MANIFEST" >"$OUT" 2>"$ERR" || rc=$?
# The runner exits non-zero for a blocking failure; that is expected and is not
# asserted here. What matters is the scorecard content and the fail-closed
# guarantee. rc is captured only so a hard crash (e.g. usage error 2) is visible
# in diagnostics.

# --- Assertion 1: the scorecard is valid JSON (no crash on secret evidence) ----
if ! jq -e . "$OUT" >/dev/null 2>&1; then
  fail "scorecard on stdout is not valid JSON (runner exit ${rc}); stdout: $(cat "$OUT"); stderr: $(cat "$ERR")"
fi

# --- Assertion 2: redaction.checked == true ------------------------------------
checked="$(jq -r '.redaction.checked' "$OUT" 2>/dev/null || true)"
[ "$checked" = "true" ] \
  || fail "expected .redaction.checked == true, got '${checked}'"

# --- Assertion 3: redaction.secrets_found == true (RED today) -------------------
secrets_found="$(jq -r '.redaction.secrets_found' "$OUT" 2>/dev/null || true)"
[ "$secrets_found" = "true" ] \
  || fail "expected .redaction.secrets_found == true when grader evidence carries a secret, got '${secrets_found}' — the redaction gate did not classify secret-bearing evidence"

# --- Assertion 4: results row failure_type == redaction_failure (RED today) -----
failure_type="$(jq -r '.results[0].failure_type' "$OUT" 2>/dev/null || true)"
[ "$failure_type" = "redaction_failure" ] \
  || fail "expected .results[0].failure_type == \"redaction_failure\", got '${failure_type}' — the secret-bearing case was not classified as a redaction failure"

# --- Assertion 5: FAIL CLOSED — the raw secret leaks on NEITHER stream ----------
# grep -c prints the matching-line count and exits 1 on zero matches; `|| true`
# keeps the count ("0") under set -euo pipefail.
secret_hits_out="$(grep -F -c -- "$SECRET" "$OUT" 2>/dev/null || true)"
[ "${secret_hits_out:-X}" = "0" ] \
  || fail "FAIL-CLOSED VIOLATION: the raw secret appears in the scorecard (stdout) ${secret_hits_out} time(s) — it must never be emitted"

secret_hits_err="$(grep -F -c -- "$SECRET" "$ERR" 2>/dev/null || true)"
[ "${secret_hits_err:-X}" = "0" ] \
  || fail "FAIL-CLOSED VIOLATION: the raw secret appears on the runner's stderr ${secret_hits_err} time(s) — it must never be emitted"

# --- Verdict -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d assertion(s) failed for feature f3-redaction-gate.\n' "$fails" >&2
  exit 1
fi

printf 'ok - run-evals.sh fails closed on secret-bearing grader evidence (f3-redaction-gate)\n'
exit 0
)
