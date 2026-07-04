#!/usr/bin/env bash
# test_trace_review_gate.sh — regression sensor for review-gate.sh trace
# emission (issue #94, feature trace-review-gate, plan Phase 4).
#
# Contract under test (plan instrumentation table):
#
#   review-gate.sh runs INSIDE the issue worktree on a feature/issue-NN-*
#   branch, so issue resolution is branch-based (no TRACE_ISSUE export) and —
#   per plan D1 — every span lands in the MAIN checkout root's
#   .copilot-tracking/issues/issue-NN/trace.jsonl, not the worktree's.
#
#   Per subcommand (the script exposes approve | check | status-doc, plus
#   help/unknown which are not gate operations and must emit nothing):
#
#   1. `approve`    → ONE LIFECYCLE span, harness.lifecycle_step=
#      review_gate_approve, harness.review_gate_sha == the approved HEAD SHA
#      (string), outcome=pass, numeric harness.exit_status=0 and
#      harness.duration_ms >= 0.
#   2. `check`      → ONE TOOL span, gen_ai.tool.name=review-gate.check
#      (plan-pinned name). Fresh approval + status-doc satisfied → pass/0.
#      Failure paths keep the script's exit 1 and messages unchanged and
#      carry the fail reason: no marker → harness.stage=no_marker; approved
#      SHA != HEAD → harness.stage=stale_head; approval fresh but
#      docs/PROGRESS.md unchanged on the branch → harness.stage=status_doc.
#   3. `status-doc` → ONE TOOL span, gen_ai.tool.name=review-gate.status-doc,
#      pass when docs/PROGRESS.md changed over <base>...HEAD, fail (non-zero
#      numeric exit_status) when not; script behavior unchanged.
#   4. Unknown subcommand → usage + exit 1 unchanged, NO span (not a gate
#      operation — mirrors start-issue's usage-error rule).
#   5. Every emitted line passes the #92 contract filter; with trace-lib.sh
#      absent the script behaves identically and emits nothing (plan D5).
#
# Fixture style follows test_review_gate.sh / test_lifecycle_order.sh:
# throwaway MAIN repo + linked issue worktrees, docs/PROGRESS.md-touching
# commits so the status-doc gate is controlled deliberately, pinned PATH.
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
  || fail "jq is required to validate review-gate trace emission"

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

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }
nth_line() { sed -n "${2}p" "$1"; }

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

# expect_line <label> <trace-file> <expected-count>
# The trace file accumulates one span per gate operation: after each call we
# assert the file grew by exactly one line (or exists at all for line 1).
expect_lines() {
  local label="$1" file="$2" want="$3"
  [ -f "$file" ] \
    || fail "${label}: no span emitted — main-root trace file missing (${file}); review-gate.sh is not instrumented (feature trace-review-gate)"
  [ "$(line_count "$file")" = "$want" ] \
    || fail "${label}: expected exactly ${want} span(s) in ${file}, got $(line_count "$file")"
}

# check_metrics <label> <line> <pass|fail>
check_metrics() {
  local label="$1" line="$2" outcome="$3"
  validate_span "$line" \
    || fail "${label}: span rejected by the contract-driven jq validation filter: ${line}"
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
    || fail "${label}: span must carry harness.outcome=${outcome}, numeric harness.exit_status and harness.duration_ms, numeric harness.issue: ${line}"
}

# Pinned PATH for the scripts under test (real tools + no gh needed).
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Fixture: MAIN repo + linked issue worktrees ---------------------------------
MAIN="${TMP_DIR}/main-repo"
mkdir -p "${MAIN}/scripts" "${MAIN}/docs"
cp "${ROOT}/scripts/review-gate.sh" "${MAIN}/scripts/"
cp "${ROOT}/scripts/trace-lib.sh" "${MAIN}/scripts/"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.name "Harness Test"
git -C "$MAIN" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > "${MAIN}/.gitignore"
printf 'fixture\n' > "${MAIN}/README.md"
printf '# Progress\n\nbaseline\n' > "${MAIN}/docs/PROGRESS.md"
git -C "$MAIN" add .gitignore README.md docs/PROGRESS.md scripts
git -C "$MAIN" commit -q -m initial

# Worktree A (issue 6): docs/PROGRESS.md IS changed on the branch, so the
# status-doc gate passes and only the approval logic varies.
WTA="${TMP_DIR}/wt-issue-06"
git -C "$MAIN" worktree add -q -b feature/issue-06-fixture "$WTA"
printf '# Progress\n\nissue-06 work\n' > "${WTA}/docs/PROGRESS.md"
git -C "$WTA" add docs/PROGRESS.md
git -C "$WTA" commit -q -m "issue-06: progress update"

TRACE_A="${MAIN}/.copilot-tracking/issues/issue-06/trace.jsonl"

run_gate() { # run_gate <worktree> <out-file> <args...>
  local wt="$1" out="$2"; shift 2
  (cd "$wt" && PATH="$BIN" ./scripts/review-gate.sh "$@") > "$out" 2>&1
}

