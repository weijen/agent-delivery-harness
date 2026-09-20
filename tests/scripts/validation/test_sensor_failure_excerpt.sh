#!/usr/bin/env bash
# Bounded sanitized failure context without replaying the sensor.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts run-sensors.sh,validation/affected-sensors.sh,lib/trace-lib.sh
REPO="$FIXTURE_REPO"
OUT="${FIXTURE_TMP_DIR}/out"
export EXECUTIONS="${FIXTURE_TMP_DIR}/executions"
fail() { cat "$OUT" >&2; printf 'failure-excerpt: %s\n' "$*" >&2; exit 1; }
run() {
  (cd "$REPO" && ./scripts/run-sensors.sh green \
    --declared tests/scripts/test_failure.sh --diff HEAD) >"$OUT" 2>&1
}
cat >"${REPO}/tests/scripts/test_failure.sh" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >>"${EXECUTIONS:?}"
printf 'FIRST-CAUSE expected 42 but got 41\n'
printf 'api_key=SYNTHETICSECRETVALUE\n'
for ((i=0; i<200; i++)); do printf '%s %01000d\n' "$i" 0; done
printf 'LAST-CAUSE assertion failed in fixture\n' >&2
printf 'password="SYNTHETIC QUOTED SECRET"\n' >&2
exit "${SENSOR_RESULT:-31}"
SH
git -C "$REPO" add tests
git -C "$REPO" commit -qm 'test: verbose failure payload'
git -C "$REPO" checkout -qb feature/issue-484-excerpt
: >"$EXECUTIONS"
rc=0
run || rc=$?
[ "$rc" = 1 ] || fail "sensor failure did not propagate"
grep -q '^  | FIRST-CAUSE expected 42 but got 41$' "$OUT" || fail "leading cause is absent"
grep -q '^  | LAST-CAUSE assertion failed in fixture$' "$OUT" || fail "trailing cause is absent"
excerpt="${FIXTURE_TMP_DIR}/excerpt"
grep '^  | ' "$OUT" >"$excerpt"
[ "$(wc -l <"$excerpt")" -le 21 ] || fail "failure excerpt exceeds 20 content lines plus omission marker"
[ "$(wc -c <"$excerpt")" -le 4500 ] || fail "long lines escaped excerpt byte bound"
! grep -q SYNTHETIC "$OUT" || fail "excerpt leaked a credential"
index="$(sed -n 's/^DIAGNOSTICS //p' "$OUT")"
log="$(sed -n '2p' "$index" | cut -f4)"
grep -Fq "log=${log}" "$OUT" || fail "complete log location missing"
[ "$(wc -l <"$log")" -eq 204 ] || fail "complete sanitized output was truncated"
! grep -q SYNTHETIC "$log" || fail "complete output leaked a credential"
[ "$(wc -l <"$EXECUTIONS")" -eq 1 ] || fail "failure diagnostic replayed the sensor"

SENSOR_RESULT=0 run || fail "successful sensor failed"
! grep -q '^  | ' "$OUT" || fail "successful run emitted a failure excerpt"
! grep -q FIRST-CAUSE "$OUT" || fail "successful output was dumped"
[ "$(wc -l <"$EXECUTIONS")" -eq 2 ] || fail "successful diagnostics changed execution count"

parent="${REPO}/.copilot-tracking/issues/issue-484"
mv "${parent}/sensor-runs" "${FIXTURE_TMP_DIR}/saved-runs"
printf 'storage unavailable\n' >"${parent}/sensor-runs"
rc=0
run || rc=$?
[ "$rc" = 1 ] || fail "missing storage concealed sensor failure"
grep -q 'log=unavailable' "$OUT" || fail "missing log was advertised as available"
! grep -q '^  | ' "$OUT" || fail "missing log produced a fabricated excerpt"
! grep -q SYNTHETIC "$OUT" || fail "storage failure exposed raw output"
[ "$(wc -l <"$EXECUTIONS")" -eq 3 ] || fail "storage failure caused a retry or skip"
printf 'PASS: bounded first/last failure causes, sanitized complete logs, no sensor replay\n'
