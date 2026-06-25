#!/usr/bin/env bash
# test_review_gate_status_doc.sh — regression + e2e sensor for the status-doc gate.
#
# Asserts that scripts/review-gate.sh enforces an update to the repo-wide status
# doc (docs/PROGRESS.md) on the branch diff (main...HEAD):
#
#   1. `review-gate.sh status-doc` exits non-zero with a clear message when
#      docs/PROGRESS.md is unchanged in <base>...HEAD.
#   2. It exits zero when docs/PROGRESS.md changed on the branch.
#   3. There is NO escape hatch: the gate still fails closed even when
#      STATUS_DOC_OPTIONAL=1 is set (every change must update docs/PROGRESS.md).
#   4. The `check` path also runs status-doc (so create-pr.sh enforces it).
#   5. E2E: ./scripts/create-pr.sh blocks without a docs/PROGRESS.md edit and
#      passes with one (deterministic enforcement on the mandatory path).
#
# Exit codes: 0 all behaviors honored · 1 a behavior regressed.

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
  git update-ref refs/heads/feature/status-doc "$commit"
  git reset -q --hard "$commit"
}

write_fake_gh() {
  mkdir -p "${TMP_DIR}/bin"
  cat > "${TMP_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2" = "pr view" ]; then
  exit 1
fi
if [ "$1 $2" = "pr create" ]; then
  printf '%s\n' "$*" >> "${GH_LOG:?}"
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "${TMP_DIR}/bin/gh"
}

setup_origin_main() {
  mkdir -p "${TMP_DIR}/origin-work/scripts" "${TMP_DIR}/origin-work/docs"
  git init -q -b main "${TMP_DIR}/origin-work"
  git -C "${TMP_DIR}/origin-work" config user.name "Harness Test"
  git -C "${TMP_DIR}/origin-work" config user.email "harness-test@example.invalid"
  cp "${ROOT}/scripts/create-pr.sh" "${TMP_DIR}/origin-work/scripts/create-pr.sh"
  cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/origin-work/scripts/review-gate.sh"
  printf '.copilot-tracking/\n' > "${TMP_DIR}/origin-work/.gitignore"
  printf 'initial\n' > "${TMP_DIR}/origin-work/README.md"
  printf '# Progress\n\nbaseline\n' > "${TMP_DIR}/origin-work/docs/PROGRESS.md"
  git -C "${TMP_DIR}/origin-work" add .
  git -C "${TMP_DIR}/origin-work" commit -q -m "initial"
  git clone -q --bare "${TMP_DIR}/origin-work" "${TMP_DIR}/origin.git"
  git -C "${TMP_DIR}/origin-work" remote add origin "${TMP_DIR}/origin.git"
}

# --- Build a working repo on a feature branch off origin/main ----------------
mkdir -p "${TMP_DIR}/repo/scripts" "${TMP_DIR}/repo/docs"
cp "${ROOT}/scripts/create-pr.sh" "${TMP_DIR}/repo/scripts/create-pr.sh"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/repo/scripts/review-gate.sh"

setup_origin_main

cd "${TMP_DIR}/repo"
git init -q -b feature/status-doc
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main

# Start the feature branch exactly at origin/main, then add a non-doc commit.
git reset -q --hard origin/main
printf 'feature\n' > feature.txt
git add feature.txt
make_commit "feature commit (no status doc change)"

# --- 1. status-doc fails closed when docs/PROGRESS.md is unchanged -----------
if ./scripts/review-gate.sh status-doc >/tmp/status-doc-unchanged.out 2>&1; then
  fail "status-doc passed when docs/PROGRESS.md was unchanged"
fi
grep -q "docs/PROGRESS.md" /tmp/status-doc-unchanged.out \
  || fail "status-doc failure did not mention docs/PROGRESS.md"

# --- 3. No escape hatch: STATUS_DOC_OPTIONAL=1 must NOT bypass the gate -------
if STATUS_DOC_OPTIONAL=1 STATUS_DOC_REASON="should be ignored" \
    ./scripts/review-gate.sh status-doc >/tmp/status-doc-optional.out 2>&1; then
  fail "STATUS_DOC_OPTIONAL=1 was honored — the gate must have no override"
fi
grep -q "docs/PROGRESS.md" /tmp/status-doc-optional.out \
  || fail "status-doc failure (with env set) did not mention docs/PROGRESS.md"

# --- 4. check path also runs status-doc --------------------------------------
./scripts/review-gate.sh approve >/dev/null
if ./scripts/review-gate.sh check >/tmp/check-status-doc.out 2>&1; then
  fail "check passed though docs/PROGRESS.md was unchanged"
fi
grep -q "docs/PROGRESS.md" /tmp/check-status-doc.out \
  || fail "check did not enforce the status-doc gate"

# --- 2. status-doc passes once docs/PROGRESS.md changed ----------------------
printf '# Progress\n\nIssue-84 in progress\n' > docs/PROGRESS.md
git add docs/PROGRESS.md
make_commit "feature commit + status doc"

if ! ./scripts/review-gate.sh status-doc >/tmp/status-doc-changed.out 2>&1; then
  fail "status-doc failed when docs/PROGRESS.md was changed"
fi

# check should now pass too (after a fresh approval for the new HEAD)
./scripts/review-gate.sh approve >/dev/null
if ! ./scripts/review-gate.sh check >/tmp/check-changed.out 2>&1; then
  fail "check failed when docs/PROGRESS.md was changed and HEAD approved"
fi

# --- 5. E2E: create-pr.sh blocks without, passes with, a status doc edit -----
write_fake_gh
export PATH="${TMP_DIR}/bin:${PATH}"
export GH_LOG="${TMP_DIR}/gh.log"

# 5a. No status doc change → create-pr.sh must block at the status-doc gate.
git reset -q --hard origin/main
printf 'feature only\n' > feature.txt
git add feature.txt
make_commit "feature only, no status doc"
./scripts/review-gate.sh approve >/dev/null
: > "$GH_LOG"
if ./scripts/create-pr.sh --title "t" --body "b" >/tmp/create-pr-block.out 2>&1; then
  fail "create-pr opened a PR without a docs/PROGRESS.md edit"
fi
grep -q "docs/PROGRESS.md" /tmp/create-pr-block.out \
  || fail "create-pr did not stop at the status-doc gate"
[ ! -s "$GH_LOG" ] || fail "create-pr opened a PR despite the status-doc block"

# 5b. With a status doc change → create-pr.sh passes (opens PR).
printf '# Progress\n\nIssue-84\n' > docs/PROGRESS.md
git add docs/PROGRESS.md
make_commit "feature + status doc"
./scripts/review-gate.sh approve >/dev/null
: > "$GH_LOG"
if ! ./scripts/create-pr.sh --title "t" --body "b" >/tmp/create-pr-pass.out 2>&1; then
  fail "create-pr blocked even though docs/PROGRESS.md changed"
fi
[ -s "$GH_LOG" ] || fail "create-pr did not open a PR after a status-doc edit"

printf 'review gate status-doc sensor passed\n'
