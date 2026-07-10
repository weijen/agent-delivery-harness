#!/usr/bin/env bash
# Regression sensor for scripts/check-feature-list.sh — the minimal feature-list
# completion check. It must validate feature_list.json structure and completion
# state, fail clearly on malformed/invalid input, warn (non-blocking) on
# incomplete features by default, and hard-fail on incomplete features only with
# REQUIRE_FEATURES_COMPLETE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/test-feature-list-check-$$"
trap 'rm -rf "${TMP_DIR}"' EXIT
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# Each numbered scenario below sets its own feature_list.json fixture, so state
# is re-established per scenario in a single shell. fail() records a diagnostic
# and marks the current scenario failed WITHOUT aborting; emit() turns that mark
# into exactly one TAP row and resets it for the next scenario. Exit semantics:
# all scenarios pass => tap_done exits 0.
_sfail=0
fail() {
  printf '# %s\n' "$*" >&2
  _sfail=1
}
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

mkdir -p "${TMP_DIR}/repo/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${TMP_DIR}/repo/scripts/issue-lib.sh"
cp "${ROOT}/scripts/start-issue.sh" "${TMP_DIR}/repo/scripts/start-issue.sh"
cp "${ROOT}/scripts/check-feature-list.sh" "${TMP_DIR}/repo/scripts/check-feature-list.sh"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"
cp "${ROOT}/scripts/trace-lib.sh" "${TMP_DIR}/repo/scripts/trace-lib.sh"

cd "${TMP_DIR}/repo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
git commit -q -m initial

CHECK_START_OUT="${TMP_DIR}/check-start.out"
CHECK_OUT="${TMP_DIR}/check.out"

SKIP_INIT=1 ./scripts/start-issue.sh 200 SLUG=check-test >"$CHECK_START_OUT"
FEATURE_LIST="${TMP_DIR}/repo-worktrees/issue-200/.copilot-tracking/issues/issue-200/feature_list.json"
TRACE_FILE="${TMP_DIR}/repo/.copilot-tracking/issues/issue-200/trace.jsonl"
[ -f "$FEATURE_LIST" ] || { printf '# BLOCKING: feature_list.json was not scaffolded\n' >&2; exit 1; }

set_features() { printf '%s\n' "$1" > "$FEATURE_LIST"; }
run_check() { ./scripts/check-feature-list.sh 200 SLUG=check-test >"$CHECK_OUT" 2>&1; }
run_check_hard() { REQUIRE_FEATURES_COMPLETE=1 ./scripts/check-feature-list.sh 200 SLUG=check-test >"$CHECK_OUT" 2>&1; }

# 1. Malformed JSON must fail clearly.
set_features 'this is not json'
if run_check; then cat "$CHECK_OUT"; fail "malformed JSON should fail"; fi
grep -qiE 'json|parse|invalid' "$CHECK_OUT" || fail "malformed JSON error message unclear"
emit "malformed JSON fails clearly"

# 2. Top-level not an object must fail.
set_features '[1,2,3]'
if run_check; then cat "$CHECK_OUT"; fail "non-object feature list should fail"; fi
emit "non-object feature list fails"

# 3. A feature missing a required field (passes) must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[]}]}'
if run_check; then cat "$CHECK_OUT"; fail "missing required field should fail"; fi
grep -qi 'passes' "$CHECK_OUT" || fail "missing-field error should name the field"
emit "a feature missing the required passes field fails and names it"

# 4. steps that is not an array must fail.
set_features '{"features":[{"id":"a","title":"A","steps":"nope","passes":false}]}'
if run_check; then cat "$CHECK_OUT"; fail "non-array steps should fail"; fi
emit "non-array steps fails"

# 5. passes that is not boolean must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":"yes"}]}'
if run_check; then cat "$CHECK_OUT"; fail "non-boolean passes should fail"; fi
emit "non-boolean passes fails"

# 6. passes:true without verification text must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":""}]}'
if run_check; then cat "$CHECK_OUT"; fail "passes:true without verification should fail"; fi
grep -qi 'verification' "$CHECK_OUT" || fail "verification error message unclear"
emit "passes:true without verification text fails and names it"

