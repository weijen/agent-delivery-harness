#!/usr/bin/env bash
# test_rebind_evidence.sh — regression sensor for issue #442 F1:
# rebind-evidence.sh re-runs the owed gate at the current HEAD and records a
# fresh evidence row, and review-gate.sh approve wires the re-bind gate.
#
# Contract under test:
#   * with no evidence at HEAD, `rebind-evidence.sh --gate pre-review` runs
#     the full gate and a green row bound to HEAD (mode pre-review) appears;
#   * red sensors → exit 1 and no green row is recorded;
#   * outside an issue context → exit 1;
#   * usage error (unknown gate/flag) → exit 2;
#   * review-gate.sh approve invokes rebind-evidence.sh fail-closed (static
#     wiring check: the approve path calls the script and refuses on failure).
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
  || fail "scripts/rebind-evidence.sh not found — #442 F1 not implemented yet"

# --- Fixture repo on an issue branch ------------------------------------------
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
head_sha="$(git -C "$FIX" rev-parse HEAD)"
EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"

rebind() { (cd "$FIX" && ./scripts/rebind-evidence.sh "$@" 2>&1); }

# 1. No evidence yet → rebind runs the gate and records a green pre-review row.
out="$(rebind --gate pre-review)" || fail "rebind with green sensors must exit 0 (got: $out)"
grep -q 're-running --gate pre-review' <<<"$out" \
  || fail "first rebind must re-run the gate (got: $out)"
[ -f "$EVIDENCE" ] || fail "rebind must record an evidence row"
jq -e --arg h "$head_sha" 'select(.head == $h and .mode == "pre-review" and .failed == 0)' \
  >/dev/null <<<"$(tail -n1 "$EVIDENCE")" \
  || fail "recorded row must be a green pre-review row bound to HEAD"
(cd "$FIX" && ./scripts/verify-sensor-evidence.sh 77 --head "$head_sha" --mode pre-review >/dev/null) \
  || fail "verify --head --mode pre-review must pass after rebind"

# 2. Red sensors → exit 1, no green row for the new state.
printf '#!/usr/bin/env bash\nexit 1\n' > "${FIX}/tests/scripts/test_red.sh"
git -C "$FIX" add tests/scripts/test_red.sh; git -C "$FIX" commit -q -m "add red"
red_sha="$(git -C "$FIX" rev-parse HEAD)"
set +e
rebind --gate pre-review >/dev/null
rc=$?
set -e
[ "$rc" = "1" ] || fail "rebind over red sensors must exit 1 (got ${rc})"
if grep -q "\"head\":\"${red_sha}\"" "$EVIDENCE" 2>/dev/null; then
  fail "no evidence row may be recorded for a red run"
fi
git -C "$FIX" rm -q tests/scripts/test_red.sh; git -C "$FIX" commit -q -m "remove red"

# 3. Outside an issue context → exit 1.
git -C "$FIX" checkout -q main
set +e
rebind --gate pre-review >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "rebind outside an issue context must exit 1 (got ${rc})"
git -C "$FIX" checkout -q feature/issue-77-fixture-work

# 4. Usage errors → exit 2.
set +e
rebind --gate nonsense >/dev/null 2>&1; rc1=$?
rebind --frobnicate >/dev/null 2>&1; rc2=$?
set -e
[ "$rc1" = "2" ] || fail "unknown gate must exit 2 (got ${rc1})"
[ "$rc2" = "2" ] || fail "unknown flag must exit 2 (got ${rc2})"

# 5. Approve wiring: review-gate.sh calls rebind-evidence.sh fail-closed.
grep -q 'rebind-evidence.sh' "${ROOT}/scripts/review-gate.sh" \
  || fail "review-gate.sh approve must invoke rebind-evidence.sh (#442)"
grep -qE 'approve refused.*re-bound|re-bound.*approve refused' "${ROOT}/scripts/review-gate.sh" \
  || fail "review-gate.sh approve must refuse approval when re-bind fails (#442)"

printf 'PASS: rebind-evidence.sh re-binds gate evidence at the current HEAD\n'
