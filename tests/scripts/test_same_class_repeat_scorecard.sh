#!/usr/bin/env bash
# End-to-end sensor for per-run and cross-run same-class generator failures.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
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

command -v jq >/dev/null 2>&1 || hard_fail "jq is required"
[ -x "$REPORT_SH" ] || hard_fail "trace-report.sh must be executable"
[ -x "$SCORECARD_SH" ] || hard_fail "trace-scorecard.sh must be executable"

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

# Historical valid v1 summary: no projection means unmeasured, not zero.
cat > "${ISSUES_DIR}/issue-22/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-22/trace.jsonl",
  "issue": 22,
  "harness_versions": ["repeat-v1"],
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

"$SCORECARD_SH" --root "$FX_ROOT" > "${TMP_DIR}/scorecard.md" \
  2> "${TMP_DIR}/scorecard.err" || hard_fail "trace-scorecard.sh failed"
SCORECARD="${FX_ROOT}/${SCORECARD_REL}"

jq -e '
  (.by_version[] | select(.harness_version == "repeat-v1")) as $b
  | $b.same_class_failures == {
      "occurrences_by_class":[
        {"failure_class":"knowledge-gap","count":6},
        {"failure_class":"complexity","count":3}
      ],
      "max_observed_per_run":4,
      "coverage":{"measured_inputs":2,"total_relevant_inputs":3},
      "target":{"operator":"<=","max_count":2,"policy":"report-only"}
    }
  and ([$b.issues[].issue] == [20,21,22])
  and ($b.issues[0].same_class_failures.max_count == 4)
  and ($b.issues[1].same_class_failures.max_count == 2)
  and ($b.issues[2].same_class_failures == null)
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "scorecard must aggregate measured summaries only and preserve old-summary null coverage"

grep -Fq '| repeat-v1 | knowledge-gap | 6 | 4 | 2/3 | <=2 (report-only) |' \
  "${TMP_DIR}/scorecard.md" \
  || fail "scorecard markdown must render grouped counts, maximum, coverage, and report-only target"

# Prove markdown is rendered from the generated object: mutate only the JSON,
# then execute the checked-in render filter extracted from the script.
awk 'index($0, "cat > \"$RENDER_FILTER\" <<'\''JQ'\''") {copy=1; next}
     copy && $0 == "JQ" {exit}
     copy {print}' \
  "$SCORECARD_SH" > "${TMP_DIR}/render-markdown.jq"
jq '.by_version[0].same_class_failures.occurrences_by_class[0].count = 99' \
  "$SCORECARD" > "${TMP_DIR}/mutated-scorecard.json"
jq -r -f "${TMP_DIR}/render-markdown.jq" "${TMP_DIR}/mutated-scorecard.json" \
  > "${TMP_DIR}/mutated-scorecard.md"
grep -Fq '| repeat-v1 | knowledge-gap | 99 | 4 | 2/3 | <=2 (report-only) |' \
  "${TMP_DIR}/mutated-scorecard.md" \
  || fail "markdown renderer must read same-class numbers from the generated scorecard object"

# Prove both generators consume the runtime schema rather than a copied enum.
# A fixture harness adds a class and moves complexity ahead of knowledge-gap;
# projection and aggregation must accept and preserve that canonical order.
MUTATED_HARNESS="${TMP_DIR}/mutated-harness"
MUTATED_ROOT="${TMP_DIR}/mutated-root"
mkdir -p "${MUTATED_HARNESS}/scripts" \
  "${MUTATED_HARNESS}/docs/evaluation" \
  "${MUTATED_ROOT}/.copilot-tracking/issues/issue-30"
cp "$REPORT_SH" "$SCORECARD_SH" "${ROOT}/scripts/issue-lib.sh" \
  "${MUTATED_HARNESS}/scripts/"
jq '
  .failure_classes = [
    "complexity",
    "schema-added",
    "knowledge-gap",
    "spec-violation",
    "validation-bypass",
    "missing-coverage",
    "regression",
    "role-boundary",
    "known-flaky",
    "polling",
    "other"
  ]
