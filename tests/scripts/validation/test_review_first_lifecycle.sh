#!/usr/bin/env bash
# Miniature real CLI lifecycle: review/repair first, one final full gate, exact publication.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts create-pr.sh,validation/review-gate.sh,log-handback.sh
REPO="$FIXTURE_REPO"
OUT="${FIXTURE_TMP_DIR}/out"
ORIGIN="${FIXTURE_TMP_DIR}/origin.git"
export SENSOR_RUN_LOG="${FIXTURE_TMP_DIR}/runs"
export GH_CREATED="${FIXTURE_TMP_DIR}/created"
BIN="${FIXTURE_TMP_DIR}/bin"
TRACK="${REPO}/.copilot-tracking/issues/issue-486"
EVIDENCE="${TRACK}/sensor-evidence.jsonl"
BRANCH=feature/issue-486-review-first
fail() { cat "$OUT" >&2; printf 'review-first: %s\n' "$*" >&2; exit 1; }
run() { (cd "$REPO" && PATH="${BIN}:${PATH}" "$@") >"$OUT" 2>&1; }
full_count() { grep -c '^full$' "$SENSOR_RUN_LOG" || true; }
publish() { run ./scripts/create-pr.sh --title fixture --body fixture; }
reject_publish() {
  local before
  before="$(full_count)"
  if publish; then fail "$1 published"; fi
  [ "$(full_count)" = "$before" ] || fail "publication ran a full sensor"
  [ ! -e "$GH_CREATED" ] || fail "refusal created a PR"
}
verdict() {
  run env TRACE_REVIEW_MODE="$1" TRACE_REPAIR_SCOPE="${2:-}" \
    ./scripts/log-handback.sh conductor review_verdict F1 pass "Fixture independent review"
}

mkdir -p "$BIN"
cat >"${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view") [ -f "${GH_CREATED:?}" ] || exit 1; printf '486\n' ;;
  "pr create") : >"${GH_CREATED:?}" ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "${BIN}/gh"
cat >"${REPO}/tests/scripts/test_feature.sh" <<'SH'
#!/usr/bin/env bash
printf 'scoped\n' >>"${SENSOR_RUN_LOG:?}"
test -f product.txt
SH
cat >"${REPO}/tests/scripts/test_boundary.sh" <<'SH'
#!/usr/bin/env bash
# harness-sensor-stage: boundary
printf 'full\n' >>"${SENSOR_RUN_LOG:?}"
test "$(cat product.txt)" = good
SH
printf 'good\n' >"${REPO}/product.txt"
git -C "$REPO" add tests product.txt
git -C "$REPO" commit -qm 'test: miniature sensors'
git clone -q --bare "$REPO" "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" checkout -qb "$BRANCH"
mkdir -p "$TRACK"
printf '{"issue":486,"features":[{"id":"F1","passes":true}]}\n' >"${TRACK}/feature_list.json"
: >"$SENSOR_RUN_LOG"

# Retired entrypoints must fail without a hidden replacement full execution.
rc=0
run ./scripts/run-sensors.sh --gate pre-review || rc=$?
[ "$rc" = 2 ] || fail "retired pre-review gate must exit 2"
grep -q 'after review' "$OUT" || fail "retired gate lacks migration guidance"
[ "$(full_count)" = 0 ] || fail "retired gate executed a full suite"
run ./scripts/run-sensors.sh green --declared tests/scripts/test_feature.sh --diff HEAD \
  || fail "scoped feature verification failed"
run ./scripts/create-pr.sh --prepare || fail "preparation failed"
reject_publish unreviewed
verdict full || fail "review handback failed"
run ./scripts/validation/review-gate.sh approve || fail "approval failed"
[ "$(full_count)" = 0 ] || fail "review or approval executed full sensors"
reject_publish no-final-evidence
run ./scripts/run-sensors.sh --gate pre-pr || fail "final gate failed"
[ "$(full_count)" = 1 ] || fail "successful path must execute exactly one full gate"
head="$(git -C "$REPO" rev-parse HEAD)"
run ./scripts/validation/verify-sensor-evidence.sh 486 --head "$head" --mode pre-pr \
  || fail "final evidence is invalid"
publish || fail "verified candidate did not publish"
[ "$(full_count)" = 1 ] || fail "publication repeated the full gate"
[ "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/${BRANCH}")" = "$head" ] \
  || fail "published a different candidate"

# A later repair needs current review, then a new successful final result.
rm "$GH_CREATED"
printf 'broken\n' >"${REPO}/product.txt"
git -C "$REPO" add product.txt
git -C "$REPO" commit -qm 'test: review repair with integration defect'
reject_publish changed-candidate
if run ./scripts/validation/review-gate.sh approve; then fail "stale verdict approved"; fi
run ./scripts/run-sensors.sh green --declared tests/scripts/test_feature.sh --diff HEAD \
  || fail "repair scoped verification failed"
verdict repair F1 || fail "repair review handback failed"
run ./scripts/validation/review-gate.sh approve || fail "repair approval failed"
[ "$(full_count)" = 1 ] || fail "repair review or approval reran full sensors"
reject_publish stale-full-evidence
rows="$(wc -l <"$EVIDENCE")"
if run ./scripts/run-sensors.sh --gate pre-pr; then fail "red full gate passed"; fi
[ "$(wc -l <"$EVIDENCE")" = "$rows" ] || fail "red gate created success evidence"
reject_publish failed-final-gate
printf 'good\n' >"${REPO}/product.txt"
printf 'repair\n' >"${REPO}/repair.txt"
git -C "$REPO" add product.txt repair.txt
git -C "$REPO" commit -qm 'test: repair final-gate defect'
if run ./scripts/validation/review-gate.sh approve; then fail "repair skipped re-review"; fi
run ./scripts/run-sensors.sh green --declared tests/scripts/test_feature.sh --diff HEAD \
  || fail "final repair scoped verification failed"
verdict repair F1 || fail "final repair review failed"
run ./scripts/validation/review-gate.sh approve || fail "final repair approval failed"
[ "$(full_count)" = 2 ] || fail "repair review triggered another full run"
run ./scripts/run-sensors.sh --gate pre-pr || fail "repaired final gate failed"
publish || fail "repaired verified candidate did not publish"
[ "$(full_count)" = 3 ] || fail "only explicit final attempts may execute full sensors"
printf 'PASS: zero full runs through review, one on successful path, explicit retries after repairs\n'
