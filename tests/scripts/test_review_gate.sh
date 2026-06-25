#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# This sensor exercises the approval-marker behavior only; its synthetic branches
# deliberately never touch the repo-wide status doc, so exempt them from the
# status-doc gate that `check`/`create-pr.sh` now enforce.
export STATUS_DOC_OPTIONAL=1
export STATUS_DOC_REASON="review-gate approval-marker test (no status doc in scope)"

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
  git update-ref refs/heads/feature/review-gate "$commit"
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
  mkdir -p "${TMP_DIR}/origin-work"
  git init -q -b main "${TMP_DIR}/origin-work"
  git -C "${TMP_DIR}/origin-work" config user.name "Harness Test"
  git -C "${TMP_DIR}/origin-work" config user.email "harness-test@example.invalid"
  mkdir -p "${TMP_DIR}/origin-work/scripts"
  cp "${ROOT}/scripts/create-pr.sh" "${TMP_DIR}/origin-work/scripts/create-pr.sh"
  cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/origin-work/scripts/review-gate.sh"
  printf '.copilot-tracking/\n' > "${TMP_DIR}/origin-work/.gitignore"
  printf 'initial\n' > "${TMP_DIR}/origin-work/README.md"
  git -C "${TMP_DIR}/origin-work" add .gitignore README.md scripts/create-pr.sh scripts/review-gate.sh
  git -C "${TMP_DIR}/origin-work" commit -q -m "initial"
  git clone -q --bare "${TMP_DIR}/origin-work" "${TMP_DIR}/origin.git"
  git -C "${TMP_DIR}/origin-work" remote add origin "${TMP_DIR}/origin.git"
  git remote add origin "${TMP_DIR}/origin.git"
  git fetch -q origin main
}

add_origin_main_commit() {
  local filename="$1"
  local content="$2"
  printf '%s\n' "$content" > "${TMP_DIR}/origin-work/${filename}"
  git -C "${TMP_DIR}/origin-work" add "$filename"
  git -C "${TMP_DIR}/origin-work" commit -q -m "main update ${filename}"
  git -C "${TMP_DIR}/origin-work" push -q origin main
}

mkdir -p "${TMP_DIR}/repo/scripts"
cp "${ROOT}/scripts/create-pr.sh" "${TMP_DIR}/repo/scripts/create-pr.sh"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/repo/scripts/review-gate.sh"

cd "${TMP_DIR}/repo"
git init -q -b feature/review-gate
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"

printf '.copilot-tracking/\n' > .gitignore
printf 'initial\n' > README.md
git add .gitignore README.md scripts/create-pr.sh scripts/review-gate.sh
make_commit "initial"

if ./scripts/review-gate.sh check >/tmp/review-gate-check.out 2>&1; then
  fail "check passed without approval"
fi
grep -q "current HEAD has not been approved" /tmp/review-gate-check.out || fail "missing unapproved HEAD message"

./scripts/review-gate.sh approve >/tmp/review-gate-approve.out
./scripts/review-gate.sh check >/tmp/review-gate-check.out
grep -q "review approved for current HEAD" /tmp/review-gate-check.out || fail "approval check did not pass"

printf 'changed\n' > README.md
git add README.md
make_commit "change head"

if ./scripts/review-gate.sh check >/tmp/review-gate-stale.out 2>&1; then
  fail "check passed after HEAD changed"
fi
grep -q "current HEAD has not been approved" /tmp/review-gate-stale.out || fail "missing stale approval message"

if ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr.out 2>&1; then
  fail "create-pr passed without current HEAD approval"
fi
grep -q "current HEAD has not been approved" /tmp/create-pr.out || fail "create-pr did not stop at review gate"

write_fake_gh
export PATH="${TMP_DIR}/bin:${PATH}"
export GH_LOG="${TMP_DIR}/gh.log"
setup_origin_main

git reset -q --hard origin/main
printf 'feature\n' > feature.txt
git add feature.txt
make_commit "feature commit"
approved_head="$(git rev-parse HEAD)"
./scripts/review-gate.sh approve >/tmp/review-gate-approved-feature.out

if ! ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr-unchanged-sync.out 2>&1; then
  fail "create-pr refused approved HEAD when sync did not change it"
fi
current_head="$(git rev-parse HEAD)"
[ "$current_head" = "$approved_head" ] || fail "unchanged sync rewrote approved HEAD"
[ -s "$GH_LOG" ] || fail "create-pr did not open PR after unchanged sync"

git reset -q --hard "$approved_head"
git push -q origin :feature/review-gate >/dev/null 2>&1 || true
: > "$GH_LOG"
add_origin_main_commit "main.txt" "main advanced"

if ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr-stale-after-sync.out 2>&1; then
  fail "create-pr passed after rebase changed the approved HEAD"
fi
grep -q "current HEAD has not been approved" /tmp/create-pr-stale-after-sync.out || fail "create-pr did not require fresh approval after sync changed HEAD"
[ ! -s "$GH_LOG" ] || fail "create-pr opened PR after sync changed approved HEAD"

printf 'review gate smoke passed\n'