#!/usr/bin/env bash
# test_validate_trace_completeness.sh — regression sensor for the finished-run
# lifecycle completeness pass in scripts/validate-trace.sh (issue #97,
# feature validate-trace-completeness, plan Phase 2 / D3).
#
# Executable spec, pinned here:
#
#   1. The completeness pass runs ONLY when the trace contains a `finish`
#      lifecycle step (a finished run). An unfinished, otherwise-valid trace
#      is NOT a violation: exit stays 0 with zero VIOLATION findings
#      (an informational note is allowed but not required by this sensor).
#   2. For a finished run, all 12 non-deviation contract lifecycle steps —
#      preflight, worktree_create, plan_handback, feature_start,
#      red_handback, impl_handback, green_handback, review_verdict,
#      review_gate_approve, pr_create, pr_merge, finish — must each appear
#      at least once. `deviation` is exceptional-path-only, never required.
#   3. Steps are counted via harness.lifecycle_step ACROSS ALL SPAN TYPES:
#      log-handback.sh rides lifecycle steps on AGENT spans, so a finished
#      trace whose plan/red/impl/green/review_verdict steps exist only on
#      agent spans is complete. Counting only span=="lifecycle" would flag
#      every real trace — the all-steps fixture makes 6 steps agent-only to
#      force cross-span counting.
#   4. Duplicates are legal (real issue-96 trace carries pr_merge x11); the
#      all-steps fixture duplicates pr_merge x3.
#   5. Finding format, pinned exactly (whole-trace finding, NO line number):
#          VIOLATION completeness: missing lifecycle step <step>
#      One finding per missing step; steps that ARE present must not be
#      named. A missing step drives exit 1.
#
# Fixtures are hand-written schema-valid JSONL (path mode), so any violation
# the validator reports is attributable to the completeness pass alone.
#
# Exit codes: 0 completeness contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the validator and this sensor are jq-driven)"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"
[ -x "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh not found or not executable (${VALIDATOR}) — the validator core (feature validate-trace-schema-core) must exist before the completeness pass can be specified"

# --- Span line builders (schema-valid by construction) --------------------------
# Lifecycle steps ride BOTH lifecycle spans and agent spans (log-handback
# shape) so the sensor forces cross-span-type counting.
lc_line() {
  printf '{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"%s"}\n' "$1"
}
ag_line() {
  printf '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"agent","harness.issue":42,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"%s","harness.feature_id":"f1","harness.outcome":"pass"}\n' "$1"
}
tool_noise_line() {
  printf '{"schema_version":1,"timestamp":"2026-07-04T12:00:02Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}\n'
}

# Emit a finished-run trace to stdout, skipping the single step named in $1
# (empty = skip nothing). 6 steps are AGENT-only; pr_merge is duplicated x3;
# a lifecycle-step-free tool span is interleaved as noise.
emit_finished_trace() {
  local skip="${1:-}"
  local lc_steps="preflight worktree_create review_gate_approve pr_create pr_merge pr_merge pr_merge finish"
  local ag_steps="plan_handback feature_start red_handback impl_handback green_handback review_verdict"
  local s
  for s in $lc_steps; do
    if [ "$s" != "$skip" ]; then
      lc_line "$s"
    fi
  done
  tool_noise_line
  for s in $ag_steps; do
    if [ "$s" != "$skip" ]; then
      ag_line "$s"
    fi
  done
}

FINISHED_ALL="${TMP_DIR}/finished_all.jsonl"
emit_finished_trace "" > "$FINISHED_ALL"
FINISHED_NO_RED="${TMP_DIR}/finished_no_red_handback.jsonl"
emit_finished_trace "red_handback" > "$FINISHED_NO_RED"
FINISHED_NO_RGA="${TMP_DIR}/finished_no_review_gate_approve.jsonl"
emit_finished_trace "review_gate_approve" > "$FINISHED_NO_RGA"

UNFINISHED="${TMP_DIR}/unfinished.jsonl"
{
  lc_line "preflight"
  lc_line "worktree_create"
  ag_line "plan_handback"
} > "$UNFINISHED"

# Fixture self-check: every hand-written line must already pass the schema
# core, so completeness is the ONLY rule at stake in these fixtures.
for f in "$FINISHED_ALL" "$FINISHED_NO_RED" "$FINISHED_NO_RGA" "$UNFINISHED"; do
  jq empty "$f" >/dev/null 2>&1 \
    || hard_fail "fixture $(basename "$f") is not valid JSONL — sensor bug"
done

# --- Validator run helper --------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_validator() {
  local rc=0
  "$VALIDATOR" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- 1. Finished run with all 12 steps (6 agent-only, pr_merge x3): clean --------
rc="$(run_validator "$FINISHED_ALL")"
[ "$rc" = "0" ] \
  || fail "finished trace with all 12 non-deviation steps must exit 0 (duplicates legal, agent-span steps counted), got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION' "$OUT" "$ERR"; then
  fail "finished trace with all 12 steps must produce zero VIOLATION findings"
fi

# --- 2. Finished run missing red_handback (an AGENT-only step) --------------------
rc="$(run_validator "$FINISHED_NO_RED")"
[ "$rc" = "1" ] \
  || fail "finished trace missing red_handback must exit 1, got ${rc}"
grep -Fq 'VIOLATION completeness: missing lifecycle step red_handback' "$OUT" \
  || fail "missing red_handback: report must carry exactly 'VIOLATION completeness: missing lifecycle step red_handback' (stdout: $(tr '\n' '|' < "$OUT"))"
[ "$(grep -c 'missing lifecycle step' "$OUT")" = "1" ] \
  || fail "missing red_handback: exactly ONE missing-step finding expected — steps that are present (incl. duplicated pr_merge and agent-span steps) must not be named"

# --- 3. Finished run missing review_gate_approve (a lifecycle-span step) ----------
rc="$(run_validator "$FINISHED_NO_RGA")"
[ "$rc" = "1" ] \
  || fail "finished trace missing review_gate_approve must exit 1, got ${rc}"
grep -Fq 'VIOLATION completeness: missing lifecycle step review_gate_approve' "$OUT" \
  || fail "missing review_gate_approve: report must carry exactly 'VIOLATION completeness: missing lifecycle step review_gate_approve' (stdout: $(tr '\n' '|' < "$OUT"))"
[ "$(grep -c 'missing lifecycle step' "$OUT")" = "1" ] \
  || fail "missing review_gate_approve: exactly ONE missing-step finding expected"

# --- 4. Unfinished run (no finish span): completeness is skipped entirely ---------
rc="$(run_validator "$UNFINISHED")"
[ "$rc" = "0" ] \
  || fail "unfinished trace (no finish step) must exit 0 — completeness runs only for finished runs, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION' "$OUT" "$ERR"; then
  fail "unfinished trace must produce zero VIOLATION findings (completeness skipped, not partially applied)"
fi

# --- Result -----------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d validate-trace completeness contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'validate-trace finished-run completeness contract honored\n'
