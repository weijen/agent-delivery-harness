#!/usr/bin/env bash
# Sensor for per-run same-class generator failure summaries.

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
mkdir -p "${ISSUES_DIR}/issue-20" "${ISSUES_DIR}/issue-21" \
  "${ISSUES_DIR}/issue-22"

# Run A: four knowledge gaps and three complexity failures are eligible.
# The normal RED/pass, reviewer failure, invalid class, and invalid other
# detail prove that the projection is structured and generator-only.
cat > "${ISSUES_DIR}/issue-20/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-21T09:00:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.outcome":"pass","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T09:01:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.outcome":"fail","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T09:02:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.outcome":"blocked","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T09:03:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.outcome":"fail","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T09:04:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.outcome":"blocked","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T09:05:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.outcome":"fail","harness.failure_class":"complexity"}
{"schema_version":1,"timestamp":"2026-07-21T09:06:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.outcome":"blocked","harness.failure_class":"complexity"}
{"schema_version":1,"timestamp":"2026-07-21T09:07:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.outcome":"fail","harness.failure_class":"complexity"}
{"schema_version":1,"timestamp":"2026-07-21T09:08:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T09:09:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.outcome":"fail","harness.failure_class":"invented"}
{"schema_version":1,"timestamp":"2026-07-21T09:10:00Z","span":"agent","harness.issue":20,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.outcome":"fail","harness.failure_class":"other","harness.failure_class_detail":""}
EOF

# Run B: two eligible knowledge gaps.
cat > "${ISSUES_DIR}/issue-21/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-21T10:00:00Z","span":"agent","harness.issue":21,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.outcome":"fail","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T10:01:00Z","span":"agent","harness.issue":21,"harness.version":"repeat-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.outcome":"blocked","harness.failure_class":"knowledge-gap"}
EOF

for issue in 20 21; do
  "$REPORT_SH" "${ISSUES_DIR}/issue-${issue}/trace.jsonl" \
    > "${TMP_DIR}/report-${issue}.md" 2> "${TMP_DIR}/report-${issue}.err" \
    || hard_fail "trace-report.sh failed for issue-${issue}"
done

SUMMARY_A="${ISSUES_DIR}/issue-20/trace-summary.json"
SUMMARY_B="${ISSUES_DIR}/issue-21/trace-summary.json"
jq -e '
  .same_class_failures == {
    "by_class":[
      {"failure_class":"knowledge-gap","count":4},
      {"failure_class":"complexity","count":3}
    ],
    "max_count":4
  }
' "$SUMMARY_A" >/dev/null 2>&1 \
  || fail "run A must count only eligible generator failures in closed-class order"
jq -e '
  .same_class_failures == {
    "by_class":[{"failure_class":"knowledge-gap","count":2}],
    "max_count":2
  }
' "$SUMMARY_B" >/dev/null 2>&1 \
  || fail "run B must report two knowledge-gap failures"
grep -Fq '| knowledge-gap | 4 |' "${TMP_DIR}/report-20.md" \
  || fail "trace report markdown must render knowledge-gap=4 from its summary"
grep -Fq 'maximum same-class failures: 4' "${TMP_DIR}/report-20.md" \
  || fail "trace report markdown must render max_count=4 from its summary"

if [ "$fails" -ne 0 ]; then
  printf '%d same-class scorecard violation(s).\n' "$fails" >&2
  exit 1
fi

printf 'same-class repeat scorecard checks passed\n'