# ============================================================================
# 1. check with NO marker → fail tool span, harness.stage=no_marker
# ============================================================================
if run_gate "$WTA" "${TMP_DIR}/a-check-nomarker.out" check; then
  cat "${TMP_DIR}/a-check-nomarker.out"; fail "unapproved check must still exit 1 (behavior unchanged)"
fi
grep -q "has not been approved" "${TMP_DIR}/a-check-nomarker.out" \
  || { cat "${TMP_DIR}/a-check-nomarker.out"; fail "unapproved check message must be unchanged"; }
expect_lines "check/no-marker" "$TRACE_A" 1
l1="$(nth_line "$TRACE_A" 1)"
check_metrics "check/no-marker" "$l1" fail
printf '%s\n' "$l1" | jq -e '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "review-gate.check")
    and (.["harness.stage"] == "no_marker")
    and (.["harness.issue"] == 6)
  ' >/dev/null \
  || fail "check/no-marker: must be a tool span gen_ai.tool.name=review-gate.check with harness.stage=no_marker, harness.issue=6 (branch-resolved): ${l1}"

# ============================================================================
# 2. approve → review_gate_approve LIFECYCLE span carrying the HEAD SHA
# ============================================================================
head_a="$(git -C "$WTA" rev-parse HEAD)"
run_gate "$WTA" "${TMP_DIR}/a-approve.out" approve \
  || { cat "${TMP_DIR}/a-approve.out"; fail "approve must still exit 0 (behavior unchanged)"; }
grep -q "review approved for current HEAD" "${TMP_DIR}/a-approve.out" \
  || { cat "${TMP_DIR}/a-approve.out"; fail "approve message must be unchanged"; }
expect_lines "approve" "$TRACE_A" 2
l2="$(nth_line "$TRACE_A" 2)"
check_metrics "approve" "$l2" pass
printf '%s\n' "$l2" | jq -e --arg sha "$head_a" '
    (.span == "lifecycle")
    and (.["harness.lifecycle_step"] == "review_gate_approve")
    and (.["harness.review_gate_sha"] == $sha)
    and ((.["harness.review_gate_sha"] | type) == "string")
  ' >/dev/null \
  || fail "approve: must be a lifecycle span review_gate_approve with harness.review_gate_sha == approved HEAD ${head_a}: ${l2}"

# The span must land at the MAIN root, never inside the worktree (plan D1).
[ ! -e "${WTA}/.copilot-tracking/issues/issue-06/trace.jsonl" ] \
  || fail "spans from the worktree must land at the MAIN root, not ${WTA}/.copilot-tracking (plan D1)"

# ============================================================================
# 3. check with FRESH approval (+ status-doc satisfied) → pass tool span
# ============================================================================
run_gate "$WTA" "${TMP_DIR}/a-check-ok.out" check \
  || { cat "${TMP_DIR}/a-check-ok.out"; fail "freshly-approved check must still exit 0 (behavior unchanged)"; }
expect_lines "check/fresh" "$TRACE_A" 3
l3="$(nth_line "$TRACE_A" 3)"
check_metrics "check/fresh" "$l3" pass
printf '%s\n' "$l3" | jq -e '
    (.span == "tool") and (.["gen_ai.tool.name"] == "review-gate.check")
  ' >/dev/null \
  || fail "check/fresh: must be a pass tool span gen_ai.tool.name=review-gate.check: ${l3}"

# ============================================================================
# 4. check after HEAD moved → fail tool span, harness.stage=stale_head
# ============================================================================
printf 'more\n' > "${WTA}/feature.txt"
git -C "$WTA" add feature.txt
git -C "$WTA" commit -q -m "issue-06: new head"
if run_gate "$WTA" "${TMP_DIR}/a-check-stale.out" check; then
  cat "${TMP_DIR}/a-check-stale.out"; fail "stale-HEAD check must still exit 1 (behavior unchanged)"
fi
grep -q "has not been approved" "${TMP_DIR}/a-check-stale.out" \
  || { cat "${TMP_DIR}/a-check-stale.out"; fail "stale-HEAD check message must be unchanged"; }
expect_lines "check/stale" "$TRACE_A" 4
l4="$(nth_line "$TRACE_A" 4)"
check_metrics "check/stale" "$l4" fail
printf '%s\n' "$l4" | jq -e '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "review-gate.check")
    and (.["harness.stage"] == "stale_head")
  ' >/dev/null \
  || fail "check/stale: fail tool span must carry harness.stage=stale_head: ${l4}"

# ============================================================================
# 5. status-doc subcommand (satisfied) → pass tool span review-gate.status-doc
# ============================================================================
run_gate "$WTA" "${TMP_DIR}/a-statusdoc.out" status-doc \
  || { cat "${TMP_DIR}/a-statusdoc.out"; fail "satisfied status-doc must still exit 0 (behavior unchanged)"; }
