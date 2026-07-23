#!/usr/bin/env bash
# test_finish_issue_log_gate.sh — RED sensor for finish-issue.sh wiring of the
# issue-log completeness gate (feature finish-issue-log-gate-wiring).
#
# Contract under test:
#
#   finish-issue.sh must run a finish_log_completeness_gate before
#   git worktree remove. The gate delegates to review-gate.sh log-completeness.
#   Ordinary review-gate use is warn-only by default, but destructive finish
#   must always turn residual placeholders into a hard refusal while the issue
#   worktree is still intact.
#
# Fixture style mirrors test_trace_finish_issue.sh: each case creates a throwaway
# main checkout, copies the harness entrypoints, initializes a real issue
# worktree via start-issue.sh SKIP_INIT=1, pins PATH, fakes gh, and plants a
# completed feature_list.json so the completion gate is not the subject.
#
# Exit codes: 0 contract honored · 1 finish-issue did not wire the log gate.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_finish_issue_log_gate.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR"

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
  cat > "$1" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc chmod cp mktemp mv
write_fake_gh "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
export ABANDONED=1

COMPLETE_LIST='{"features":[{"id":"finish-issue-log-gate-wiring","title":"finish issue log gate wiring","steps":[],"passes":true,"verification":"done"}]}'

make_finish_fixture() {
  local dir="$1" issue="$2" pad start_out
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  local s
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh review-gate.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  chmod +x "${dir}/scripts/"*.sh

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial

  if ! start_out="$(cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture 2>&1)"; then
    printf '%s\n' "$start_out"
    fail "setup: start-issue for issue ${issue} failed"
  fi
  [ -d "${dir}/.worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"
  printf '%s\n' "$COMPLETE_LIST" > "${dir}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

write_clean_progress() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  cat > "${main}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/progress.md" <<MD
# Issue ${issue} progress

Status: complete.

## Action Log

- Verified finish issue log gate wiring.
MD
}

write_placeholder_progress() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  cat > "${main}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/progress.md" <<MD
# Issue ${issue} progress

Status: in progress.

## Action Log

- Recorded on completion below
- TBD
MD
}

assert_removed() {
  local label="$1" path="$2"
  [ ! -e "$path" ] || fail "${label}: worktree must be REMOVED"
}

assert_intact() {
  local label="$1" path="$2"
  [ -d "$path" ] || fail "${label}: worktree must be left INTACT when the log-completeness gate blocks"
}

# 1. clean_default: no placeholders, default mode removes the worktree.
R1="${TMP_DIR}/r80"
make_finish_fixture "$R1" 80
write_clean_progress "$R1" 80
rc=0
out="$(cd "$R1" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 80 SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "clean_default: finish-issue.sh must exit 0"; }
assert_removed "clean_default" "${R1}/.worktrees/issue-80"

# 3. placeholder_require_blocks: placeholders + REQUIRE_LOG_COMPLETE=1 must
# block before worktree_remove. This is the RED failure until finish-issue.sh
# wires finish_log_completeness_gate.
R3="${TMP_DIR}/r82"
make_finish_fixture "$R3" 82
write_placeholder_progress "$R3" 82
rc=0
out="$(cd "$R3" && PATH="$BIN" REQUIRE_LOG_COMPLETE=1 FORCE=1 ./scripts/finish-issue.sh 82 SLUG=fixture 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  printf '%s\n' "$out"
  fail "placeholder_require_blocks: expected non-zero exit under REQUIRE_LOG_COMPLETE=1"
fi
assert_intact "placeholder_require_blocks" "${R3}/.worktrees/issue-82"

# 2. placeholder_default_blocks: ordinary review-gate use remains warn-only,
# but destructive finish always promotes residual placeholders to a hard gate.
R2="${TMP_DIR}/r81"
make_finish_fixture "$R2" 81
write_placeholder_progress "$R2" 81
rc=0
out="$(cd "$R2" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 81 SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || { printf '%s\n' "$out"; fail "placeholder_default_blocks: finish must reject placeholders"; }
printf '%s\n' "$out" | grep -q "log-completeness" \
  || { printf '%s\n' "$out"; fail "placeholder_default_blocks: output must mention log-completeness"; }
printf '%s\n' "$out" | grep -q "Recorded on completion below" \
  || { printf '%s\n' "$out"; fail "placeholder_default_blocks: output must include placeholder finding text"; }
assert_intact "placeholder_default_blocks" "${R2}/.worktrees/issue-81"

# 4. clean_require_ok: REQUIRE_LOG_COMPLETE=1 does not block a clean log.
R4="${TMP_DIR}/r83"
make_finish_fixture "$R4" 83
write_clean_progress "$R4" 83
rc=0
out="$(cd "$R4" && PATH="$BIN" REQUIRE_LOG_COMPLETE=1 FORCE=1 ./scripts/finish-issue.sh 83 SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "clean_require_ok: clean log must exit 0 under REQUIRE_LOG_COMPLETE=1"; }
assert_removed "clean_require_ok" "${R4}/.worktrees/issue-83"

printf 'finish-issue log-completeness gate wiring contract honored\n'
