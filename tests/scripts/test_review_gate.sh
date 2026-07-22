#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# This sensor drives one long, sequentially-mutated git repo, so scenarios share
# state in a single shell. fail() records a diagnostic and marks the current
# scenario failed WITHOUT aborting; emit() turns that mark into exactly one TAP
# row and resets it. Unconditional setup steps between scenarios still run under
# `set -e`, so a failed assertion never fail-fasts yet the state chain is
# preserved. Exit semantics: all scenarios pass => tap_done exits 0.
_sfail=0
fail() {
  printf '# %s\n' "$*" >&2
  _sfail=1
}
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
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
  # Real gh returns the PR number once the PR exists; model that so the
  # create-pr.sh "unresolvable PR number" guard (issue #90) is satisfied.
  [ -n "${GH_LOG:-}" ] && [ -f "${GH_LOG}.created" ] || exit 1
  printf '123\n'
  exit 0
fi

if [ "$1 $2" = "pr create" ]; then
  printf '%s\n' "$*" >> "${GH_LOG:?}"
  : > "${GH_LOG}.created"
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
  mkdir -p "${TMP_DIR}/origin-work/docs"
  printf '# Progress\n\nbaseline\n' > "${TMP_DIR}/origin-work/docs/PROGRESS.md"
  git -C "${TMP_DIR}/origin-work" add .gitignore README.md docs/PROGRESS.md scripts/create-pr.sh scripts/review-gate.sh
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
mkdir -p docs
printf '# Progress\n\nbaseline\n' > docs/PROGRESS.md
git add .gitignore README.md docs/PROGRESS.md scripts/create-pr.sh scripts/review-gate.sh
# Baseline commit on a local `main` ref — the status-doc gate's diff base when no
# origin/main exists yet (Phase A). Feature commits below modify docs/PROGRESS.md.
base_tree="$(git write-tree)"
base_commit="$(printf 'baseline\n' | git commit-tree "$base_tree")"
git branch -f main "$base_commit"
git update-ref refs/heads/feature/review-gate "$base_commit"
git reset -q --hard "$base_commit"

printf '# Progress\n\ninitial feature work\n' > docs/PROGRESS.md
git add docs/PROGRESS.md
make_commit "initial"

if ./scripts/review-gate.sh check >/tmp/review-gate-check.out 2>&1; then
  fail "check passed without approval"
fi
grep -q "current HEAD has not been approved" /tmp/review-gate-check.out || fail "missing unapproved HEAD message"
emit "review-gate check fails on an unapproved HEAD"

./scripts/review-gate.sh approve >/tmp/review-gate-approve.out
./scripts/review-gate.sh check >/tmp/review-gate-check.out
grep -q "review approved for current HEAD" /tmp/review-gate-check.out || fail "approval check did not pass"
emit "review-gate check passes after approving the current HEAD"

# NB: root *.md would now legitimately carry the approval (docs-only carry,
# 2026-07-22) — move HEAD with a SCRIPT change so stale-head still triggers.
printf '# changed\n' >> scripts/probe.sh 2>/dev/null || printf '#!/usr/bin/env bash\n' > scripts/probe.sh
git add scripts/probe.sh
make_commit "change head"

if ./scripts/review-gate.sh check >/tmp/review-gate-stale.out 2>&1; then
  fail "check passed after HEAD changed"
fi
grep -q "current HEAD has not been approved" /tmp/review-gate-stale.out || fail "missing stale approval message"
emit "review-gate check fails after HEAD moves past the approval"

if ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr.out 2>&1; then
  fail "create-pr passed without current HEAD approval"
fi
grep -q "current HEAD has not been approved" /tmp/create-pr.out || fail "create-pr did not stop at review gate"
emit "create-pr refuses without current-HEAD approval"

write_fake_gh
export PATH="${TMP_DIR}/bin:${PATH}"
export GH_LOG="${TMP_DIR}/gh.log"
setup_origin_main

git reset -q --hard origin/main
printf 'feature\n' > feature.txt
printf '# Progress\n\nphase B feature\n' > docs/PROGRESS.md
git add feature.txt docs/PROGRESS.md
make_commit "feature commit"
approved_head="$(git rev-parse HEAD)"
./scripts/review-gate.sh approve >/tmp/review-gate-approved-feature.out

if ! ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr-unchanged-sync.out 2>&1; then
  fail "create-pr refused approved HEAD when sync did not change it"
fi
current_head="$(git rev-parse HEAD)"
[ "$current_head" = "$approved_head" ] || fail "unchanged sync rewrote approved HEAD"
[ -s "$GH_LOG" ] || fail "create-pr did not open PR after unchanged sync"
emit "create-pr opens a PR on an approved HEAD when sync does not change it"

git reset -q --hard "$approved_head"
git push -q origin :feature/review-gate >/dev/null 2>&1 || true
: > "$GH_LOG"
rm -f "${GH_LOG}.created"
add_origin_main_commit "main.txt" "main advanced"

# Issue #310: a content-preserving rebase carries the approval forward via
# patch-id identity — no fresh approve needed. The PR must open on the
# first try after the rebase.
if ! ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr-stale-after-sync.out 2>&1; then
  fail "create-pr must succeed after content-preserving rebase (carry approval — issue #310)"
fi
# Independently assert the PR opened via the GH_LOG (the fake gh pr create writes
# to it). Do not rely on carry-diagnostic text being present in output — that
# diagnostic is an implementation detail, not the observable contract.
[ -s "$GH_LOG" ] \
  || { cat /tmp/create-pr-stale-after-sync.out; fail "create-pr did not open PR after content-preserving rebase (carry approval — issue #310)"; }
emit "create-pr carries approval across a content-preserving rebase (issue #310)"

tap_done