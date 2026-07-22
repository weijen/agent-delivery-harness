#!/usr/bin/env bash
# test_trace_generator_experiment_metrics.sh — regression and e2e sensor for
# trace-derived generator experiment measurements (issue #296, Phase 4).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
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

command -v jq >/dev/null 2>&1 || hard_fail "jq is required"
[ -x "$REPORT_SH" ] || hard_fail "trace-report.sh must be executable"

FX_ROOT="${TMP_DIR}/fixture-root"
ISSUES_DIR="${FX_ROOT}/.copilot-tracking/issues"
mkdir -p "${ISSUES_DIR}/issue-10" "${ISSUES_DIR}/issue-11" \
  "${ISSUES_DIR}/issue-12" "${ISSUES_DIR}/issue-13" \
  "${ISSUES_DIR}/issue-14" "${ISSUES_DIR}/issue-15" \
  "${ISSUES_DIR}/issue-16"

# Historical role names are deliberate provenance. Feature alpha has two
# GREEN observations; elapsed uses the last later GREEN and records one
# blocked GREEN. Feature beta is started but unpaired.
cat > "${ISSUES_DIR}/issue-10/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-17T09:59:50.500Z","span":"agent","harness.issue":10,"harness.version":"experiment-v1","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"alpha","harness.outcome":"blocked"}
{"schema_version":1,"timestamp":"2026-07-17T10:00:00.250Z","span":"lifecycle","harness.issue":10,"harness.version":"experiment-v1","harness.lifecycle_step":"feature_start","harness.feature_id":"alpha","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T10:00:01.000Z","span":"lifecycle","harness.issue":10,"harness.version":"experiment-v1","harness.lifecycle_step":"feature_start","harness.feature_id":"","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T10:00:05.500Z","span":"agent","harness.issue":10,"harness.version":"experiment-v1","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"alpha","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T10:00:10.750Z","span":"agent","harness.issue":10,"harness.version":"experiment-v1","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"alpha","harness.outcome":"blocked"}
{"schema_version":1,"timestamp":"2026-07-17T10:00:20.125Z","span":"agent","harness.issue":10,"harness.version":"experiment-v1","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"alpha","harness.outcome":"fail"}
{"schema_version":1,"timestamp":"2026-07-17T10:00:25.875Z","span":"agent","harness.issue":10,"harness.version":"experiment-v1","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"alpha","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T10:00:30.750Z","span":"agent","harness.issue":10,"harness.version":"experiment-v1","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"alpha","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T10:01:00.500Z","span":"lifecycle","harness.issue":10,"harness.version":"experiment-v1","harness.lifecycle_step":"feature_start","harness.feature_id":"beta","harness.outcome":"pass"}
EOF

# Current generator role. This run intentionally has no review_verdict, which
# must produce a null review rate rather than a fabricated zero-rate sample.
cat > "${ISSUES_DIR}/issue-11/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-17T11:00:00.900Z","span":"lifecycle","harness.issue":11,"harness.version":"experiment-v1","harness.lifecycle_step":"feature_start","harness.feature_id":"gamma","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T11:00:02.100Z","span":"agent","harness.issue":11,"harness.version":"experiment-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"gamma","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T11:00:10.100Z","span":"agent","harness.issue":11,"harness.version":"experiment-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.feature_id":"gamma","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T11:00:20.900Z","span":"agent","harness.issue":11,"harness.version":"experiment-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"gamma","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T11:00:21.000Z","span":"lifecycle","harness.issue":11,"harness.version":"experiment-v1","harness.lifecycle_step":"finish","harness.outcome":"pass","harness.economics.review_rounds":99}
EOF

for issue in 10 11; do
  "$REPORT_SH" "${ISSUES_DIR}/issue-${issue}/trace.jsonl" \
    > "${TMP_DIR}/report-${issue}.md" 2> "${TMP_DIR}/report-${issue}.err" \
    || hard_fail "trace-report.sh failed for issue-${issue}"
done

LEGACY_SUMMARY="${ISSUES_DIR}/issue-10/trace-summary.json"
GENERATOR_SUMMARY="${ISSUES_DIR}/issue-11/trace-summary.json"

jq -e '
  .feature_delivery.coverage == {"paired":1,"of":2}
  and .feature_delivery.rows == [{
    "id":"alpha",
    "start_timestamp":"2026-07-17T10:00:00.250Z",
    "green_timestamp":"2026-07-17T10:00:30.750Z",
    "elapsed_seconds":30.5,
    "final_green_outcome":"pass",
    "blocked_green_count":1
  }]
  and .review_verdicts == {"pass":1,"fail":1,"blocked":0,"total":2,"fail_rate":0.5}
  and .green_handbacks == {"pass":1,"fail":0,"blocked":2,"total":3,"blocked_rate":(2/3)}
' "$LEGACY_SUMMARY" >/dev/null 2>&1 \
  || fail "legacy summary must preserve alpha elapsed 30.5 while excluding pre-start GREEN and empty feature ids: $(jq -c '.feature_delivery' "$LEGACY_SUMMARY" 2>/dev/null)"

jq -e '
  .feature_delivery.coverage == {"paired":1,"of":1}
  and .feature_delivery.rows == [{
    "id":"gamma",
    "start_timestamp":"2026-07-17T11:00:00.900Z",
    "green_timestamp":"2026-07-17T11:00:20.900Z",
    "elapsed_seconds":20,
    "final_green_outcome":"pass",
    "blocked_green_count":0
  }]
  and .review_verdicts == {"pass":0,"fail":0,"blocked":0,"total":0,"fail_rate":null}
  and .green_handbacks == {"pass":1,"fail":0,"blocked":0,"total":1,"blocked_rate":0}
