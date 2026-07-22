#!/usr/bin/env bash
# test_finish_issue_state_hygiene.sh — regression sensor for finish-issue
# best-effort local state hygiene during teardown (issue #175, feature
# teardown-state-hygiene-gc).
#
# Contract under test:
#
#   finish-issue.sh, at closeout, runs a BEST-EFFORT state hygiene sweep that
#   removes issue-scoped orphaned Claude duration-correlation hook state from
#   the MAIN checkout. The sweep is warn-only: teardown still exits 0 and
#   removes the worktree.
#
# RED until finish-issue.sh wires that hygiene step: the finish exits 0, but the
# issue .hook-state directory remains.
#
# Exit codes: 0 closeout state hygiene contract honored · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-test-tmp/test-finish-issue-state-hygiene.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Presence gate ------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || fail "jq is required (check-feature-list.sh validates the feature_list)"

for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh trace-lib.sh trace-report.sh; do
  [ -f "${ROOT}/scripts/${s}" ] \
    || fail "required harness script missing: scripts/${s}"
done

link_tools() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

write_fake_gh() {
  cat > "$1" <<'FAKE_GH'
#!/usr/bin/env bash
exit 1
FAKE_GH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
mkdir -p "$TMP_DIR"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc find mktemp mv cp
write_fake_gh "${BIN}/gh"

# Never let the harness runner's own environment leak into the fixture.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE FORCE DELETE_BRANCH \
  REQUIRE_TRACE_CONSISTENCY TRACE_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING \
  COPILOT_TRANSCRIPTS_DIR 2>/dev/null || true
# Hermeticity (issue #329): finish-issue.sh closeout now joins native Copilot
# economics from ${COPILOT_CLI_STATE_ROOT}/<session>/events.jsonl. Pin the root
# to an isolated empty dir and unset the ambient session id so this fixture's
# assertions never read the real developer ~/.copilot session state.
unset COPILOT_AGENT_SESSION_ID 2>/dev/null || true
export COPILOT_CLI_STATE_ROOT="${TMP_DIR}/native-empty"
export ABANDONED=1

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'

make_state_hygiene_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"

  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh trace-lib.sh trace-report.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/trace-schema.v1.json"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial

  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out"; fail "setup: start-issue for issue ${issue} failed"; }

  [ -d "${dir}-worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"
  printf '%s\n' "$COMPLETE_LIST" \
    > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"

  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}/.hook-state"
  printf 'orphan\n' \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/.hook-state/session-a-tool-b"

  [ -e "${dir}/.copilot-tracking/issues/issue-${pad}/.hook-state/session-a-tool-b" ] \
    || fail "setup: orphaned hook-state file must exist before finish"
}

ISSUE=57
PAD="$(printf '%02d' "$ISSUE")"
MAIN="${TMP_DIR}/main"
make_state_hygiene_fixture "$MAIN" "$ISSUE"

(cd "$MAIN" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$ISSUE" SLUG=fixture) \
  > "${TMP_DIR}/finish.out" 2>&1 \
  || { cat "${TMP_DIR}/finish.out"; fail "state hygiene: finish-issue.sh must exit 0; hygiene is warn-only and must not block teardown"; }

[ ! -e "${MAIN}-worktrees/issue-${PAD}" ] \
  || fail "state hygiene: worktree must still be removed"
defects=()
if [ -e "${MAIN}/.copilot-tracking/issues/issue-${PAD}/.hook-state" ]; then
  defects+=("orphaned issue hook-state directory still exists")
fi
if [ "${#defects[@]}" -ne 0 ]; then
  printf 'FAIL: state hygiene sweep did not clean expected issue-scoped state after finish exited 0:\n' >&2
  printf '  - %s\n' "${defects[@]}" >&2
  exit 1
fi

printf 'finish-issue closeout state hygiene contract honored\n'
