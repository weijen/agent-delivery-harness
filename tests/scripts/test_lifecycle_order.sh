#!/usr/bin/env bash
# Behavioral lifecycle-ORDER sensor for the harness scripts.
#
# docs/harness-contract.yml declares four lifecycle gates, and
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
#
# Every external tool is pinned to a per-test PATH (real coreutils/git/jq plus
# fake gh) so the result never depends on the developer's login or ambient
# toolchain ordering.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/harness-contract.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

contract_has_ref() {
  local section="${1%%:*}" id="${1#*:}"
  awk -v section="$section" -v id="$id" '
    /^[A-Za-z_]+:/ { current=$0; sub(/:.*/, "", current); in_section=(current==section); next }
    in_section && $0 == "  - id: " id { found=1; exit }
    END { exit(found ? 0 : 1) }
  ' "$CONTRACT"
}

for ref in gate_start:issue-worktree gate_review:approved-pr gate_merge_closeout:issue-closeout; do
  contract_has_ref "$ref" || { printf '# missing contract gate ref: %s\n' "$ref" >&2; exit 1; }
done

# Each of the three ordering scenarios below runs inside its own `set -e`
# subshell (see the `( set -e ... )` wrappers). fail() therefore exits only that
# subshell; tap_result turns the subshell's exit code into exactly one TAP row
# and the run continues to the next scenario instead of fail-fast. Exit
# semantics are preserved: all scenarios pass => tap_done exits 0.
fail() {
  printf '# %s\n' "$*" >&2
  exit 1
}

tap_result() {
  if [ "$1" -eq 0 ]; then tap_ok "$2"; else tap_not_ok "$2"; fi
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

# link_tools <dir> <tool...> — symlink real tool paths into an isolated bin dir.
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

# write_fake_gh <path> — a fake gh: `pr view` => no PR; `pr create` logs to
# GH_LOG; `issue view` => fail (callers fall back). Everything else fails.
write_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")    exit 1 ;;
  "pr create")  printf '%s\n' "$*" >> "${GH_LOG:?}"; exit 0 ;;
  "issue view") exit 1 ;;
esac
exit 1
SH
  chmod +x "$1"
}

# ============================================================================
# 1. start-issue: preflight BEFORE worktree creation
# ============================================================================
set +e
(
  set -e
R1="${TMP_DIR}/r1"
mkdir -p "${R1}/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${R1}/scripts/"
cp "${ROOT}/scripts/start-issue.sh" "${R1}/scripts/"
# A preflight that FAILS — start-issue must honor it and stop.
cat > "${R1}/scripts/init.sh" <<'SH'
#!/usr/bin/env bash
echo "fake preflight failing on purpose"
exit 1
SH
chmod +x "${R1}/scripts/init.sh"

R1BIN="${TMP_DIR}/r1bin"
link_tools "$R1BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf
write_fake_gh "${R1BIN}/gh"

cd "$R1"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial" main

# NOTE: SKIP_INIT is intentionally NOT set — we want preflight to run.
if PATH="$R1BIN" ./scripts/start-issue.sh 300 SLUG=order >"${TMP_DIR}/order-start.out" 2>&1; then
  cat "${TMP_DIR}/order-start.out"; fail "start-issue must abort when preflight fails"
fi
grep -qi "Preflight failed" "${TMP_DIR}/order-start.out" || { cat "${TMP_DIR}/order-start.out"; fail "start-issue did not report the preflight failure"; }
if [ -e "${TMP_DIR}/r1/.worktrees/issue-300" ]; then
  fail "start-issue created a worktree despite a failed preflight (worktree created BEFORE preflight gate)"
fi
if git show-ref --verify --quiet refs/heads/feature/issue-300-order; then
  fail "start-issue created the issue branch despite a failed preflight"
fi
)
_rc=$?
set -e
tap_result "$_rc" "start-issue runs preflight before creating a worktree"

