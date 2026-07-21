#!/usr/bin/env bash
# Regression sensor for issue #317, feature generator-research-provenance.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${ROOT}/scripts/log-handback.sh"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
GENERATOR="${ROOT}/.copilot/agents/generator-subagent.agent.md"
TMP_BASE="${ROOT}/.test-artifacts"
mkdir -p "$TMP_BASE"
TMP_DIR="$(mktemp -d "${TMP_BASE}/provenance.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"; rmdir "${TMP_BASE}" 2>/dev/null || true' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -x "$HELPER" ] || fail "missing executable helper: $HELPER"

REPO="${TMP_DIR}/repo"
mkdir -p "${REPO}/.copilot-tracking/issues/issue-317"
(
  cd "$REPO"
  git init -q
  git checkout -q -b feature/issue-317-provenance
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf '# Issue 317\n\n## Action Log\n\n' \
    > .copilot-tracking/issues/issue-317/progress.md
  git add -A
  git commit -q -m "test fixture"
)

TRACE="${REPO}/.copilot-tracking/issues/issue-317/trace.jsonl"
PROGRESS="${REPO}/.copilot-tracking/issues/issue-317/progress.md"
URL="https://example.invalid/research/one"
SUMMARY="Document describes the bounded adapter contract."

run_handback() {
  local output="$1" url="$2" research_summary="$3" disposition="$4"
  shift 4
  (
    cd "$REPO"
    TRACE_ISSUE=317 \
      TRACE_RESEARCH_URL="$url" \
      TRACE_RESEARCH_SUMMARY="$research_summary" \
      TRACE_FAILURE_DISPOSITION="$disposition" \
      "$HELPER" "$@"
  ) >"$output" 2>&1
}

span_count() {
  [ -f "$TRACE" ] && wc -l < "$TRACE" | tr -d '[:space:]' || printf '0'
}

# A research disposition claims that an external action occurred, so provenance
# is mandatory rather than optional on that route.
if run_handback "${TMP_DIR}/missing-pair.out" "" "" research \
  generator-subagent impl_handback generator-research-provenance pass \
  "performed bounded research without provenance"; then
  fail "performed research without URL and summary must be rejected"
fi

# A performed generator research handback records the same validated pair in
# its span and the single Action Log row produced by this invocation.
run_handback "${TMP_DIR}/valid.out" "$URL" "$SUMMARY" research \
  generator-subagent impl_handback generator-research-provenance pass \
  "researched ${URL} — ${SUMMARY}" \
  || fail "valid research provenance must not fail the handback"
[ "$(span_count)" = "1" ] || fail "valid handback must emit exactly one span"
jq -e --arg url "$URL" --arg summary "$SUMMARY" '
  .["harness.research_url"] == $url
  and .["harness.research_summary"] == $summary
' "$TRACE" >/dev/null || fail "trace must carry separate validated URL and summary fields"
[ "$(grep -Fc -- "- [generator-subagent] impl_handback generator-research-provenance pass" "$PROGRESS")" = "1" ] \
  || fail "the helper invocation must append exactly one Action Log row"
tail -n 1 "$PROGRESS" | grep -Fq "research: ${URL} — ${SUMMARY}" \
  || fail "the same Action Log row must make validated research provenance auditable"

expect_rejected() {
  local name="$1" url="$2" summary="$3" disposition="$4"
  local before after
  before="$(span_count)"
  if run_handback "${TMP_DIR}/${name}.out" "$url" "$summary" "$disposition" \
    generator-subagent green_handback generator-research-provenance blocked \
    "provenance rejection fixture"; then
    fail "${name}: invalid performed-research provenance must be rejected"
  fi
  after="$(span_count)"
  [ "$after" -eq "$before" ] || fail "${name}: rejected provenance must not emit a span"
}

expect_rejected missing-summary "$URL" "" research
expect_rejected malformed-url "file:///private/source" "$SUMMARY" research
expect_rejected missing-host "https:///path-only" "$SUMMARY" research
expect_rejected blank-summary "$URL" "   " research
expect_rejected multiline-summary "$URL" $'first line\nsecond line' research

# research-requested means the adapter could not perform research, so supplied
# provenance must warn rather than claim that a source was consulted.
before="$(span_count)"
run_handback "${TMP_DIR}/research-requested.out" "$URL" "$SUMMARY" research-requested \
  generator-subagent green_handback generator-research-provenance blocked \
  "provenance omission fixture" \
  || fail "research-requested: supplied fake provenance must warn and continue"
