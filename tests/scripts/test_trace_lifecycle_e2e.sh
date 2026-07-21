#!/usr/bin/env bash
# test_trace_lifecycle_e2e.sh — L0 ordered-span trajectory sensor (issue #94,
# feature trace-lifecycle-e2e, plan Phase 8, decision D8).
#
# Drives one full scripted issue lifecycle against a temp main repo with a
# bare local origin and a fake gh, then asserts the SINGLE main-root
# trace.jsonl tells the whole story in append order:
#
#   1. The lifecycle-span subsequence, in FILE (append) order, is exactly
#        preflight → worktree_create → review_gate_approve → pr_create →
#        pr_merge → finish
#      (D8: order by file position, never timestamps — second-granularity
#      timestamps tie).
#   2. Every lifecycle span carries harness.outcome=pass, NUMERIC
#      harness.exit_status=0 and NUMERIC harness.duration_ms >= 0.
#   3. A check-feature-list TOOL span appears between the worktree_create
#      and review_gate_approve lifecycle spans (the explicit validation step
#      of the drive; finish-issue's child check appears later).
#   4. Every line passes the #92 contract-driven jq filter.
#   5. One file: no trace ever exists under the worktree path (plan D1), and
#      the finish span survives worktree teardown.
#
# This trace is the first real trajectory fixture for
# docs/evaluation/trajectory-evals.md.
#
# Fixture: test_lifecycle_order.sh precedents — pinned PATH (real
# coreutils/git/jq + fake gh), bare local origin, stub init.sh exiting 0.
#
# Exit codes: 0 trajectory contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate the lifecycle trace trajectory"

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

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

# Fake gh spanning the whole lifecycle: pr view resolves 123 only after
# pr create ran (GH_STATE); checks are one green line; merge succeeds;
# pr list returns the merged PR record so finish_progress_finalize can
# confirm the merge evidence.
write_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "issue view") exit 1 ;;
  "pr view")
    if [ -f "${GH_STATE:?}" ]; then
      case "$*" in
        *"state,mergeCommit"*) printf 'MERGED\tdeadbeef0001cafe\n' ;;
        *) echo 123 ;;
      esac
      exit 0
    fi
    exit 1
    ;;
  "pr create")
    printf '%s\n' "$*" >> "${GH_LOG:?}"
    : > "${GH_STATE:?}"
    exit 0
    ;;
  "pr checks")
    printf 'harness-smoke  pass  1m\n'
    exit 0
    ;;
  "pr merge") exit 0 ;;
  "pr list")
    if [ -f "${GH_STATE:?}" ]; then
      printf '[{"headRefName":"feature/issue-42-e2e","state":"MERGED","mergedAt":"2024-01-01T00:00:00Z","number":123}]\n'
    else
      printf '[]\n'
    fi
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut \
  grep printf jq date od wc awk sort comm uniq mktemp head tail ls cp mv ln touch \
  uname true false
write_fake_gh "${BIN}/gh"
export GH_STATE="${TMP_DIR}/gh.state"
export GH_LOG="${TMP_DIR}/gh.log"
: > "$GH_LOG"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE SKIP_INIT FORCE DELETE_BRANCH 2>/dev/null || true

# --- Fixture: main repo with all harness scripts + bare origin ------------------
R="${TMP_DIR}/repo"
mkdir -p "${R}/scripts" "${R}/docs"
for s in issue-lib.sh start-issue.sh check-feature-list.sh review-gate.sh \
         create-pr.sh merge-pr.sh finish-issue.sh finish-lib.sh trace-lib.sh; do
  cp "${ROOT}/scripts/${s}" "${R}/scripts/"
done
cat > "${R}/scripts/init.sh" <<'SH'
#!/usr/bin/env bash
echo "stub preflight ok"
exit 0
SH
chmod +x "${R}/scripts/init.sh"
git -C "$R" init -q -b main
git -C "$R" config user.name "Harness Test"
git -C "$R" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > "${R}/.gitignore"
printf 'fixture\n' > "${R}/README.md"
printf '# Progress\n\nbaseline\n' > "${R}/docs/PROGRESS.md"
git -C "$R" add .gitignore README.md docs/PROGRESS.md scripts
git -C "$R" commit -q -m initial
git clone -q --bare "$R" "${TMP_DIR}/origin.git"
git -C "$R" remote add origin "${TMP_DIR}/origin.git"
git -C "$R" fetch -q origin main

WT="${R}-worktrees/issue-42"
TRACE="${R}/.copilot-tracking/issues/issue-42/trace.jsonl"
WT_TRACE="${WT}/.copilot-tracking/issues/issue-42/trace.jsonl"

run_step() { # run_step <label> <cwd> <cmd...>
  local label="$1" cwd="$2"; shift 2
  (cd "$cwd" && PATH="$BIN" "$@") > "${TMP_DIR}/${label}.out" 2>&1 \
    || { cat "${TMP_DIR}/${label}.out"; fail "lifecycle step '${label}' failed — trajectory cannot be recorded"; }
}