# 7. Incomplete (passes:false) in DEFAULT mode is a non-blocking warning.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "incomplete feature should warn (exit 0) in default mode"; fi
grep -qi 'incomplete' "$CHECK_OUT" || fail "default mode should report incomplete features as a warning"
emit "incomplete feature warns (exit 0) in default mode"

# 8. Incomplete in HARD mode (REQUIRE_FEATURES_COMPLETE=1) must fail.
if run_check_hard; then cat "$CHECK_OUT"; fail "incomplete feature should fail under REQUIRE_FEATURES_COMPLETE=1"; fi
grep -qi 'incomplete' "$CHECK_OUT" || fail "hard mode should report incomplete features"
emit "incomplete feature fails under REQUIRE_FEATURES_COMPLETE=1"

# 9. A fully complete, well-formed list passes in both modes.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green"}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "complete list should pass in default mode"; fi
if ! run_check_hard; then cat "$CHECK_OUT"; fail "complete list should pass in hard mode"; fi
grep -qiE 'passed|ok|complete' "$CHECK_OUT" || fail "complete list should report success"
emit "a complete well-formed list passes in default and hard modes"

# 10. Missing feature_list.json must fail clearly (standalone contract).
rm -f "$FEATURE_LIST"
if run_check; then cat "$CHECK_OUT"; fail "missing feature_list should fail"; fi
grep -qiE 'not found|missing' "$CHECK_OUT" || fail "missing-file error message unclear"
emit "missing feature_list.json fails clearly"

# 11. Missing jq: the check must SKIP with a warning and exit 0, never crash.
#     Run under a restricted PATH that provides git + coreutils but omits jq.
NOJQ_BIN="${TMP_DIR}/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in git env bash sh dirname basename mkdir rm cat sed tr cut grep printf; do
  tp="$(command -v "$tool" || true)"
  [ -n "$tp" ] && ln -sf "$tp" "${NOJQ_BIN}/${tool}"
done
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'
if ! PATH="$NOJQ_BIN" ./scripts/check-feature-list.sh 200 SLUG=check-test >"$CHECK_OUT" 2>&1; then
  cat "$CHECK_OUT"; fail "missing jq should warn and exit 0, not fail"
fi
grep -qi "jq not installed" "$CHECK_OUT" || fail "missing-jq run did not emit the jq-skip warning"
if grep -qi "command not found" "$CHECK_OUT"; then
  fail "missing-jq run hit an undefined command (crash, not a clean skip)"
fi
emit "missing jq skips the check with a warning and exit 0"

# 12. A well-formed optional teeth_proof object is accepted.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"red_first","evidence":"new sensor failed before production change"}}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "well-formed teeth_proof should pass"; fi
emit "well-formed teeth_proof is accepted"

# 13. A present teeth_proof that is not an object must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":"red_first evidence"}]}'
if run_check; then cat "$CHECK_OUT"; fail "non-object teeth_proof should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "non-object teeth_proof error should name teeth_proof"
emit "non-object teeth_proof hard-fails and names teeth_proof"

# 14. A teeth_proof kind outside the closed set must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"manual","evidence":"not an allowed kind"}}]}'
if run_check; then cat "$CHECK_OUT"; fail "invalid teeth_proof.kind should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "invalid teeth_proof.kind error should name teeth_proof"
emit "invalid teeth_proof.kind hard-fails and names teeth_proof"

# 15. Empty or whitespace-only teeth_proof evidence must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"mutation","evidence":"   "}}]}'
if run_check; then cat "$CHECK_OUT"; fail "whitespace-only teeth_proof.evidence should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "empty teeth_proof.evidence error should name teeth_proof"
emit "empty teeth_proof.evidence hard-fails and names teeth_proof"

# 16. Missing teeth_proof evidence must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"negative_fixture"}}]}'
if run_check; then cat "$CHECK_OUT"; fail "missing teeth_proof.evidence should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "missing teeth_proof.evidence error should name teeth_proof"
emit "missing teeth_proof.evidence hard-fails and names teeth_proof"

