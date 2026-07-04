#!/usr/bin/env bash
# test_trace_lib_mainroot.sh — regression sensor for scripts/trace-lib.sh
# main-root pinning, trace_now_ms, and harness.* numeric typing
# (issue #94, feature trace-lib-mainroot, plan Phase 1 / decisions D1 + D4).
#
# Contract under test:
#
#   1. MAIN-ROOT PINNING (plan D1): sourcing trace-lib.sh INSIDE a linked
#      git worktree and calling trace_span writes the span to the MAIN
#      checkout root's .copilot-tracking/issues/issue-NN/trace.jsonl — NOT
#      to the worktree's own toplevel — while harness.issue still resolves
#      from the worktree's feature/issue-NN-* branch name. This is what
#      lets finish-issue.sh emit its `finish` span after worktree teardown.
#   2. PLAIN-REPO BEHAVIOR UNCHANGED: in a plain (non-linked) repo,
#      dirname(git-common-dir) == toplevel, so trace_span keeps writing to
#      that repo's own root exactly as today.
#   3. trace_now_ms: the library defines a trace_now_ms helper printing
#      integer epoch MILLISECONDS (not seconds); two successive calls are
#      monotone-ish (second >= first).
#   4. NUMERIC TYPING EXTENSION (plan D4): integer-looking values for
#      harness.exit_status, harness.duration_ms and harness.incomplete_count
#      serialize as JSON numbers, while other harness.* free text (e.g.
#      harness.stage=push) stays a JSON string.
#   5. Every emitted line passes the contract-driven jq validation filter
#      lifted verbatim from test_trace_schema.sh (issue #92 contract).
#
# Fixture style follows test_trace_lib.sh: throwaway git repos under
# mktemp -d, trace-lib copied in and committed, sourced under strict mode.
#
# Exit codes: 0 main-root contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# jq drives both the emitter (plan D4) and the contract validation filter, so
# hard-require it the way test_trace_schema.sh does.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace-lib main-root span emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB})"

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

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }

nth_line() { sed -n "${2}p" "$1"; }

# Validate every line of one trace file against the #92 contract filter.
validate_file() {
  local label="$1" file="$2" n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    validate_span "$line" \
      || fail "${label}: line ${n} rejected by the contract-driven jq validation filter: ${line}"
  done < "$file"
  [ "$n" -gt 0 ] || fail "${label}: trace file is empty (${file})"
}

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Fixture A: MAIN repo + LINKED WORKTREE -------------------------------------
# trace-lib.sh is committed in the main repo so the linked worktree shares it
# via git (real deployment shape: one scripts/ tree, many worktrees).
MAIN="${TMP_DIR}/main-repo"
WT="${TMP_DIR}/wt"
mkdir -p "${MAIN}/scripts"
cp "$LIB" "${MAIN}/scripts/trace-lib.sh"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.name "Harness Test"
git -C "$MAIN" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${MAIN}/README.md"
git -C "$MAIN" add README.md scripts/trace-lib.sh
git -C "$MAIN" commit -q -m initial
git -C "$MAIN" worktree add -q -b feature/issue-05-fixture "$WT" \
  || fail "fixture: could not create linked worktree at ${WT}"
[ -f "${WT}/scripts/trace-lib.sh" ] \
  || fail "fixture: linked worktree does not share scripts/trace-lib.sh"

MAIN_TRACE="${MAIN}/.copilot-tracking/issues/issue-05/trace.jsonl"
WT_TRACE="${WT}/.copilot-tracking/issues/issue-05/trace.jsonl"

# --- 1. Spans emitted FROM the linked worktree land at the MAIN root ------------
# Source inside the worktree (exactly how review-gate/create-pr/merge-pr run)
# and emit one lifecycle span + one tool span carrying the D4-typed attrs.
(
  cd "$WT"
  # shellcheck source=/dev/null
  source "./scripts/trace-lib.sh"
  trace_span lifecycle \
    "harness.lifecycle_step=preflight" \
    "harness.outcome=pass" \
    "harness.exit_status=0" \
    "harness.duration_ms=123"
  trace_span tool \
    "gen_ai.tool.name=check-feature-list" \
    "harness.outcome=pass" \
    "harness.exit_status=0" \
    "harness.duration_ms=123" \
    "harness.incomplete_count=2" \
    "harness.stage=push"
) || fail "sourcing trace-lib.sh and calling trace_span inside the linked worktree returned non-zero"

[ ! -e "$WT_TRACE" ] \
  || fail "main-root pinning (plan D1): trace_span called from a linked worktree must NOT write to the worktree's own root (found ${WT_TRACE})"
[ -f "$MAIN_TRACE" ] \
  || fail "main-root pinning (plan D1): trace_span called from a linked worktree must write to the MAIN checkout root (${MAIN_TRACE} missing)"
[ "$(line_count "$MAIN_TRACE")" = "2" ] \
  || fail "expected exactly 2 spans in the main-root trace file, got $(line_count "$MAIN_TRACE")"

