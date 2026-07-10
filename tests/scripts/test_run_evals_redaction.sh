#!/usr/bin/env bash
# test_run_evals_redaction.sh — regression sensor for feature f3-redaction-gate
# (issue #62): the L0 eval runner `tests/evals/bin/run-evals.sh` must enforce a
# FAIL-CLOSED redaction gate over grader evidence.
#
# Contract pinned here (models the exporter's "Fail-closed export gates" in
# docs/runtime-adapters/otlp-azure-monitor.md; reuses the repo's redaction
# policy in scripts/trace-lib.sh `trace_redact`;
# failure_type vocabulary in docs/evaluation/l0-solution/spec.md § "Scorecard
# Schema"):
#
#   When a graded case's captured grader evidence contains a secret shape, the
#   emitted scorecard MUST:
#     1. be VALID JSON (the runner does not crash on secret-bearing evidence);
#     2. set  .redaction.checked        == true;
#     3. set  .redaction.secrets_found  == true;
#     4. classify the affected results row  .results[0].failure_type
#        == "redaction_failure";
#     5. FAIL CLOSED — the raw secret string MUST NOT appear anywhere in the
#        runner's STDOUT (the scorecard) NOR in the runner's STDERR. This is the
#        core guarantee: zero literal matches of the secret on either stream.
#
# The grader below prints a clearly-FAKE, shape-valid GitHub personal-access
# token to stdout. `ghp_FAKE0000000000000000000000000000000000` matches the
# repo redactor's very first rule in scripts/trace-lib.sh `trace_redact`
# (`s/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED]/g`). It is NOT a real
# credential — it is the literal word FAKE followed by zeros — so committing
# this sensor leaks nothing.
#
# RED (pre-implementation) expectation: the current runner discards grader
# output and self-declares `redaction.secrets_found:false` with the status
# mapping limited to pass/fail/invalid_manifest. So for this secret-bearing,
# non-zero grader the current runner emits `secrets_found:false` and
# `failure_type:"target_failure"` — assertions 3 and 4 FAIL. That is the RIGHT
# RED reason (no redaction classification of secret-bearing evidence), not a
# sensor bug. Assertions 1, 2, and 5 already hold today (the discarded output
# means the secret never reaches the scorecard), and must KEEP holding once the
# gate captures + scrubs evidence.
#
# Exit codes: 0 the redaction gate contract is honored · 1 a contract
# obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
