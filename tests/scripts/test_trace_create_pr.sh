#!/usr/bin/env bash
# test_trace_create_pr.sh — regression sensor for create-pr.sh trace emission
# (issue #94, feature trace-create-pr, plan Phase 5).
#
# Contract under test (plan instrumentation table, decision D3):
#
#   create-pr.sh emits exactly ONE `pr_create` LIFECYCLE terminal span per
#   invocation via a stage-tracked EXIT trap, with harness.stage naming the
#   last stage reached (preconditions|review_gate|rebase|post_sync_gate|
#   push|pr_create|done) on failure. The script runs inside the issue
#   worktree on a feature/issue-NN-* branch → branch-resolved issue, span at
#   the MAIN root trace file (plan D1). Note: create-pr.sh invokes
#   review-gate.sh check as a child process, whose own spans ALSO land in
#   the same trace file — assertions therefore count pr_create spans, not
#   total lines.
#
#   1. Happy path (approved HEAD, clean rebase, fake gh creates PR #123) →
#      pr_create span outcome=pass, numeric exit_status=0/duration_ms,
#      harness.pr_number=123, harness.branch=<branch>; script exit 0.
#   2. Missing review approval → pr_create span outcome=fail,
#      harness.stage=review_gate, non-zero numeric exit_status; exit 1 and
#      gate message unchanged, nothing pushed.
#   3. Rebase conflict (origin/main advanced with a conflicting change) →
#      fail span harness.stage=rebase; conflict message + exit 1 unchanged.
#   4. `gh pr create` failure → fail span harness.stage=pr_create; exit 1.
#   5. Dirty tree → fail span harness.stage=preconditions; exit 1 unchanged.
#   6. Refusal on `main` → exit 1 unchanged and NO emission (no issue is
#      resolvable from branch `main`; not an issue-scoped operation).
#   7. Every emitted line passes the #92 contract filter; with trace-lib.sh
#      absent behavior is identical and nothing is emitted (plan D5).
#
# Fixture style follows test_lifecycle_order.sh R2: plain repo on a
# feature/issue-NN-* branch, bare local origin, pinned PATH with a fake gh.
#
# Exit codes: 0 emission contract honored · 1 a contract obligation regressed.

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
  || fail "jq is required to validate create-pr trace emission"

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

# get_pr_span <label> <trace-file> — exactly ONE pr_create lifecycle span
# must exist in the file (child review-gate spans may coexist); prints it.
get_pr_span() {
  local label="$1" file="$2" spans count
  [ -f "$file" ] \
    || fail "${label}: main-root trace file missing (${file}) — create-pr.sh is not instrumented (feature trace-create-pr)"
  spans="$(jq -c 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "pr_create")' "$file")"
  count="$(printf '%s' "$spans" | grep -c . || true)"
  [ "$count" = "1" ] \
    || fail "${label}: expected exactly ONE pr_create lifecycle span per invocation, found ${count} in ${file} — create-pr.sh is not instrumented (feature trace-create-pr)"
  printf '%s' "$spans"
}

# check_pr_span <label> <line> <pass|fail> [expected-stage]
check_pr_span() {
  local label="$1" line="$2" outcome="$3" stage="${4:-}"
  validate_span "$line" \
    || fail "${label}: pr_create span rejected by the contract filter: ${line}"
  printf '%s\n' "$line" | jq -e --arg outcome "$outcome" '
      (.["harness.outcome"] == $outcome)
      and ((.["harness.exit_status"] | type) == "number")
      and (if $outcome == "pass"
           then (.["harness.exit_status"] == 0)
           else (.["harness.exit_status"] != 0)
           end)
      and ((.["harness.duration_ms"] | type) == "number")
      and (.["harness.duration_ms"] >= 0)
      and ((.["harness.issue"] | type) == "number")
    ' >/dev/null \
    || fail "${label}: pr_create span must carry harness.outcome=${outcome}, numeric harness.exit_status/duration_ms, numeric harness.issue: ${line}"
  if [ -n "$stage" ]; then
    printf '%s\n' "$line" | jq -e --arg stage "$stage" '.["harness.stage"] == $stage' >/dev/null \
      || fail "${label}: fail span must name the failing sub-step harness.stage=${stage}: ${line}"
  fi
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

# Fake gh: `pr view` fails until `pr create` has run (state file), then
# answers --json number/url queries; `pr create` logs and can be forced to
# fail via GH_CREATE_FAIL=1.
write_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")
    if [ -f "${GH_STATE:?}" ]; then
      case "$*" in
        *url*)    printf 'https://example.invalid/pr/123\n' ;;
        *number*) printf '123\n' ;;
        *)        printf '123\n' ;;
      esac
      exit 0
    fi
    exit 1
    ;;
  "pr create")
    if [ "${GH_CREATE_FAIL:-0}" = "1" ]; then
      printf 'fake gh: pr create forced to fail\n' >&2
      exit 1
    fi
    printf '%s\n' "$*" >> "${GH_LOG:?}"
    : > "${GH_STATE:?}"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc touch