' "${ROOT}/docs/evaluation/trace-schema.v1.json" \
  > "${MUTATED_HARNESS}/docs/evaluation/trace-schema.v1.json"
cat > "${MUTATED_ROOT}/.copilot-tracking/issues/issue-30/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-21T11:00:00Z","span":"agent","harness.issue":30,"harness.version":"mutated-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.outcome":"fail","harness.failure_class":"knowledge-gap"}
{"schema_version":1,"timestamp":"2026-07-21T11:01:00Z","span":"agent","harness.issue":30,"harness.version":"mutated-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.outcome":"blocked","harness.failure_class":"schema-added"}
{"schema_version":1,"timestamp":"2026-07-21T11:02:00Z","span":"agent","harness.issue":30,"harness.version":"mutated-v1","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.outcome":"fail","harness.failure_class":"complexity"}
EOF
"${MUTATED_HARNESS}/scripts/trace-report.sh" \
  "${MUTATED_ROOT}/.copilot-tracking/issues/issue-30/trace.jsonl" \
  > "${TMP_DIR}/mutated-schema-report.md" 2> "${TMP_DIR}/mutated-schema-report.err" \
  || hard_fail "trace-report.sh failed against mutated canonical schema"
MUTATED_SUMMARY="${MUTATED_ROOT}/.copilot-tracking/issues/issue-30/trace-summary.json"
jq -e '
  [.same_class_failures.by_class[].failure_class]
  == ["complexity", "schema-added", "knowledge-gap"]
' "$MUTATED_SUMMARY" >/dev/null 2>&1 \
  || fail "trace report must accept additions and preserve canonical failure_classes order"

"${MUTATED_HARNESS}/scripts/trace-scorecard.sh" --root "$MUTATED_ROOT" \
  > "${TMP_DIR}/mutated-schema-scorecard.md" \
  2> "${TMP_DIR}/mutated-schema-scorecard.err" \
  || hard_fail "trace-scorecard.sh failed against mutated canonical schema"
MUTATED_SCORECARD="${MUTATED_ROOT}/${SCORECARD_REL}"
jq -e '
  [.by_version[0].same_class_failures.occurrences_by_class[].failure_class]
  == ["complexity", "schema-added", "knowledge-gap"]
' "$MUTATED_SCORECARD" >/dev/null 2>&1 \
  || fail "scorecard must preserve canonical failure_classes order during aggregation"

# Contract loss must stop both generators explicitly, never fall back to a
# stale embedded enum.
rm "${MUTATED_HARNESS}/docs/evaluation/trace-schema.v1.json"
if "${MUTATED_HARNESS}/scripts/trace-report.sh" \
  "${MUTATED_ROOT}/.copilot-tracking/issues/issue-30/trace.jsonl" \
  > "${TMP_DIR}/missing-schema-report.out" \
  2> "${TMP_DIR}/missing-schema-report.err"; then
  fail "trace report must fail closed when the canonical schema is unavailable"
else
  status=$?
  [ "$status" -eq 2 ] \
    || fail "trace report schema failure must use environment exit 2, got ${status}"
fi
grep -Fq 'trace schema has no valid unique non-empty failure_classes enum' \
  "${TMP_DIR}/missing-schema-report.err" \
  || fail "trace report schema failure must be explicit"

if "${MUTATED_HARNESS}/scripts/trace-scorecard.sh" --root "$MUTATED_ROOT" \
  > "${TMP_DIR}/missing-schema-scorecard.out" \
  2> "${TMP_DIR}/missing-schema-scorecard.err"; then
  fail "scorecard must fail closed when the canonical schema is unavailable"
else
  status=$?
  [ "$status" -eq 2 ] \
    || fail "scorecard schema failure must use environment exit 2, got ${status}"
fi
grep -Fq 'trace schema has no valid unique non-empty failure_classes enum' \
  "${TMP_DIR}/missing-schema-scorecard.err" \
  || fail "scorecard schema failure must be explicit"

if [ "$fails" -ne 0 ]; then
  printf '%d same-class scorecard violation(s).\n' "$fails" >&2
  exit 1
fi

printf 'same-class repeat scorecard checks passed\n'
