#!/usr/bin/env bash
# test_create_pr_help_no_side_effects.sh — regression sensor for issue #328
# feature create-pr-help-side-effect-free.
#
# Contract under test:
#   ./scripts/create-pr.sh -h|--help must print usage and exit 0 BEFORE any
#   review-gate check, git fetch, git rebase, git push, gh call, or trace
#   span emission — anywhere in $@, not just as $1. Today the script ignores
#   -h/--help entirely, runs the review-gate check, fetches, and rebases (a
#   real HEAD-moving rebase, because origin/main carries a pre-staged
#   conflicting change), so a --help invocation silently rebases an
#   already-pushed branch and invalidates a HEAD-bound review approval.
#
# Fixture style mirrors test_trace_create_pr.sh: a plain repo on a
# feature/issue-NN-* branch with a bare local origin, origin/main advanced
# with a conflicting change so a real rebase would observably move HEAD, and
# review-gate pre-approved so nothing else short-circuits before rebase. A
# fake `gh` on PATH always rejects any call, proving zero `gh` invocations.
#
# Exit codes: 0 help path is side-effect free · 1 a side effect regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Restricted bin with a fake gh that rejects every call -------------------
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git basename dirname mkdir rm cat sed tr cut grep printf date wc touch; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
chmod +x "${BIN}/gh"

# make_pr_repo <dir> <issue-pad> — feature/issue-<pad>-fixture on a bare
# origin, with the review-gate's own status-doc gate satisfied.
make_pr_repo() {
  local dir="$1" pad="$2"
  mkdir -p "${dir}/scripts" "${dir}/docs"
  cp "${ROOT}/scripts/create-pr.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/review-gate.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  printf 'base\n' > "${dir}/conflict.txt"
  git -C "$dir" add .gitignore README.md docs/PROGRESS.md conflict.txt scripts
  git -C "$dir" commit -q -m initial
  git clone -q --bare "$dir" "${dir}-origin.git"
  git -C "$dir" remote add origin "${dir}-origin.git"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$pad" > "${dir}/docs/PROGRESS.md"
  printf 'feature\n' > "${dir}/conflict.txt"
  git -C "$dir" add docs/PROGRESS.md conflict.txt
  git -C "$dir" commit -q -m "issue-${pad}: feature work"
  git -C "$dir" fetch -q origin main
}

# advance_origin_main <dir> — push a conflicting change to origin's main so a
# real rebase would move HEAD and hit a conflict.
advance_origin_main() {
  local dir="$1"
  local work="${dir}-mainwork"
  git clone -q "${dir}-origin.git" "$work"
  git -C "$work" config user.name "Harness Test"
  git -C "$work" config user.email "harness-test@example.invalid"
  printf 'mainline\n' > "${work}/conflict.txt"
  git -C "$work" add conflict.txt
  git -C "$work" commit -q -m "main: conflicting change"
  git -C "$work" push -q origin main
  git -C "$dir" fetch -q origin main
}

R1="${TMP_DIR}/r328"
PAD=328
make_pr_repo "$R1" "$PAD"
advance_origin_main "$R1"
(cd "$R1" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "setup: approve in fixture repo failed"

BRANCH="feature/issue-${PAD}-fixture"
HEAD_BEFORE="$(git -C "$R1" rev-parse HEAD)"

run_help() {
  local flag="$1" out="$2"
  (cd "$R1" && PATH="$BIN" ./scripts/create-pr.sh "$flag") > "$out" 2>&1
}

# --- --help: exit 0, usage printed, no side effect --------------------------
OUT_LONG="${TMP_DIR}/cpr-help-long.out"
if ! run_help --help "$OUT_LONG"; then
  cat "$OUT_LONG"
  fail "--help must exit 0 before any git/gh side effect"
fi
grep -Eq 'Usage:.*create-pr\.sh' "$OUT_LONG" \
  || { cat "$OUT_LONG"; fail "--help must print usage text mentioning create-pr.sh"; }

HEAD_AFTER_LONG="$(git -C "$R1" rev-parse HEAD)"
[ "$HEAD_AFTER_LONG" = "$HEAD_BEFORE" ] \
  || fail "--help must not rebase — HEAD moved from ${HEAD_BEFORE} to ${HEAD_AFTER_LONG}"

git -C "$R1" ls-remote --heads origin "$BRANCH" | grep -q . \
  && fail "--help must not push — origin unexpectedly carries ${BRANCH}"

[ ! -e "${R1}/.copilot-tracking/issues" ] \
  || fail "--help must not emit any trace span (no .copilot-tracking/issues expected)"

# --- -h: same guarantees, short flag ----------------------------------------
OUT_SHORT="${TMP_DIR}/cpr-help-short.out"
if ! run_help -h "$OUT_SHORT"; then
  cat "$OUT_SHORT"
  fail "-h must exit 0 before any git/gh side effect"
fi
grep -Eq 'Usage:.*create-pr\.sh' "$OUT_SHORT" \
  || { cat "$OUT_SHORT"; fail "-h must print usage text mentioning create-pr.sh"; }

HEAD_AFTER_SHORT="$(git -C "$R1" rev-parse HEAD)"
[ "$HEAD_AFTER_SHORT" = "$HEAD_BEFORE" ] \
  || fail "-h must not rebase — HEAD moved from ${HEAD_BEFORE} to ${HEAD_AFTER_SHORT}"

git -C "$R1" ls-remote --heads origin "$BRANCH" | grep -q . \
  && fail "-h must not push — origin unexpectedly carries ${BRANCH}"

[ ! -e "${R1}/.copilot-tracking/issues" ] \
  || fail "-h must not emit any trace span (no .copilot-tracking/issues expected)"

printf 'create-pr.sh --help/-h is side-effect free\n'
