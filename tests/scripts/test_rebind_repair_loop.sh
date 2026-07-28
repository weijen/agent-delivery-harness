#!/usr/bin/env bash
# test_rebind_repair_loop.sh — regression sensor for issue #442 F3: the
# foundry issue-48 repair sequence can no longer produce stale gate evidence.
#
# Reproduced sequence (the #383 "pre-verdict dependency cycle"):
#   1. pre-review gate runs green at SHA A (evidence bound to A);
#   2. a repair commit lands → HEAD becomes B; evidence for B is now owed;
#   3. the harness re-binds (the deterministic script action) instead of
#      leaving the staleness for the next review round to discover.
#
# Contract under test:
#   * after step 2, verify --head B fails (the old failure mode is real);
#   * after rebind, verify --head B --mode pre-review passes — the reviewer's
#     prescribed check (#441) finds current evidence and can emit no
#     stale-evidence finding;
#   * the evidence history keeps the row at A (append-only re-bind, no
#     rewriting of past evidence).
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this sensor"
[ -f "${ROOT}/scripts/rebind-evidence.sh" ] \
  || fail "scripts/rebind-evidence.sh not found — #442 not implemented yet"

FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/tests/scripts" "${FIX}/tests/meta"
for s in rebind-evidence.sh run-sensors.sh affected-sensors.sh verify-sensor-evidence.sh trace-lib.sh; do
  cp "${ROOT}/scripts/${s}" "${FIX}/scripts/"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "${FIX}/tests/scripts/test_green.sh"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"

# 1. Gate green at SHA A.
sha_a="$(git -C "$FIX" rev-parse HEAD)"
(cd "$FIX" && ./scripts/rebind-evidence.sh --gate pre-review >/dev/null) \
  || fail "gate at SHA A must pass"
(cd "$FIX" && ./scripts/verify-sensor-evidence.sh 77 --head "$sha_a" --mode pre-review >/dev/null) \
  || fail "evidence must be bound to SHA A"

# 2. Repair commit lands → HEAD B; the old failure mode: evidence is stale.
printf '# repaired\n' >> "${FIX}/tests/scripts/test_green.sh"
git -C "$FIX" commit -qam "repair finding"
sha_b="$(git -C "$FIX" rev-parse HEAD)"
[ "$sha_a" != "$sha_b" ] || fail "fixture must move HEAD"
set +e
(cd "$FIX" && ./scripts/verify-sensor-evidence.sh 77 --head "$sha_b" --mode pre-review >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" = "1" ] \
  || fail "pre-rebind, evidence for the repaired HEAD must be missing (the reproduced #383 gap)"

# 3. Re-bind → the reviewer's prescribed check now passes; no stale finding possible.
(cd "$FIX" && ./scripts/rebind-evidence.sh --gate pre-review >/dev/null) \
  || fail "rebind at the repaired HEAD must pass"
(cd "$FIX" && ./scripts/verify-sensor-evidence.sh 77 --head "$sha_b" --mode pre-review >/dev/null) \
  || fail "post-rebind, the reviewer's prescribed check must find current evidence at B"

# Append-only: the SHA-A row is still present (evidence history preserved).
grep -q "\"head\":\"${sha_a}\"" "$EVIDENCE" \
  || fail "re-bind must append, not rewrite, past evidence"

printf 'PASS: issue-48 repair sequence re-binds evidence instead of leaving a stale finding\n'