expect_lines "status-doc/pass" "$TRACE_A" 5
l5="$(nth_line "$TRACE_A" 5)"
check_metrics "status-doc/pass" "$l5" pass
printf '%s\n' "$l5" | jq -e '
    (.span == "tool") and (.["gen_ai.tool.name"] == "review-gate.status-doc")
  ' >/dev/null \
  || fail "status-doc/pass: must be a pass tool span gen_ai.tool.name=review-gate.status-doc: ${l5}"

# ============================================================================
# 6. Unknown subcommand → usage + exit 1, NO span (not a gate operation)
# ============================================================================
if run_gate "$WTA" "${TMP_DIR}/a-bogus.out" bogus; then
  cat "${TMP_DIR}/a-bogus.out"; fail "unknown subcommand must still exit 1 (behavior unchanged)"
fi
grep -q "Usage:" "${TMP_DIR}/a-bogus.out" \
  || { cat "${TMP_DIR}/a-bogus.out"; fail "unknown subcommand must still print usage"; }
expect_lines "after unknown subcommand" "$TRACE_A" 5

# ============================================================================
# 7. Worktree B (issue 8): PROGRESS.md NOT changed on the branch
#    status-doc → fail tool span; approved-but-status-doc-failing check →
#    fail tool span with harness.stage=status_doc
# ============================================================================
WTB="${TMP_DIR}/wt-issue-08"
git -C "$MAIN" worktree add -q -b feature/issue-08-nodoc "$WTB"
printf 'no doc update\n' > "${WTB}/feature.txt"
git -C "$WTB" add feature.txt
git -C "$WTB" commit -q -m "issue-08: no progress update"
TRACE_B="${MAIN}/.copilot-tracking/issues/issue-08/trace.jsonl"

if run_gate "$WTB" "${TMP_DIR}/b-statusdoc.out" status-doc; then
  cat "${TMP_DIR}/b-statusdoc.out"; fail "unsatisfied status-doc must still exit 1 (behavior unchanged)"
fi
grep -q "was not updated on this branch" "${TMP_DIR}/b-statusdoc.out" \
  || { cat "${TMP_DIR}/b-statusdoc.out"; fail "status-doc failure message must be unchanged"; }
expect_lines "status-doc/fail" "$TRACE_B" 1
b1="$(nth_line "$TRACE_B" 1)"
check_metrics "status-doc/fail" "$b1" fail
printf '%s\n' "$b1" | jq -e '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "review-gate.status-doc")
    and (.["harness.issue"] == 8)
  ' >/dev/null \
  || fail "status-doc/fail: must be a fail tool span gen_ai.tool.name=review-gate.status-doc for issue 8: ${b1}"

run_gate "$WTB" "${TMP_DIR}/b-approve.out" approve \
  || { cat "${TMP_DIR}/b-approve.out"; fail "approve in worktree B must still exit 0"; }
expect_lines "approve (B)" "$TRACE_B" 2

if run_gate "$WTB" "${TMP_DIR}/b-check.out" check; then
  cat "${TMP_DIR}/b-check.out"; fail "approved check must still exit 1 when the status-doc gate fails (behavior unchanged)"
fi
expect_lines "check/status-doc-fail" "$TRACE_B" 3
b3="$(nth_line "$TRACE_B" 3)"
check_metrics "check/status-doc-fail" "$b3" fail
printf '%s\n' "$b3" | jq -e '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "review-gate.check")
    and (.["harness.stage"] == "status_doc")
  ' >/dev/null \
  || fail "check/status-doc-fail: fail tool span must carry harness.stage=status_doc: ${b3}"

# ============================================================================
# 8. Guarded sourcing: trace-lib.sh absent — behavior identical, no emission
# ============================================================================
R3="${TMP_DIR}/r3"
mkdir -p "${R3}/scripts" "${R3}/docs"
cp "${ROOT}/scripts/review-gate.sh" "${R3}/scripts/"
git -C "$R3" init -q -b feature/issue-09-nolib
git -C "$R3" config user.name "Harness Test"
git -C "$R3" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > "${R3}/.gitignore"
printf '# Progress\n\nbaseline\n' > "${R3}/docs/PROGRESS.md"
git -C "$R3" add .gitignore docs/PROGRESS.md scripts
git -C "$R3" commit -q -m initial
[ ! -e "${R3}/scripts/trace-lib.sh" ] || fail "fixture bug: R3 must not contain trace-lib.sh"

(cd "$R3" && PATH="$BIN" ./scripts/review-gate.sh approve) > "${TMP_DIR}/r3-approve.out" 2>&1 \
  || { cat "${TMP_DIR}/r3-approve.out"; fail "trace-lib absent: approve must still exit 0 (guarded source / no-op fallback, plan D5)"; }
grep -q "review approved for current HEAD" "${TMP_DIR}/r3-approve.out" \
  || { cat "${TMP_DIR}/r3-approve.out"; fail "trace-lib absent: approve message must be unchanged"; }
[ ! -e "${R3}/.copilot-tracking/issues/issue-09/trace.jsonl" ] \
  || fail "trace-lib absent: no trace file may be created (no-op fallback)"

printf 'review-gate trace emission contract honored\n'
