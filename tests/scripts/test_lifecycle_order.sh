#!/usr/bin/env bash
# Behavioral lifecycle-ORDER sensor for the harness scripts.
#
# docs/harness-contract.yml declares a lifecycle ORDER, and
# tests/scripts/test_harness_contract.sh proves each step's text is still
# present. Presence is not order: a refactor could keep every string yet run the
# steps in the wrong sequence. This sensor proves the critical ordering
# boundaries behaviorally, by observing side effects:
#
#   1. start-issue.sh runs preflight (init.sh) BEFORE `git worktree add`
#      — a failing preflight must abort with NO worktree created.
#   2. create-pr.sh enforces review-gate `check` BEFORE pushing
#      — an unapproved HEAD must abort with NO branch pushed to origin.
#   3. finish-issue.sh validates feature completion BEFORE removing the worktree
#      — a hard completion failure must leave the worktree intact.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_commit() {
  local message="$1" branch="$2" tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref "refs/heads/${branch}" "$commit"
  git reset -q --hard "$commit"
}

# ============================================================================
# 1. start-issue: preflight BEFORE worktree creation
# ============================================================================
mkdir -p "${TMP_DIR}/r1/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${TMP_DIR}/r1/scripts/"
cp "${ROOT}/scripts/start-issue.sh" "${TMP_DIR}/r1/scripts/"
# A preflight that FAILS — start-issue must honor it and stop.
cat > "${TMP_DIR}/r1/scripts/init.sh" <<'SH'
#!/usr/bin/env bash
echo "fake preflight failing on purpose"
exit 1
SH
chmod +x "${TMP_DIR}/r1/scripts/init.sh"

cd "${TMP_DIR}/r1"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial" main

# NOTE: SKIP_INIT is intentionally NOT set — we want preflight to run.
if ./scripts/start-issue.sh 300 SLUG=order >/tmp/order-start.out 2>&1; then
  cat /tmp/order-start.out; fail "start-issue must abort when preflight fails"
fi
grep -qi "Preflight failed" /tmp/order-start.out || { cat /tmp/order-start.out; fail "start-issue did not report the preflight failure"; }
if [ -e "${TMP_DIR}/r1-worktrees/issue-300" ]; then
  fail "start-issue created a worktree despite a failed preflight (worktree created BEFORE preflight gate)"
fi
if git show-ref --verify --quiet refs/heads/feature/issue-300-order; then
  fail "start-issue created the issue branch despite a failed preflight"
fi

# ============================================================================
# 2. create-pr: review-gate check BEFORE push
# ============================================================================
# Fake gh: `pr view` -> no PR; `pr create` -> log (should never be reached here).
mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")   exit 1 ;;
  "pr create") printf '%s\n' "$*" >> "${GH_LOG:?}"; exit 0 ;;
esac
exit 1
SH
chmod +x "${TMP_DIR}/bin/gh"

# Bare origin so a push, if it happened, would be observable.
mkdir -p "${TMP_DIR}/origin-seed/scripts"
cp "${ROOT}/scripts/create-pr.sh" "${TMP_DIR}/origin-seed/scripts/"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/origin-seed/scripts/"
cd "${TMP_DIR}/origin-seed"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'seed\n' > README.md
git add .gitignore README.md scripts
git commit -q -m initial
git clone -q --bare "${TMP_DIR}/origin-seed" "${TMP_DIR}/origin.git"

mkdir -p "${TMP_DIR}/r2/scripts"
cp "${ROOT}/scripts/create-pr.sh" "${TMP_DIR}/r2/scripts/"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/r2/scripts/"
cd "${TMP_DIR}/r2"
git init -q -b feature/issue-301-order
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'work\n' > README.md
git add .gitignore README.md scripts
make_commit "feature commit" feature/issue-301-order
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main

export PATH="${TMP_DIR}/bin:${PATH}"
export GH_LOG="${TMP_DIR}/gh.log"
: > "$GH_LOG"

# No approval recorded -> create-pr must stop at the gate, before push.
if ./scripts/create-pr.sh --title "t" --body "b" >/tmp/order-pr.out 2>&1; then
  cat /tmp/order-pr.out; fail "create-pr must refuse without a review approval"
fi
grep -qi "has not been approved" /tmp/order-pr.out || { cat /tmp/order-pr.out; fail "create-pr did not stop at the review gate"; }
if git ls-remote --heads origin "feature/issue-301-order" 2>/dev/null | grep -q .; then
  fail "create-pr pushed the branch despite a failed review gate (push BEFORE gate)"
fi
[ ! -s "$GH_LOG" ] || fail "create-pr opened a PR despite a failed review gate"

# ============================================================================
# 3. finish-issue: validate completion BEFORE removing the worktree
# ============================================================================
mkdir -p "${TMP_DIR}/r3/scripts"
for s in issue-lib.sh start-issue.sh finish-issue.sh check-feature-list.sh init.sh; do
  cp "${ROOT}/scripts/${s}" "${TMP_DIR}/r3/scripts/"
done
cd "${TMP_DIR}/r3"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial" main

SKIP_INIT=1 ./scripts/start-issue.sh 302 SLUG=order >/tmp/order-finish-start.out
WT="${TMP_DIR}/r3-worktrees/issue-302"
FL="${WT}/.copilot-tracking/issues/issue-302/feature_list.json"
[ -d "$WT" ] || fail "setup: worktree for issue 302 was not created"

# Incomplete feature list + hard mode -> finish must fail AND keep the worktree.
printf '%s\n' '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}' > "$FL"
if REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 302 SLUG=order >/tmp/order-finish.out 2>&1; then
  cat /tmp/order-finish.out; fail "finish-issue must hard-fail on an incomplete feature list (REQUIRE_FEATURES_COMPLETE=1)"
fi
grep -qi "incomplete" /tmp/order-finish.out || { cat /tmp/order-finish.out; fail "finish-issue did not report the incomplete feature list"; }
if [ ! -d "$WT" ]; then
  fail "finish-issue removed the worktree despite a failed completion check (removal BEFORE validation)"
fi

printf 'lifecycle order checks passed\n'
