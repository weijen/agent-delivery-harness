#!/usr/bin/env bash
# Approval and compatibility evidence verification never execute sensors.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts validation/review-gate.sh,validation/rebind-evidence.sh,lib/trace-lib.sh
FIX="$FIXTURE_REPO"
OUT="${FIXTURE_TMP_DIR}/out"
export SENSOR_RUN_LOG="${FIXTURE_TMP_DIR}/runs"
fail() { cat "$OUT" >&2; printf 'approval-evidence: %s\n' "$*" >&2; exit 1; }
cat >"${FIX}/tests/scripts/test_counted.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' >>"${SENSOR_RUN_LOG:?}"
exit "${SENSOR_EXIT:-0}"
SH
git -C "$FIX" add tests
git -C "$FIX" commit -qm 'test: count sensor execution'
git -C "$FIX" checkout -qb feature/issue-77-fixture
head_sha="$(git -C "$FIX" rev-parse HEAD)"
EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"
MARKER="${FIX}/.copilot-tracking/review-gate/issue-77/approved-head"

approve() { (cd "$FIX" && ./scripts/validation/review-gate.sh approve) >"$OUT" 2>&1; }
rebind() { (cd "$FIX" && ./scripts/validation/rebind-evidence.sh "$@") >"$OUT" 2>&1; }
no_execution() { [ ! -s "$SENSOR_RUN_LOG" ] || fail "review/evidence verification executed a sensor"; }

# Approval reflects review. An as-yet-unexecuted full-suite failure is found by
# the explicit final gate, never by a hidden approval-time execution.
rc=0
SENSOR_EXIT=1 approve || rc=$?
no_execution
[ "$rc" = 0 ] || fail "review approval requires an unowed full-suite result"
[ "$(head -1 "$MARKER")" = "$head_sha" ] || fail "approval did not bind current HEAD"
[ ! -f "$EVIDENCE" ] || fail "approval fabricated computational evidence"

# A retained compatibility command verifies only: it cannot fill a missing row.
if rebind; then fail "missing final evidence reported current"; fi
no_execution
grep -qi 'pre-pr' "$OUT" || fail "missing evidence diagnostic lacks the owed gate"
[ ! -f "$EVIDENCE" ] || fail "verification created evidence"

# The explicit final gate still fails normally and produces no successful row.
git -C "$FIX" update-ref refs/remotes/origin/main HEAD
if (cd "$FIX" && SENSOR_EXIT=1 ./scripts/run-sensors.sh --gate pre-pr) >"$OUT" 2>&1; then
  fail "a red final gate reported success"
fi
[ ! -f "$EVIDENCE" ] || fail "red final gate recorded successful evidence"
(cd "$FIX" && ./scripts/run-sensors.sh --gate pre-pr) >"$OUT" 2>&1 \
  || fail "explicit green final gate failed"
cp "$EVIDENCE" "${FIXTURE_TMP_DIR}/saved-evidence"
: >"$SENSOR_RUN_LOG"
rebind || fail "current final evidence failed verification"
no_execution
cmp -s "$EVIDENCE" "${FIXTURE_TMP_DIR}/saved-evidence" || fail "verification changed evidence"

# Review no longer depends on the obsolete automatic-rebinding path.
mv "${FIX}/scripts/validation/rebind-evidence.sh" "${FIXTURE_TMP_DIR}/rebind.saved"
approve || fail "approval still depends on an evidence-rebinding executable"
no_execution
mv "${FIXTURE_TMP_DIR}/rebind.saved" "${FIX}/scripts/validation/rebind-evidence.sh"

printf '# changed\n' >>"${FIX}/tests/scripts/test_counted.sh"
git -C "$FIX" commit -qam 'test: repaired candidate'
approve || fail "approval of a repaired candidate required a full run"
if rebind; then fail "stale evidence satisfied the repaired candidate"; fi
no_execution
cmp -s "$EVIDENCE" "${FIXTURE_TMP_DIR}/saved-evidence" || fail "stale evidence was rewritten"

git -C "$FIX" checkout -q main
rebind || fail "non-issue compatibility verification should report nothing owed"
grep -q 'no per-issue evidence owed' "$OUT" || fail "missing non-issue diagnostic"
no_execution
for arg in '--gate nonsense' --frobnicate; do
  rc=0
  if [ "$arg" = '--gate nonsense' ]; then rebind --gate nonsense || rc=$?
  else rebind --frobnicate || rc=$?; fi
  [ "$rc" = 2 ] || fail "invalid helper usage did not exit 2"
done
printf 'Approval and compatibility evidence verification execute zero sensors\n'
