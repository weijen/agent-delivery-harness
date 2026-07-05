#!/usr/bin/env bash
# test_eval_manifest_validator.sh — regression sensor for feature
# f2-manifest-validator (issue #61): the eval-case manifest validator
# `tests/evals/bin/validate-manifest.sh <manifest-path>` enforces the Manifest
# Schema contract in docs/evaluation/l0-solution/spec.md § "Manifest Schema".
#
# Executable spec for the validator:
#   * REQUIRED fields (all present): id, schema_version, target, capability,
#     boundary, fixture, expected_outcome, grader, blocking.
#   * `boundary` is one of: script-lifecycle, skill-trigger, skill-artifact,
#     skill-behavior.
#   * `blocking` is a JSON boolean.
#   * `fixture` is a oneOf — EITHER generated (declares `builder`) XOR static
#     (declares `path`). Declaring neither shape, or both, is invalid.
#   * A fully valid manifest exits 0.
#   * On ANY violation the validator exits NON-ZERO and prints, to stderr, the
#     status token `invalid_manifest` plus a SPECIFIC reason naming the
#     offending field/rule.
#
# Each negative below is a real mutation of one otherwise-valid base manifest
# (exactly one field changed/removed), so a passing assertion proves the
# specific guard rather than incidental failure. Fixtures are generated inline
# via heredoc + jq into a throwaway temp dir (runtime-fixture pattern); nothing
# is committed and nothing touches the developer's real checkout.
#
# Exit codes: 0 validator contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT}/tests/evals/bin/validate-manifest.sh"
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
  || hard_fail "jq is required (this sensor builds manifest mutations with jq)"

# RED gate: the script under test must exist and be executable before any
# behavior can be specified against it.
[ -f "$VALIDATOR" ] \
  || hard_fail "tests/evals/bin/validate-manifest.sh not found (${VALIDATOR}) — the eval manifest validator for feature f2-manifest-validator (issue #61) is not implemented yet"
[ -x "$VALIDATOR" ] \
  || hard_fail "tests/evals/bin/validate-manifest.sh exists but is not executable (${VALIDATOR})"

# --- Base valid manifest (generated-fixture shape) -----------------------------
# Only required fields, so each "missing required" mutation is unambiguous. The
# generated fixture declares `type: generated` + `builder`.
BASE="${TMP_DIR}/base.json"
cat > "$BASE" <<'JSON'
{
  "id": "l0-review-gate-freshness",
  "schema_version": 1,
  "target": "scripts/review-gate.sh",
  "capability": "blocks_stale_review_approval",
  "boundary": "script-lifecycle",
  "fixture": {
    "type": "generated",
    "builder": "tests/scripts/test_review_gate.sh"
  },
  "expected_outcome": "reject",
  "grader": {
    "type": "shell",
    "command": "tests/scripts/test_review_gate.sh"
  },
  "blocking": true
}
JSON

# Sanity: the base itself must be parseable JSON, else the mutations are junk.
jq -e . "$BASE" >/dev/null \
  || hard_fail "base manifest fixture is not valid JSON — sensor bug, fix the heredoc"

# --- Derive fixtures by mutating exactly one field -----------------------------
# Valid static-fixture shape: swap the generated fixture for a static one
# (declares `type: static` + `path`).
STATIC_VALID="${TMP_DIR}/static-valid.json"
jq '.fixture = {type: "static", path: "tests/evals/fixtures/scripts/review-gate/"}' \
  "$BASE" > "$STATIC_VALID"

# Missing a required field: drop `expected_outcome`.
MISSING_REQUIRED="${TMP_DIR}/missing-expected-outcome.json"
jq 'del(.expected_outcome)' "$BASE" > "$MISSING_REQUIRED"

# Bad `boundary` enum value: a token outside the closed set.
BAD_BOUNDARY="${TMP_DIR}/bad-boundary.json"
jq '.boundary = "bogus-boundary"' "$BASE" > "$BAD_BOUNDARY"

# `fixture` declaring NEITHER shape: no `builder` and no `path`.
FIXTURE_NEITHER="${TMP_DIR}/fixture-neither.json"
jq '.fixture = {}' "$BASE" > "$FIXTURE_NEITHER"

# `fixture` declaring BOTH shapes: carries `builder` AND `path`.
FIXTURE_BOTH="${TMP_DIR}/fixture-both.json"
jq '.fixture = {type: "generated", builder: "tests/scripts/test_review_gate.sh", path: "tests/evals/fixtures/scripts/review-gate/"}' \
  "$BASE" > "$FIXTURE_BOTH"

# Malformed JSON: not parseable at all (written directly, not via jq).
MALFORMED="${TMP_DIR}/malformed.json"
printf '{ "id": "broken", this is not json,,, \n' > "$MALFORMED"

# --- Validator run helper ------------------------------------------------------
# Captures the exit code, with stdout/stderr pinned to files so assertions can
# inspect the reason text.
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_validator() {
  local rc=0
  "$VALIDATOR" "$1" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# A valid manifest must exit 0.
assert_valid() {
  local label="$1" manifest="$2" rc
  rc="$(run_validator "$manifest")"
  [ "$rc" = "0" ] \
    || fail "${label}: expected exit 0 for a valid manifest, got ${rc} (stderr: $(cat "$ERR"))"
}

# An invalid manifest must exit non-zero, print the invalid_manifest status,
# and name the offending field/rule. `reason` may be empty (malformed JSON only
# has to surface invalid_manifest).
assert_invalid() {
  local label="$1" manifest="$2" reason="$3" rc
  rc="$(run_validator "$manifest")"
  [ "$rc" != "0" ] \
    || fail "${label}: expected non-zero exit for an invalid manifest, got 0 (stdout: $(cat "$OUT"))"
  grep -Fq -- 'invalid_manifest' "$ERR" \
    || fail "${label}: stderr must report status invalid_manifest; got: $(cat "$ERR")"
  if [ -n "$reason" ]; then
    grep -Fqi -- "$reason" "$ERR" \
      || fail "${label}: stderr must name the offending field/rule '${reason}'; got: $(cat "$ERR")"
  fi
}

# --- Cases ---------------------------------------------------------------------
assert_valid   "valid/generated-fixture"   "$BASE"
assert_valid   "valid/static-fixture"      "$STATIC_VALID"
assert_invalid "missing-required-field"    "$MISSING_REQUIRED" "expected_outcome"
assert_invalid "bad-boundary-enum"         "$BAD_BOUNDARY"     "boundary"
assert_invalid "fixture-neither-shape"     "$FIXTURE_NEITHER"  "fixture"
assert_invalid "fixture-both-shapes"       "$FIXTURE_BOTH"     "fixture"
assert_invalid "malformed-json"            "$MALFORMED"        ""

# --- Verdict -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf 'FAIL: %d manifest-validator assertion(s) regressed for tests/evals/bin/validate-manifest.sh\n' \
    "$fails" >&2
  exit 1
fi

printf 'PASS: manifest validator honors the schema contract across all 7 cases\n'
