#!/usr/bin/env bash
# test_finish_issue_economics_stamp.sh — RED sensor for issue #267 feature f2
# economics-stamp wiring. The production helpers are intentionally absent until
# the implementation phase, so this sensor must fail red for that reason.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_finish_issue_economics_stamp.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR"

count_marker() {
  local file="$1" marker="$2" count
  count="$(grep -F -c "$marker" "$file" || true)"
  printf '%s' "$count"
}

assert_marker_count() {
  local file="$1" marker="$2" expected="$3" actual
  actual="$(count_marker "$file" "$marker")"
  [ "$actual" -eq "$expected" ] \
    || fail "expected ${expected} copies of ${marker}, found ${actual}"
}

assert_file_contains() {
  local file="$1" needle="$2"
  grep -F -q -- "$needle" "$file" \
    || fail "expected ${file} to contain: ${needle}"
}

assert_file_not_contains() {
  local file="$1" needle="$2"
  if grep -F -q -- "$needle" "$file"; then
    fail "expected ${file} not to contain: ${needle}"
  fi
}

call_economics_stamp_into() {
  local progress_file="$1" block_text="$2"
  (
    set -euo pipefail
    # shellcheck source=scripts/finish-lib.sh
    source "${ROOT}/scripts/finish-lib.sh"
    economics_stamp_into "$progress_file" "$block_text"
  )
}

link_tools() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  local tool path
  for tool in "$@"; do
    path="$(command -v "$tool" || true)"
    [ -n "$path" ] && ln -sf "$path" "${dir}/${tool}"
  done
}

write_fake_gh() {
  cat > "$1" <<'FAKEGH'
#!/usr/bin/env bash
exit 1
FAKEGH
  chmod +x "$1"
}

copy_finish_fixture_scripts() {
  local dir="$1" script
  mkdir -p "${dir}/scripts"
  for script in \
    issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh review-gate.sh \
    trace-lib.sh log-handback.sh validate-trace.sh check-trace-consistency.sh trace-report.sh; do
    cp "${ROOT}/scripts/${script}" "${dir}/scripts/"
  done
  chmod +x "${dir}/scripts/"*.sh
}

