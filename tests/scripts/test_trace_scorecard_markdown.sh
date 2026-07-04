#!/usr/bin/env bash
# test_trace_scorecard_markdown.sh — regression + e2e sensor for the human
# markdown report of scripts/trace-scorecard.sh (issue #104, feature
# scorecard-markdown, plan Phase 3).
#
# Executable spec (this sensor IS the spec — plan D5 single-source doctrine).
# Pinned conventions:
#
#   1. Delivery: the markdown report is ALWAYS-ON on stdout (no flag),
#      mirroring trace-report.sh — markdown to stdout, JSON to the stable
#      file, rendered FROM the same scorecard object (single source of
#      numbers: human and machine artifacts can never disagree).
#   2. Shape: a `# ` heading mentioning "scorecard"; a per-version pipe
#      table with the column order
#        version | runs | passed | red-reentry-free | deviations | tool calls | tokens
#      one row per by_version bucket (the mixed bucket visibly labeled
#      "mixed" in the version column).
#   3. Honest rendering: a null tokens bucket renders `n/a` in the tokens
#      cell — NEVER `0`; a data-carrying bucket shows its real input/output
#      sums; red-reentry-free renders as `free/of` (explicit denominator).
#   4. Sections: when inputs.missing_summaries is non-empty, a missing
#      section names each issue dir and the trace-report.sh regeneration
#      hint; when inputs.skipped is non-empty, a skipped section names each
#      skipped file.
#   5. Single source: every table number equals the corresponding field of
#      the written trace-scorecard.json (cross-checked with jq here, not
#      hardcoded twice).
#   6. The JSON artifact keeps being written unchanged; exit stays 0.
#
# Fixture (same shapes the core/honesty sensors pin):
#   issue-10  vA single: runs 1, passed 1, free 1/1, deviations 2,
#             tool calls 5, tokens null → n/a
#   issue-11  [vB, vZ] + trace whose last version-carrying span is vB:
#             runs 1, passed 1, free 0/1, deviations 0, tool calls 4,
#             tokens input 1000 / output 200
#   issue-12  trace.jsonl only → missing section
#   issue-13  [mA, mB] no trace → mixed row in the table
#   issue-14  summary_schema_version 2 → skipped section (lands with
#             feature scorecard-honesty; RED here until both land)
#
# Exit codes: 0 markdown contract honored · 1 an obligation regressed
# (RED today: stdout carries only the "scorecard written" note, no report).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCORECARD_SH="${ROOT}/scripts/trace-scorecard.sh"
SCORECARD_REL="tests/evals/scorecards/trace-scorecard.json"

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
note() {
  printf 'note: %s\n' "$*"
}

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

# --- Prerequisites -----------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the scorecard contract and this sensor are jq-driven)"
[ -f "$SCORECARD_SH" ] \
  || hard_fail "scripts/trace-scorecard.sh not found (${SCORECARD_SH}) — feature scorecard-core must land before its markdown report can be specified"
[ -x "$SCORECARD_SH" ] \
  || hard_fail "scripts/trace-scorecard.sh exists but is not executable (${SCORECARD_SH})"

# --- Fixture main root ---------------------------------------------------------
FX_ROOT="${TMP_DIR}/fixture-root"
ISSUES_DIR="${FX_ROOT}/.copilot-tracking/issues"
mkdir -p "${ISSUES_DIR}/issue-10" "${ISSUES_DIR}/issue-11" \
  "${ISSUES_DIR}/issue-12" "${ISSUES_DIR}/issue-13" "${ISSUES_DIR}/issue-14"

cat > "${ISSUES_DIR}/issue-10/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-10/trace.jsonl",
  "issue": 10,
  "harness_versions": ["vA"],
  "finished": true,
  "final_outcome": "pass",
  "span_counts": {"total": 8, "invalid_lines": 0, "by_type": {"lifecycle": 4, "tool": 4}},
  "wall_clock": {"first_timestamp": "2026-07-04T10:00:00Z", "last_timestamp": "2026-07-04T10:01:40Z", "elapsed_seconds": 100},
  "stages": [{"step": "preflight", "spans": 1, "duration_ms": 50}],
  "tools": [
    {"name": "git", "calls": 3, "fail_calls": 1, "duration_ms": 15},
    {"name": "jq", "calls": 2, "fail_calls": 0, "duration_ms": null}
  ],
  "tokens": null,
  "loop_indicators": [],
  "red_reentry": [],
  "deviations": {"count": 2, "feature_ids": ["feat-a", "feat-b"]}
}
EOF

