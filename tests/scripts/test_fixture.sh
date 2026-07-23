#!/usr/bin/env bash
# Behavioral self-test for tests/scripts/lib/fixture.sh (issue #373).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_LIB="${ROOT}/tests/scripts/lib/fixture.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$FIXTURE_LIB" ] \
  || fail "shared fixture library is missing: ${FIXTURE_LIB}"

# shellcheck source=tests/scripts/lib/fixture.sh
source "$FIXTURE_LIB"

fixture_repo --with-scripts trace-lib.sh,log-handback.sh
FIRST_TMP="$FIXTURE_TMP_DIR"

[ "$FIXTURE_MAIN" = "$FIXTURE_REPO" ] \
  || fail "default fixture main path must equal its repository path"
[ "$FIXTURE_WORKTREE" = "$FIXTURE_REPO" ] \
  || fail "default fixture worktree path must equal its repository path"
[ "$FIXTURE_BRANCH" = "main" ] \
  || fail "default fixture branch must be main"
[ -z "$FIXTURE_PROGRESS" ] \
  || fail "default fixture must not create a progress scaffold"
[ "$(git -C "$FIXTURE_REPO" branch --show-current)" = "main" ] \
  || fail "default fixture repository is not on main"
git -C "$FIXTURE_REPO" rev-parse --verify HEAD >/dev/null 2>&1 \
  || fail "default fixture repository has no baseline commit"
for script in trace-lib.sh log-handback.sh; do
  [ -f "${FIXTURE_REPO}/scripts/${script}" ] \
    || fail "requested script was not copied: ${script}"
done

fixture_repo --worktree 7 --with-scripts issue-lib.sh --progress
[ "$FIXTURE_TMP_DIR" != "$FIRST_TMP" ] \
  || fail "each fixture_repo call must allocate an isolated root"
[ "$FIXTURE_ISSUE" = "07" ] \
  || fail "worktree issue must be zero-padded"
[ "$FIXTURE_BRANCH" = "feature/issue-07-fixture" ] \
  || fail "worktree branch has the wrong name"
[ "$FIXTURE_WORKTREE" = "${FIXTURE_REPO}/.worktrees/issue-07" ] \
  || fail "worktree path is outside the repository trust boundary"
[ "$(git -C "$FIXTURE_WORKTREE" branch --show-current)" = "$FIXTURE_BRANCH" ] \
  || fail "fixture worktree is not on the returned branch"
[ "$FIXTURE_PROGRESS" = "${FIXTURE_WORKTREE}/.copilot-tracking/issues/issue-07/progress.md" ] \
  || fail "progress global has the wrong path"
[ -f "$FIXTURE_PROGRESS" ] \
  || fail "requested progress scaffold was not created"
grep -q '^# Issue 7 progress$' "$FIXTURE_PROGRESS" \
  || fail "progress scaffold does not identify the issue"

# Resolve the repository source through a symlink and work under a pinned PATH.
SELF_TMP="$(mktemp -d)"
PINNED_BIN="${SELF_TMP}/bin"
mkdir -p "$PINNED_BIN"
for tool in bash git mkdir mktemp rm cp readlink dirname; do
  path="$(command -v "$tool" || true)"
  [ -n "$path" ] && ln -s "$path" "${PINNED_BIN}/${tool}"
done
ln -s "$FIXTURE_LIB" "${SELF_TMP}/linked-fixture.sh"
(
  PATH="$PINNED_BIN"
  # shellcheck source=/dev/null
  source "${SELF_TMP}/linked-fixture.sh"
  fixture_repo --with-scripts trace-lib.sh
  [ -f "${FIXTURE_REPO}/scripts/trace-lib.sh" ]
) || fail "symlinked helper failed under a pinned PATH"

# The helper-owned EXIT trap removes every allocated fixture root.
CLEANUP_RECORD="${SELF_TMP}/cleanup-path"
PATH="$PINNED_BIN" bash -c '
  set -euo pipefail
  source "$1"
  fixture_repo
  printf "%s\n" "$FIXTURE_TMP_DIR" > "$2"
' _ "$FIXTURE_LIB" "$CLEANUP_RECORD"
CLEANED_PATH="$(cat "$CLEANUP_RECORD")"
[ ! -e "$CLEANED_PATH" ] \
  || fail "helper EXIT trap did not remove its fixture root"

if fixture_repo --unknown-option >/dev/null 2>&1; then
  fail "unknown fixture_repo options must fail"
fi
if fixture_repo --with-scripts ../escape.sh >/dev/null 2>&1; then
  fail "script names containing paths must fail"
fi

fixture_cleanup
rm -rf "$SELF_TMP"

printf 'shared fixture helper contract honored\n'
