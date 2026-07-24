#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-test-tmp/test-issue-scaffold.$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# Each scenario below runs inside its own `set -e` subshell (the `( set -e ... )`
# wrappers), so fail() exits only that subshell and tap_result turns its exit
# code into exactly one TAP row; the run then continues instead of fail-fast.
# The subshells share on-disk state (worktrees, feature_list.json) but isolate
# variables and cwd. Exit semantics: all scenarios pass => tap_done exits 0.
fail() {
  printf '# %s\n' "$*" >&2
  exit 1
}

tap_result() {
  if [ "$1" -eq 0 ]; then tap_ok "$2"; else tap_not_ok "$2"; fi
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
cp "${ROOT}/scripts/lifecycle-runtime-lib.sh" "${TMP_DIR}/repo/scripts/lifecycle-runtime-lib.sh"
cp "${ROOT}/scripts/finish-lib.sh" "${TMP_DIR}/repo/scripts/finish-lib.sh"
cp "${ROOT}/scripts/check-feature-list.sh" "${TMP_DIR}/repo/scripts/check-feature-list.sh"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"

cd "${TMP_DIR}/repo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial"

SKIP_INIT=1 ./scripts/start-issue.sh 123 SLUG=scaffold-test >"${TMP_DIR}/start-issue.out"
WORKTREE="${TMP_DIR}/repo/.worktrees/issue-123"
FEATURE_LIST="${WORKTREE}/.copilot-tracking/issues/issue-123/feature_list.json"

set +e
(
  set -e
[ -f "$FEATURE_LIST" ] || fail "feature_list.json was not scaffolded"
jq -e '.feature_schema.steps and (.feature_schema.passes == false) and (.feature_schema.regression_sensor == null) and (.feature_schema.e2e_sensor == null) and (.feature_schema.blocked_on == null) and (.feature_schema.verification == null)' "$FEATURE_LIST" >/dev/null || fail "feature schema missing expected fields"
)
_rc=$?
set -e
tap_result "$_rc" "start-issue scaffolds feature_list.json with the expected schema fields"

set +e
(
  set -e
jq '.features = [{"id":"fixture","title":"Fixture","steps":[],"passes":false,"regression_sensor":"fixture","e2e_sensor":null,"blocked_on":null,"verification":null}]' "$FEATURE_LIST" >"${FEATURE_LIST}.tmp"
mv "${FEATURE_LIST}.tmp" "$FEATURE_LIST"

if REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 123 SLUG=scaffold-test >"${TMP_DIR}/finish-hard.out" 2>&1; then
  fail "finish hard gate passed with incomplete features"
fi
grep -q "incomplete feature_list items" "${TMP_DIR}/finish-hard.out" || fail "finish hard gate did not report incomplete features"
)
_rc=$?
set -e
tap_result "$_rc" "finish hard gate refuses an incomplete feature_list"

set +e
(
  set -e
jq '.features[0].passes = true | .features[0].verification = "verified: closeout smoke green"' "$FEATURE_LIST" >"${FEATURE_LIST}.tmp"
mv "${FEATURE_LIST}.tmp" "$FEATURE_LIST"
ABANDONED=1 REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 123 SLUG=scaffold-test >"${TMP_DIR}/finish-pass.out"
)
_rc=$?
set -e
tap_result "$_rc" "finish hard gate passes once every feature is complete"

# --- Issue #17 regression: warning paths must not crash on an undefined helper ---
# finish-issue.sh has two warning-mode branches (incomplete features in default mode,
# and missing jq). Both call a warning helper; if that helper is undefined the script
# aborts with "command not found" under `set -e` instead of warning. Exercise both.

# (a) Default mode (REQUIRE_FEATURES_COMPLETE unset): incomplete features are a WARNING.
#     finish-issue.sh must exit 0 and emit the warning, not crash.
set +e
(
  set -e
SKIP_INIT=1 ./scripts/start-issue.sh 124 SLUG=warn-test >"${TMP_DIR}/start-warn.out"
WORKTREE_WARN="${TMP_DIR}/repo/.worktrees/issue-124"
FEATURE_LIST_WARN="${WORKTREE_WARN}/.copilot-tracking/issues/issue-124/feature_list.json"
jq '.features = [{"id":"fixture","title":"Fixture","steps":[],"passes":false,"regression_sensor":null,"e2e_sensor":null,"blocked_on":null,"verification":null}]' "$FEATURE_LIST_WARN" >"${FEATURE_LIST_WARN}.tmp"
mv "${FEATURE_LIST_WARN}.tmp" "$FEATURE_LIST_WARN"
if ! ABANDONED=1 ./scripts/finish-issue.sh 124 SLUG=warn-test >"${TMP_DIR}/finish-warn.out" 2>&1; then
  cat "${TMP_DIR}/finish-warn.out" >&2
  fail "default-mode finish crashed on incomplete features (expected a warning + exit 0)"
fi
grep -q "incomplete feature_list items remain" "${TMP_DIR}/finish-warn.out" || fail "default-mode finish did not emit the incomplete-features warning"
if grep -qi "command not found" "${TMP_DIR}/finish-warn.out"; then
  fail "default-mode finish hit an undefined helper (yellow-path regression)"
fi
)
_rc=$?
set -e
tap_result "$_rc" "default-mode finish warns (not crash) on incomplete features"

# (b) Missing jq: the completion check must SKIP with a warning, not crash. Run with a
#     restricted PATH that provides the tools finish-issue.sh needs but omits jq.
set +e
(
  set -e
SKIP_INIT=1 ./scripts/start-issue.sh 125 SLUG=nojq-test >"${TMP_DIR}/start-nojq.out"
WORKTREE_NOJQ="${TMP_DIR}/repo/.worktrees/issue-125"
FEATURE_LIST_NOJQ="${WORKTREE_NOJQ}/.copilot-tracking/issues/issue-125/feature_list.json"
jq '.features = [{"id":"fixture","title":"Fixture","steps":[],"passes":false,"regression_sensor":null,"e2e_sensor":null,"blocked_on":null,"verification":null}]' "$FEATURE_LIST_NOJQ" >"${FEATURE_LIST_NOJQ}.tmp"
mv "${FEATURE_LIST_NOJQ}.tmp" "$FEATURE_LIST_NOJQ"
NOJQ_BIN="${TMP_DIR}/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in git env bash sh dirname basename mkdir rm cat sed tr cut grep \
  printf mktemp mv cp awk find sort comm chmod date od wc; do
  tool_path="$(command -v "$tool" || true)"
  [ -n "$tool_path" ] && ln -sf "$tool_path" "${NOJQ_BIN}/${tool}"
done
if ! PATH="$NOJQ_BIN" ABANDONED=1 ./scripts/finish-issue.sh 125 SLUG=nojq-test >"${TMP_DIR}/finish-nojq.out" 2>&1; then
  cat "${TMP_DIR}/finish-nojq.out" >&2
  fail "missing-jq finish crashed (expected a skip warning + exit 0)"
fi
grep -q "jq not installed" "${TMP_DIR}/finish-nojq.out" || fail "missing-jq finish did not emit the jq-skip warning"
if grep -qi "command not found" "${TMP_DIR}/finish-nojq.out"; then
  fail "missing-jq finish hit an undefined helper (yellow-path regression)"
fi
)
_rc=$?
set -e
tap_result "$_rc" "missing-jq finish skips with a warning (not crash)"

# Note (issue #305, feature start-issue-no-hook-seed): the runtime capture layer
# is retiring, so start-issue.sh no longer seeds the developer-local Copilot
# trace hook config (.github/hooks/harness-trace.json) into fresh worktrees. The
# former #144 hook-seeding cases were removed here with that production block;
# the structural sensor tests/scripts/test_start_issue_no_hook_seed.sh now pins
# the no-seeding contract.

tap_done
(
cd "$ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

REPO="${TMP_DIR}/repo"
BIN="${TMP_DIR}/bin"
mkdir -p "${REPO}/scripts" "$BIN"
cp "${ROOT}/scripts/start-issue.sh" "${ROOT}/scripts/issue-lib.sh" \
  "${ROOT}/scripts/lifecycle-runtime-lib.sh" "${REPO}/scripts/"
cat >"${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Repo-local worktree fixture'
EOF
chmod +x "${BIN}/gh"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Harness Test"
git -C "$REPO" config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' >"${REPO}/.gitignore"
printf 'fixture\n' >"${REPO}/README.md"
git -C "$REPO" add .gitignore README.md scripts
git -C "$REPO" commit -qm "test: seed repository"

(
	cd "$REPO"
	PATH="${BIN}:/usr/bin:/bin" SKIP_INIT=1 \
		./scripts/start-issue.sh 77 SLUG=repo-local
) >"${TMP_DIR}/start.out" 2>&1 \
	|| {
		cat "${TMP_DIR}/start.out" >&2
		fail "start-issue failed"
	}

WORKTREE="${REPO}/.worktrees/issue-77"
[ -d "$WORKTREE" ] || fail "new worktree was not created under repo/.worktrees"
[ ! -e "${TMP_DIR}/repo-worktrees/issue-77" ] \
	|| fail "new worktree still used the historical sibling layout"
git -C "$REPO" check-ignore -q .worktrees/issue-77 \
	|| fail "repo-local worktree is not covered by the root ignore rule"
[ -z "$(git -C "$REPO" status --porcelain)" ] \
	|| fail "repo-local worktree dirtied the main checkout"
grep -Fq "worktree: ${WORKTREE}" "${TMP_DIR}/start.out" \
	|| fail "start-issue did not report the repo-local path"

printf 'repo-local issue worktree contract honored\n'
)

(
cd "$ROOT"

START_ISSUE="${ROOT}/scripts/start-issue.sh"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${START_ISSUE}" ]; then
  printf 'FAIL: start-issue.sh not found (%s)\n' "${START_ISSUE}" >&2
  exit 1
fi

# 1a. The "Seeded developer-local hook config" success message must be gone.
if grep -qF 'Seeded developer-local hook config' "${START_ISSUE}"; then
  fail "start-issue.sh must not print 'Seeded developer-local hook config' (seeding retired)"
fi

# 1b. The seeding destination/source vars must be gone (they existed only in the
#     §5 seeding block).
for tok in HOOK_DST HOOK_SRC; do
  if grep -qE "^[[:space:]]*${tok}=" "${START_ISSUE}"; then
    fail "start-issue.sh must not define ${tok} (hook-seeding block retired)"
  fi
done

# 1c. No `cp` of the hook file into the worktree.
if grep -qE '\bcp\b[^#]*harness-trace\.json' "${START_ISSUE}"; then
  fail "start-issue.sh must not cp harness-trace.json into the worktree (seeding retired)"
fi
if grep -qE '\bcp\b[^#]*HOOK_SRC' "${START_ISSUE}"; then
  fail "start-issue.sh must not cp the seed hook source into the worktree (seeding retired)"
fi

# 2. The obsolete dark-run launch warning must be gone.
if grep -qiF 'dark run' "${START_ISSUE}"; then
  fail "start-issue.sh must not frame a missing hook config as a 'dark run' (obsolete after #305 F1)"
fi
if grep -qiF 'runtime spans are only captured' "${START_ISSUE}"; then
  fail "start-issue.sh must not carry the 'runtime spans are only captured …' warning (capture retiring)"
fi

if [ "${fails}" -ne 0 ]; then
  printf '\n%d assertion(s) failed — start-issue.sh still seeds the hook / warns of a dark run.\n' \
    "${fails}" >&2
  exit 1
fi

printf 'PASS: start-issue.sh no longer seeds the runtime hook config or warns of a dark run.\n'
)

(
cd "$ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

# The adversarial title: an embedded double-quote, a backslash, and a newline.
NASTY_TITLE='He said "hi" \back
and newline'

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
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

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc head tail

# Fake gh: `issue view … -q .title` prints the adversarial title; everything
# else fails so the slug still comes from the explicit SLUG= argument.
cat > "${BIN}/gh" <<SH
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
  cat <<'TITLE'
${NASTY_TITLE}
TITLE
  exit 0
fi
exit 1
SH
chmod +x "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

REPO="${TMP_DIR}/repo"
mkdir -p "${REPO}/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${REPO}/scripts/"
cp "${ROOT}/scripts/start-issue.sh" "${REPO}/scripts/"
cp "${ROOT}/scripts/lifecycle-runtime-lib.sh" "${REPO}/scripts/"
cp "${ROOT}/scripts/trace-lib.sh" "${REPO}/scripts/"
cat > "${REPO}/scripts/init.sh" <<'SH'
#!/usr/bin/env bash
echo "stub preflight"
exit 0
SH
chmod +x "${REPO}/scripts/init.sh"

cd "$REPO"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial" main

PATH="$BIN" ./scripts/start-issue.sh 88 SLUG=nasty-title >"${TMP_DIR}/start.out" 2>&1 \
  || { cat "${TMP_DIR}/start.out"; fail "start-issue.sh must exit 0 while scaffolding"; }

FL="${TMP_DIR}/repo/.worktrees/issue-88/.copilot-tracking/issues/issue-88/feature_list.json"
if [ ! -f "$FL" ]; then
  cat "${TMP_DIR}/start.out" 2>/dev/null || true
  fail "feature_list.json was not scaffolded at ${FL}"
else
  if ! jq -e . "$FL" >/dev/null 2>&1; then
    printf '# offending feature_list.json:\n' >&2
    cat "$FL" >&2
    fail "feature_list.json is not valid JSON when the issue title contains a quote/backslash/newline"
  else
    got_title="$(jq -r '.title' "$FL")"
    [ "$got_title" = "$NASTY_TITLE" ] \
      || fail "title did not round-trip: expected <${NASTY_TITLE}>, got <${got_title}>"
  fi
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d start-issue title-escape violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'start-issue title JSON-escape contract honored\n'
)