cat > "${ISSUES_DIR}/issue-11/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-11/trace.jsonl",
  "issue": 11,
  "harness_versions": ["vB", "vZ"],
  "finished": true,
  "final_outcome": "pass",
  "span_counts": {"total": 3, "invalid_lines": 0, "by_type": {"lifecycle": 2, "tool": 1}},
  "wall_clock": {"first_timestamp": "2026-07-04T09:00:00Z", "last_timestamp": "2026-07-04T09:20:00Z", "elapsed_seconds": 1200},
  "stages": [{"step": "preflight", "spans": 1, "duration_ms": null}],
  "tools": [
    {"name": "git", "calls": 4, "fail_calls": 0, "duration_ms": 20}
  ],
  "tokens": {"input": 1000, "output": 200},
  "loop_indicators": [],
  "red_reentry": ["feat-c"],
  "deviations": {"count": 0, "feature_ids": []}
}
EOF
printf '%s\n' \
  '{"schema_version":1,"timestamp":"2026-07-04T09:00:00Z","span":"lifecycle","harness.issue":11,"harness.version":"vZ","harness.lifecycle_step":"preflight"}' \
  '{"schema_version":1,"timestamp":"2026-07-04T09:10:00Z","span":"tool","harness.issue":11,"harness.version":"vB","gen_ai.tool.name":"git","harness.outcome":"pass"}' \
  '{"schema_version":1,"timestamp":"2026-07-04T09:20:00Z","span":"lifecycle","harness.issue":11,"harness.lifecycle_step":"finish","harness.outcome":"pass"}' \
  > "${ISSUES_DIR}/issue-11/trace.jsonl"

printf '%s\n' \
  '{"schema_version":1,"timestamp":"2026-07-04T08:00:00Z","span":"lifecycle","harness.issue":12,"harness.version":"vA","harness.lifecycle_step":"preflight"}' \
  > "${ISSUES_DIR}/issue-12/trace.jsonl"

cat > "${ISSUES_DIR}/issue-13/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-13/trace.jsonl",
  "issue": 13,
  "harness_versions": ["mA", "mB"],
  "finished": false,
  "final_outcome": null,
  "span_counts": {"total": 1, "invalid_lines": 0, "by_type": {"lifecycle": 1}},
  "wall_clock": null,
  "stages": [],
  "tools": [],
  "tokens": null,
  "loop_indicators": [],
  "red_reentry": [],
  "deviations": {"count": 0, "feature_ids": []}
}
EOF

cat > "${ISSUES_DIR}/issue-14/trace-summary.json" <<EOF
{
  "summary_schema_version": 2,
  "trace_file": "${ISSUES_DIR}/issue-14/trace.jsonl",
  "issue": 14,
  "harness_versions": ["vTWO"],
  "finished": true,
  "final_outcome": "pass",
  "span_counts": {"total": 1, "invalid_lines": 0, "by_type": {"lifecycle": 1}},
  "wall_clock": null,
  "stages": [],
  "tools": [],
  "tokens": null,
  "loop_indicators": [],
  "red_reentry": [],
  "deviations": {"count": 0, "feature_ids": []}
}
EOF

# --- Run -----------------------------------------------------------------------
OUT_MD="${TMP_DIR}/stdout.md"
rc=0
"$SCORECARD_SH" --root "$FX_ROOT" > "$OUT_MD" 2> "${TMP_DIR}/stderr.txt" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "trace-scorecard.sh exited ${rc}, want 0; stderr: $(cat "${TMP_DIR}/stderr.txt")"
fi
SCORECARD="${FX_ROOT}/${SCORECARD_REL}"
[ -f "$SCORECARD" ] \
  || hard_fail "scorecard JSON no longer written — the markdown report must be an addition, not a replacement"
jq empty "$SCORECARD" >/dev/null 2>&1 \
  || hard_fail "scorecard JSON is invalid (${SCORECARD})"

# --- 2a. Heading ---------------------------------------------------------------
if grep -Eiq '^# .*scorecard' "$OUT_MD"; then
  note "markdown heading present"
else
  fail "stdout must carry a markdown report with a '# ...scorecard...' heading (always-on, mirroring trace-report.sh); got: $(head -3 "$OUT_MD" | tr '\n' ' ')"
fi

# --- 2b. Per-version comparison table -------------------------------------------
# Pinned column order: version | runs | passed | red-reentry-free | deviations
#                      | tool calls | tokens
# cell <row> <n> → the n-th pipe cell, whitespace-trimmed ($1 is empty before
# the leading '|', so cell 1 == awk field 2).
cell() {
  printf '%s\n' "$1" | awk -F'|' -v n="$(($2 + 1))" \
    '{gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n}'
}
find_row() {
  # Empty output (no match) is a reportable assertion failure downstream,
  # not a sensor crash — neutralize grep's exit 1 under pipefail.
  grep -E "^\|[ \t]*${1}[ \t]*\|" "$OUT_MD" | head -n 1 || true
}

row_va="$(find_row "vA")"
row_vb="$(find_row "vB")"
row_mixed="$(find_row "mixed")"

if [ -z "$row_va" ]; then
  fail "no table row for version vA (expected '| vA | ... |' pipe row in the comparison table)"