# harness.issue still resolves from the WORKTREE's branch name (issue 5).
jq -e '(.["harness.issue"] == 5) and ((.["harness.issue"] | type) == "number")' \
  "$MAIN_TRACE" >/dev/null \
  || fail "spans emitted from the worktree must stamp harness.issue=5 (JSON number) from the feature/issue-05-* branch name"

validate_file "worktree-emitted main-root trace" "$MAIN_TRACE"

# --- 2. Plain-repo behavior unchanged --------------------------------------------
# In a plain (non-linked) repo, dirname(git-common-dir) == toplevel: spans keep
# landing at that repo's own root, exactly as every existing trace-lib fixture.
PLAIN="${TMP_DIR}/plain-repo"
mkdir -p "${PLAIN}/scripts"
cp "$LIB" "${PLAIN}/scripts/trace-lib.sh"
git -C "$PLAIN" init -q -b main
git -C "$PLAIN" config user.name "Harness Test"
git -C "$PLAIN" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${PLAIN}/README.md"
git -C "$PLAIN" add README.md scripts/trace-lib.sh
git -C "$PLAIN" commit -q -m initial
git -C "$PLAIN" checkout -q -b feature/issue-07-plain-fixture

PLAIN_TRACE="${PLAIN}/.copilot-tracking/issues/issue-07/trace.jsonl"
(
  cd "$PLAIN"
  # shellcheck source=/dev/null
  source "./scripts/trace-lib.sh"
  trace_span lifecycle "harness.lifecycle_step=preflight" "harness.outcome=pass"
) || fail "trace_span in a plain repo returned non-zero"

[ -f "$PLAIN_TRACE" ] \
  || fail "plain-repo behavior regressed: trace_span must keep writing to the plain repo's own root (${PLAIN_TRACE} missing)"
[ "$(line_count "$PLAIN_TRACE")" = "1" ] \
  || fail "plain-repo call must append exactly one line, got $(line_count "$PLAIN_TRACE")"
jq -e '(.["harness.issue"] == 7) and ((.["harness.issue"] | type) == "number")' \
  "$PLAIN_TRACE" >/dev/null \
  || fail "plain-repo span must stamp harness.issue=7 from the feature/issue-07-* branch name"
validate_file "plain-repo trace" "$PLAIN_TRACE"

# --- 3. trace_now_ms: integer milliseconds, monotone-ish -------------------------
now_out="$(
  cd "$PLAIN"
  # shellcheck source=/dev/null
  source "./scripts/trace-lib.sh"
  declare -F trace_now_ms >/dev/null 2>&1 || exit 9
  t1="$(trace_now_ms)"
  t2="$(trace_now_ms)"
  printf '%s %s' "$t1" "$t2"
)" || fail "trace-lib.sh must define a trace_now_ms function (millisecond clock helper, plan Phase 1)"
read -r t1 t2 <<< "$now_out"
if ! [[ "$t1" =~ ^[0-9]+$ ]] || ! [[ "$t2" =~ ^[0-9]+$ ]]; then
  fail "trace_now_ms must print a bare integer, got '${t1}' / '${t2}'"
fi
# Epoch milliseconds are 13 digits in this era; 10 digits would mean seconds.
[ "${#t1}" -ge 13 ] \
  || fail "trace_now_ms must return MILLISECONDS since epoch (>= 13 digits), got '${t1}' — looks like seconds"
[ "$t2" -ge "$t1" ] \
  || fail "trace_now_ms must be monotone-ish: second call ${t2} < first call ${t1}"

# --- 4. Numeric typing extension (plan D4) ----------------------------------------
# harness.exit_status / harness.duration_ms / harness.incomplete_count must be
# JSON numbers; harness.stage free text must stay a JSON string.
lifecycle_line="$(nth_line "$MAIN_TRACE" 1)"
printf '%s\n' "$lifecycle_line" | jq -e '
    ((.["harness.exit_status"] | type) == "number")
    and (.["harness.exit_status"] == 0)
    and ((.["harness.duration_ms"] | type) == "number")
    and (.["harness.duration_ms"] == 123)
  ' >/dev/null \
  || fail "numeric typing (plan D4): harness.exit_status=0 and harness.duration_ms=123 must serialize as JSON numbers on the lifecycle span: ${lifecycle_line}"

tool_line="$(nth_line "$MAIN_TRACE" 2)"
printf '%s\n' "$tool_line" | jq -e '
    ((.["harness.exit_status"] | type) == "number")
    and (.["harness.exit_status"] == 0)
    and ((.["harness.duration_ms"] | type) == "number")
    and (.["harness.duration_ms"] == 123)
    and ((.["harness.incomplete_count"] | type) == "number")
    and (.["harness.incomplete_count"] == 2)
  ' >/dev/null \
  || fail "numeric typing (plan D4): harness.exit_status/harness.duration_ms/harness.incomplete_count must serialize as JSON numbers on the tool span: ${tool_line}"
printf '%s\n' "$tool_line" | jq -e '
    (.["harness.stage"] == "push") and ((.["harness.stage"] | type) == "string")
  ' >/dev/null \
  || fail "numeric typing (plan D4): non-integer harness.* free text like harness.stage=push must STAY a JSON string: ${tool_line}"

printf 'trace-lib main-root pinning, trace_now_ms and numeric typing contract honored\n'
