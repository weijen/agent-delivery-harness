#!/usr/bin/env bash
# test_trace_finish_issue.sh — regression sensor for finish-issue.sh trace
# emission (issue #94, feature trace-finish-issue, plan Phase 7).
#
# Contract under test (plan instrumentation table; the SURVIVAL property is
# the whole point of plan D1):
#
#   finish-issue.sh runs from the MAIN checkout on branch `main`, so it must
#   export TRACE_ISSUE (plan D6) and its `finish` LIFECYCLE span — emitted
#   from the terminal EXIT trap AFTER `git worktree remove` — can only exist
#   because the trace file lives at the MAIN checkout root. The sensor
#   therefore asserts the worktree directory is GONE *and* the finish span
#   exists in <main-root>/.copilot-tracking/issues/issue-NN/trace.jsonl.
#
#   Exactly ONE finish span per invocation, with harness.outcome, NUMERIC
#   harness.exit_status / harness.duration_ms. finish-issue delegates the
#   completion check to check-feature-list.sh, whose own (already
#   instrumented) tool span lands in the SAME trace file — assertions count
#   finish spans, not lines.
#
#   1. Complete feature_list + FORCE=1 (the gitignored tracking dir makes a
#      plain `git worktree remove` refuse) → exit 0 unchanged, worktree
#      removed, finish span outcome=pass / exit_status=0.
#   2. Incomplete feature_list, warn mode (default) → warning is
#      non-blocking: exit 0 unchanged, worktree removed, finish span
#      outcome=pass.
#   3. Incomplete + REQUIRE_FEATURES_COMPLETE=1 → hard refusal: exit 1 and
#      worktree INTACT (existing ordering invariant), finish span
#      outcome=fail, non-zero exit_status, harness.stage=completion_check.
#   4. Every emitted line passes the #92 contract filter; with trace-lib.sh
#      absent behavior is identical and nothing is emitted (plan D5).
#
# Fixture style follows test_lifecycle_order.sh case 3: temp main repo,
# worktree created via start-issue.sh SKIP_INIT=1, pinned PATH (jq required
# by check-feature-list), fake gh.
#
# Exit codes: 0 emission contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="${ROOT}/.copilot-test-tmp/test-trace-finish-issue.$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate finish-issue trace emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

validate_file() {
  local label="$1" file="$2" n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    validate_span "$line" \
      || fail "${label}: line ${n} rejected by the contract-driven jq validation filter: ${line}"
  done < "$file"
}

# get_finish_span <label> <trace-file> — exactly ONE finish lifecycle span
# (start-issue and check-feature-list spans coexist in the same file).
get_finish_span() {
  local label="$1" file="$2" spans count
  [ -f "$file" ] \
    || fail "${label}: main-root trace file missing (${file})"
  spans="$(jq -c 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "finish")' "$file")"
  count="$(printf '%s' "$spans" | grep -c . || true)"
  [ "$count" = "1" ] \
    || fail "${label}: expected exactly ONE finish lifecycle span, found ${count} in ${file} — finish-issue.sh is not instrumented (feature trace-finish-issue)"
  printf '%s' "$spans"
}

# check_finish_span <label> <line> <pass|fail> <issue>
check_finish_span() {
  local label="$1" line="$2" outcome="$3" issue="$4"
  validate_span "$line" \
    || fail "${label}: finish span rejected by the contract filter: ${line}"
  printf '%s\n' "$line" | jq -e --arg outcome "$outcome" --argjson issue "$issue" '
      (.["harness.outcome"] == $outcome)
      and ((.["harness.exit_status"] | type) == "number")
      and (if $outcome == "pass"
           then (.["harness.exit_status"] == 0)
           else (.["harness.exit_status"] != 0)
           end)
      and ((.["harness.duration_ms"] | type) == "number")
      and (.["harness.duration_ms"] >= 0)
      and (.["harness.issue"] == $issue)
      and ((.["harness.issue"] | type) == "number")
    ' >/dev/null \
    || fail "${label}: finish span must carry harness.outcome=${outcome}, numeric harness.exit_status/duration_ms, harness.issue=${issue} (via the script's TRACE_ISSUE export — it runs on branch main): ${line}"
}