write_fake_gh "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID GH_CREATE_FAIL 2>/dev/null || true

# make_pr_repo <dir> <issue-pad> <with_trace_lib:0|1>
# Plain repo on feature/issue-<PAD>-fixture with a bare local origin carrying
# main; the feature commit updates docs/PROGRESS.md (status-doc gate) and
# conflict.txt (rebase-conflict raw material).
make_pr_repo() {
  local dir="$1" pad="$2" with_lib="$3"
  mkdir -p "${dir}/scripts" "${dir}/docs"
  cp "${ROOT}/scripts/create-pr.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/review-gate.sh" "${dir}/scripts/"
  if [ "$with_lib" = "1" ]; then
    cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  fi
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  printf 'base\n' > "${dir}/conflict.txt"
  git -C "$dir" add .gitignore README.md docs/PROGRESS.md conflict.txt scripts
  git -C "$dir" commit -q -m initial
  git clone -q --bare "$dir" "${dir}-origin.git"
  git -C "$dir" remote add origin "${dir}-origin.git"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$pad" > "${dir}/docs/PROGRESS.md"
  printf 'feature\n' > "${dir}/conflict.txt"
  git -C "$dir" add docs/PROGRESS.md conflict.txt
  git -C "$dir" commit -q -m "issue-${pad}: feature work"
  git -C "$dir" fetch -q origin main
}

# advance_origin_main <dir> — push a conflicting change to origin's main.
advance_origin_main() {
  local dir="$1"
  local work="${dir}-mainwork"
  git clone -q "${dir}-origin.git" "$work"
  git -C "$work" config user.name "Harness Test"
  git -C "$work" config user.email "harness-test@example.invalid"
  printf 'mainline\n' > "${work}/conflict.txt"
  git -C "$work" add conflict.txt
  git -C "$work" commit -q -m "main: conflicting change"
  git -C "$work" push -q origin main
  git -C "$dir" fetch -q origin main
}

# run_cpr <dir> <state-suffix> <out-file> <args...>
run_cpr() {
  local dir="$1" sfx="$2" out="$3"; shift 3
  (cd "$dir" && PATH="$BIN" GH_STATE="${TMP_DIR}/gh-state-${sfx}" GH_LOG="${TMP_DIR}/gh-log-${sfx}" \
    ./scripts/create-pr.sh "$@") > "$out" 2>&1
}

