#!/usr/bin/env bash
# Regression sensor for scripts/check-feature-list.sh — the minimal feature-list
# completion check. It must validate feature_list.json structure and completion
# state, fail clearly on malformed/invalid input, warn (non-blocking) on
# incomplete features by default, and hard-fail on incomplete features only with
# REQUIRE_FEATURES_COMPLETE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${TMP_DIR}/repo/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${TMP_DIR}/repo/scripts/issue-lib.sh"
cp "${ROOT}/scripts/start-issue.sh" "${TMP_DIR}/repo/scripts/start-issue.sh"
cp "${ROOT}/scripts/check-feature-list.sh" "${TMP_DIR}/repo/scripts/check-feature-list.sh"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"

cd "${TMP_DIR}/repo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
git commit -q -m initial

SKIP_INIT=1 ./scripts/start-issue.sh 200 SLUG=check-test >/tmp/check-start.out
FEATURE_LIST="${TMP_DIR}/repo-worktrees/issue-200/.copilot-tracking/issues/issue-200/feature_list.json"
[ -f "$FEATURE_LIST" ] || fail "feature_list.json was not scaffolded"

set_features() { printf '%s\n' "$1" > "$FEATURE_LIST"; }
run_check() { ./scripts/check-feature-list.sh 200 SLUG=check-test >/tmp/check.out 2>&1; }
run_check_hard() { REQUIRE_FEATURES_COMPLETE=1 ./scripts/check-feature-list.sh 200 SLUG=check-test >/tmp/check.out 2>&1; }

# 1. Malformed JSON must fail clearly.
set_features 'this is not json'
if run_check; then cat /tmp/check.out; fail "malformed JSON should fail"; fi
grep -qiE 'json|parse|invalid' /tmp/check.out || fail "malformed JSON error message unclear"

# 2. Top-level not an object must fail.
set_features '[1,2,3]'
if run_check; then cat /tmp/check.out; fail "non-object feature list should fail"; fi

# 3. A feature missing a required field (passes) must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[]}]}'
if run_check; then cat /tmp/check.out; fail "missing required field should fail"; fi
grep -qi 'passes' /tmp/check.out || fail "missing-field error should name the field"

# 4. steps that is not an array must fail.
set_features '{"features":[{"id":"a","title":"A","steps":"nope","passes":false}]}'
if run_check; then cat /tmp/check.out; fail "non-array steps should fail"; fi

# 5. passes that is not boolean must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":"yes"}]}'
if run_check; then cat /tmp/check.out; fail "non-boolean passes should fail"; fi

# 6. passes:true without verification text must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":""}]}'
if run_check; then cat /tmp/check.out; fail "passes:true without verification should fail"; fi
grep -qi 'verification' /tmp/check.out || fail "verification error message unclear"

# 7. Incomplete (passes:false) in DEFAULT mode is a non-blocking warning.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'
if ! run_check; then cat /tmp/check.out; fail "incomplete feature should warn (exit 0) in default mode"; fi
grep -qi 'incomplete' /tmp/check.out || fail "default mode should report incomplete features as a warning"

# 8. Incomplete in HARD mode (REQUIRE_FEATURES_COMPLETE=1) must fail.
if run_check_hard; then cat /tmp/check.out; fail "incomplete feature should fail under REQUIRE_FEATURES_COMPLETE=1"; fi
grep -qi 'incomplete' /tmp/check.out || fail "hard mode should report incomplete features"

# 9. A fully complete, well-formed list passes in both modes.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green"}]}'
if ! run_check; then cat /tmp/check.out; fail "complete list should pass in default mode"; fi
if ! run_check_hard; then cat /tmp/check.out; fail "complete list should pass in hard mode"; fi
grep -qiE 'passed|ok|complete' /tmp/check.out || fail "complete list should report success"

# 10. Missing feature_list.json must fail clearly (standalone contract).
rm -f "$FEATURE_LIST"
if run_check; then cat /tmp/check.out; fail "missing feature_list should fail"; fi
grep -qiE 'not found|missing' /tmp/check.out || fail "missing-file error message unclear"

# 11. Missing jq: the check must SKIP with a warning and exit 0, never crash.
#     Run under a restricted PATH that provides git + coreutils but omits jq.
NOJQ_BIN="${TMP_DIR}/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in git env bash sh dirname basename mkdir rm cat sed tr cut grep printf; do
  tp="$(command -v "$tool" || true)"
  [ -n "$tp" ] && ln -sf "$tp" "${NOJQ_BIN}/${tool}"
done
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'
if ! PATH="$NOJQ_BIN" ./scripts/check-feature-list.sh 200 SLUG=check-test >/tmp/check.out 2>&1; then
  cat /tmp/check.out; fail "missing jq should warn and exit 0, not fail"
fi
grep -qi "jq not installed" /tmp/check.out || fail "missing-jq run did not emit the jq-skip warning"
if grep -qi "command not found" /tmp/check.out; then
  fail "missing-jq run hit an undefined command (crash, not a clean skip)"
fi

printf 'feature-list-check regression checks passed\n'
