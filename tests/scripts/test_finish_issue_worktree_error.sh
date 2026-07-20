#!/usr/bin/env bash
# test_finish_issue_worktree_error.sh — regression sensor for finish-issue.sh
# worktree-remove error surfacing (issue #91).
#
# Contract under test:
#   When `git worktree remove` fails, finish-issue.sh must NOT swallow git's
#   stderr behind a generic "uncommitted changes (or is locked)" message. It
#   must (a) exit 1 and (b) include git's OWN error text (e.g. "contains
#   modified or untracked files") alongside the existing FORCE=1 remediation
#   hint, so a resuming operator can tell dirty vs locked vs other failure.
#   FORCE=1 behavior is unchanged (discards the work, removes the worktree).
#
# The issue worktree carries a gitignored `.copilot-tracking/` tree, so a plain
# `git worktree remove` (no --force) refuses with git's "contains modified or
# untracked files" — the deterministic failure this sensor drives.
#
# Fixture mirrors test_trace_finish_issue.sh's make_finish_fixture: a main repo
# on `main` + a real issue worktree created via start-issue.sh SKIP_INIT=1, with
# a complete feature_list.json planted so completion_check passes and the run
# reaches the worktree_remove stage.
#
# Exit codes: 0 error surfaced (and FORCE=1 still works) · 1 a contract regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc touch mktemp mv cp
# Fake gh: finish-issue.sh only needs it absent-of-error for non-PR paths.
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
export ABANDONED=1

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'

# make_finish_fixture <dir> <issue> — main repo + issue worktree with a
# complete feature_list.json planted in the worktree tracking dir.
make_finish_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh trace-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out"; fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}-worktrees/issue-${pad}" ] || fail "setup: worktree for issue ${issue} not created"
  printf '%s\n' "$COMPLETE_LIST" \
    > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
  # A non-ignored untracked file makes a plain `git worktree remove` refuse
  # (gitignored files alone do not block removal).
  printf 'uncommitted work\n' > "${dir}-worktrees/issue-${pad}/dirty.txt"
}

# ============================================================================
# 1. No FORCE, dirty worktree → exit 1, git's OWN error text + FORCE=1 hint
# ============================================================================
R1="${TMP_DIR}/r91"
make_finish_fixture "$R1" 91
OUT1="${TMP_DIR}/fin-dirty.out"
if (cd "$R1" && PATH="$BIN" ./scripts/finish-issue.sh 91 SLUG=fixture) > "$OUT1" 2>&1; then
  cat "$OUT1"; fail "(1) finish-issue.sh must exit 1 when git worktree remove fails"
fi
# git's own refusal text is surfaced (indented under the "Could not remove"
# header). The exact wording has been stable for years; assert it, but also
# accept any git-emitted reason (untracked/modified/locked) so a future git
# rewording fails on the harness contract, not on a brittle string match.
{ grep -qi 'contains modified or untracked files' "$OUT1" \
  || grep -qiE 'modified|untracked|locked' "$OUT1"; } \
  || { cat "$OUT1"; fail "(1) output must include git's OWN worktree-remove error text (not a suppressed generic message)"; }
# The old suppressed generic message must no longer be the only diagnostic.
if grep -q 'Worktree has uncommitted changes (or is locked)' "$OUT1"; then
  cat "$OUT1"; fail "(1) the suppressed generic message must not replace git's own error"
fi
grep -q 'FORCE=1' "$OUT1" \
  || { cat "$OUT1"; fail "(1) the FORCE=1 remediation hint must remain"; }
[ -e "${R1}-worktrees/issue-91" ] \
  || fail "(1) the worktree must survive a refused removal"

# ============================================================================
# 2. FORCE=1 → unchanged: worktree removed, exit 0
# ============================================================================
R2="${TMP_DIR}/r92"
make_finish_fixture "$R2" 91
OUT2="${TMP_DIR}/fin-force.out"
(cd "$R2" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 91 SLUG=fixture) > "$OUT2" 2>&1 \
  || { cat "$OUT2"; fail "(2) FORCE=1 finish must still exit 0 (behavior unchanged)"; }
grep -q 'Removed worktree' "$OUT2" \
  || { cat "$OUT2"; fail "(2) FORCE=1 removal message must be unchanged"; }
[ ! -e "${R2}-worktrees/issue-91" ] \
  || fail "(2) FORCE=1 must remove the worktree (behavior unchanged)"

printf 'finish-issue worktree-error sensor passed\n'
