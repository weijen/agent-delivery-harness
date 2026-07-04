#!/usr/bin/env bash
# test_trace_merge_pr.sh — regression sensor for merge-pr.sh trace emission
# (issue #94, feature trace-merge-pr, plan Phase 6).
#
# Contract under test (plan instrumentation table, decision D3):
#
#   merge-pr.sh emits exactly ONE `pr_merge` LIFECYCLE terminal span per
#   invocation via a stage-tracked EXIT trap, carrying harness.outcome,
#   NUMERIC harness.exit_status / harness.duration_ms, harness.pr_number,
#   and — on failure — harness.stage naming the failing sub-step
#   (resolve_pr|ci_checks|merge|done). It runs inside the issue worktree on
#   a feature/issue-NN-* branch → branch-resolved issue, main-root trace
#   file (plan D1).
#
#   1. Green checks + merge ok  → pass span, exit_status=0, pr_number=123;
#      script exit 0 and merge sentinel written (behavior unchanged).
#   2. `gh pr checks` exits 1 (CI red/pending) → fail span
#      harness.stage=ci_checks, non-zero exit_status; refusal + exit 1
#      unchanged, no merge attempted.
#   3. Zero checks reported (rc 0, empty output) → fail span
#      harness.stage=ci_checks (the CI gate is what refused); exit 1 and
#      no merge, unchanged.
#   4. No open PR (`gh pr view` fails) → fail span harness.stage=resolve_pr.
#   5. `gh pr merge` fails → fail span harness.stage=merge.
#   6. Stray positional arg → usage refusal + exit 1 unchanged, NO span
#      (rejected before any stage begins — mirrors the usage-error rule).
#   7. Every emitted line passes the #92 contract filter; with trace-lib.sh
#      absent behavior is identical and nothing is emitted (plan D5).
#
# Fixture style follows test_merge_pr_ci_gate.sh (env-driven fake gh with a
# merge sentinel) on per-case plain repos, pinned PATH.
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
  || fail "jq is required to validate merge-pr trace emission"

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
  [ -f "$file" ] \
    || fail "${label}: main-root trace file missing (${file}) — merge-pr.sh is not instrumented (feature trace-merge-pr)"
  while IFS= read -r line; do
    n=$((n + 1))
    validate_span "$line" \
      || fail "${label}: line ${n} rejected by the contract-driven jq validation filter: ${line}"
  done < "$file"
}

# get_merge_span <label> <trace-file> — exactly ONE pr_merge lifecycle span.
get_merge_span() {
  local label="$1" file="$2" spans count
  [ -f "$file" ] \
    || fail "${label}: main-root trace file missing (${file}) — merge-pr.sh is not instrumented (feature trace-merge-pr)"
  spans="$(jq -c 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "pr_merge")' "$file")"
  count="$(printf '%s' "$spans" | grep -c . || true)"
  [ "$count" = "1" ] \
    || fail "${label}: expected exactly ONE pr_merge lifecycle span per invocation, found ${count} in ${file} — merge-pr.sh is not instrumented (feature trace-merge-pr)"
  printf '%s' "$spans"
}

# check_merge_span <label> <line> <pass|fail> [expected-stage]
check_merge_span() {
  local label="$1" line="$2" outcome="$3" stage="${4:-}"
  validate_span "$line" \
    || fail "${label}: pr_merge span rejected by the contract filter: ${line}"
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
    || fail "${label}: pr_merge span must carry harness.outcome=${outcome}, numeric harness.exit_status/duration_ms, numeric harness.issue: ${line}"
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

# Fake gh (test_merge_pr_ci_gate.sh precedent): pr view exits FAKE_PR_VIEW_RC,
# pr checks echoes FAKE_CHECKS_OUT and exits FAKE_CHECKS_RC, pr merge records
# a sentinel and exits FAKE_MERGE_RC.
cat > "${TMP_DIR}/gh-src" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
case "$1 ${2:-}" in
  "pr view")
    [ "${FAKE_PR_VIEW_RC:-0}" = "0" ] || exit "${FAKE_PR_VIEW_RC}"
    echo "${FAKE_PR_NUMBER:-123}"
    exit 0
    ;;
  "pr checks")
    [ -n "${FAKE_CHECKS_OUT:-}" ] && printf '%s\n' "$FAKE_CHECKS_OUT"
    exit "${FAKE_CHECKS_RC:-0}"
    ;;
  "pr merge")
    printf '%s\n' "$*" >> "${MERGE_SENTINEL:?}"
    exit "${FAKE_MERGE_RC:-0}"
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc
cp "${TMP_DIR}/gh-src" "${BIN}/gh"
chmod +x "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# make_merge_repo <dir> <issue-pad> <with_trace_lib:0|1> — plain repo on a
# feature/issue-<PAD>-fixture branch with merge-pr.sh (+ optional trace-lib).
make_merge_repo() {
  local dir="$1" pad="$2" with_lib="$3"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/merge-pr.sh" "${dir}/scripts/"
  if [ "$with_lib" = "1" ]; then
    cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  fi
  git -C "$dir" init -q -b "feature/issue-${pad}-fixture"
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
}

