#!/usr/bin/env bash
# test_create_pr_failure.sh — regression sensor for create-pr.sh loud-failure
# semantics (issue #90).
#
# Contract under test:
#   create-pr.sh is the only sanctioned path for opening a PR. It must never
#   report a successful closeout on a FAILED one. Two failure modes:
#
#   (a) `gh pr create` exits non-zero (network / auth / permission) → the
#       script exits non-zero with a clear PR-creation error and NEVER prints
#       the `✓ PR #… is open.` success line.
#   (b) `gh pr create` succeeds but the PR number cannot be resolved afterward
#       (`gh pr view` yields an empty number) → the script exits non-zero and
#       tells the operator to check GitHub manually, rather than printing
#       `✓ PR #  is open.` with a blank number and exit 0.
#
#   The idempotent path (a PR already exists → re-sync + push, no create) must
#   stay untouched: that is verified by exercising the create branch only.
#
# Fixture style mirrors test_trace_create_pr.sh: a plain repo on a
# feature/issue-NN-* branch with a bare local origin and a pinned PATH carrying
# a fake `gh`, driven through the real review-gate approval first.
#
# Exit codes: 0 both failure modes fail loudly · 1 a failure mode regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo
TMP_DIR="$FIXTURE_TMP_DIR"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Restricted bin with a controllable fake gh ------------------------------
# `pr view` fails until `pr create` has run (state file); once state exists it
# answers number/url queries — UNLESS GH_VIEW_BLANK=1, in which case it returns
# success with an EMPTY number (the "PR number unresolvable" mode). `pr create`
# succeeds unless GH_CREATE_FAIL=1.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git basename dirname mkdir rm cat sed tr cut grep printf date wc touch; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")
    [ -f "${GH_STATE:?}" ] || exit 1
    if [ "${GH_VIEW_BLANK:-0}" = "1" ]; then
      printf '\n'
      exit 0
    fi
    case "$*" in
      *url*)    printf 'https://example.invalid/pr/123\n' ;;
      *number*) printf '123\n' ;;
      *)        printf '123\n' ;;
    esac
    exit 0
    ;;
  "pr create")
    if [ "${GH_CREATE_FAIL:-0}" = "1" ]; then
      printf 'fake gh: pr create forced to fail\n' >&2
      exit 1
    fi
    : > "${GH_STATE:?}"
    exit 0
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
chmod +x "${BIN}/gh"

# make_pr_repo <issue-pad> — feature/issue-<pad>-fixture on a bare origin.
make_pr_repo() {
  local pad="$1" dir=""
  fixture_repo --with-scripts create-pr.sh,review-gate.sh,trace-lib.sh
  dir="$FIXTURE_REPO"
  mkdir -p "${dir}/docs"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs/PROGRESS.md
  git -C "$dir" commit -q -m "add progress baseline"
  git clone -q --bare "$dir" "${FIXTURE_TMP_DIR}/origin.git"
  git -C "$dir" remote add origin "${FIXTURE_TMP_DIR}/origin.git"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$pad" > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs/PROGRESS.md
  git -C "$dir" commit -q -m "issue-${pad}: feature work"
  git -C "$dir" fetch -q origin main
  PR_REPO="$dir"
}

# run_cpr <dir> <state-suffix> <out-file> [env=val ...] -- <args...>
run_cpr() {
  local dir="$1" sfx="$2" out="$3"; shift 3
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  (cd "$dir" && env PATH="$BIN" GH_STATE="${TMP_DIR}/gh-state-${sfx}" "${envs[@]}" \
    ./scripts/create-pr.sh "$@") > "$out" 2>&1
}

# ============================================================================
# (a) gh pr create exits non-zero → loud failure, NO success line
# ============================================================================
make_pr_repo 90
RA="$PR_REPO"
(cd "$RA" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "setup: approve in gh-create-fail repo failed"
OUT_A="${TMP_DIR}/a.out"
if run_cpr "$RA" a "$OUT_A" GH_CREATE_FAIL=1 -- --title t --body b; then
  cat "$OUT_A"; fail "(a) create-pr.sh must exit non-zero when gh pr create fails"
fi
if grep -q 'is open' "$OUT_A"; then
  cat "$OUT_A"; fail "(a) create-pr.sh must NOT print the '✓ PR #… is open.' success line on a failed create"
fi
{ grep -q '✗' "$OUT_A" && grep -qi 'pr' "$OUT_A"; } \
  || { cat "$OUT_A"; fail "(a) create-pr.sh must print its own clear PR-creation error (✗ …)"; }

# ============================================================================
# (b) gh pr create succeeds but PR number is unresolvable → loud failure
# ============================================================================
make_pr_repo 90
RB="$PR_REPO"
(cd "$RB" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "setup: approve in blank-number repo failed"
OUT_B="${TMP_DIR}/b.out"
if run_cpr "$RB" b "$OUT_B" GH_VIEW_BLANK=1 -- --title t --body b; then
  cat "$OUT_B"; fail "(b) create-pr.sh must exit non-zero when the PR number cannot be resolved"
fi
if grep -Eq '✓ PR #[[:space:]]+is open' "$OUT_B" && ! grep -qi 'manual' "$OUT_B"; then
  cat "$OUT_B"; fail "(b) create-pr.sh must not report a blank PR number as success"
fi
grep -qi 'manual\|check github\|could not' "$OUT_B" \
  || { cat "$OUT_B"; fail "(b) create-pr.sh must tell the operator to check GitHub manually"; }

printf 'create-pr loud-failure sensor passed\n'