# ============================================================================
# 2. create-pr: review-gate check BEFORE push
# ============================================================================
set +e
(
  set -e
# Bare origin so a push, if it happened, would be observable.
mkdir -p "${TMP_DIR}/origin-seed/scripts"
cp "${ROOT}/scripts/create-pr.sh" "${TMP_DIR}/origin-seed/scripts/"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/origin-seed/scripts/"
cd "${TMP_DIR}/origin-seed"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'seed\n' > README.md
git add .gitignore README.md scripts
git commit -q -m initial
git clone -q --bare "${TMP_DIR}/origin-seed" "${TMP_DIR}/origin.git"

R2="${TMP_DIR}/r2"
mkdir -p "${R2}/scripts"
cp "${ROOT}/scripts/create-pr.sh" "${R2}/scripts/"
cp "${ROOT}/scripts/review-gate.sh" "${R2}/scripts/"
cd "$R2"
git init -q -b feature/issue-301-order
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'work\n' > README.md
git add .gitignore README.md scripts
make_commit "feature commit" feature/issue-301-order
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main

R2BIN="${TMP_DIR}/r2bin"
link_tools "$R2BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf
write_fake_gh "${R2BIN}/gh"
export GH_LOG="${TMP_DIR}/gh.log"
: > "$GH_LOG"

# No approval recorded -> create-pr must stop at the gate, before push.
if PATH="$R2BIN" ./scripts/create-pr.sh --title "t" --body "b" >"${TMP_DIR}/order-pr.out" 2>&1; then
  cat "${TMP_DIR}/order-pr.out"; fail "create-pr must refuse without a review approval"
fi
grep -qi "has not been approved" "${TMP_DIR}/order-pr.out" || { cat "${TMP_DIR}/order-pr.out"; fail "create-pr did not stop at the review gate"; }
if git ls-remote --heads origin "feature/issue-301-order" 2>/dev/null | grep -q .; then
  fail "create-pr pushed the branch despite a failed review gate (push BEFORE gate)"
fi
[ ! -s "$GH_LOG" ] || fail "create-pr opened a PR despite a failed review gate"
)
_rc=$?
set -e
tap_result "$_rc" "create-pr enforces the review gate before pushing"

# ============================================================================
# 3. finish-issue: validate completion BEFORE removing the worktree
# ============================================================================
set +e
(
  set -e
R3="${TMP_DIR}/r3"
mkdir -p "${R3}/scripts"
for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh init.sh; do
  cp "${ROOT}/scripts/${s}" "${R3}/scripts/"
done
# Pin a PATH that includes jq + a fake gh so the completion check actually runs,
# independent of whether the ambient PATH has jq (check-feature-list.sh hard-
# requires jq and silently skips when it is absent).
command -v jq >/dev/null 2>&1 || fail "this test requires jq (a harness dependency) to be installed"
R3BIN="${TMP_DIR}/r3bin"
link_tools "$R3BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq
write_fake_gh "${R3BIN}/gh"

cd "$R3"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial" main

PATH="$R3BIN" SKIP_INIT=1 ./scripts/start-issue.sh 302 SLUG=order >"${TMP_DIR}/order-finish-start.out"
WT="${TMP_DIR}/r3/.worktrees/issue-302"
FL="${WT}/.copilot-tracking/issues/issue-302/feature_list.json"
[ -d "$WT" ] || fail "setup: worktree for issue 302 was not created"

# Incomplete feature list + hard mode -> finish must fail AND keep the worktree.
printf '%s\n' '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}' > "$FL"
if PATH="$R3BIN" REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 302 SLUG=order >"${TMP_DIR}/order-finish.out" 2>&1; then
  cat "${TMP_DIR}/order-finish.out"; fail "finish-issue must hard-fail on an incomplete feature list (REQUIRE_FEATURES_COMPLETE=1)"
fi
grep -qi "incomplete" "${TMP_DIR}/order-finish.out" || { cat "${TMP_DIR}/order-finish.out"; fail "finish-issue did not report the incomplete feature list"; }
if [ ! -d "$WT" ]; then
  fail "finish-issue removed the worktree despite a failed completion check (removal BEFORE validation)"
fi
)
_rc=$?
set -e
tap_result "$_rc" "finish-issue validates completion before removing the worktree"

tap_done