# run_merge <dir> <sentinel> <out-file> [env pairs prefixed]... — callers set
# FAKE_* in the environment of the call.
run_merge() {
  local dir="$1" sentinel="$2" out="$3"; shift 3
  rm -f "$sentinel"
  (cd "$dir" && PATH="$BIN" MERGE_SENTINEL="$sentinel" ./scripts/merge-pr.sh "$@") > "$out" 2>&1
}

# ============================================================================
# 1. Green checks + merge ok → ONE pr_merge pass span with pr_number
# ============================================================================
R1="${TMP_DIR}/r30"
make_merge_repo "$R1" 30 1
FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='harness-smoke  pass  1m' \
  run_merge "$R1" "${TMP_DIR}/s1.log" "${TMP_DIR}/m-ok.out" \
  || { cat "${TMP_DIR}/m-ok.out"; fail "green checks: merge-pr.sh must still exit 0 (behavior unchanged)"; }
[ -f "${TMP_DIR}/s1.log" ] || fail "green checks: gh pr merge must still be called (behavior unchanged)"
TRACE1="${R1}/.copilot-tracking/issues/issue-30/trace.jsonl"
validate_file "green-merge trace" "$TRACE1"
m1="$(get_merge_span "green merge" "$TRACE1")"
check_merge_span "green merge" "$m1" pass
printf '%s\n' "$m1" | jq -e '
    ((.["harness.pr_number"] | tostring) == "123") and (.["harness.issue"] == 30)
  ' >/dev/null \
  || fail "green merge: pass span must carry harness.pr_number=123 (branch-resolved issue 30): ${m1}"

# ============================================================================
# 2. CI red (gh pr checks exits 1) → fail span harness.stage=ci_checks
# ============================================================================
R2="${TMP_DIR}/r31"
make_merge_repo "$R2" 31 1
if FAKE_CHECKS_RC=1 FAKE_CHECKS_OUT='harness-smoke  fail' \
    run_merge "$R2" "${TMP_DIR}/s2.log" "${TMP_DIR}/m-red.out"; then
  cat "${TMP_DIR}/m-red.out"; fail "CI red: merge-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -Eiq 'checks are not green' "${TMP_DIR}/m-red.out" \
  || { cat "${TMP_DIR}/m-red.out"; fail "CI red: refusal message must be unchanged"; }
[ ! -f "${TMP_DIR}/s2.log" ] || fail "CI red: gh pr merge must NOT be called (behavior unchanged)"
TRACE2="${R2}/.copilot-tracking/issues/issue-31/trace.jsonl"
validate_file "ci-red trace" "$TRACE2"
m2="$(get_merge_span "CI red" "$TRACE2")"
check_merge_span "CI red" "$m2" fail ci_checks

# ============================================================================
# 3. Zero checks reported (rc 0, empty) → fail span harness.stage=ci_checks
# ============================================================================
R3="${TMP_DIR}/r32"
make_merge_repo "$R3" 32 1
if FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='' \
    run_merge "$R3" "${TMP_DIR}/s3.log" "${TMP_DIR}/m-zero.out"; then
  cat "${TMP_DIR}/m-zero.out"; fail "zero checks: merge-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -Eiq 'checks are not green' "${TMP_DIR}/m-zero.out" \
  || { cat "${TMP_DIR}/m-zero.out"; fail "zero checks: refusal message must be unchanged"; }
