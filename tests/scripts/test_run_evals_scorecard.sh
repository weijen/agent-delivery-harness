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
