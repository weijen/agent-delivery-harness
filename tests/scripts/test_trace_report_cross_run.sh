#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -x "$REPORT_SH" ] || fail "trace-report.sh must be executable"

selector="${1:-regression}"
case "$selector" in
  regression | e2e) ;;
  *) fail "usage: $0 <regression|e2e>" ;;
esac

FX_ROOT="${TMP_DIR}/fixture-root"
ISSUES_DIR="${FX_ROOT}/.copilot-tracking/issues"
mkdir -p "${ISSUES_DIR}"/issue-{10,11,12,13,14,15,16,17,18}

write_summary() {
  local issue="$1" versions="$2" tokens="$3" extras="$4"
  cat > "${ISSUES_DIR}/issue-${issue}/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-${issue}/trace.jsonl",
  "issue": ${issue},
  "harness_versions": ${versions},
  "finished": true,
  "final_outcome": "pass",
  "span_counts": {"total": 3, "invalid_lines": 0, "by_type": {"lifecycle": 2, "tool": 1}},
  "coverage": {"has_tool_spans": true, "has_model_spans": false},
  "wall_clock": {"elapsed_seconds": 30},
  "tools": [{"name": "git", "calls": 2, "fail_calls": 0, "duration_ms": null}],
  "tokens": ${tokens},
  "loop_indicators": [],
  "red_reentry": [],
  "deviations": {"count": 0, "feature_ids": []},
  ${extras}
}
EOF
}

write_summary 10 '["vA"]' 'null' \
  '"feature_delivery":{"rows":[{"elapsed_seconds":10}],"coverage":{"paired":1,"of":1}},"review_verdicts":{"fail":1,"total":2},"green_handbacks":{"blocked":0,"total":1},"same_class_failures":{"by_class":[{"failure_class":"knowledge-gap","count":2}],"max_count":2}'
write_summary 11 '["vB","vZ"]' '{"input_tokens":999,"output_tokens":111}' \
  '"feature_delivery":{"rows":[{"elapsed_seconds":20}],"coverage":{"paired":1,"of":1}},"review_verdicts":{"fail":0,"total":0},"green_handbacks":{"blocked":1,"total":2},"same_class_failures":{"by_class":[{"failure_class":"knowledge-gap","count":3}],"max_count":3}'
write_summary 12 '["vA"]' 'null' \
  '"feature_delivery":{"rows":[{"elapsed_seconds":20}],"coverage":{"paired":1,"of":1}},"review_verdicts":{"fail":0,"total":0},"green_handbacks":{"blocked":0,"total":0},"same_class_failures":{"by_class":[],"max_count":0}'
write_summary 17 '["vBad"]' '"not-a-token-object"' \
  '"feature_delivery":{"rows":[],"coverage":{"paired":0,"of":0}},"review_verdicts":{"fail":0,"total":0},"green_handbacks":{"blocked":0,"total":0},"same_class_failures":{"by_class":[],"max_count":0}'
write_summary 18 '["vD"]' 'null' \
  '"feature_delivery":{"rows":[],"coverage":{"paired":0,"of":0}},"review_verdicts":{"fail":0,"total":0},"green_handbacks":{"blocked":0,"total":0},"same_class_failures":{"by_class":[],"max_count":0}'

# Every v1 structure consumed by --all must pass admission validation before
# aggregation. Each malformed fixture starts from one otherwise valid legacy
# summary, and each expected reason names the precise rejected field.
MALFORMED_CASES="${TMP_DIR}/malformed-cases.tsv"
cat > "$MALFORMED_CASES" <<'EOF'
harness_versions	.harness_versions = [1]	invalid harness_versions[]
issue	.issue = "17"	invalid issue
finished	.finished = null	invalid finished
final_outcome	.final_outcome = 7	invalid final_outcome
red_reentry	.red_reentry = {}	invalid red_reentry
deviations	.deviations.feature_ids = 1	invalid deviations.feature_ids
tools	.tools = [1]	invalid tools[]
tokens	.tokens = "not-a-token-object"	invalid tokens
coverage	.coverage.has_tool_spans = "yes"	invalid coverage.has_tool_spans
wall_clock	.wall_clock.elapsed_seconds = "30"	invalid wall_clock.elapsed_seconds
feature_delivery_rows	.feature_delivery.rows = [1]	invalid feature_delivery.rows[]
feature_delivery_coverage	.feature_delivery.coverage.paired = "0"	invalid feature_delivery.coverage.paired
review_verdicts	.review_verdicts.fail = "0"	invalid review_verdicts.fail
green_handbacks	.green_handbacks.blocked = []	invalid green_handbacks.blocked
same_class_by_class	.same_class_failures.by_class = [1]	invalid same_class_failures.by_class[]
same_class_max	.same_class_failures.max_count = "0"	invalid same_class_failures.max_count
skills	.skills = [1]	invalid skills[]
loop_indicators	.loop_indicators = {}	invalid loop_indicators
span_counts	.span_counts.invalid_lines = "0"	invalid span_counts.invalid_lines
EOF

