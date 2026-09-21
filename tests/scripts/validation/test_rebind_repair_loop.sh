#!/usr/bin/env bash
# Repaired candidates require a new explicit final result; history stays intact.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this sensor"
[ -f "${ROOT}/scripts/validation/rebind-evidence.sh" ] \
  || fail "scripts/validation/rebind-evidence.sh not found — #442 not implemented yet"

FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts/lib" "${FIX}/scripts/validation" "${FIX}/tests/scripts" "${FIX}/tests/scripts/validation" "${FIX}/tests/meta"
for s in validation/rebind-evidence.sh run-sensors.sh validation/run-sensors.sh validation/affected-sensors.sh validation/verify-sensor-evidence.sh lib/trace-lib.sh; do
  cp "${ROOT}/scripts/${s}" "${FIX}/scripts/${s}"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "${FIX}/tests/scripts/test_green.sh"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" update-ref refs/remotes/origin/main HEAD
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"

# 1. Gate green at SHA A.
sha_a="$(git -C "$FIX" rev-parse HEAD)"
(cd "$FIX" && ./scripts/run-sensors.sh --gate pre-pr >/dev/null) \
  || fail "gate at SHA A must pass"
(cd "$FIX" && ./scripts/validation/verify-sensor-evidence.sh 77 --head "$sha_a" --mode pre-pr >/dev/null) \
  || fail "evidence must be bound to SHA A"

# 2. Repair commit lands → HEAD B; the old failure mode: evidence is stale.
printf '# repaired\n' >> "${FIX}/tests/scripts/test_green.sh"
git -C "$FIX" commit -qam "repair finding"
sha_b="$(git -C "$FIX" rev-parse HEAD)"
[ "$sha_a" != "$sha_b" ] || fail "fixture must move HEAD"
set +e
(cd "$FIX" && ./scripts/validation/verify-sensor-evidence.sh 77 --head "$sha_b" --mode pre-pr >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" = "1" ] \
  || fail "pre-rebind, evidence for the repaired HEAD must be missing (the reproduced #383 gap)"

# 3. Compatibility verification refuses staleness without executing a gate.
before="$(cat "$EVIDENCE")"
if (cd "$FIX" && ./scripts/validation/rebind-evidence.sh --gate pre-pr >/dev/null 2>&1); then
  fail "stale evidence was silently refreshed"
fi
[ "$(cat "$EVIDENCE")" = "$before" ] || fail "stale check changed evidence history"
(cd "$FIX" && ./scripts/run-sensors.sh --gate pre-pr >/dev/null) \
  || fail "explicit final gate at repaired HEAD must pass"
(cd "$FIX" && ./scripts/validation/verify-sensor-evidence.sh 77 --head "$sha_b" --mode pre-pr >/dev/null) \
  || fail "explicit final gate must produce current evidence at B"

# Append-only: the SHA-A row is still present (evidence history preserved).
grep -q "\"head\":\"${sha_a}\"" "$EVIDENCE" \
  || fail "re-bind must append, not rewrite, past evidence"

printf 'PASS: repaired candidates need explicit final validation and preserve prior evidence\n'