# ============================================================================
# 1. Happy path → ONE pr_create pass span with pr_number + branch
# ============================================================================
R1="${TMP_DIR}/r20"
make_pr_repo "$R1" 20 1
(cd "$R1" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "setup: approve in happy-path repo failed"
run_cpr "$R1" 20 "${TMP_DIR}/cpr-ok.out" --title "t" --body "b" \
  || { cat "${TMP_DIR}/cpr-ok.out"; fail "happy path: create-pr.sh must still exit 0 (behavior unchanged)"; }
grep -q "PR #123 is open" "${TMP_DIR}/cpr-ok.out" \
  || { cat "${TMP_DIR}/cpr-ok.out"; fail "happy path: PR-open message must be unchanged"; }
TRACE1="${R1}/.copilot-tracking/issues/issue-20/trace.jsonl"
validate_file "happy-path trace" "$TRACE1"
s1="$(get_pr_span "happy path" "$TRACE1")"
check_pr_span "happy path" "$s1" pass
child_tools="$(jq -r 'select(.span == "tool") | .["gen_ai.tool.name"]' "$TRACE1")"
[ -z "$child_tools" ] \
  || fail "happy path: child gate spans must collapse into pr_create, found: ${child_tools}"
printf '%s\n' "$s1" | jq -e '
    ((.["harness.pr_number"] | tostring) == "123")
    and (.["harness.branch"] == "feature/issue-20-fixture")
    and (.["harness.issue"] == 20)
  ' >/dev/null \
  || fail "happy path: pr_create pass span must carry harness.pr_number=123 and harness.branch (branch-resolved issue 20): ${s1}"

# ============================================================================
# 2. Missing review approval → fail span harness.stage=review_gate
# ============================================================================
R2="${TMP_DIR}/r21"
make_pr_repo "$R2" 21 1
if run_cpr "$R2" 21 "${TMP_DIR}/cpr-gate.out" --title "t" --body "b"; then
  cat "${TMP_DIR}/cpr-gate.out"; fail "unapproved HEAD: create-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -q "has not been approved" "${TMP_DIR}/cpr-gate.out" \
  || { cat "${TMP_DIR}/cpr-gate.out"; fail "unapproved HEAD: gate message must be unchanged"; }
git -C "$R2" ls-remote --heads origin "feature/issue-21-fixture" | grep -q . \
  && fail "unapproved HEAD: branch must not be pushed (existing ordering invariant)"
TRACE2="${R2}/.copilot-tracking/issues/issue-21/trace.jsonl"
validate_file "gate-fail trace" "$TRACE2"
s2="$(get_pr_span "gate fail" "$TRACE2")"
check_pr_span "gate fail" "$s2" fail review_gate

# ============================================================================
# 3. Rebase conflict → fail span harness.stage=rebase
# ============================================================================
R3="${TMP_DIR}/r22"
make_pr_repo "$R3" 22 1
advance_origin_main "$R3"
(cd "$R3" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "setup: approve in rebase-conflict repo failed"
if run_cpr "$R3" 22 "${TMP_DIR}/cpr-rebase.out" --title "t" --body "b"; then
  cat "${TMP_DIR}/cpr-rebase.out"; fail "rebase conflict: create-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -q "hit conflicts" "${TMP_DIR}/cpr-rebase.out" \
  || { cat "${TMP_DIR}/cpr-rebase.out"; fail "rebase conflict: conflict message must be unchanged"; }
TRACE3="${R3}/.copilot-tracking/issues/issue-22/trace.jsonl"
validate_file "rebase-fail trace" "$TRACE3"
s3="$(get_pr_span "rebase fail" "$TRACE3")"
check_pr_span "rebase fail" "$s3" fail rebase

# ============================================================================
# 4. gh pr create failure → fail span harness.stage=pr_create
# ============================================================================
R4="${TMP_DIR}/r23"
make_pr_repo "$R4" 23 1
(cd "$R4" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "setup: approve in gh-fail repo failed"
if (cd "$R4" && PATH="$BIN" GH_STATE="${TMP_DIR}/gh-state-23" GH_LOG="${TMP_DIR}/gh-log-23" GH_CREATE_FAIL=1 \
      ./scripts/create-pr.sh --title "t" --body "b") > "${TMP_DIR}/cpr-ghfail.out" 2>&1; then
  cat "${TMP_DIR}/cpr-ghfail.out"; fail "gh pr create failure: create-pr.sh must still exit non-zero (behavior unchanged)"
fi
TRACE4="${R4}/.copilot-tracking/issues/issue-23/trace.jsonl"
validate_file "gh-fail trace" "$TRACE4"
s4="$(get_pr_span "gh create fail" "$TRACE4")"
check_pr_span "gh create fail" "$s4" fail pr_create

# ============================================================================
# 5. Dirty tree → fail span harness.stage=preconditions
# ============================================================================
R5="${TMP_DIR}/r24"
make_pr_repo "$R5" 24 1
printf 'uncommitted\n' > "${R5}/dirty.txt"
if run_cpr "$R5" 24 "${TMP_DIR}/cpr-dirty.out" --title "t" --body "b"; then
  cat "${TMP_DIR}/cpr-dirty.out"; fail "dirty tree: create-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -q "Working tree is dirty" "${TMP_DIR}/cpr-dirty.out" \
  || { cat "${TMP_DIR}/cpr-dirty.out"; fail "dirty tree: refusal message must be unchanged"; }
TRACE5="${R5}/.copilot-tracking/issues/issue-24/trace.jsonl"
validate_file "dirty-tree trace" "$TRACE5"
s5="$(get_pr_span "dirty tree" "$TRACE5")"
check_pr_span "dirty tree" "$s5" fail preconditions

# ============================================================================
# 6. Refusal on main → exit 1 unchanged, NO emission (issue unresolvable)
# ============================================================================
R6="${TMP_DIR}/r25"
make_pr_repo "$R6" 25 1
git -C "$R6" checkout -q main
if run_cpr "$R6" 25 "${TMP_DIR}/cpr-main.out" --title "t" --body "b"; then
  cat "${TMP_DIR}/cpr-main.out"; fail "on main: create-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -q "Refusing to open a PR from 'main'" "${TMP_DIR}/cpr-main.out" \
  || { cat "${TMP_DIR}/cpr-main.out"; fail "on main: refusal message must be unchanged"; }
[ ! -e "${R6}/.copilot-tracking/issues" ] \
  || fail "on main: no trace may be emitted (no issue is resolvable from branch main)"

# ============================================================================
# 7. Guarded sourcing: trace-lib.sh absent — behavior identical, no emission
# ============================================================================
R7="${TMP_DIR}/r26"
make_pr_repo "$R7" 26 0
[ ! -e "${R7}/scripts/trace-lib.sh" ] || fail "fixture bug: R7 must not contain trace-lib.sh"
if run_cpr "$R7" 26 "${TMP_DIR}/cpr-nolib.out" --title "t" --body "b"; then
  cat "${TMP_DIR}/cpr-nolib.out"; fail "trace-lib absent: unapproved create-pr must still exit 1 (guarded source / no-op fallback, plan D5)"
fi
grep -q "has not been approved" "${TMP_DIR}/cpr-nolib.out" \
  || { cat "${TMP_DIR}/cpr-nolib.out"; fail "trace-lib absent: gate message must be unchanged"; }
[ ! -e "${R7}/.copilot-tracking/issues/issue-26/trace.jsonl" ] \
  || fail "trace-lib absent: no trace file may be created (no-op fallback)"

printf 'create-pr trace emission contract honored\n'
