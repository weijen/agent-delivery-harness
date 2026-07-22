#!/usr/bin/env bash
# test_review_gate_docs_only_carry.sh — regression sensor for the docs-only
# approval carry (2026-07-22 review diet 2).
#
# Contract: after `review-gate.sh approve`, `check` PASSES with a carry notice
# when every commit since the approved SHA touches only documentation
# (docs/**, root *.md, LICENSE); it FAILS for any script/test change and for
# doctrine files (.copilot/**, AGENTS.md) even though they are markdown.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'cd /; rm -rf "${TMP_DIR}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

FIX="${TMP_DIR}/repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs" "${FIX}/.copilot/skills"
for f in review-gate.sh issue-lib.sh trace-lib.sh ci-coverage-lib.sh check-trace-consistency.sh check-feature-list.sh; do
  [ -f "${ROOT}/scripts/$f" ] && cp "${ROOT}/scripts/$f" "${FIX}/scripts/"
done
printf 'guide\n' > "${FIX}/docs/guide.md"
printf 'doctrine\n' > "${FIX}/.copilot/skills/doc.md"
printf 'agents\n' > "${FIX}/AGENTS.md"
git -C "$FIX" init -q -b feature/issue-77-fixture
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A && git -C "$FIX" commit -qm base
cd "$FIX"
mkdir -p .copilot-tracking/review-gate

./scripts/review-gate.sh approve >/dev/null 2>&1 || fail "approve failed"

# 1. docs-only delta carries
printf 'more\n' >> docs/guide.md && git add docs/guide.md && git commit -qm "docs: more"
out="$(./scripts/review-gate.sh check 2>&1)" || fail "docs-only delta must carry the approval (got: $out)"
grep -q "carried" <<<"$out" || fail "carry notice missing (got: $out)"

# 2. script delta must fail
printf '# x\n' >> scripts/issue-lib.sh && git add scripts/issue-lib.sh && git commit -qm "chore: touch"
if ./scripts/review-gate.sh check >/dev/null 2>&1; then
  fail "script delta must invalidate the approval"
fi
git reset -q --hard HEAD~1

# 3. doctrine markdown must fail
./scripts/review-gate.sh approve >/dev/null 2>&1
printf 'x\n' >> .copilot/skills/doc.md && git add .copilot/skills/doc.md && git commit -qm "docs: doctrine"
if ./scripts/review-gate.sh check >/dev/null 2>&1; then
  fail ".copilot/** markdown must invalidate the approval (doctrine is behavior)"
fi
git reset -q --hard HEAD~1

# 4. AGENTS.md must fail
./scripts/review-gate.sh approve >/dev/null 2>&1
printf 'x\n' >> AGENTS.md && git add AGENTS.md && git commit -qm "docs: agents"
if ./scripts/review-gate.sh check >/dev/null 2>&1; then
  fail "AGENTS.md must invalidate the approval (doctrine is behavior)"
fi

printf 'PASS: docs-only carry honors the review-diet-2 contract\n'
