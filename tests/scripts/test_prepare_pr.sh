#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"

fail() { cat "$OUT" >&2; printf 'prepare-pr: %s\n' "$*" >&2; exit 1; }
for mode in rebase merge conflict dirty; do
  fixture_repo --with-scripts create-pr.sh,validation/review-gate.sh,lib/trace-lib.sh
  REPO="$FIXTURE_REPO"
  OUT="${FIXTURE_TMP_DIR}/out"
  ORIGIN="${FIXTURE_TMP_DIR}/origin.git"
  PEER="${FIXTURE_TMP_DIR}/peer"
  export PREPARE_SENSOR_LOG="${FIXTURE_TMP_DIR}/sensor.log"
  export PREPARE_GH_LOG="${FIXTURE_TMP_DIR}/gh.log"
  : >"$PREPARE_SENSOR_LOG"
  : >"$PREPARE_GH_LOG"
  mkdir -p "${FIXTURE_TMP_DIR}/bin"
  cat >"${FIXTURE_TMP_DIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PREPARE_GH_LOG:?}"
exit 91
SH
  chmod +x "${FIXTURE_TMP_DIR}/bin/gh"
  cat >"${REPO}/tests/scripts/test_upstream.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
test -f upstream.txt
printf 'ran\n' >>"${PREPARE_SENSOR_LOG:?}"
SH
  git -C "$REPO" add tests
  git -C "$REPO" commit -qm 'test: upstream validation fixture'
  git clone -q --bare "$REPO" "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git clone -q "$ORIGIN" "$PEER"
  git -C "$PEER" config user.name 'Harness Test'
  git -C "$PEER" config user.email 'harness-test@example.invalid'
  git -C "$PEER" config commit.gpgsign false
  printf 'upstream\n' >"${PEER}/upstream.txt"
  printf 'upstream\n' >"${PEER}/README.md"
  git -C "$PEER" add upstream.txt README.md
  git -C "$PEER" commit -qm 'test: main advanced'
  git -C "$PEER" push -q origin main
  upstream="$(git -C "$PEER" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/issue-482-prepare
  printf 'feature\n' >"${REPO}/feature.txt"
  if [ "$mode" = conflict ]; then
    printf 'conflict\n' >"${REPO}/README.md"
  fi
  git -C "$REPO" add .
  git -C "$REPO" commit -qm 'test: feature candidate'
  before="$(git -C "$REPO" rev-parse HEAD)"
  if [ "$mode" = dirty ]; then
    printf 'uncommitted\n' >>"${REPO}/README.md"
  fi
  rc=0
  (
    cd "$REPO"
    no_rewrite=0
    if [ "$mode" = merge ]; then no_rewrite=1; fi
    env PATH="${FIXTURE_TMP_DIR}/bin:${PATH}" CREATE_PR_NO_REWRITE="$no_rewrite" \
      ./scripts/create-pr.sh --prepare
  ) >"$OUT" 2>&1 || rc=$?
  [ ! -s "$PREPARE_SENSOR_LOG" ] || fail "${mode}: preparation ran sensors"
  [ ! -s "$PREPARE_GH_LOG" ] || fail "${mode}: preparation contacted PR APIs"
  if git --git-dir="$ORIGIN" show-ref --verify --quiet refs/heads/feature/issue-482-prepare; then
    fail "${mode}: preparation pushed"
  fi
  if [ "$mode" = conflict ] || [ "$mode" = dirty ]; then
    [ "$rc" -ne 0 ] || fail "${mode}: unsafe preparation succeeded"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$before" ] || fail "${mode}: failure moved HEAD"
    [ ! -d "${REPO}/.git/rebase-merge" ] || fail "${mode}: rebase was not aborted"
    if [ "$mode" = conflict ]; then
      [ -z "$(git -C "$REPO" status --porcelain)" ] || fail "conflict recovery left dirty files"
    else
      grep -q uncommitted "${REPO}/README.md" || fail "dirty input was lost"
    fi
    continue
  fi
  [ "$rc" -eq 0 ] || fail "${mode}: preparation must work before approval"
  git -C "$REPO" merge-base --is-ancestor "$upstream" HEAD || fail "${mode}: main not integrated"
  if [ "$mode" = merge ]; then
    [ "$(git -C "$REPO" rev-parse HEAD^1)" = "$before" ] || fail "non-rewrite mode rewrote history"
  fi
  prepared="$(git -C "$REPO" rev-parse HEAD)"
  (
    cd "$REPO"
    PATH="${FIXTURE_TMP_DIR}/bin:${PATH}" ./scripts/create-pr.sh --prepare
  ) >"$OUT" 2>&1 || fail "${mode}: repeated preparation failed"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$prepared" ] || fail "${mode}: no-op preparation rewrote HEAD"
  [ ! -s "$PREPARE_SENSOR_LOG" ] || fail "${mode}: repeated preparation ran sensors"
  (
    cd "$REPO"
    ./scripts/run-sensors.sh --gate pre-pr
  ) >"$OUT" 2>&1 || fail "${mode}: explicit validation did not see synchronized main"
  [ "$(wc -l <"$PREPARE_SENSOR_LOG" | tr -d ' ')" = 1 ] || fail "explicit gate did not run exactly once"
  if [ -f "${REPO}/.copilot-tracking/issues/issue-482/trace.jsonl" ]; then
    jq -es 'all(.[]; .["harness.lifecycle_step"] != "pr_create")' \
      "${REPO}/.copilot-tracking/issues/issue-482/trace.jsonl" >/dev/null \
      || fail "preparation consumed a PR round"
  fi
done
printf 'explicit preparation precedes validation without tests or publication\n'
