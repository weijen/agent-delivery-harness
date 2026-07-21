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

# The consistency checker independently rejects hand-written research spans
# that bypass the emitter without a valid pair.
CONSISTENCY_DIR="${TMP_DIR}/consistency"
mkdir -p "$CONSISTENCY_DIR"
printf '# Fixture\n\n## Action Log\n\n- [generator-subagent] impl_handback fixture pass — fixture\n' \
  > "${CONSISTENCY_DIR}/progress.md"
cat > "${CONSISTENCY_DIR}/trace.jsonl" <<'JSON'
{"span":"agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.feature_id":"fixture","harness.outcome":"pass","harness.failure_disposition":"research"}
JSON
if "$CHECKER" "${CONSISTENCY_DIR}/trace.jsonl" >"${TMP_DIR}/consistency.out" 2>&1; then
  fail "consistency checker must reject research disposition without provenance"
fi
grep -Fq 'generator_research_provenance_invalid line 1' "${TMP_DIR}/consistency.out" \
  || fail "consistency checker must report the missing or invalid research pair"

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
