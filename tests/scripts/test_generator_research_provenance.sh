#!/usr/bin/env bash
# Regression sensor for issue #317, feature generator-research-provenance.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${ROOT}/scripts/log-handback.sh"
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

expect_omitted() {
  local name="$1" url="$2" summary="$3" disposition="$4"
  local before after span
  before="$(span_count)"
  run_handback "${TMP_DIR}/${name}.out" "$url" "$summary" "$disposition" \
    generator-subagent green_handback generator-research-provenance blocked \
    "provenance omission fixture" \
    || fail "${name}: malformed optional provenance must warn and continue"
  after="$(span_count)"
  [ "$after" -eq $((before + 1)) ] || fail "${name}: expected one new span"
  span="$(tail -n 1 "$TRACE")"
  printf '%s\n' "$span" | jq -e '
    (has("harness.research_url") | not)
    and (has("harness.research_summary") | not)
  ' >/dev/null || fail "${name}: invalid provenance must emit both-or-neither"
  grep -qi 'research.*provenance' "${TMP_DIR}/${name}.out" \
    || fail "${name}: invalid provenance omission must warn"
  if tail -n 1 "$PROGRESS" | grep -Fq 'research:'; then
    fail "${name}: invalid provenance must not create Action Log evidence"
  fi
}

expect_omitted missing-summary "$URL" "" research
expect_omitted malformed-url "file:///private/source" "$SUMMARY" research
expect_omitted missing-host "https:///path-only" "$SUMMARY" research
expect_omitted blank-summary "$URL" "   " research
expect_omitted multiline-summary "$URL" $'first line\nsecond line' research

# research-requested means the adapter could not perform research, so supplied
# provenance must warn rather than claim that a source was consulted.
expect_omitted research-requested "$URL" "$SUMMARY" research-requested

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

jq -e '
  .optional_fields["harness.research_url"]
  and .optional_fields["harness.research_summary"]
' "$SCHEMA" >/dev/null || fail "trace schema must document both provenance fields"

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