[ ! -f "${TMP_DIR}/s3.log" ] || fail "zero checks: gh pr merge must NOT be called"
TRACE3="${R3}/.copilot-tracking/issues/issue-32/trace.jsonl"
validate_file "zero-checks trace" "$TRACE3"
m3="$(get_merge_span "zero checks" "$TRACE3")"
check_merge_span "zero checks" "$m3" fail ci_checks

# ============================================================================
# 4. No open PR (gh pr view fails) → fail span harness.stage=resolve_pr
# ============================================================================
R4="${TMP_DIR}/r33"
make_merge_repo "$R4" 33 1
if FAKE_PR_VIEW_RC=1 \
    run_merge "$R4" "${TMP_DIR}/s4.log" "${TMP_DIR}/m-nopr.out"; then
  cat "${TMP_DIR}/m-nopr.out"; fail "no PR: merge-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -q "No open PR found" "${TMP_DIR}/m-nopr.out" \
  || { cat "${TMP_DIR}/m-nopr.out"; fail "no PR: refusal message must be unchanged"; }
TRACE4="${R4}/.copilot-tracking/issues/issue-33/trace.jsonl"
validate_file "no-pr trace" "$TRACE4"
m4="$(get_merge_span "no PR" "$TRACE4")"
check_merge_span "no PR" "$m4" fail resolve_pr

# ============================================================================
# 5. gh pr merge fails → fail span harness.stage=merge
# ============================================================================
R5="${TMP_DIR}/r34"
make_merge_repo "$R5" 34 1
if FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='harness-smoke  pass  1m' FAKE_MERGE_RC=1 \
    run_merge "$R5" "${TMP_DIR}/s5.log" "${TMP_DIR}/m-mergefail.out"; then
  cat "${TMP_DIR}/m-mergefail.out"; fail "merge failure: merge-pr.sh must still exit non-zero (behavior unchanged)"
fi
TRACE5="${R5}/.copilot-tracking/issues/issue-34/trace.jsonl"
validate_file "merge-fail trace" "$TRACE5"
m5="$(get_merge_span "merge fail" "$TRACE5")"
check_merge_span "merge fail" "$m5" fail merge

# ============================================================================
# 6. Stray positional arg → usage refusal, exit 1 unchanged, NO span
# ============================================================================
R6="${TMP_DIR}/r35"
make_merge_repo "$R6" 35 1
if FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='harness-smoke  pass  1m' \
    run_merge "$R6" "${TMP_DIR}/s6.log" "${TMP_DIR}/m-stray.out" 73; then
  cat "${TMP_DIR}/m-stray.out"; fail "stray positional arg: merge-pr.sh must still exit 1 (behavior unchanged)"
fi
grep -q "unexpected positional argument" "${TMP_DIR}/m-stray.out" \
  || { cat "${TMP_DIR}/m-stray.out"; fail "stray positional arg: refusal message must be unchanged"; }
[ ! -f "${TMP_DIR}/s6.log" ] || fail "stray positional arg: gh pr merge must NOT be called"
[ ! -e "${R6}/.copilot-tracking/issues/issue-35/trace.jsonl" ] \
  || fail "stray positional arg: usage refusal happens before any stage — NO span may be emitted"

# ============================================================================
# 7. Guarded sourcing: trace-lib.sh absent — behavior identical, no emission
# ============================================================================
R7="${TMP_DIR}/r36"
make_merge_repo "$R7" 36 0
[ ! -e "${R7}/scripts/trace-lib.sh" ] || fail "fixture bug: R7 must not contain trace-lib.sh"
if FAKE_PR_VIEW_RC=1 \
    run_merge "$R7" "${TMP_DIR}/s7.log" "${TMP_DIR}/m-nolib.out"; then
  cat "${TMP_DIR}/m-nolib.out"; fail "trace-lib absent: no-PR refusal must still exit 1 (guarded source / no-op fallback, plan D5)"
fi
grep -q "No open PR found" "${TMP_DIR}/m-nolib.out" \
  || { cat "${TMP_DIR}/m-nolib.out"; fail "trace-lib absent: refusal message must be unchanged"; }
[ ! -e "${R7}/.copilot-tracking/issues/issue-36/trace.jsonl" ] \
  || fail "trace-lib absent: no trace file may be created (no-op fallback)"

printf 'merge-pr trace emission contract honored\n'
