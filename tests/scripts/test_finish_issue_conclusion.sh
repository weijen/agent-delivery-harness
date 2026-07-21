#!/usr/bin/env bash
# Regression sensor for issue #320: finish-issue writes one durable, honest
# terminal conclusion before removing an issue worktree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-test-tmp/test-finish-issue-conclusion.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

link_tools() {
  local dir="$1" tool="" path=""
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    path="$(command -v "$tool" || true)"
    [ -n "$path" ] && ln -sf "$path" "${dir}/${tool}"
  done
}

BIN="${TMP_DIR}/bin"
mkdir -p "$TMP_DIR"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep \
  printf jq date od wc find mktemp mv cp awk sort comm chmod
cat > "${BIN}/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  printf 'fixture issue\n'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"
  exit "${FAKE_GH_PR_RC:-0}"
fi
exit 1
GH
chmod +x "${BIN}/gh"

make_fixture() {
  local name="$1" issue="$2" dir="${TMP_DIR}/$1" pad=""
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/"{issue-lib.sh,start-issue.sh,finish-issue.sh,finish-lib.sh,check-feature-list.sh,trace-lib.sh} \
    "${dir}/scripts/"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
  (
    cd "$dir"
    PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture
  ) > "${TMP_DIR}/${name}-start.out" 2>&1 || fail "${name}: fixture start failed"
  printf '{"features":[{"id":"done","title":"Done","steps":[],"passes":true,"regression_sensor":"fixture","e2e_sensor":null,"blocked_on":null,"verification":"sensor","teeth_proof":{"kind":"red_first","evidence":"fixture"}}]}\n' \
    > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
  printf '%s' "$dir"
}

