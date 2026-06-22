#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_commit() {
  local message="$1"
  local tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref refs/heads/main "$commit"
  git reset -q --hard "$commit"
}

mkdir -p "${TMP_DIR}/repo/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${TMP_DIR}/repo/scripts/issue-lib.sh"
cp "${ROOT}/scripts/start-issue.sh" "${TMP_DIR}/repo/scripts/start-issue.sh"
cp "${ROOT}/scripts/finish-issue.sh" "${TMP_DIR}/repo/scripts/finish-issue.sh"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"

cd "${TMP_DIR}/repo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial"

SKIP_INIT=1 ./scripts/start-issue.sh 123 SLUG=scaffold-test >/tmp/start-issue.out
WORKTREE="${TMP_DIR}/repo-worktrees/issue-123"
FEATURE_LIST="${WORKTREE}/.copilot-tracking/issues/issue-123/feature_list.json"

[ -f "$FEATURE_LIST" ] || fail "feature_list.json was not scaffolded"
jq -e '.feature_schema.steps and (.feature_schema.passes == false) and (.feature_schema.regression_sensor == null) and (.feature_schema.e2e_sensor == null) and (.feature_schema.blocked_on == null) and (.feature_schema.verification == null)' "$FEATURE_LIST" >/dev/null || fail "feature schema missing expected fields"

jq '.features = [{"id":"fixture","title":"Fixture","steps":[],"passes":false,"regression_sensor":"fixture","e2e_sensor":null,"blocked_on":null,"verification":null}]' "$FEATURE_LIST" >"${FEATURE_LIST}.tmp"
mv "${FEATURE_LIST}.tmp" "$FEATURE_LIST"

if REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 123 SLUG=scaffold-test >/tmp/finish-hard.out 2>&1; then
  fail "finish hard gate passed with incomplete features"
fi
grep -q "incomplete feature_list items" /tmp/finish-hard.out || fail "finish hard gate did not report incomplete features"

jq '.features[0].passes = true' "$FEATURE_LIST" >"${FEATURE_LIST}.tmp"
mv "${FEATURE_LIST}.tmp" "$FEATURE_LIST"
REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 123 SLUG=scaffold-test >/tmp/finish-pass.out

printf 'issue scaffold smoke passed\n'