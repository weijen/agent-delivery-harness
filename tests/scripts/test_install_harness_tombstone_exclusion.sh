#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-install-harness-tombstones.sh"
TMP_DIR="$(mktemp -d)"
REPO="${TMP_DIR}/repo"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

git init -q "$REPO"
git -C "$REPO" config user.name "Harness Test"
git -C "$REPO" config user.email "harness-test@example.invalid"
mkdir -p \
  "${REPO}/scripts" \
  "${REPO}/docs" \
  "${REPO}/.github/workflows"
printf '#!/usr/bin/env bash\n' >"${REPO}/scripts/install-harness.sh"
printf '# Tombstones\n' >"${REPO}/scripts/install-harness.tombstones"
printf 'managed docs\n' >"${REPO}/docs/HARNESS.md"
printf 'adopter docs\n' >"${REPO}/docs/adopter-notes.md"
printf 'managed workflow\n' >"${REPO}/.github/workflows/harness-smoke.yml"
printf 'adopter workflow\n' >"${REPO}/.github/workflows/deploy.yml"
git -C "$REPO" add .
git -C "$REPO" commit -qm "add installer"

rm "${REPO}/docs/adopter-notes.md" "${REPO}/.github/workflows/deploy.yml"
git -C "$REPO" add -u
git -C "$REPO" commit -qm "remove adopter-owned files"
"$CHECKER" "$REPO" >/dev/null \
  || fail "checker treated adopter-owned docs or workflows as managed"

docs_digest="$(shasum -a 256 "${REPO}/docs/HARNESS.md" | awk '{print $1}')"
workflow_digest="$(shasum -a 256 "${REPO}/.github/workflows/harness-smoke.yml" | awk '{print $1}')"
rm "${REPO}/docs/HARNESS.md" "${REPO}/.github/workflows/harness-smoke.yml"
git -C "$REPO" add -u
git -C "$REPO" commit -qm "remove harness-managed files"

if "$CHECKER" "$REPO" >"${TMP_DIR}/missing.out" 2>&1; then
  fail "checker accepted missing tombstones for managed docs and workflows"
fi
grep -Fq 'docs/HARNESS.md' "${TMP_DIR}/missing.out" \
  || fail "managed docs deletion was not reported"
grep -Fq '.github/workflows/harness-smoke.yml' "${TMP_DIR}/missing.out" \
  || fail "managed workflow deletion was not reported"

{
  printf '%s\t%s\n' "$docs_digest" 'docs/HARNESS.md'
  printf '%s\t%s\n' "$workflow_digest" '.github/workflows/harness-smoke.yml'
} >>"${REPO}/scripts/install-harness.tombstones"
"$CHECKER" "$REPO" >/dev/null \
  || fail "checker rejected complete managed-path tombstones"

printf 'install-harness tombstone exclusion policy honored\n'
