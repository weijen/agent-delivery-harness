#!/usr/bin/env bash
# Consolidated behavioral sensor for current same-class escalation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts log-handback.sh,trace-lib.sh,render-action-log.sh,issue-lib.sh
TMP_DIR="$FIXTURE_TMP_DIR"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

# The live writer puts escalation metadata on conductor deviation spans.
MAIN="$FIXTURE_REPO"
WT="${TMP_DIR}/writer-wt"
git -C "$MAIN" worktree add -q -b feature/issue-317-fixture "$WT"
mkdir -p "${WT}/.copilot-tracking/issues/issue-317"
printf '# Issue 317\n\n## Action Log\n\n' \
  > "${WT}/.copilot-tracking/issues/issue-317/progress.md"
(
  cd "$WT"
  TRACE_FAILURE_CLASS=knowledge-gap \
    TRACE_FAILURE_DISPOSITION=research \
    TRACE_RESEARCH_URL=https://example.invalid/research \
    TRACE_RESEARCH_SUMMARY="Fixture source summary." \
    ./scripts/log-handback.sh conductor deviation selected-feature blocked \
      "research route" >/dev/null
)
WRITER_TRACE="${MAIN}/.copilot-tracking/issues/issue-317/trace.jsonl"
jq -e '
  .["gen_ai.agent.name"] == "conductor"
  and .["harness.lifecycle_step"] == "deviation"
  and .["harness.failure_class"] == "knowledge-gap"
  and .["harness.failure_disposition"] == "research"
  and .["harness.research_url"] == "https://example.invalid/research"
  and .["harness.research_summary"] == "Fixture source summary."
' "$WRITER_TRACE" >/dev/null || fail "writer dropped valid escalation metadata"

(
  cd "$WT"
  TRACE_FAILURE_CLASS=not-a-class TRACE_FAILURE_DISPOSITION=not-a-route \
    ./scripts/log-handback.sh conductor deviation selected-feature blocked \
      "invalid metadata" >/dev/null 2>"${TMP_DIR}/writer-warning"
)
tail -n 1 "$WRITER_TRACE" | jq -e '
  (has("harness.failure_class") | not)
  and (has("harness.failure_disposition") | not)
' >/dev/null || fail "writer emitted invalid escalation metadata"
grep -Fq 'TRACE_FAILURE_CLASS' "${TMP_DIR}/writer-warning" \
  || fail "writer did not warn about an invalid class"
grep -Fq 'TRACE_FAILURE_DISPOSITION' "${TMP_DIR}/writer-warning" \
  || fail "writer did not warn about an invalid disposition"

case_dir() {
  printf '%s/%s/.copilot-tracking/issues/issue-317' "$TMP_DIR" "$1"
}

make_case() {
  local name="$1" dir
  dir="$(case_dir "$name")"
  mkdir -p "$dir"
  printf '# Issue 317\n\n## Action Log\n\n' > "${dir}/progress.md"
  printf '# Fixture instructions\n' > "${TMP_DIR}/${name}/AGENTS.md"
  : > "${dir}/trace.jsonl"
}

add_span() {
  local name="$1" role="$2" step="$3" outcome="$4" cls="$5"
  local disposition="$6" detail="${7:-}" extras="${8:-}" dir
  dir="$(case_dir "$name")"
  [ -n "$extras" ] || extras='{}'
  jq -cn \
    --arg role "$role" --arg step "$step" --arg outcome "$outcome" \
    --arg cls "$cls" --arg disposition "$disposition" --arg detail "$detail" \
    --argjson extras "$extras" '
      {
        schema_version: 1,
        timestamp: "2026-07-21T00:00:00Z",
        span: "agent",
        "harness.issue": 317,
        "harness.version": "0.0.0-dev",
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": $role,
        "harness.lifecycle_step": $step,
        "harness.feature_id": "selected-feature",
        "harness.outcome": $outcome,
        "harness.summary": "fixture"
      }
      + (if $cls == "" then {} else {"harness.failure_class": $cls} end)
      + (if $disposition == "" then {} else {"harness.failure_disposition": $disposition} end)
      + (if $detail == "" then {} else {"harness.failure_class_detail": $detail} end)
      + $extras
    ' >> "${dir}/trace.jsonl"
  printf -- '- [%s] %s selected-feature %s — fixture\n' \
    "$role" "$step" "$outcome" >> "${dir}/progress.md"
}

