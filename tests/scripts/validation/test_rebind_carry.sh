#!/usr/bin/env bash
# test_rebind_carry.sh — regression sensor for issue #442 F2: the carry rule
# verifies an existing row without executing or changing anything.
#
# Contract under test:
#   * second rebind at an unchanged HEAD → "carried", no gate re-run, and the
#     evidence file gains no new row;
#   * a row for the same HEAD but a different mode does NOT carry;
#   * missing-mode or tampered evidence fails without a replacement run.
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
# The sensor logs each execution so a carried rebind is provably run-free.
cat > "${FIX}/tests/scripts/test_green.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' >>"${SENSOR_RUN_LOG:?}"
exit 0
SH
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" update-ref refs/remotes/origin/main HEAD
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"
export SENSOR_RUN_LOG="${TMP_DIR}/runs.log"
: >"$SENSOR_RUN_LOG"

rebind() { (cd "$FIX" && ./scripts/validation/rebind-evidence.sh "$@" 2>&1); }

# Seed through the explicit final gate, never through the compatibility helper.
(cd "$FIX" && ./scripts/run-sensors.sh --gate pre-pr >/dev/null) || fail "seed gate must pass"
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "1" ] || fail "seed rebind must run the sensor once"
rows_before="$(wc -l < "$EVIDENCE" | tr -d ' ')"

# 1. Unchanged HEAD → carried: no sensor execution, no new row.
out="$(rebind --gate pre-pr)" || fail "current evidence must verify"
grep -q 'carried' <<<"$out" || fail "unchanged HEAD must carry (got: $out)"
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "1" ] \
  || fail "carried rebind must NOT re-run sensors"
[ "$(wc -l < "$EVIDENCE" | tr -d ' ')" = "$rows_before" ] \
  || fail "carried rebind must not append rows"

# 2. Same HEAD, different mode does not match or provoke execution.
if rebind --gate pre-review >/dev/null 2>&1; then
  fail "a pre-pr row satisfied a different requested mode"
fi
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "1" ] || fail "missing mode executed sensors"
[ "$(wc -l < "$EVIDENCE" | tr -d ' ')" = "$rows_before" ] || fail "missing mode changed evidence"

# 3. Tampering stays a visible failure; verification cannot repair history.
first_row="$(head -n1 "$EVIDENCE")"
jq -c '.ran = 99' <<<"$first_row" > "$EVIDENCE"
if rebind --gate pre-pr >/dev/null 2>&1; then
  fail "tampered evidence reported success"
fi
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "1" ] || fail "tampering caused a replacement run"
[ "$(wc -l < "$EVIDENCE" | tr -d ' ')" = "1" ] || fail "tampering caused an appended row"
set +e
(cd "$FIX" && ./scripts/validation/verify-sensor-evidence.sh 77 >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" = "1" ] \
  || fail "the tampered historical row must keep failing verification (tamper-evident, got ${rc})"

# Historical pre-review rows remain readable, without authorizing pre-pr.
legacy="$(jq -c '.mode="pre-review" | .scope="full"' <<<"$first_row")"
canonical="$(jq -r '["v1", .head, .mode, .scope, (.ran|tostring), (.failed|tostring), .timestamp] | join("|")' <<<"$legacy")"
checksum="sha256:$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')"
jq -c --arg checksum "$checksum" '.checksum=$checksum' <<<"$legacy" >"$EVIDENCE"
rebind --gate pre-review >/dev/null || fail "valid historical evidence became unreadable"
if rebind --gate pre-pr >/dev/null 2>&1; then fail "historical review evidence authorized final validation"; fi
[ "$(grep -c ran "$SENSOR_RUN_LOG")" = "1" ] || fail "historical evidence verification executed sensors"
printf 'PASS: compatibility checks verify existing evidence without executing sensors\n'
