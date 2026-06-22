#!/usr/bin/env bash
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
  git update-ref refs/heads/feature/review-gate "$commit"
  git reset -q --hard "$commit"
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

printf 'review gate smoke passed\n'