make_finish_fixture() {
  local dir="$1" issue="$2" pad start_out
  pad="$(printf '%02d' "$issue")"
  copy_finish_fixture_scripts "$dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial

  if ! start_out="$(cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture 2>&1)"; then
    printf '%s\n' "$start_out"
    fail "setup: start-issue for issue ${issue} failed"
  fi
  [ -d "${dir}-worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"

  cat > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json" <<JSON
{
  "features": [
    {
      "id": "economics-stamp",
      "title": "Delivery economics stamp",
      "steps": [],
      "passes": true,
      "verification": "done",
      "teeth_proof": {"kind": "red_first", "evidence": "fixture complete"}
    }
  ]
}
JSON
}

write_trace_fixture() {
  local main="$1" issue="$2" pad trace_dir
  pad="$(printf '%02d' "$issue")"
  trace_dir="${main}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$trace_dir"
  cat > "${trace_dir}/trace.jsonl" <<'JSONL'
{"timestamp":"2026-07-10T10:00:00Z","span":"model","gen_ai.usage.input_tokens":120,"gen_ai.usage.output_tokens":30}
{"timestamp":"2026-07-10T10:30:00Z","span":"model","gen_ai.usage.input_tokens":80,"gen_ai.usage.output_tokens":20}
{"timestamp":"2026-07-10T10:40:00Z","span":"lifecycle","harness.lifecycle_step":"review_verdict","harness.outcome":"fail"}
{"timestamp":"2026-07-10T10:50:00Z","span":"lifecycle","harness.lifecycle_step":"review_verdict","harness.outcome":"pass"}
{"timestamp":"2026-07-10T11:00:00Z","span":"lifecycle","harness.lifecycle_step":"deviation","harness.outcome":"warn"}
JSONL
}

assert_behavioral_finish_stamps_before_remove() {
  local main="$1" issue="$2" out rc economics_line removed_line
  make_finish_fixture "$main" "$issue"
  write_trace_fixture "$main" "$issue"

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "finish-issue.sh must exit 0"; }
  printf '%s\n' "$out" | grep -F -q '## Delivery economics (auto-stamped, trace-derived)' \
    || { printf '%s\n' "$out"; fail "finish output must print delivery economics block"; }
  if printf '%s\n' "$out" | grep -F -q -- '- Tokens: n/a'; then
    printf '%s\n' "$out"
    fail "finish output must not report n/a tokens when MAIN-root trace has token data"
  fi
  printf '%s\n' "$out" | grep -F -q -- '- Tokens: in ' \
    || { printf '%s\n' "$out"; fail "finish output must include real token totals"; }

  economics_line="$(printf '%s\n' "$out" | grep -n -F '## Delivery economics (auto-stamped, trace-derived)' | head -n 1 | cut -d: -f1)"
  removed_line="$(printf '%s\n' "$out" | grep -n -F 'Removed worktree' | head -n 1 | cut -d: -f1)"
  [ -n "$economics_line" ] || fail "could not locate economics line in finish output"
  [ -n "$removed_line" ] || fail "could not locate Removed worktree line in finish output"
  [ "$economics_line" -lt "$removed_line" ] \
    || fail "delivery economics must print before Removed worktree"

  # SURVIVAL (#285 item 1): the flagship human-readable artifact must OUTLIVE
  # `git worktree remove`. The worktree progress.md is deleted with the
  # worktree, so the block must land in a surviving file under the MAIN
  # checkout tracking dir (where trace.jsonl already lives).
  local pad main_progress
  pad="$(printf '%02d' "$issue")"
  main_progress="${main}/.copilot-tracking/issues/issue-${pad}/progress.md"
  [ ! -d "${main}-worktrees/issue-${pad}" ] \
    || fail "worktree for issue ${issue} must be removed after finish"
  [ -f "$main_progress" ] \
    || fail "economics block must survive teardown in a MAIN-checkout progress.md (${main_progress} missing)"
  grep -F -q '## Delivery economics (auto-stamped, trace-derived)' "$main_progress" \
    || { echo "--- ${main_progress} ---"; cat "$main_progress" 2>/dev/null; fail "surviving MAIN-checkout progress.md must contain the delivery economics block after teardown"; }
}

# UNIT U1: append the economics region into progress.md.
PROGRESS="${TMP_DIR}/unit-progress.md"
cat > "$PROGRESS" <<'MD'
# Issue 267 progress

## Action Log

- Existing handback.
MD

OLD_BLOCK=$'## Delivery economics (auto-stamped, trace-derived)\n- x'
call_economics_stamp_into "$PROGRESS" "$OLD_BLOCK"
assert_marker_count "$PROGRESS" '<!-- delivery-economics:start -->' 1
assert_marker_count "$PROGRESS" '<!-- delivery-economics:end -->' 1
assert_file_contains "$PROGRESS" '## Delivery economics (auto-stamped, trace-derived)'
assert_file_contains "$PROGRESS" '- x'

# UNIT U2: replace the existing region without duplicating markers.
NEW_BLOCK=$'## Delivery economics (auto-stamped, trace-derived)\n- y'
call_economics_stamp_into "$PROGRESS" "$NEW_BLOCK"
assert_marker_count "$PROGRESS" '<!-- delivery-economics:start -->' 1
assert_marker_count "$PROGRESS" '<!-- delivery-economics:end -->' 1
assert_file_contains "$PROGRESS" '- y'
assert_file_not_contains "$PROGRESS" '- x'

# UNIT U3: missing path warns to stderr only, writes no stdout, and returns 0.
rc=0
warn_out="$(call_economics_stamp_into "${TMP_DIR}/does-not-exist/progress.md" "block" 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "missing progress.md path must return 0"
[ -z "$warn_out" ] || fail "missing progress.md path must write nothing to stdout"

# BEHAVIOR: finish-issue prints/stamps the economics block before teardown.
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc chmod cp head
write_fake_gh "${BIN}/gh"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
assert_behavioral_finish_stamps_before_remove "${TMP_DIR}/r86" 86

printf 'finish-issue delivery economics stamp contract honored\n'