malformed_issue=30
while IFS=$'\t' read -r case_name mutation expected_reason; do
  issue_dir="${ISSUES_DIR}/issue-${malformed_issue}"
  mkdir -p "$issue_dir"
  jq --argjson issue "$malformed_issue" --arg version "malformed-${case_name}" \
    ".issue = \$issue | .harness_versions = [\$version] | $mutation" \
    "${ISSUES_DIR}/issue-10/trace-summary.json" > "${issue_dir}/trace-summary.json"
  printf '%s\t%s\n' "${issue_dir}/trace-summary.json" "$expected_reason" \
    >> "${TMP_DIR}/malformed-expected.tsv"
  malformed_issue=$((malformed_issue + 1))
done < "$MALFORMED_CASES"

# Multiple versions use the last version-bearing span. Multiple economics
# spans use the final one; deprecated summary/model tokens must not win.
cat > "${ISSUES_DIR}/issue-11/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-22T10:00:00Z","span":"lifecycle","harness.issue":11,"harness.version":"vZ","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"2026-07-22T10:01:00Z","span":"tool","harness.issue":11,"harness.version":"vB","gen_ai.tool.name":"finish-issue.economics","harness.outcome":"pass","harness.economics.native_subagent_tokens":10,"harness.economics.native_subagent_count":1,"harness.economics.native_tool_calls":2,"harness.economics.native_duration_ms":100}
{"schema_version":1,"timestamp":"2026-07-22T10:02:00Z","span":"tool","harness.issue":11,"gen_ai.tool.name":"finish-issue.economics","harness.outcome":"pass","harness.economics.native_subagent_tokens":700,"harness.economics.native_subagent_count":2,"harness.economics.native_tool_calls":9,"harness.economics.native_duration_ms":500,"harness.economics.native_models_distinct":2,"harness.economics.native_aiu_nano_delta":42}
EOF

cat > "${ISSUES_DIR}/issue-10/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-22T09:00:00Z","span":"tool","harness.issue":10,"harness.version":"vA","gen_ai.tool.name":"finish-issue.economics","harness.outcome":"pass","harness.economics.native_subagent_tokens":300,"harness.economics.native_subagent_count":1,"harness.economics.native_tool_calls":4,"harness.economics.native_duration_ms":250,"harness.economics.native_models_distinct":1}
EOF

# Valid regenerated summary with no economics span: honest n/a coverage.
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-22T09:00:00Z","span":"lifecycle","harness.issue":12,"harness.version":"vA"}' \
  > "${ISSUES_DIR}/issue-12/trace.jsonl"

# A final economics span without any native numeric measurement is not measured.
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-22T09:00:00Z","span":"tool","harness.issue":18,"harness.version":"vD","gen_ai.tool.name":"finish-issue.economics","harness.outcome":"pass"}' \
  > "${ISSUES_DIR}/issue-18/trace.jsonl"

# Visible input gaps: missing summary, unknown major, malformed summary.
printf '%s\n' '{"schema_version":1,"span":"lifecycle","harness.issue":13}' \
  > "${ISSUES_DIR}/issue-13/trace.jsonl"
printf '%s\n' '{"summary_schema_version":2,"harness_versions":["future"]}' \
  > "${ISSUES_DIR}/issue-14/trace-summary.json"
printf '%s\n' '{broken' > "${ISSUES_DIR}/issue-15/trace-summary.json"

# Produce one input through the real per-run path. Cross-run mode must consume
# the regenerated v1 summary while taking economics from its sibling trace.
cat > "${ISSUES_DIR}/issue-16/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-22T11:00:00Z","span":"lifecycle","harness.issue":16,"harness.version":"vC","harness.lifecycle_step":"finish","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-22T11:00:01Z","span":"tool","harness.issue":16,"harness.version":"vC","gen_ai.tool.name":"finish-issue.economics","harness.outcome":"pass","harness.economics.native_subagent_tokens":80,"harness.economics.native_subagent_count":1,"harness.economics.native_tool_calls":3,"harness.economics.native_duration_ms":90,"harness.economics.native_models_distinct":1}
EOF
"$REPORT_SH" "${ISSUES_DIR}/issue-16/trace.jsonl" > "${TMP_DIR}/regenerated.md" ||
  fail "per-run summary regeneration failed"
