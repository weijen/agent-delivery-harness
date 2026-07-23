#!/usr/bin/env bash
# Regression sensor for issue #320: finish-issue strips only the exact
# start-issue scaffold cruft, then rejects every remaining known placeholder.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
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
  printf jq date od wc find mktemp mv cp cmp awk sort comm chmod
cat > "${BIN}/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  printf 'fixture issue\n'
  exit 0
fi
exit 1
GH
chmod +x "${BIN}/gh"

# Hermeticity (issue #329): finish-issue.sh closeout now joins native Copilot
# economics from ${COPILOT_CLI_STATE_ROOT}/<session>/events.jsonl. Pin the root
# to an isolated empty dir and unset the ambient session id so this fixture's
# assertions never read the real developer ~/.copilot session state.
unset COPILOT_AGENT_SESSION_ID 2>/dev/null || true
export COPILOT_CLI_STATE_ROOT="${TMP_DIR}/native-empty"

make_fixture() {
  local name="$1" issue="$2" dir="${TMP_DIR}/$1" pad=""
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  cp "${ROOT}/scripts/"{issue-lib.sh,start-issue.sh,finish-issue.sh,finish-lib.sh,check-feature-list.sh,review-gate.sh,trace-lib.sh,trace-report.sh} \
    "${dir}/scripts/"
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/trace-schema.v1.json"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
  (
    cd "$dir"
    PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture
  ) > "${TMP_DIR}/${name}-start.out" 2>&1 || fail "${name}: fixture start failed"
  printf '{"features":[{"id":"done","title":"Done","steps":[],"passes":true,"regression_sensor":"fixture","e2e_sensor":null,"blocked_on":null,"verification":"sensor","teeth_proof":{"kind":"red_first","evidence":"fixture"}}]}\n' \
    > "${dir}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
  printf '%s' "$dir"
}

run_finish() {
  local main="$1" issue="$2" out="$3"
  (
    cd "$main"
    PATH="$BIN" FORCE=1 ABANDONED=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture
  ) > "$out" 2>&1
}

assert_contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "expected ${file} to contain: ${text}"
}

assert_not_contains() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "expected ${file} not to contain: ${text}"
  fi
}

# Exact generated cruft is removed, while authored text that merely resembles
# it remains byte-for-byte and the sanitized record survives teardown.
MAIN="$(make_fixture clean 61)"
PROGRESS="${MAIN}/.worktrees/issue-61/.copilot-tracking/issues/issue-61/progress.md"
cat >> "$PROGRESS" <<'AUTHORED'
- Record conductor handbacks here after each meaningful decision.
The conductor authors feature_list.json after planning in this project.
- [generator-subagent] green_handback done pass — complete
AUTHORED
run_finish "$MAIN" 61 "${TMP_DIR}/clean.out" \
  || { cat "${TMP_DIR}/clean.out"; fail "clean: finish unexpectedly failed"; }
[ ! -e "${MAIN}/.worktrees/issue-61" ] || fail "clean: worktree must be removed"
MIGRATED="${MAIN}/.copilot-tracking/issues/issue-61/progress.md"
assert_not_contains "$MIGRATED" \
  '- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._'
assert_not_contains "$MIGRATED" \
  "The **conductor authors** \`feature_list.json\` — but only *after* the"
assert_contains "$MIGRATED" '- Record conductor handbacks here after each meaningful decision.'
assert_contains "$MIGRATED" 'The conductor authors feature_list.json after planning in this project.'
assert_contains "$MIGRATED" 'Conclusion: abandoned; review verdict: n-a.'

# A failed final rename cannot partially sanitize the source record.
ATOMIC="${TMP_DIR}/atomic-progress.md"
cp "$MIGRATED" "$ATOMIC"
printf '%s\n' \
  '- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._' >> "$ATOMIC"
cp "$ATOMIC" "${ATOMIC}.before"
MVFAIL_BIN="${TMP_DIR}/bin-mvfail"
cp -R "$BIN" "$MVFAIL_BIN"
rm -f "${MVFAIL_BIN}/mv"
cat > "${MVFAIL_BIN}/mv" <<'MV'
#!/usr/bin/env bash
exit 7
MV
chmod +x "${MVFAIL_BIN}/mv"
if (
  PATH="$MVFAIL_BIN"
  # shellcheck source=scripts/issue-lib.sh
  source "${ROOT}/scripts/issue-lib.sh"
  # shellcheck source=scripts/finish-lib.sh
  source "${ROOT}/scripts/finish-lib.sh"
  finish__strip_scaffold_cruft "$ATOMIC"
); then
  fail "atomic: failed rename must make scaffold cleanup fail"
fi
cmp -s "$ATOMIC" "${ATOMIC}.before" \
  || fail "atomic: failed cleanup must leave progress.md byte-identical"

# Every known residual signature is a hard closeout failure even when the
# ordinary review-gate default remains warn-only. No conclusion may be written.
issue_offset=0
for case_data in \
  'recorded|Recorded on completion below' \
  'tbd|TBD' \
  'todo|TODO(fill this)'; do
  label="${case_data%%|*}"
  placeholder="${case_data#*|}"
  issue=$((62 + issue_offset))
  issue_offset=$((issue_offset + 1))
  MAIN="$(make_fixture "$label" "$issue")"
  PROGRESS="${MAIN}/.worktrees/issue-${issue}/.copilot-tracking/issues/issue-${issue}/progress.md"
  printf '%s\n' "$placeholder" >> "$PROGRESS"
  if run_finish "$MAIN" "$issue" "${TMP_DIR}/${label}.out"; then
    fail "${label}: residual placeholder must block closeout by default"
  fi
  [ -d "${MAIN}/.worktrees/issue-${issue}" ] || fail "${label}: worktree must remain intact"
  if grep -q '^Conclusion:' "$PROGRESS"; then
    fail "${label}: blocked closeout must not write a conclusion"
  fi
done

printf 'finish-issue scaffold cruft stripping contract honored\n'
