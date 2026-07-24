#!/usr/bin/env bash
# Comprehensive finish-issue.sh closeout contract for issues
# #175, #290, #316, #320, #323, and #329.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts finish-lib.sh,trace-lib.sh,log-handback.sh,check-trace-consistency.sh,trace-report.sh,issue-lib.sh,start-issue.sh,finish-issue.sh,check-feature-list.sh
# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/native-economics-fixture.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"${BIN}/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  printf 'fixture issue\n'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"
  exit 0
fi
exit 1
GH
chmod +x "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE \
  REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH ABANDONED 2>/dev/null || true

COMPLETE_LIST='{"features":[{"id":"done","title":"Done","steps":[],"passes":true,"regression_sensor":"fixture","e2e_sensor":"fixture","blocked_on":null,"verification":"sensor","teeth_proof":{"kind":"red_first","evidence":"fixture"}}]}'

new_fixture() {
  local name="$1" issue="$2" main="" pad=""
  main="${TMP_DIR}/${name}"
  pad="$(printf '%02d' "$issue")"
  copy_fixture_scripts "$main"
  (
    cd "$main"
    PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture
  ) >"${TMP_DIR}/${name}-start.out" 2>&1 \
    || { cat "${TMP_DIR}/${name}-start.out"; fail "${name}: start-issue failed"; }

  printf '%s\n' "$COMPLETE_LIST" \
    >"${main}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
  cat >"${main}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/progress.md" <<PROGRESS
# Issue ${issue} progress

Status: implementation complete.

- Branch: \`feature/issue-${pad}-fixture\`

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
The **conductor authors** \`feature_list.json\` — but only *after* the
\`planning-subagent\` plan is approved and the human-input gate has resolved
every Open Question. The planning-subagent never writes this breakdown. Once it
is populated (each feature carrying its \`regression_sensor\`/\`e2e_sensor\`),
work one \`passes:false\` item at a time (see harness §3 and docs/HARNESS.md
step 4).
- Authored closeout note must survive.
PROGRESS

  mkdir -p "${main}/.copilot-tracking/issues/issue-${pad}"
  cat >"${main}/.copilot-tracking/issues/issue-${pad}/trace.jsonl" <<TRACE
{"schema_version":1,"timestamp":"2026-05-01T10:00:00Z","span":"agent","harness.issue":${issue},"harness.version":"test","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"done","harness.outcome":"pass"}
TRACE
  NEW_MAIN="$main"
  NEW_PAD="$pad"
}

run_finish() {
  local main="$1" issue="$2" output="$3"
  shift 3
  (
    cd "$main"
    PATH="${FINISH_PATH:-$BIN}" "$@" ./scripts/finish-issue.sh "$issue" SLUG=fixture
  ) >"$output" 2>&1
}

assert_contains() {
  grep -Fq -- "$2" "$1" || {
    cat "$1" >&2
    fail "expected $1 to contain: $2"
  }
}

assert_absent() {
  if grep -Fq -- "$2" "$1"; then
    cat "$1" >&2
    fail "expected $1 not to contain: $2"
  fi
}

# Happy path: authoritative merge evidence produces one durable conclusion,
# migrates and sanitizes progress, clears issue state, and tears down the
# worktree with a terminal lifecycle span.
new_fixture happy 41
MAIN="$NEW_MAIN"
PAD="$NEW_PAD"
mkdir -p "${MAIN}/.copilot-tracking/issues/issue-${PAD}/.hook-state"
printf 'orphan\n' >"${MAIN}/.copilot-tracking/issues/issue-${PAD}/.hook-state/session-a-tool-b"
printf '{"summary_schema_version":1,"finished":false}\n' \
  >"${MAIN}/.copilot-tracking/issues/issue-${PAD}/trace-summary.json"
STATE="${TMP_DIR}/native-state"
plant_events "$STATE" "$SID" bracket
FAKE_GH_PR_JSON='[{"headRefName":"feature/issue-41-fixture","state":"MERGED","mergedAt":"2026-05-01T12:30:00Z","number":441}]' \
  run_finish "$MAIN" 41 "${TMP_DIR}/happy.out" env FORCE=1 \
    COPILOT_AGENT_SESSION_ID="$SID" COPILOT_CLI_STATE_ROOT="$STATE" \
  || { cat "${TMP_DIR}/happy.out"; fail "happy: finish unexpectedly failed"; }
[ ! -e "${MAIN}/.worktrees/issue-${PAD}" ] || fail "happy: worktree must be removed"
PROGRESS="${MAIN}/.copilot-tracking/issues/issue-${PAD}/progress.md"
SUMMARY="${MAIN}/.copilot-tracking/issues/issue-${PAD}/trace-summary.json"
assert_contains "$PROGRESS" 'Conclusion: merged; review verdict: APPROVED.'
[ "$(grep -c '^Conclusion:' "$PROGRESS")" -eq 1 ] \
  || fail "happy: conclusion must be written exactly once"
assert_absent "$PROGRESS" 'Status:'
assert_absent "$PROGRESS" '- _Record conductor handbacks'
assert_absent "$PROGRESS" 'The **conductor authors**'
assert_contains "$PROGRESS" '- Authored closeout note must survive.'
assert_contains "$PROGRESS" '## Delivery economics (auto-stamped, trace-derived)'
assert_contains "$PROGRESS" '3500'
assert_contains "$PROGRESS" 'claude-sonnet-5'
assert_absent "${TMP_DIR}/happy.out" '## Delivery economics (auto-stamped, trace-derived)'
[ ! -e "${MAIN}/.copilot-tracking/issues/issue-${PAD}/.hook-state" ] \
  || fail "happy: issue-scoped hook state must be removed"
jq -e '.finished == true and .final_outcome == "pass"' "$SUMMARY" >/dev/null \
  || { cat "$SUMMARY"; fail "happy: final trace summary was not regenerated"; }
[ "$(jq -es 'length' "$SUMMARY")" -eq 1 ] \
  || fail "happy: summary must contain exactly one JSON document"
TRACE="${MAIN}/.copilot-tracking/issues/issue-${PAD}/trace.jsonl"
[ "$(jq -nRr '[inputs | fromjson? | objects |
  select(.span == "lifecycle" and .["harness.lifecycle_step"] == "finish")] |
  length' < "$TRACE")" -eq 1 ] \
  || fail "happy: exactly one terminal finish lifecycle span must survive"
if jq -e 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "finish") |
  [keys[] | select(startswith("harness.economics."))] | length > 0' "$TRACE" >/dev/null; then
  fail "happy: terminal finish span must not carry analytics attributes"
fi

# #316: absent authoritative merged-PR evidence must refuse before teardown or
# conclusion mutation.
new_fixture no-pr 42
MAIN="$NEW_MAIN"
if FAKE_GH_PR_JSON='[]' run_finish "$MAIN" 42 "${TMP_DIR}/no-pr.out" env; then
  fail "no-pr: finish must reject absent merged-PR evidence"
fi
[ -d "${MAIN}/.worktrees/issue-42" ] || fail "no-pr: worktree must remain"
PROGRESS="${MAIN}/.worktrees/issue-42/.copilot-tracking/issues/issue-42/progress.md"
assert_contains "$PROGRESS" 'Status: implementation complete.'
assert_absent "$PROGRESS" 'Conclusion:'

# #323: a different pre-existing conclusion is immutable.
new_fixture write-once 43
MAIN="$NEW_MAIN"
PROGRESS="${MAIN}/.worktrees/issue-43/.copilot-tracking/issues/issue-43/progress.md"
sed -i.bak 's/^Status:.*$/Conclusion: abandoned; review verdict: NEEDS_REVISION./' "$PROGRESS"
rm -f "${PROGRESS}.bak"
if FAKE_GH_PR_JSON='[{"headRefName":"feature/issue-43-fixture","state":"MERGED","mergedAt":"2026-05-01T12:30:00Z","number":443}]' \
  run_finish "$MAIN" 43 "${TMP_DIR}/write-once.out" env FORCE=1; then
  fail "write-once: a different conclusion must block"
fi
[ -d "${MAIN}/.worktrees/issue-43" ] || fail "write-once: worktree must remain"
assert_contains "$PROGRESS" 'Conclusion: abandoned; review verdict: NEEDS_REVISION.'

# Residual scaffold placeholders remain a hard closeout refusal.
new_fixture placeholder 44
MAIN="$NEW_MAIN"
PROGRESS="${MAIN}/.worktrees/issue-44/.copilot-tracking/issues/issue-44/progress.md"
printf 'TODO(fill this)\n' >>"$PROGRESS"
if run_finish "$MAIN" 44 "${TMP_DIR}/placeholder.out" env ABANDONED=1 FORCE=1; then
  fail "placeholder: residual placeholder must block"
fi
[ -d "${MAIN}/.worktrees/issue-44" ] || fail "placeholder: worktree must remain"
assert_absent "$PROGRESS" 'Conclusion:'

# #290: an unsafe durable migration destination blocks before teardown.
new_fixture migration-refusal 45
MAIN="$NEW_MAIN"
mkdir -p "${TMP_DIR}/outside"
rm -rf "${MAIN}/.copilot-tracking/issues/issue-45"
ln -s "${TMP_DIR}/outside" "${MAIN}/.copilot-tracking/issues/issue-45"
if run_finish "$MAIN" 45 "${TMP_DIR}/migration-refusal.out" env ABANDONED=1 FORCE=1; then
  fail "migration-refusal: unsafe destination must block"
fi
[ -d "${MAIN}/.worktrees/issue-45" ] || fail "migration-refusal: worktree must remain"

# A symlink at the progress leaf must block migration without touching its target.
new_fixture migration-leaf 49
MAIN="$NEW_MAIN"
OUTSIDE="${TMP_DIR}/progress-outside"
printf 'do not overwrite\n' >"$OUTSIDE"
ln -s "$OUTSIDE" "${MAIN}/.copilot-tracking/issues/issue-49/progress.md"
if run_finish "$MAIN" 49 "${TMP_DIR}/migration-leaf.out" env ABANDONED=1 FORCE=1; then
  fail "migration-leaf: symlink destination must block"
fi
[ -d "${MAIN}/.worktrees/issue-49" ] || fail "migration-leaf: worktree must remain"
[ "$(cat "$OUTSIDE")" = "do not overwrite" ] \
  || fail "migration-leaf: unrelated destination was overwritten"

# economics_stamp_into independently rejects symlinks even without migration.
ECON_LINK="${TMP_DIR}/economics-progress"
ln -s "$OUTSIDE" "$ECON_LINK"
(
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/finish-lib.sh"
  economics_stamp_into "$ECON_LINK" 'unsafe block'
) >"${TMP_DIR}/economics-symlink.out" 2>&1
[ "$(cat "$OUTSIDE")" = "do not overwrite" ] \
  || fail "economics-symlink: unrelated destination was overwritten"
assert_contains "${TMP_DIR}/economics-symlink.out" 'is a symlink'

# Reporter failure is advisory and cannot block destructive teardown.
new_fixture summary-refusal 46
MAIN="$NEW_MAIN"
cat >"${MAIN}/scripts/trace-report.sh" <<'BROKEN'
#!/usr/bin/env bash
exit 7
BROKEN
chmod +x "${MAIN}/scripts/trace-report.sh"
run_finish "$MAIN" 46 "${TMP_DIR}/summary-refusal.out" env ABANDONED=1 FORCE=1 \
  || { cat "${TMP_DIR}/summary-refusal.out"; fail "summary-refusal: reporter failure must not block"; }
[ ! -e "${MAIN}/.worktrees/issue-46" ] \
  || fail "summary-refusal: worktree must be removed despite reporter failure"
assert_absent "${TMP_DIR}/summary-refusal.out" 'trace-summary regeneration'

# A pre-planted summary symlink remains protected without blocking teardown.
new_fixture summary-symlink 48
MAIN="$NEW_MAIN"
OUTSIDE="${TMP_DIR}/summary-outside"
printf 'do not overwrite\n' >"$OUTSIDE"
ln -s "$OUTSIDE" "${MAIN}/.copilot-tracking/issues/issue-48/trace-summary.json"
run_finish "$MAIN" 48 "${TMP_DIR}/summary-symlink.out" env ABANDONED=1 FORCE=1 \
  || { cat "${TMP_DIR}/summary-symlink.out"; fail "summary-symlink: reporting refusal must not block"; }
[ ! -e "${MAIN}/.worktrees/issue-48" ] \
  || fail "summary-symlink: worktree must be removed"
[ "$(cat "$OUTSIDE")" = "do not overwrite" ] \
  || fail "summary-symlink: unrelated destination was overwritten"

# #91: surface git's own dirty-worktree error and retain the FORCE hint.
new_fixture worktree-error 47
MAIN="$NEW_MAIN"
printf 'uncommitted\n' >"${MAIN}/.worktrees/issue-47/dirty.txt"
if run_finish "$MAIN" 47 "${TMP_DIR}/worktree-error.out" env ABANDONED=1; then
  fail "worktree-error: dirty worktree removal must fail"
fi
[ -d "${MAIN}/.worktrees/issue-47" ] || fail "worktree-error: worktree must remain"
grep -qi 'contains modified or untracked files' "${TMP_DIR}/worktree-error.out" \
  || { cat "${TMP_DIR}/worktree-error.out"; fail "worktree-error: git reason missing"; }
assert_contains "${TMP_DIR}/worktree-error.out" 'FORCE=1'

printf 'finish-issue consolidated closeout contract honored\n'