jq -e '.summary_schema_version == 1 and .issue == 16' \
  "${ISSUES_DIR}/issue-16/trace-summary.json" >/dev/null ||
  fail "fixture must include a genuinely regenerated v1 summary"

OUT1="${TMP_DIR}/out-1.md"
OUT2="${TMP_DIR}/out-2.md"
"$REPORT_SH" --all --root "$FX_ROOT" > "$OUT1" 2> "${TMP_DIR}/err-1" ||
  fail "trace-report.sh --all --root failed: $(cat "${TMP_DIR}/err-1")"

if [ "$selector" = "regression" ]; then
  grep -Fq '# Cross-run trace report:' "$OUT1" || fail "cross-run heading missing"
  grep -Fq '| vA | 2 | 2 | 1/2 | 300 | 1 | 4 | 250 | 1 | n/a |' "$OUT1" ||
    fail "vA economics row must preserve measured values and 1/2 coverage"
  grep -Fq '| vB | 1 | 1 | 1/1 | 700 | 2 | 9 | 500 | 2 | 42 |' "$OUT1" ||
    fail "vB row must use the final economics span and trace-last version"
  grep -Fq '| vC | 1 | 1 | 1/1 | 80 | 1 | 3 | 90 | 1 | n/a |' "$OUT1" ||
    fail "cross-run mode must consume the regenerated v1 summary and final economics"
  grep -Fq '| vD | 1 | 1 | 0/1 | n/a | n/a | n/a | n/a | n/a | n/a |' "$OUT1" ||
    fail "economics coverage must exclude spans with no native numeric measurements"
  ! grep -Fq '| vZ |' "$OUT1" || fail "summary sort order must not attribute vB run to vZ"
  ! grep -Fq '| vBad |' "$OUT1" || fail "malformed v1 summary must not reach aggregation"
  grep -Fq '| vA | 2 | 2 | 2/2 | 0/2 | n/a |' "$OUT1" ||
    fail "comparison row must render absent token totals as n/a with coverage"
  grep -Fq '| vB | 1 | 1 | 1/1 | 1/1 | in 999 / out 111 |' "$OUT1" ||
    fail "comparison row must render token totals and coverage"
  grep -Fq '| vA | 2 | 15 | 17.5 | 19.5 | 2/2 | 1/2 (0.5) | 0/1 (0) |' "$OUT1" ||
    fail "generator metrics must be aggregated from regenerated summaries"
  grep -Fq '| vB | knowledge-gap | 3 | 3 | 1/1 | <=2 (report-only) |' "$OUT1" ||
    fail "same-class metrics must remain visible"
  grep -Fq '| vD | none | 0 | 0 | 1/1 | <=2 (report-only) |' "$OUT1" ||
    fail "measured zero same-class failures must render coverage and max per run"
  grep -Fq 'issue-13: trace.jsonl present but no trace-summary.json' "$OUT1" ||
    fail "missing summary must be visible"
  grep -Fq 'unknown summary_schema_version major (2)' "$OUT1" ||
    fail "unknown major must be visibly skipped"
  grep -Fq 'issue-15/trace-summary.json' "$OUT1" ||
    fail "malformed summary must be visibly skipped"
  grep -Fq 'issue-17/trace-summary.json' "$OUT1" ||
    fail "parseable v1 summary with malformed tokens must be visibly skipped"
  grep -Fq 'invalid tokens:' "$OUT1" ||
    fail "malformed token skip must explain the invalid field"
  while IFS=$'\t' read -r malformed_file expected_reason; do
    grep -Fq "${malformed_file} — ${expected_reason}" "$OUT1" ||
      fail "malformed consumed field must be visibly skipped: ${expected_reason}"
  done < "${TMP_DIR}/malformed-expected.tsv"
  [ ! -e "${FX_ROOT}/tests/evals/scorecards/trace-scorecard.json" ] ||
    fail "cross-run report must not write a replacement scorecard"
else
  "$REPORT_SH" --all --root "$FX_ROOT" > "$OUT2" 2> "${TMP_DIR}/err-2" ||
    fail "second trace-report invocation failed"
  cmp -s "$OUT1" "$OUT2" || fail "cross-run markdown must be byte-deterministic"
  "$REPORT_SH" "${ISSUES_DIR}/issue-10/trace.jsonl" > "${TMP_DIR}/per-run.md" ||
    fail "existing per-run mode must remain executable"
  grep -Fq '# Trace report:' "${TMP_DIR}/per-run.md" ||
    fail "existing per-run report heading changed"
fi

printf 'test_trace_report_cross_run %s: PASS\n' "$selector"