run_checker() {
  local name="$1" rc=0 dir
  dir="$(case_dir "$name")"
  "$CHECKER" "${dir}/trace.jsonl" \
    >"${TMP_DIR}/${name}/out" 2>"${TMP_DIR}/${name}/err" || rc=$?
  printf '%s' "$rc"
}

expect_clean() {
  local name="$1" rc
  rc="$(run_checker "$name")"
  [ "$rc" = "0" ] || fail "${name}: expected clean checker exit, got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/${name}/out")"
}

expect_violation() {
  local name="$1" finding="$2" rc
  rc="$(run_checker "$name")"
  [ "$rc" = "1" ] || fail "${name}: expected checker exit 1, got ${rc}"
  grep -Fq "VIOLATION consistency: ${finding}" "${TMP_DIR}/${name}/out" \
    || fail "${name}: missing ${finding}: $(tr '\n' '|' < "${TMP_DIR}/${name}/out")"
}

# Historical handback spans remain readable but no longer participate in the
# current-run same-class gate.
make_case legacy-reader
add_span legacy-reader generator-subagent impl_handback fail "" ""
expect_clean legacy-reader

make_case missing-class
add_span missing-class conductor deviation blocked "" point-fix
expect_violation missing-class "generator_failure_class_missing line 1"

make_case first-point-fix
add_span first-point-fix conductor deviation blocked regression point-fix
expect_clean first-point-fix

make_case repeated-point-fix
add_span repeated-point-fix conductor deviation fail regression point-fix
add_span repeated-point-fix conductor deviation blocked regression point-fix
expect_violation repeated-point-fix "generator_repeated_point_fix line 2"

# Occurrence two must use the class-specific route.
for route in \
  "knowledge-gap research-requested" \
  "complexity decompose" \
  "known-flaky exemption" \
  "polling override" \
  "regression class-fix"; do
  cls="${route%% *}"
  disposition="${route#* }"
  name="route-${cls}-${disposition}"
  make_case "$name"
  add_span "$name" conductor deviation fail "$cls" point-fix
  add_span "$name" conductor deviation blocked "$cls" "$disposition"
  expect_clean "$name"
done

make_case wrong-route
add_span wrong-route conductor deviation fail complexity point-fix
add_span wrong-route conductor deviation blocked complexity research-requested
expect_violation wrong-route "generator_failure_route_mismatch line 2"

# Occurrence two with no disposition at all must be flagged distinctly from a
# repeated point-fix or a wrong route (reviewer-added coverage, issue #375).
make_case disposition-missing
add_span disposition-missing conductor deviation fail regression point-fix
add_span disposition-missing conductor deviation blocked regression ""
expect_violation disposition-missing "generator_failure_disposition_missing line 2"

make_case other-no-detail
add_span other-no-detail conductor deviation fail other point-fix
expect_violation other-no-detail "generator_failure_class_other_no_detail line 1"

# Research is a route-dependent pair: research needs a valid URL and one-line
# summary, while every other route forbids both fields.
make_case research-valid
add_span research-valid conductor deviation fail knowledge-gap point-fix
add_span research-valid conductor deviation blocked knowledge-gap research "" \
  '{"harness.research_url":"https://example.invalid/source","harness.research_summary":"One source."}'
expect_clean research-valid

make_case research-missing
add_span research-missing conductor deviation fail knowledge-gap point-fix
add_span research-missing conductor deviation blocked knowledge-gap research
expect_violation research-missing "generator_research_provenance_invalid line 2"

make_case research-stray
add_span research-stray conductor deviation blocked complexity point-fix "" \
  '{"harness.research_url":"https://example.invalid/source","harness.research_summary":"Stray."}'
expect_violation research-stray "generator_research_provenance_invalid line 1"

# A successful escalated repair after two failures must persist a durable rule.
make_case durable-missing
add_span durable-missing conductor deviation fail regression point-fix
add_span durable-missing conductor deviation blocked regression class-fix
add_span durable-missing conductor deviation pass regression class-fix
expect_violation durable-missing "generator_durable_rule_missing line 3"

make_case durable-valid
add_span durable-valid conductor deviation fail regression point-fix
add_span durable-valid conductor deviation blocked regression class-fix
add_span durable-valid conductor deviation pass regression class-fix "" \
  '{"harness.durable_rule_path":"AGENTS.md","harness.durable_rule_summary":"Keep one durable class rule."}'
expect_clean durable-valid

printf 'current same-class escalation contract honored\n'
