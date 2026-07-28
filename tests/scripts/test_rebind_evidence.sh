#!/usr/bin/env bash
# test_rebind_evidence.sh — regression sensor for issue #442 F1:
# rebind-evidence.sh re-runs the owed gate at the current HEAD and records a
# fresh evidence row, and review-gate.sh approve wires the re-bind gate.
#
# Contract under test:
#   * with no evidence at HEAD, `rebind-evidence.sh --gate pre-review` runs
#     the full gate and a green row bound to HEAD (mode pre-review) appears;
#   * red sensors → exit 1 and no green row is recorded;
#   * outside an issue context → exit 0 (no per-issue evidence owed);
#   * usage error (unknown gate/flag) → exit 2;
#   * review-gate.sh approve invokes rebind-evidence.sh fail-closed
#     (behavioral: red -> refused with no marker, green -> marker + fresh row,
#     missing script -> refused).
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

# 3. Outside an issue context there is no per-issue evidence contract: warn +
#    exit 0 (reviews only exist for issue branches; blocking here would break
#    approve paths in non-issue repositories).
git -C "$FIX" checkout -q main
out="$(rebind --gate pre-review)" \
  || fail "rebind outside an issue context must exit 0 (nothing owed)"
grep -q 'no per-issue evidence owed' <<<"$out" \
  || fail "no-issue-context rebind must say nothing is owed (got: $out)"
git -C "$FIX" checkout -q feature/issue-77-fixture-work

# 4. Usage errors → exit 2.
set +e
rebind --gate nonsense >/dev/null 2>&1; rc1=$?
rebind --frobnicate >/dev/null 2>&1; rc2=$?
set -e
[ "$rc1" = "2" ] || fail "unknown gate must exit 2 (got ${rc1})"
[ "$rc2" = "2" ] || fail "unknown flag must exit 2 (got ${rc2})"

# 5. Approve wiring is BEHAVIORAL and fail-closed: a fixture approve refuses
#    over red sensors (no marker written), succeeds over green sensors (marker
#    written + fresh pre-review row), and refuses when the rebind script is
#    missing (hard gate — no silent downgrade).
for s in review-gate.sh lifecycle-runtime-lib.sh issue-lib.sh github-identity-lib.sh; do
  [ -f "${ROOT}/scripts/${s}" ] && cp "${ROOT}/scripts/${s}" "${FIX}/scripts/"
done
approve() { (cd "$FIX" && ./scripts/review-gate.sh approve 2>&1); }
marker_of() { # newest approved-head marker content, if any
  cat "${FIX}"/.copilot-tracking/review-gate/*/approved-head 2>/dev/null | sed -n 1p
}

head_now="$(git -C "$FIX" rev-parse HEAD)"
out="$(approve)" || fail "approve over green sensors must succeed (got: $out)"
[ "$(marker_of)" = "$head_now" ] \
  || fail "approve must record the current HEAD in the marker (got: $(marker_of))"
jq -e --arg h "$head_now" 'select(.head == $h and .mode == "pre-review" and .failed == 0)' \
  >/dev/null <<<"$(tail -n1 "$EVIDENCE")" \
  || fail "approve must leave a green pre-review row bound to the approved HEAD"

printf '#!/usr/bin/env bash\nexit 1\n' > "${FIX}/tests/scripts/test_red.sh"
git -C "$FIX" add tests/scripts/test_red.sh; git -C "$FIX" commit -q -m "regress"
red_head="$(git -C "$FIX" rev-parse HEAD)"
set +e
out="$(approve)"
rc=$?
set -e
[ "$rc" = "1" ] || fail "approve over red sensors must refuse (got ${rc}: $out)"
[ "$(marker_of)" != "$red_head" ] \
  || fail "a refused approve must not record the red HEAD as approved"
git -C "$FIX" rm -q tests/scripts/test_red.sh; git -C "$FIX" commit -q -m "unregress"

mv "${FIX}/scripts/rebind-evidence.sh" "${FIX}/scripts/rebind-evidence.sh.away"
set +e
out="$(approve)"
rc=$?
set -e
mv "${FIX}/scripts/rebind-evidence.sh.away" "${FIX}/scripts/rebind-evidence.sh"
[ "$rc" = "1" ] \
  || fail "approve with rebind-evidence.sh missing must refuse — the gate is hard (got ${rc}: $out)"

printf 'PASS: rebind-evidence.sh re-binds gate evidence at the current HEAD\n'