' "$GENERATOR_SUMMARY" >/dev/null 2>&1 \
  || fail "generator summary must preserve fractional timestamp edges and null no-review denominator"

grep -Fq 'feature elapsed coverage: 1/2' "${TMP_DIR}/report-10.md" \
  || fail "trace report markdown must render feature elapsed coverage"
grep -Fq '| alpha | 30.5 | pass | 1 |' "${TMP_DIR}/report-10.md" \
  || fail "trace report markdown must render the paired elapsed row"
grep -Fq 'review failures: 0/0 (n/a)' "${TMP_DIR}/report-11.md" \
  || fail "trace report markdown must render a zero review denominator as n/a"

# Pre-instrumentation summary: valid v1 with no experiment keys. It must remain
# aggregatable and contribute no invented samples or denominators.
cat > "${ISSUES_DIR}/issue-12/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-12/trace.jsonl",
  "issue": 12,
  "harness_versions": ["experiment-v1"],
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

# Instrumented but unpaired: explicit zero denominators must retain null rates,
# and a one-run bucket with no elapsed samples must retain null percentiles.
cat > "${ISSUES_DIR}/issue-13/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-17T12:00:00Z","span":"lifecycle","harness.issue":13,"harness.version":"zero-v","harness.lifecycle_step":"feature_start","harness.feature_id":"delta","harness.outcome":"pass"}
EOF

# A later GREEN in the same whole second is still chronologically later. This
# fixture prevents timestamp normalization from collapsing a valid pair.
cat > "${ISSUES_DIR}/issue-14/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-17T13:00:00.100Z","span":"lifecycle","harness.issue":14,"harness.version":"fraction-v","harness.lifecycle_step":"feature_start","harness.feature_id":"epsilon","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T13:00:00.900Z","span":"agent","harness.issue":14,"harness.version":"fraction-v","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"epsilon","harness.outcome":"pass"}
EOF

# Fractions must also survive when the pair crosses a whole-second boundary.
cat > "${ISSUES_DIR}/issue-15/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-17T13:00:00.900Z","span":"lifecycle","harness.issue":15,"harness.version":"boundary-v","harness.lifecycle_step":"feature_start","harness.feature_id":"zeta","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-17T13:00:01.100Z","span":"agent","harness.issue":15,"harness.version":"boundary-v","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"zeta","harness.outcome":"pass"}
EOF

# Lexical timestamp ordering must not reverse a whole-second timestamp and a
# later fractional timestamp from the same second. Invalid timestamp strings
# are excluded from endpoint selection rather than replacing a valid edge.
cat > "${ISSUES_DIR}/issue-16/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-17T13:00:00Z","span":"lifecycle","harness.issue":16,"harness.version":"mixed-precision-v","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"not-a-timestamp","span":"tool","harness.issue":16,"harness.version":"mixed-precision-v","gen_ai.tool.name":"invalid-timestamp-fixture"}
{"schema_version":1,"timestamp":"2026-07-17T13:00:00.100Z","span":"lifecycle","harness.issue":16,"harness.version":"mixed-precision-v","harness.lifecycle_step":"finish","harness.outcome":"pass"}
EOF

for issue in 13 14 15 16; do
  "$REPORT_SH" "${ISSUES_DIR}/issue-${issue}/trace.jsonl" \
    > "${TMP_DIR}/report-${issue}.md" 2> "${TMP_DIR}/report-${issue}.err" \
    || hard_fail "trace-report.sh failed for issue-${issue}"
done

jq -e '
  .feature_delivery == {"rows":[],"coverage":{"paired":0,"of":1}}
  and .review_verdicts == {"pass":0,"fail":0,"blocked":0,"total":0,"fail_rate":null}
  and .green_handbacks == {"pass":0,"fail":0,"blocked":0,"total":0,"blocked_rate":null}
' "${ISSUES_DIR}/issue-13/trace-summary.json" >/dev/null 2>&1 \
  || fail "instrumented zero review and GREEN denominators must produce null rates"

jq -e '
  .feature_delivery.coverage == {"paired":1,"of":1}
  and .feature_delivery.rows == [{
    "id":"epsilon",
    "start_timestamp":"2026-07-17T13:00:00.100Z",
    "green_timestamp":"2026-07-17T13:00:00.900Z",
    "elapsed_seconds":0.8,
    "final_green_outcome":"pass",
    "blocked_green_count":0
  }]
' "${ISSUES_DIR}/issue-14/trace-summary.json" >/dev/null 2>&1 \
  || fail "fractional timestamps within one second must remain a valid later-GREEN pair"

jq -e '
  .feature_delivery.coverage == {"paired":1,"of":1}
  and .feature_delivery.rows == [{
    "id":"zeta",
    "start_timestamp":"2026-07-17T13:00:00.900Z",
    "green_timestamp":"2026-07-17T13:00:01.100Z",
    "elapsed_seconds":0.2,
    "final_green_outcome":"pass",
    "blocked_green_count":0
  }]
' "${ISSUES_DIR}/issue-15/trace-summary.json" >/dev/null 2>&1 \
  || fail "fractional elapsed time must remain exact across a whole-second boundary"

jq -e '
  .wall_clock == {
    "first_timestamp":"2026-07-17T13:00:00Z",
    "last_timestamp":"2026-07-17T13:00:00.100Z",
    "elapsed_seconds":0.1
  }
' "${ISSUES_DIR}/issue-16/trace-summary.json" >/dev/null 2>&1 \
  || fail "wall-clock ordering must compare parsed timestamps rather than lexical timestamp strings"

if [ "$fails" -ne 0 ]; then
  printf '%d generator experiment metric violation(s).\n' "$fails" >&2
  exit 1
fi

printf 'generator experiment metric checks passed\n'