else
  [ "$(cell "$row_va" 2)" = "1" ] \
    || fail "vA row runs cell must be 1, got '$(cell "$row_va" 2)' (row: ${row_va})"
  [ "$(cell "$row_va" 3)" = "1" ] \
    || fail "vA row passed cell must be 1, got '$(cell "$row_va" 3)' (row: ${row_va})"
  [ "$(cell "$row_va" 4)" = "1/1" ] \
    || fail "vA row red-reentry-free cell must be '1/1' (explicit of-denominator), got '$(cell "$row_va" 4)'"
  [ "$(cell "$row_va" 5)" = "2" ] \
    || fail "vA row deviations cell must be 2, got '$(cell "$row_va" 5)'"
  [ "$(cell "$row_va" 6)" = "5" ] \
    || fail "vA row tool-calls cell must be 5, got '$(cell "$row_va" 6)'"
  tok_va="$(cell "$row_va" 7)"
  if [ "$tok_va" = "n/a" ]; then
    note "vA tokens render as n/a (null, never 0)"
  else
    fail "vA row tokens cell must be 'n/a' for a null-tokens bucket — never 0, got '${tok_va}'"
  fi
fi

if [ -z "$row_vb" ]; then
  fail "no table row for version vB (issue-11 must be attributed vB via the trace peek and rendered)"
else
  [ "$(cell "$row_vb" 2)" = "1" ] \
    || fail "vB row runs cell must be 1, got '$(cell "$row_vb" 2)'"
  [ "$(cell "$row_vb" 4)" = "0/1" ] \
    || fail "vB row red-reentry-free cell must be '0/1' (feat-c re-entered red), got '$(cell "$row_vb" 4)'"
  [ "$(cell "$row_vb" 5)" = "0" ] \
    || fail "vB row deviations cell must be 0 (measured zero is a real 0), got '$(cell "$row_vb" 5)'"
  [ "$(cell "$row_vb" 6)" = "4" ] \
    || fail "vB row tool-calls cell must be 4, got '$(cell "$row_vb" 6)'"
  tok_vb="$(cell "$row_vb" 7)"
  if printf '%s' "$tok_vb" | grep -q '1000' && printf '%s' "$tok_vb" | grep -q '200'; then
    note "vB tokens cell carries the real sums (${tok_vb})"
  else
    fail "vB row tokens cell must show the real input/output sums 1000 and 200, got '${tok_vb}'"
  fi
fi

if [ -z "$row_mixed" ]; then
  fail "no table row labeled 'mixed' — the unresolved multi-version run (issue-13) must stay VISIBLE in the comparison table (conductor-resolved Open Question 3 = A)"
else
  note "mixed bucket visibly labeled in the table"
fi

# --- 4. Missing + skipped sections when non-empty --------------------------------
if grep -Eiq 'missing' "$OUT_MD" && grep -q 'issue-12' "$OUT_MD" \
  && grep -q 'trace-report.sh' "$OUT_MD"; then
  note "missing-summaries section present with the trace-report.sh hint"
else
  fail "report must carry a missing-summaries section naming issue-12 and the trace-report.sh regeneration hint"
fi
if grep -Eiq 'skipped' "$OUT_MD" && grep -q 'issue-14' "$OUT_MD"; then
  note "skipped section present naming issue-14"
else
  fail "report must carry a skipped section naming issue-14 (unknown summary_schema_version major — depends on feature scorecard-honesty)"
fi

# --- 5. Single source: table numbers equal the JSON ------------------------------
if [ -n "$row_va" ]; then
  json_calls="$(jq -r '.by_version[] | select(.harness_version == "vA") | .tool_calls.calls' "$SCORECARD")"
  [ "$(cell "$row_va" 6)" = "$json_calls" ] \
    || fail "single-source violation: vA tool-calls cell '$(cell "$row_va" 6)' != JSON .tool_calls.calls '${json_calls}' — the markdown must be rendered FROM the scorecard object"
  json_runs="$(jq -r '.by_version[] | select(.harness_version == "vA") | .runs' "$SCORECARD")"
  [ "$(cell "$row_va" 2)" = "$json_runs" ] \
    || fail "single-source violation: vA runs cell '$(cell "$row_va" 2)' != JSON .runs '${json_runs}'"
fi
if [ -n "$row_vb" ]; then
  json_in="$(jq -r '.by_version[] | select(.harness_version == "vB") | .tokens.input' "$SCORECARD")"
  printf '%s' "$(cell "$row_vb" 7)" | grep -q -- "$json_in" \
    || fail "single-source violation: vB tokens cell '$(cell "$row_vb" 7)' does not carry JSON .tokens.input '${json_in}'"
fi

# --- Verdict --------------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  printf 'test_trace_scorecard_markdown: %d failure(s)\n' "$fails" >&2
  exit 1
fi
echo "test_trace_scorecard_markdown: PASS"
