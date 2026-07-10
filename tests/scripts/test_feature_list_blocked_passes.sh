#!/usr/bin/env bash
# Regression sensor (issue #88, Loop 3 fail-closed rule): a feature can never be
# blocked_on a replan AND passes:true at the same time. check-feature-list.sh
# must reject that contradiction as a hard structural failure (exit 1), while a
# feature with blocked_on:null and passes:true still validates. This keeps a
# falsified/replanned feature from silently staying "green".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/test-feature-list-blocked-passes-$$"
trap 'rm -rf "${TMP_DIR}"' EXIT
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

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

START_OUT="${TMP_DIR}/start.out"
CHECK_OUT="${TMP_DIR}/check.out"

SKIP_INIT=1 ./scripts/start-issue.sh 300 SLUG=blocked-test >"$START_OUT"
FEATURE_LIST="${TMP_DIR}/repo-worktrees/issue-300/.copilot-tracking/issues/issue-300/feature_list.json"
[ -f "$FEATURE_LIST" ] || { printf '# BLOCKING: feature_list.json was not scaffolded\n' >&2; exit 1; }

set_features() { printf '%s\n' "$1" > "$FEATURE_LIST"; }
run_check() { ./scripts/check-feature-list.sh 300 SLUG=blocked-test >"$CHECK_OUT" 2>&1; }

# 1. blocked_on set AND passes:true is a contradiction → hard fail.
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":true,"verification":"done","blocked_on":"replan: sensor contract wrong"}]}'
if run_check; then cat "$CHECK_OUT"; fail "blocked_on + passes:true must be a hard failure"; fi
grep -qiE 'blocked_on|blocked' "$CHECK_OUT" || { cat "$CHECK_OUT"; fail "error message must name the blocked_on/passes conflict"; }
emit "blocked_on + passes:true is rejected"

# 2. blocked_on set with passes:false is legitimate (feature paused, not green).
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":false,"blocked_on":"replan: sensor contract wrong"}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "blocked_on + passes:false must be allowed"; fi
emit "blocked_on + passes:false is allowed"

# 3. blocked_on:null + passes:true (with verification) still validates.
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":true,"verification":"done","blocked_on":null}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "blocked_on:null + passes:true must still pass"; fi
emit "blocked_on:null + passes:true still validates"

# 4. blocked_on set to empty string is not "blocked" → passes:true allowed.
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":true,"verification":"done","blocked_on":""}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "empty-string blocked_on must not count as blocked"; fi
emit "empty-string blocked_on + passes:true allowed"

tap_done
