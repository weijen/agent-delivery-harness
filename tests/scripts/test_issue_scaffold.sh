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
cp "${ROOT}/scripts/check-feature-list.sh" "${TMP_DIR}/repo/scripts/check-feature-list.sh"
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

jq '.features[0].passes = true | .features[0].verification = "verified: closeout smoke green"' "$FEATURE_LIST" >"${FEATURE_LIST}.tmp"
mv "${FEATURE_LIST}.tmp" "$FEATURE_LIST"
REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 123 SLUG=scaffold-test >/tmp/finish-pass.out

# --- Issue #17 regression: warning paths must not crash on an undefined helper ---
# finish-issue.sh has two warning-mode branches (incomplete features in default mode,
# and missing jq). Both call a warning helper; if that helper is undefined the script
# aborts with "command not found" under `set -e` instead of warning. Exercise both.

# (a) Default mode (REQUIRE_FEATURES_COMPLETE unset): incomplete features are a WARNING.
#     finish-issue.sh must exit 0 and emit the warning, not crash.
SKIP_INIT=1 ./scripts/start-issue.sh 124 SLUG=warn-test >/tmp/start-warn.out
WORKTREE_WARN="${TMP_DIR}/repo-worktrees/issue-124"
FEATURE_LIST_WARN="${WORKTREE_WARN}/.copilot-tracking/issues/issue-124/feature_list.json"
jq '.features = [{"id":"fixture","title":"Fixture","steps":[],"passes":false,"regression_sensor":null,"e2e_sensor":null,"blocked_on":null,"verification":null}]' "$FEATURE_LIST_WARN" >"${FEATURE_LIST_WARN}.tmp"
mv "${FEATURE_LIST_WARN}.tmp" "$FEATURE_LIST_WARN"
if ! ./scripts/finish-issue.sh 124 SLUG=warn-test >/tmp/finish-warn.out 2>&1; then
  cat /tmp/finish-warn.out >&2
  fail "default-mode finish crashed on incomplete features (expected a warning + exit 0)"
fi
grep -q "incomplete feature_list items remain" /tmp/finish-warn.out || fail "default-mode finish did not emit the incomplete-features warning"
if grep -qi "command not found" /tmp/finish-warn.out; then
  fail "default-mode finish hit an undefined helper (yellow-path regression)"
fi

# (b) Missing jq: the completion check must SKIP with a warning, not crash. Run with a
#     restricted PATH that provides the tools finish-issue.sh needs but omits jq.
SKIP_INIT=1 ./scripts/start-issue.sh 125 SLUG=nojq-test >/tmp/start-nojq.out
WORKTREE_NOJQ="${TMP_DIR}/repo-worktrees/issue-125"
FEATURE_LIST_NOJQ="${WORKTREE_NOJQ}/.copilot-tracking/issues/issue-125/feature_list.json"
jq '.features = [{"id":"fixture","title":"Fixture","steps":[],"passes":false,"regression_sensor":null,"e2e_sensor":null,"blocked_on":null,"verification":null}]' "$FEATURE_LIST_NOJQ" >"${FEATURE_LIST_NOJQ}.tmp"
mv "${FEATURE_LIST_NOJQ}.tmp" "$FEATURE_LIST_NOJQ"
NOJQ_BIN="${TMP_DIR}/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in git env bash sh dirname basename mkdir rm cat sed tr cut grep; do
  tool_path="$(command -v "$tool" || true)"
  [ -n "$tool_path" ] && ln -sf "$tool_path" "${NOJQ_BIN}/${tool}"
done
if ! PATH="$NOJQ_BIN" ./scripts/finish-issue.sh 125 SLUG=nojq-test >/tmp/finish-nojq.out 2>&1; then
  cat /tmp/finish-nojq.out >&2
  fail "missing-jq finish crashed (expected a skip warning + exit 0)"
fi
grep -q "jq not installed" /tmp/finish-nojq.out || fail "missing-jq finish did not emit the jq-skip warning"
if grep -qi "command not found" /tmp/finish-nojq.out; then
  fail "missing-jq finish hit an undefined helper (yellow-path regression)"
fi

printf 'issue scaffold smoke passed\n'