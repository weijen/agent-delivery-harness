#!/usr/bin/env bash
# test_rebind_carry.sh — regression sensor for issue #442 F2: the carry rule
# is deterministic. A green row already bound to the CURRENT HEAD at the
# requested gate mode carries (no re-run); anything else re-runs.
#
# Contract under test:
#   * second rebind at an unchanged HEAD → "carried", no gate re-run, and the
#     evidence file gains no new row;
#   * a row for the same HEAD but a different mode does NOT carry;
#   * a tampered row does NOT carry (verification fails → re-run).
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
# The sensor logs each execution so a carried rebind is provably run-free.
cat > "${FIX}/tests/scripts/test_green.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' >>"${SENSOR_RUN_LOG:?}"
exit 0
SH
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
head_sha="$(git -C "$FIX" rev-parse HEAD)"
EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"
export SENSOR_RUN_LOG="${TMP_DIR}/runs.log"
: >"$SENSOR_RUN_LOG"

rebind() { (cd "$FIX" && ./scripts/rebind-evidence.sh "$@" 2>&1); }

# Seed: first rebind runs the gate.
rebind --gate pre-review >/dev/null || fail "seed rebind must pass"
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "1" ] || fail "seed rebind must run the sensor once"
rows_before="$(wc -l < "$EVIDENCE" | tr -d ' ')"

# 1. Unchanged HEAD → carried: no sensor execution, no new row.
out="$(rebind --gate pre-review)" || fail "carry rebind must exit 0"
grep -q 'carried' <<<"$out" || fail "unchanged HEAD must carry (got: $out)"
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "1" ] \
  || fail "carried rebind must NOT re-run sensors"
[ "$(wc -l < "$EVIDENCE" | tr -d ' ')" = "$rows_before" ] \
  || fail "carried rebind must not append rows"

# 2. Same HEAD, different mode → no carry: pre-pr still owed, gate re-runs.
out="$(rebind --gate pre-pr)" || fail "pre-pr rebind must pass"
grep -q 're-running --gate pre-pr' <<<"$out" \
  || fail "a pre-review row must not satisfy the pre-pr gate (got: $out)"
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "2" ] || fail "pre-pr rebind must run the gate"

# 3. Tampered evidence → no carry: verification fails, gate re-runs. The
#    tampered row stays flagged (tamper-EVIDENT history is never silently
#    healed) while a fresh valid row for HEAD is appended.
first_row="$(head -n1 "$EVIDENCE")"
jq -c '.ran = 99' <<<"$first_row" > "$EVIDENCE"
out="$(rebind --gate pre-review)" || fail "rebind over tampered evidence must still succeed by re-running"
grep -q 're-running --gate pre-review' <<<"$out" \
  || fail "tampered evidence must trigger a re-run, not a carry (got: $out)"
jq -e --arg h "$head_sha" 'select(.head == $h and .mode == "pre-review" and .failed == 0)' \
  >/dev/null <<<"$(tail -n1 "$EVIDENCE")" \
  || fail "re-run must append a fresh green pre-review row at HEAD"
set +e
(cd "$FIX" && ./scripts/verify-sensor-evidence.sh 77 >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" = "1" ] \
  || fail "the tampered historical row must keep failing verification (tamper-evident, got ${rc})"

printf 'PASS: rebind carry rule is deterministic (same-HEAD green row carries, all else re-runs)\n'