# 17. A passes:true feature without teeth_proof is warn-only and reports coverage.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green"}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "missing teeth_proof should warn only (exit 0)"; fi
grep -q 'teeth_proof_missing' "$CHECK_OUT" || fail "missing teeth_proof warning should report teeth_proof_missing"
emit "passes:true without teeth_proof warns with teeth_proof_missing"

# 18. A valid red_first_waiver suppresses teeth_proof_missing.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","red_first_waiver":{"kind":"justified","reason":"legacy feature was already complete before this sensor existed"}}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "valid red_first_waiver should keep missing teeth_proof warn-only"; fi
if grep -q 'teeth_proof_missing' "$CHECK_OUT"; then
  fail "valid red_first_waiver should suppress teeth_proof_missing"
fi
emit "valid red_first_waiver suppresses teeth_proof_missing"

# 19. A valid teeth_proof_waiver suppresses teeth_proof_missing.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof_waiver":{"kind":"doc-only","reason":"docs only, no code path"}}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "valid teeth_proof_waiver should keep missing teeth_proof warn-only"; fi
if grep -q 'teeth_proof_missing' "$CHECK_OUT"; then
  fail "valid teeth_proof_waiver should suppress teeth_proof_missing"
fi
emit "valid teeth_proof_waiver suppresses teeth_proof_missing"

# 20. An empty teeth_proof_waiver hard-fails and names teeth_proof_waiver.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof_waiver":{}}]}'
if run_check; then cat "$CHECK_OUT"; fail "empty teeth_proof_waiver should fail"; fi
grep -q 'teeth_proof_waiver' "$CHECK_OUT" || fail "empty teeth_proof_waiver error should name teeth_proof_waiver"
emit "empty teeth_proof_waiver hard-fails and names teeth_proof_waiver"

# 21. The trace span records teeth_proof_missing_count as a numeric attribute.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green"}]}'
rm -f "$TRACE_FILE"
if ! run_check; then cat "$CHECK_OUT"; fail "missing teeth_proof should warn only (exit 0) while emitting trace"; fi
if [ ! -s "$TRACE_FILE" ]; then
  fail "check-feature-list did not emit trace.jsonl"
else
  missing_count_present="$(jq -r 'select(.span == "tool" and ."gen_ai.tool.name" == "check-feature-list") | has("harness.teeth_proof_missing_count")' "$TRACE_FILE" | tail -n 1)"
  missing_count_type="$(jq -r 'select(.span == "tool" and ."gen_ai.tool.name" == "check-feature-list") | ."harness.teeth_proof_missing_count" | type' "$TRACE_FILE" | tail -n 1)"
  missing_count_value="$(jq -r 'select(.span == "tool" and ."gen_ai.tool.name" == "check-feature-list") | ."harness.teeth_proof_missing_count"' "$TRACE_FILE" | tail -n 1)"
  [ "$missing_count_present" = "true" ] || fail "harness.teeth_proof_missing_count missing from tool span"
  [ "$missing_count_type" = "number" ] || fail "harness.teeth_proof_missing_count type is ${missing_count_type} (expected number)"
  [ "$missing_count_value" = "1" ] || fail "harness.teeth_proof_missing_count value is ${missing_count_value} (expected 1)"
fi
emit "trace span records numeric teeth_proof_missing_count"

# 22. A passes:true feature with teeth_proof:null treats null as absent and warns only.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":null}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "teeth_proof:null should warn only (exit 0) for passes:true"; fi
grep -q 'teeth_proof_missing' "$CHECK_OUT" || fail "teeth_proof:null should report teeth_proof_missing for passes:true"
emit "passes:true with teeth_proof null warns with teeth_proof_missing"

# 23. A passes:false feature with teeth_proof:null treats null as absent and warns only.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false,"teeth_proof":null}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "teeth_proof:null should not hard-fail for passes:false"; fi
emit "passes:false with teeth_proof null does not hard-fail"

tap_done
