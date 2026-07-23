#!/usr/bin/env bash
# Regression sensor for scripts/issue-lib.sh — the single source of truth for
# per-issue naming used by the worktree harness. issue-lib.sh is SOURCED (not
# executed), so this test sources it inside throwaway git repos and asserts the
# pure naming contract: issue-number parsing, zero-padding, slug derivation +
# offline fallback, branch naming, worktree-path naming, and main-checkout
# resolution from inside a linked worktree.
#
# It uses a temp repo and a fake `gh` so it does not touch the developer's real
# repo or network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Canonicalize a directory path (resolve symlinks like macOS /var -> /private/var)
# so comparisons are stable regardless of where issue_main_root was invoked from.
canon() { (cd "$1" && pwd -P); }

# --- A throwaway "main" checkout that carries a copy of issue-lib.sh -----------
REPO="${TMP_DIR}/myrepo"
mkdir -p "${REPO}/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${REPO}/scripts/issue-lib.sh"
cd "${REPO}"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf 'fixture\n' > README.md
git add README.md scripts/issue-lib.sh
git commit -q -m initial

# A fake gh whose `issue view --json title` behavior is controlled by GH_TITLE:
#   GH_TITLE unset/empty  -> exit 1 (simulates offline / not found)
#   GH_TITLE set          -> print that title as JSON-quoted -q .title output
mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  if [ -z "${GH_TITLE:-}" ]; then
    exit 1
  fi
  printf '%s\n' "${GH_TITLE}"
  exit 0
fi
exit 1
SH
chmod +x "${TMP_DIR}/bin/gh"
export PATH="${TMP_DIR}/bin:${PATH}"

# shellcheck source=/dev/null
source "${REPO}/scripts/issue-lib.sh"

# --- 1. issue_parse_number ---------------------------------------------------
[ "$(issue_parse_number 31)" = "31" ]        || fail "parse: bare number not returned verbatim"
[ "$(issue_parse_number ISSUE=31)" = "31" ]  || fail "parse: ISSUE= prefix not stripped"
[ "$(issue_parse_number 007)" = "007" ]      || fail "parse: digits altered unexpectedly"

if issue_parse_number "abc" >/dev/null 2>"${TMP_DIR}/parse.err"; then
  fail "parse: non-numeric input should be rejected (non-zero)"
fi
grep -qi "issue number" "${TMP_DIR}/parse.err" || fail "parse: rejection message should mention an issue number"

if issue_parse_number "ISSUE=" >/dev/null 2>&1; then
  fail "parse: empty ISSUE= should be rejected"
fi

# --- 2. resolve_issue_env: zero-padding + naming (explicit slug avoids gh) ----
resolve_issue_env 7 demo-slug
[ "$ISSUE_PAD" = "07" ]                                  || fail "pad: 7 should zero-pad to 07 (got '$ISSUE_PAD')"
[ "$BRANCH" = "feature/issue-07-demo-slug" ]             || fail "branch: unexpected name '$BRANCH'"
case "$WORKTREE_DIR" in
  */myrepo/.worktrees/issue-07) : ;;
  *) fail "worktree: unexpected path '$WORKTREE_DIR'" ;;
esac
case "$TRACKING_DIR" in
  "${WORKTREE_DIR}/.copilot-tracking/issues/issue-07") : ;;
  *) fail "tracking: unexpected path '$TRACKING_DIR'" ;;
esac

# Wider numbers are left untouched by the 2-digit pad.
resolve_issue_env 105 wide
[ "$ISSUE_PAD" = "105" ]                      || fail "pad: 105 should be left untouched (got '$ISSUE_PAD')"
[ "$BRANCH" = "feature/issue-105-wide" ]      || fail "branch: 3-digit branch name wrong '$BRANCH'"

# --- 3. Slug derivation + offline fallback -----------------------------------
# Offline / not found: gh exits 1 -> slug falls back to issue-<num>.
unset GH_TITLE
[ "$(issue_derive_slug 42)" = "issue-42" ]    || fail "slug: offline gh should fall back to issue-42"

# A real title is lowercased, hyphenated, and trimmed.
GH_TITLE="Hello, World!  Foo" issue_derive_slug 42 >"${TMP_DIR}/slug.out"
[ "$(cat "${TMP_DIR}/slug.out")" = "hello-world-foo" ] || fail "slug: title not normalized (got '$(cat "${TMP_DIR}/slug.out")')"

# resolve_issue_env with NO explicit slug uses the derived (fallback) slug.
unset GH_TITLE
resolve_issue_env 42
[ "$BRANCH" = "feature/issue-42-issue-42" ]   || fail "resolve: fallback slug not used in branch (got '$BRANCH')"

# --- 4. main-checkout resolution from inside a linked worktree ---------------
# issue_main_root must point at the MAIN checkout even when invoked from a
# linked worktree (this is what makes naming identical across worktrees).
expected_main="$(canon "${REPO}")"
[ "$(canon "$(issue_main_root)")" = "$expected_main" ] || fail "main-root: wrong from main checkout"

WT="${TMP_DIR}/myrepo/.worktrees/issue-99"
git worktree add -q -b feature/issue-99-x "$WT" main
(
  cd "$WT"
  # shellcheck source=/dev/null
  source "${REPO}/scripts/issue-lib.sh"
  got="$(cd "$(issue_main_root)" && pwd -P)"
  [ "$got" = "$expected_main" ] || { printf 'FAIL: main-root from linked worktree got %s want %s\n' "$got" "$expected_main" >&2; exit 1; }
  # Naming computed from inside the worktree must match the main-checkout naming.
  resolve_issue_env 7 demo-slug
  [ "$BRANCH" = "feature/issue-07-demo-slug" ] || { printf 'FAIL: branch from worktree wrong %s\n' "$BRANCH" >&2; exit 1; }
  case "$WORKTREE_DIR" in
    */myrepo/.worktrees/issue-07) : ;;
    *) printf 'FAIL: worktree path from worktree wrong %s\n' "$WORKTREE_DIR" >&2; exit 1 ;;
  esac
)

git worktree remove --force "$WT" 2>/dev/null || true

printf 'issue-lib unit checks passed\n'