link_tools() {
  local dir="$1"; shift
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
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep \
  printf jq date od wc find mktemp mv cp awk sort comm chmod
write_fake_gh "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
export ABANDONED=1

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'
INCOMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'

# make_finish_fixture <dir> <issue> <with_trace_lib:0|1> <feature-list-json>
# Main repo + worktree for <issue> created via start-issue.sh SKIP_INIT=1,
# feature_list.json planted in the worktree tracking dir.
make_finish_fixture() {
  local dir="$1" issue="$2" with_lib="$3" list="$4" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  if [ "$with_lib" = "1" ]; then
    cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  fi
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out"; fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}-worktrees/issue-${pad}" ] || fail "setup: worktree for issue ${issue} was not created"
  printf '%s\n' "$list" > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

# ============================================================================
# 1. Complete list + FORCE=1 → worktree GONE and finish pass span SURVIVES
# ============================================================================
R1="${TMP_DIR}/r70"
make_finish_fixture "$R1" 70 1 "$COMPLETE_LIST"
(cd "$R1" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 70 SLUG=fixture) > "${TMP_DIR}/fin-ok.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-ok.out"; fail "complete finish: finish-issue.sh must still exit 0 (behavior unchanged)"; }
grep -q "Removed worktree" "${TMP_DIR}/fin-ok.out" \
  || { cat "${TMP_DIR}/fin-ok.out"; fail "complete finish: removal message must be unchanged"; }
[ ! -e "${R1}-worktrees/issue-70" ] \
  || fail "complete finish: worktree must be removed (behavior unchanged)"
TRACE1="${R1}/.copilot-tracking/issues/issue-70/trace.jsonl"
# THE SURVIVAL PROPERTY (plan D1): the worktree is gone, yet the finish span
# exists — only a main-root trace file can hold a post-teardown span.
f1="$(get_finish_span "complete finish (post-teardown survival)" "$TRACE1")"
check_finish_span "complete finish" "$f1" pass 70
validate_file "complete-finish trace" "$TRACE1"

# ============================================================================
# 2. Incomplete list, warn mode → exit 0 unchanged, finish pass span
# ============================================================================
R2="${TMP_DIR}/r71"
make_finish_fixture "$R2" 71 1 "$INCOMPLETE_LIST"
(cd "$R2" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 71 SLUG=fixture) > "${TMP_DIR}/fin-warn.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-warn.out"; fail "warn finish: incomplete list must stay non-blocking by default (behavior unchanged)"; }
grep -q "warning only" "${TMP_DIR}/fin-warn.out" \
  || { cat "${TMP_DIR}/fin-warn.out"; fail "warn finish: warning text must be unchanged"; }
[ ! -e "${R2}-worktrees/issue-71" ] \
  || fail "warn finish: worktree must still be removed (warning is non-blocking)"
TRACE2="${R2}/.copilot-tracking/issues/issue-71/trace.jsonl"
f2="$(get_finish_span "warn finish" "$TRACE2")"
check_finish_span "warn finish" "$f2" pass 71
validate_file "warn-finish trace" "$TRACE2"

# ============================================================================
# 3. Incomplete + REQUIRE_FEATURES_COMPLETE=1 → refusal, worktree intact,
#    finish fail span with harness.stage=completion_check
# ============================================================================
R3="${TMP_DIR}/r72"
make_finish_fixture "$R3" 72 1 "$INCOMPLETE_LIST"
if (cd "$R3" && PATH="$BIN" REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 72 SLUG=fixture) > "${TMP_DIR}/fin-hard.out" 2>&1; then
  cat "${TMP_DIR}/fin-hard.out"; fail "hard finish: incomplete list must still hard-fail under REQUIRE_FEATURES_COMPLETE=1 (behavior unchanged)"
fi
grep -qi "incomplete" "${TMP_DIR}/fin-hard.out" \
  || { cat "${TMP_DIR}/fin-hard.out"; fail "hard finish: incomplete message must be unchanged"; }
[ -d "${R3}-worktrees/issue-72" ] \
  || fail "hard finish: worktree must be left INTACT on a failed completion check (existing ordering invariant)"
TRACE3="${R3}/.copilot-tracking/issues/issue-72/trace.jsonl"
f3="$(get_finish_span "hard finish" "$TRACE3")"
check_finish_span "hard finish" "$f3" fail 72
printf '%s\n' "$f3" | jq -e '.["harness.stage"] == "completion_check"' >/dev/null \
  || fail "hard finish: fail span must carry harness.stage=completion_check: ${f3}"
validate_file "hard-finish trace" "$TRACE3"

# ============================================================================
# 4. Guarded sourcing: trace-lib.sh absent — behavior identical, no emission
# ============================================================================
R4="${TMP_DIR}/r73"
make_finish_fixture "$R4" 73 0 "$COMPLETE_LIST"
(cd "$R4" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 73 SLUG=fixture) > "${TMP_DIR}/fin-nolib.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-nolib.out"; fail "trace-lib absent: finish-issue.sh must still exit 0 (guarded source / no-op fallback, plan D5)"; }
[ ! -e "${R4}-worktrees/issue-73" ] \
  || fail "trace-lib absent: worktree must still be removed (behavior unchanged)"
[ ! -e "${R4}/.copilot-tracking/issues/issue-73/trace.jsonl" ] \
  || fail "trace-lib absent: no trace file may be created (no-op fallback)"

printf 'finish-issue trace emission contract honored\n'