[ "$(span_count)" -eq $((before + 1)) ] || fail "research-requested: expected one new span"
tail -n 1 "$TRACE" | jq -e '
  (has("harness.research_url") | not)
  and (has("harness.research_summary") | not)
' >/dev/null || fail "research-requested: fake provenance must be omitted"
grep -qi 'research.*provenance' "${TMP_DIR}/research-requested.out" \
  || fail "research-requested: fake provenance omission must warn"

# Ambient provenance never leaks onto ineligible roles or non-research routes.
before="$(span_count)"
run_handback "${TMP_DIR}/ineligible.out" "$URL" "$SUMMARY" research \
  conductor deviation generator-research-provenance blocked "fixture" \
  || fail "ineligible role must still log normally"
run_handback "${TMP_DIR}/wrong-route.out" "$URL" "$SUMMARY" class-fix \
  generator-subagent green_handback generator-research-provenance pass "fixture" \
  || fail "non-research generator route must still log normally"
[ "$(span_count)" -eq $((before + 2)) ] || fail "ineligible calls must each emit one span"
tail -n 2 "$TRACE" | jq -e -s 'all(.[];
  (has("harness.research_url") | not)
  and (has("harness.research_summary") | not)
)' >/dev/null || fail "provenance must be limited to eligible generator research handbacks"

# The consistency checker independently enforces the complete route-dependent
# provenance truth table for hand-written traces that bypass the emitter.
CONSISTENCY_DIR="${TMP_DIR}/consistency"
mkdir -p "$CONSISTENCY_DIR"
check_direct_trace() {
  local name="$1" expected="$2" trace="$3" role="${4:-generator-subagent}"
  local step="${5:-impl_handback}" output="${TMP_DIR}/consistency-${1}.out"
  printf '%s\n' "$trace" > "${CONSISTENCY_DIR}/trace.jsonl"
  printf '# Fixture\n\n## Action Log\n\n- [%s] %s fixture pass — fixture\n' \
    "$role" "$step" > "${CONSISTENCY_DIR}/progress.md"
  if "$CHECKER" "${CONSISTENCY_DIR}/trace.jsonl" >"$output" 2>&1; then
    [ "$expected" = "pass" ] || fail "${name}: contradictory provenance passed consistency"
  else
    [ "$expected" != "pass" ] || fail "${name}: valid provenance failed consistency"
    if [ "$expected" = "fail" ]; then
      grep -Fq 'generator_research_provenance_invalid line 1' "$output" \
        || fail "${name}: expected provenance consistency finding"
    else
      ! grep -Fq 'generator_research_provenance_invalid' "$output" \
        || fail "${name}: unrelated route was incorrectly provenance-validated"
    fi
  fi
}

for step in red_handback impl_handback green_handback; do
  DIRECT_BASE="\"span\":\"agent\",\"gen_ai.agent.name\":\"generator-subagent\",\"harness.lifecycle_step\":\"${step}\",\"harness.feature_id\":\"fixture\",\"harness.outcome\":\"pass\""
  check_direct_trace "${step}-research-valid" pass \
    "{${DIRECT_BASE},\"harness.failure_disposition\":\"research\",\"harness.research_url\":\"${URL}\",\"harness.research_summary\":\"${SUMMARY}\"}" \
    generator-subagent "$step"
  check_direct_trace "${step}-research-missing" fail \
    "{${DIRECT_BASE},\"harness.failure_disposition\":\"research\"}" generator-subagent "$step"
  check_direct_trace "${step}-research-url-only" fail \
    "{${DIRECT_BASE},\"harness.failure_disposition\":\"research\",\"harness.research_url\":\"${URL}\"}" \
    generator-subagent "$step"
  check_direct_trace "${step}-research-summary-only" fail \
    "{${DIRECT_BASE},\"harness.failure_disposition\":\"research\",\"harness.research_summary\":\"${SUMMARY}\"}" \
    generator-subagent "$step"
  check_direct_trace "${step}-research-malformed-url" fail \
    "{${DIRECT_BASE},\"harness.failure_disposition\":\"research\",\"harness.research_url\":\"file:///private/source\",\"harness.research_summary\":\"${SUMMARY}\"}" \
    generator-subagent "$step"
  check_direct_trace "${step}-research-blank-summary" fail \
    "{${DIRECT_BASE},\"harness.failure_disposition\":\"research\",\"harness.research_url\":\"${URL}\",\"harness.research_summary\":\" \"}" \
    generator-subagent "$step"
  check_direct_trace "${step}-research-multiline-summary" fail \
    "{${DIRECT_BASE},\"harness.failure_disposition\":\"research\",\"harness.research_url\":\"${URL}\",\"harness.research_summary\":\"first\\nsecond\"}" \
    generator-subagent "$step"

  for disposition in point-fix class-fix decompose exemption override research-requested; do
    check_direct_trace "${step}-${disposition}-absent" pass \
      "{${DIRECT_BASE},\"harness.failure_disposition\":\"${disposition}\"}" generator-subagent "$step"
    check_direct_trace "${step}-${disposition}-url-only" fail \
      "{${DIRECT_BASE},\"harness.failure_disposition\":\"${disposition}\",\"harness.research_url\":\"${URL}\"}" \
      generator-subagent "$step"
    check_direct_trace "${step}-${disposition}-summary-only" fail \
      "{${DIRECT_BASE},\"harness.failure_disposition\":\"${disposition}\",\"harness.research_summary\":\"${SUMMARY}\"}" \
      generator-subagent "$step"
    check_direct_trace "${step}-${disposition}-pair" fail \
      "{${DIRECT_BASE},\"harness.failure_disposition\":\"${disposition}\",\"harness.research_url\":\"${URL}\",\"harness.research_summary\":\"${SUMMARY}\"}" \
      generator-subagent "$step"
  done