write_progress() {
  local main="$1" issue="$2" status="$3" pad=""
  pad="$(printf '%02d' "$issue")"
  cat > "${main}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/progress.md" <<PROGRESS
# Issue ${issue} progress

Status: ${status}.

- Branch: \`feature/issue-${pad}-fixture\`

## Action Log
PROGRESS
}

write_verdict_trace() {
  local main="$1" issue="$2" outcomes="$3" pad="" i=0 outcome=""
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${main}/.copilot-tracking/issues/issue-${pad}"
  : > "${main}/.copilot-tracking/issues/issue-${pad}/trace.jsonl"
  for outcome in $outcomes; do
    i=$((i + 1))
    printf '{"schema_version":1,"timestamp":"2026-07-20T12:00:%02dZ","span":"agent","harness.issue":%s,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"done","harness.outcome":"%s"}\n' \
      "$i" "$issue" "$outcome" \
      >> "${main}/.copilot-tracking/issues/issue-${pad}/trace.jsonl"
  done
}

append_pr_merge_span() {
  local main="$1" issue="$2" outcome="$3" merge_state="${4:-}" merge_sha="${5:-}" pad="" extra=""
  pad="$(printf '%02d' "$issue")"
  [ -n "$merge_state" ] && extra="${extra},\"harness.merge_state\":\"${merge_state}\""
  [ -n "$merge_sha" ] && extra="${extra},\"harness.merge_sha\":\"${merge_sha}\""
  printf '{"schema_version":1,"timestamp":"2026-07-20T12:05:00Z","span":"lifecycle","harness.issue":%s,"harness.version":"0.0.0-dev","harness.lifecycle_step":"pr_merge","harness.outcome":"%s","harness.exit_status":0,"harness.duration_ms":10%s}\n' \
    "$issue" "$outcome" "$extra" \
    >> "${main}/.copilot-tracking/issues/issue-${pad}/trace.jsonl"
}

run_finish() {
  local main="$1" issue="$2" out="$3"
  shift 3
  (
    cd "$main"
    PATH="${FINISH_PATH:-$BIN}" FORCE=1 "$@" ./scripts/finish-issue.sh "$issue" SLUG=fixture
  ) > "$out" 2>&1
}

assert_contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || {
    cat "$file" >&2
    fail "expected ${file} to contain: ${text}"
  }
}

# Merged closeout requires authoritative merged-PR evidence for the exact branch,
# uses the latest logical review verdict, and survives worktree teardown.
MAIN="$(make_fixture merged 41)"
write_progress "$MAIN" 41 "implementation complete"
write_verdict_trace "$MAIN" 41 "fail pass"
FAKE_GH_PR_JSON='[{"headRefName":"feature/issue-41-fixture","state":"MERGED","mergedAt":"2026-07-20T12:30:00Z","number":441}]' \
  run_finish "$MAIN" 41 "${TMP_DIR}/merged.out" env \
  || { cat "${TMP_DIR}/merged.out"; fail "merged: finish unexpectedly failed"; }
[ ! -e "${MAIN}-worktrees/issue-41" ] || fail "merged: worktree must be removed"
assert_contains "${MAIN}/.copilot-tracking/issues/issue-41/progress.md" \
  'Conclusion: merged; review verdict: APPROVED.'
grep -q '^Status:' "${MAIN}/.copilot-tracking/issues/issue-41/progress.md" \
  && fail "merged: top in-flight Status must be replaced"

# Stale local-main state and a non-merged/no-match PR response are insufficient.
MAIN="$(make_fixture refused 42)"
write_progress "$MAIN" 42 "implementation complete"
write_verdict_trace "$MAIN" 42 "pass"
if FAKE_GH_PR_JSON='[]' run_finish "$MAIN" 42 "${TMP_DIR}/refused.out" env; then
  fail "refused: finish must reject absent authoritative merged-PR evidence"
fi
[ -d "${MAIN}-worktrees/issue-42" ] || fail "refused: worktree must remain intact"
assert_contains "${MAIN}-worktrees/issue-42/.copilot-tracking/issues/issue-42/progress.md" \
  'Status: implementation complete.'

# Explicit abandonment is the only non-merged closeout and missing review
# evidence remains honest rather than being fabricated.
MAIN="$(make_fixture abandoned 43)"
write_progress "$MAIN" 43 "implementation stopped"
write_verdict_trace "$MAIN" 43 ""
FAKE_GH_PR_JSON='[]' run_finish "$MAIN" 43 "${TMP_DIR}/abandoned.out" env ABANDONED=1
[ ! -e "${MAIN}-worktrees/issue-43" ] || fail "abandoned: worktree must be removed"
assert_contains "${MAIN}/.copilot-tracking/issues/issue-43/progress.md" \
  'Conclusion: abandoned; review verdict: n-a.'

MAIN="$(make_fixture needs-revision 50)"
write_progress "$MAIN" 50 "implementation stopped"
write_verdict_trace "$MAIN" 50 "fail"
FAKE_GH_PR_JSON='[]' run_finish "$MAIN" 50 "${TMP_DIR}/needs-revision.out" env ABANDONED=1
assert_contains "${MAIN}/.copilot-tracking/issues/issue-50/progress.md" \
  'Conclusion: abandoned; review verdict: NEEDS_REVISION.'

# An identical conclusion is idempotent; a different one is write-once and
# blocks before teardown.
MAIN="$(make_fixture idempotent 44)"
write_progress "$MAIN" 44 "implementation complete"
write_verdict_trace "$MAIN" 44 "pass"
sed -i.bak 's/^Status:.*$/Conclusion: merged; review verdict: APPROVED./' \
  "${MAIN}-worktrees/issue-44/.copilot-tracking/issues/issue-44/progress.md"
rm -f "${MAIN}-worktrees/issue-44/.copilot-tracking/issues/issue-44/progress.md.bak"
FAKE_GH_PR_JSON='[{"headRefName":"feature/issue-44-fixture","state":"MERGED","mergedAt":"2026-07-20T12:30:00Z","number":444}]' \
  run_finish "$MAIN" 44 "${TMP_DIR}/idempotent.out" env
assert_contains "${MAIN}/.copilot-tracking/issues/issue-44/progress.md" \
  'Conclusion: merged; review verdict: APPROVED.'

MAIN="$(make_fixture conflict 45)"
write_progress "$MAIN" 45 "implementation complete"
write_verdict_trace "$MAIN" 45 "pass"
sed -i.bak 's/^Status:.*$/Conclusion: abandoned; review verdict: NEEDS_REVISION./' \
  "${MAIN}-worktrees/issue-45/.copilot-tracking/issues/issue-45/progress.md"
rm -f "${MAIN}-worktrees/issue-45/.copilot-tracking/issues/issue-45/progress.md.bak"
if FAKE_GH_PR_JSON='[{"headRefName":"feature/issue-45-fixture","state":"MERGED","mergedAt":"2026-07-20T12:30:00Z","number":445}]' \
  run_finish "$MAIN" 45 "${TMP_DIR}/conflict.out" env; then
  fail "conflict: existing different conclusion must not be overwritten"
fi
[ -d "${MAIN}-worktrees/issue-45" ] || fail "conflict: worktree must remain intact"
assert_contains "${MAIN}-worktrees/issue-45/.copilot-tracking/issues/issue-45/progress.md" \
  'Conclusion: abandoned; review verdict: NEEDS_REVISION.'

# Missing progress and unsafe migration destinations are hard pre-teardown
# failures, rather than advisory data-loss warnings.
MAIN="$(make_fixture missing 46)"
rm -f "${MAIN}-worktrees/issue-46/.copilot-tracking/issues/issue-46/progress.md"
if FAKE_GH_PR_JSON='[]' run_finish "$MAIN" 46 "${TMP_DIR}/missing.out" env ABANDONED=1; then
  fail "missing: absent progress must block"
fi
[ -d "${MAIN}-worktrees/issue-46" ] || fail "missing: worktree must remain intact"

MAIN="$(make_fixture unsafe 47)"
write_progress "$MAIN" 47 "implementation stopped"
mkdir -p "${MAIN}/.copilot-tracking/issues"
rm -rf "${MAIN}/.copilot-tracking/issues/issue-47"
ln -s "${TMP_DIR}/outside" "${MAIN}/.copilot-tracking/issues/issue-47"
mkdir -p "${TMP_DIR}/outside"
if FAKE_GH_PR_JSON='[]' run_finish "$MAIN" 47 "${TMP_DIR}/unsafe.out" env ABANDONED=1; then
  fail "unsafe: unsafe migration destination must block"
fi
[ -d "${MAIN}-worktrees/issue-47" ] || fail "unsafe: worktree must remain intact"

MAIN="$(make_fixture unwritable 49)"
write_progress "$MAIN" 49 "implementation stopped"
MVFAIL_BIN="${TMP_DIR}/bin-mvfail"
cp -R "$BIN" "$MVFAIL_BIN"
rm -f "${MVFAIL_BIN}/mv"
cat > "${MVFAIL_BIN}/mv" <<'MV'
#!/usr/bin/env bash
exit 7
MV
chmod +x "${MVFAIL_BIN}/mv"
if FINISH_PATH="$MVFAIL_BIN" FAKE_GH_PR_JSON='[]' \
  run_finish "$MAIN" 49 "${TMP_DIR}/unwritable.out" env ABANDONED=1; then
  fail "unwritable: atomic finalization failure must block"
fi
[ -d "${MAIN}-worktrees/issue-49" ] || fail "unwritable: worktree must remain intact"
assert_contains "${MAIN}-worktrees/issue-49/.copilot-tracking/issues/issue-49/progress.md" \
  'Status: implementation stopped.'

# A present-but-authoritative-confirmed pr_merge span carrying full merge
# evidence (harness.merge_state=MERGED, non-empty harness.merge_sha) does not
# block the existing authoritative GitHub merged-PR check.
MAIN="$(make_fixture merged-evidence 51)"
write_progress "$MAIN" 51 "implementation complete"
write_verdict_trace "$MAIN" 51 "pass"
append_pr_merge_span "$MAIN" 51 pass MERGED deadbeef0001
FAKE_GH_PR_JSON='[{"headRefName":"feature/issue-51-fixture","state":"MERGED","mergedAt":"2026-07-20T12:30:00Z","number":451}]' \
  run_finish "$MAIN" 51 "${TMP_DIR}/merged-evidence.out" env \
  || { cat "${TMP_DIR}/merged-evidence.out"; fail "merged-evidence: finish unexpectedly failed"; }
[ ! -e "${MAIN}-worktrees/issue-51" ] || fail "merged-evidence: worktree must be removed"
assert_contains "${MAIN}/.copilot-tracking/issues/issue-51/progress.md" \
  'Conclusion: merged; review verdict: APPROVED.'

# A present successful pr_merge span with no merge evidence (the issue-318
# shape) must block the merged conclusion even though GitHub's own record
# independently reports MERGED.
MAIN="$(make_fixture merged-missing-evidence 52)"
write_progress "$MAIN" 52 "implementation complete"
write_verdict_trace "$MAIN" 52 "pass"
append_pr_merge_span "$MAIN" 52 pass
if FAKE_GH_PR_JSON='[{"headRefName":"feature/issue-52-fixture","state":"MERGED","mergedAt":"2026-07-20T12:30:00Z","number":452}]' \
  run_finish "$MAIN" 52 "${TMP_DIR}/merged-missing-evidence.out" env; then
  fail "merged-missing-evidence: finish must reject a present successful pr_merge span with no merge evidence"
fi
[ -d "${MAIN}-worktrees/issue-52" ] || fail "merged-missing-evidence: worktree must remain intact"
assert_contains "${MAIN}-worktrees/issue-52/.copilot-tracking/issues/issue-52/progress.md" \
  'Status: implementation complete.'

# A finished trace cannot coexist with a surviving in-flight Status.
CONSISTENCY="${TMP_DIR}/consistency"
mkdir -p "$CONSISTENCY"
cat > "${CONSISTENCY}/trace.jsonl" <<'TRACE'
{"schema_version":1,"timestamp":"2026-07-20T12:00:00Z","span":"agent","harness.issue":48,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"feature_start","harness.feature_id":"x","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-20T12:01:00Z","span":"lifecycle","harness.issue":48,"harness.version":"0.0.0-dev","harness.lifecycle_step":"worktree_create","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-20T12:02:00Z","span":"lifecycle","harness.issue":48,"harness.version":"0.0.0-dev","harness.lifecycle_step":"finish","harness.outcome":"pass"}
TRACE
printf '# Issue 48 progress\n\nStatus: implementation complete.\n\n## Action Log\n\n- [conductor] feature_start x pass — selected\n' \
  > "${CONSISTENCY}/progress.md"
if "${ROOT}/scripts/check-trace-consistency.sh" "${CONSISTENCY}/trace.jsonl" \
  > "${TMP_DIR}/consistency.out" 2>&1; then
  fail "consistency: finished trace with in-flight Status must violate"
fi
assert_contains "${TMP_DIR}/consistency.out" \
  'VIOLATION consistency: finished_with_inflight_status'

printf 'finish-issue write-once conclusion contract honored\n'