# --- Drive the full scripted lifecycle ------------------------------------------
run_step start "$R" ./scripts/start-issue.sh 42 SLUG=e2e
[ -d "$WT" ] || fail "start-issue did not create the issue-42 worktree"

# Conductor authors a COMPLETE feature list (passes:true + verification).
printf '%s\n' '{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}' \
  > "${WT}/.copilot-tracking/issues/issue-42/feature_list.json"

# The branch must update docs/PROGRESS.md (status-doc gate, no opt-out).
printf '# Progress\n\nissue-42 shipped\n' > "${WT}/docs/PROGRESS.md"
git -C "$WT" add docs/PROGRESS.md
git -C "$WT" commit -q -m "issue-42: progress update"

run_step check "$WT" ./scripts/check-feature-list.sh 42 SLUG=e2e
run_step approve "$WT" ./scripts/review-gate.sh approve
run_step create-pr "$WT" ./scripts/create-pr.sh --title "t" --body "b"
run_step merge-pr "$WT" ./scripts/merge-pr.sh

# D1: even before teardown, NO trace file may exist under the worktree.
[ ! -e "$WT_TRACE" ] \
  || fail "a trace file appeared under the worktree (${WT_TRACE}) — plan D1 requires ONE main-root file"

run_step finish "$R" env FORCE=1 ./scripts/finish-issue.sh 42 SLUG=e2e
[ ! -e "$WT" ] || fail "finish-issue did not remove the worktree"

# --- Assert the trajectory --------------------------------------------------------
[ -f "$TRACE" ] || fail "main-root trace file missing after a full lifecycle run (${TRACE})"

# 1+4. Every line passes the contract filter (and the finish span survived
# teardown because the file lives at the MAIN root).
n=0
while IFS= read -r line; do
  n=$((n + 1))
  validate_span "$line" \
    || fail "trace line ${n} rejected by the contract-driven jq validation filter: ${line}"
done < "$TRACE"
[ "$n" -gt 0 ] || fail "trace file is empty"

# 2. Lifecycle subsequence in FILE ORDER is exactly the contract order (D8).
steps="$(jq -r 'select(.span == "lifecycle") | .["harness.lifecycle_step"]' "$TRACE" | paste -sd, -)"
[ "$steps" = "preflight,worktree_create,review_gate_approve,pr_create,pr_merge,finish" ] \
  || fail "lifecycle spans out of order or incomplete: expected 'preflight,worktree_create,review_gate_approve,pr_create,pr_merge,finish' in append order, got '${steps}'"

# 3. Every lifecycle span: outcome=pass, numeric exit_status=0, numeric duration.
jq -e '
    select(.span == "lifecycle")
    | (.["harness.outcome"] == "pass")
      and (.["harness.exit_status"] == 0)
      and ((.["harness.exit_status"] | type) == "number")
      and ((.["harness.duration_ms"] | type) == "number")
      and (.["harness.duration_ms"] >= 0)
      and (.["harness.issue"] == 42)
  ' "$TRACE" >/dev/null \
  || fail "every lifecycle span must carry harness.outcome=pass, numeric harness.exit_status=0, numeric harness.duration_ms >= 0, harness.issue=42"

# 4. The explicit check-feature-list TOOL span sits between worktree_create
#    and review_gate_approve (file positions).
idx_wt="$(jq -n 'first(inputs | select(.value.span == "lifecycle" and .value["harness.lifecycle_step"] == "worktree_create") | .key)' \
  < <(jq -c '.' "$TRACE" | jq -c -n '[inputs] | to_entries[]'))"
idx_check="$(jq -n 'first(inputs | select(.value.span == "tool" and .value["gen_ai.tool.name"] == "check-feature-list") | .key)' \
  < <(jq -c '.' "$TRACE" | jq -c -n '[inputs] | to_entries[]'))"
idx_approve="$(jq -n 'first(inputs | select(.value.span == "lifecycle" and .value["harness.lifecycle_step"] == "review_gate_approve") | .key)' \
  < <(jq -c '.' "$TRACE" | jq -c -n '[inputs] | to_entries[]'))"
if [ -z "$idx_wt" ] || [ "$idx_wt" = "null" ]; then
  fail "worktree_create span not found for position check"
fi
if [ -z "$idx_check" ] || [ "$idx_check" = "null" ]; then
  fail "no check-feature-list tool span found in the trajectory"
fi
if [ -z "$idx_approve" ] || [ "$idx_approve" = "null" ]; then
  fail "review_gate_approve span not found for position check"
fi
if [ "$idx_check" -le "$idx_wt" ] || [ "$idx_check" -ge "$idx_approve" ]; then
  fail "the check-feature-list tool span must appear between worktree_create (line-idx ${idx_wt}) and review_gate_approve (line-idx ${idx_approve}); found at line-idx ${idx_check}"
fi

printf 'lifecycle e2e ordered-span trajectory honored\n'