done

check_direct_trace unrelated-role pass \
  "{\"span\":\"agent\",\"gen_ai.agent.name\":\"conductor\",\"harness.lifecycle_step\":\"deviation\",\"harness.feature_id\":\"fixture\",\"harness.outcome\":\"pass\",\"harness.failure_disposition\":\"research-requested\",\"harness.research_url\":\"${URL}\",\"harness.research_summary\":\"${SUMMARY}\"}" \
  conductor deviation
check_direct_trace unrelated-step pass \
  "{\"span\":\"agent\",\"gen_ai.agent.name\":\"generator-subagent\",\"harness.lifecycle_step\":\"deviation\",\"harness.feature_id\":\"fixture\",\"harness.outcome\":\"pass\",\"harness.failure_disposition\":\"research-requested\",\"harness.research_url\":\"${URL}\",\"harness.research_summary\":\"${SUMMARY}\"}" \
  generator-subagent deviation

jq -e '
  .optional_fields["harness.research_url"]
  and .optional_fields["harness.research_summary"]
' "$SCHEMA" >/dev/null || fail "trace schema must document both provenance fields"
jq -er '.notes.research_provenance' "$SCHEMA" \
  | grep -Eqi 'globally optional.*conditionally required.*valid pair' \
  || fail "trace schema must distinguish globally optional fields from the required research pair"
jq -er '.notes.research_provenance' "$SCHEMA" \
  | grep -Eqi 'hard-fails.*before span or Action Log emission.*direct traces fail consistency' \
  || fail "trace schema must document pre-emission and direct-trace failure semantics"
grep -Eqi 'globally optional, open-world fields' \
  "${ROOT}/docs/evaluation/observability-and-trace-schema.md" \
  || fail "trace prose must not describe research provenance as unconditionally optional"
tr '\n' ' ' < "${ROOT}/docs/evaluation/observability-and-trace-schema.md" \
  | grep -Eqi 'missing, partial, malformed, or multiline.{0,80}hard-fails before either the span or Action Log' \
  || fail "trace prose must document hard failure before both emissions"
tr '\n' ' ' < "${ROOT}/docs/evaluation/observability-and-trace-schema.md" \
  | grep -Eqi 'research-requested.{0,120}ineligible' \
  || fail "trace prose must document research-requested provenance ineligibility"

grep -Fq "\`Research provenance\`" "$GENERATOR" \
  || fail "generator output contract must require a Research provenance inventory"
grep -Eqi 'URL.*one-line content summary|one-line content summary.*URL' "$GENERATOR" \
  || fail "generator inventory must pair each URL with a one-line content summary"
tr '\n' ' ' < "$GENERATOR" \
  | grep -Eqi 'structured payload.{0,180}same URL.{0,80}summary|same URL.{0,80}summary.{0,180}structured payload' \
  || fail "generator contract must require matching provenance in the relevant payload summary"
tr '\n' ' ' < "$GENERATOR" \
  | grep -Eqi 'fetched (page )?content.{0,120}(out of|never.*in).*trace|trace.{0,120}never.*fetched (page )?content' \
  || fail "generator contract must keep fetched page content out of trace"

printf 'generator research provenance contract honored\n'
