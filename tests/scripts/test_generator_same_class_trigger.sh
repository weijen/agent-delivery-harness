#!/usr/bin/env bash
# Regression sensor for issue #317, feature generator-same-class-trigger.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
LOG_HANDBACK="${ROOT}/scripts/log-handback.sh"
GENERATOR="${ROOT}/.copilot/agents/generator-subagent.agent.md"
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
[ -x "$CHECKER" ] || hard_fail "missing executable checker: $CHECKER"
[ -x "$LOG_HANDBACK" ] || hard_fail "missing executable emitter: $LOG_HANDBACK"

make_case() {
  local name="$1"
  mkdir -p "${TMP_DIR}/${name}"
  printf '# Issue 317\n\n## Action Log\n\n' > "${TMP_DIR}/${name}/progress.md"
  : > "${TMP_DIR}/${name}/trace.jsonl"
}

add_span() {
  local name="$1" role="$2" step="$3" outcome="$4" cls="$5" disposition="$6" detail="${7:-}"
  jq -cn \
    --arg role "$role" --arg step "$step" --arg outcome "$outcome" \
    --arg cls "$cls" --arg disposition "$disposition" --arg detail "$detail" '
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
        "harness.outcome": $outcome
      }
      + (if $cls == "" then {} else {"harness.failure_class": $cls} end)
      + (if $disposition == "" then {} else {"harness.failure_disposition": $disposition} end)
      + (if $detail == "" then {} else {"harness.failure_class_detail": $detail} end)
    ' >> "${TMP_DIR}/${name}/trace.jsonl"
  printf -- '- [%s] %s selected-feature %s — fixture\n' \
    "$role" "$step" "$outcome" >> "${TMP_DIR}/${name}/progress.md"
}

OUT="${TMP_DIR}/out"
ERR="${TMP_DIR}/err"
run_checker() {
  local name="$1" rc=0
  "$CHECKER" "${TMP_DIR}/${name}/trace.jsonl" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

expect_clean() {
  local name="$1" rc
  rc="$(run_checker "$name")"
  [ "$rc" = "0" ] \
    || fail "${name}: expected clean exit, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
}

expect_violation() {
  local name="$1" finding="$2" rc
  rc="$(run_checker "$name")"
  [ "$rc" = "1" ] \
    || fail "${name}: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
  grep -Fq "VIOLATION consistency: ${finding}" "$OUT" \
    || fail "${name}: missing ${finding} ($(tr '\n' '|' < "$OUT"))"
}

# A passing RED is evidence that the sensor failed as intended, not a stuck
# generator failure. The later blocked occurrence is therefore occurrence 1.
make_case red-pass-not-counted
add_span red-pass-not-counted generator-subagent red_handback pass knowledge-gap point-fix
add_span red-pass-not-counted generator-subagent impl_handback blocked knowledge-gap point-fix
expect_clean red-pass-not-counted

# First eligible occurrence may use a point fix.
make_case first-point-fix
add_span first-point-fix generator-subagent impl_handback fail regression point-fix
expect_clean first-point-fix

# Occurrence 2+ may use neither point-fix nor a missing disposition.
make_case repeated-point-fix
add_span repeated-point-fix generator-subagent impl_handback fail regression point-fix
add_span repeated-point-fix generator-subagent green_handback blocked regression point-fix
expect_violation repeated-point-fix "generator_repeated_point_fix line 2"

make_case repeated-missing
add_span repeated-missing generator-subagent red_handback blocked complexity point-fix
add_span repeated-missing generator-subagent impl_handback fail complexity ""
expect_violation repeated-missing "generator_failure_disposition_missing line 2"

# Closed class-specific routing on occurrence 2.
for route_case in \
  "knowledge-gap research" \
  "knowledge-gap research-requested" \
  "complexity decompose" \
  "known-flaky exemption" \
  "known-flaky override" \
  "polling exemption" \
  "polling override" \
  "regression class-fix"; do
  cls="${route_case%% *}"
  disposition="${route_case#* }"
  name="route-${cls}-${disposition}"
  make_case "$name"
  add_span "$name" generator-subagent impl_handback fail "$cls" point-fix
  add_span "$name" generator-subagent green_handback blocked "$cls" "$disposition"
  expect_clean "$name"
done

make_case wrong-route
add_span wrong-route generator-subagent impl_handback fail complexity point-fix
add_span wrong-route generator-subagent green_handback blocked complexity research
expect_violation wrong-route "generator_failure_route_mismatch line 2"

make_case invalid-disposition
add_span invalid-disposition generator-subagent impl_handback fail regression invented-route
expect_violation invalid-disposition "generator_failure_disposition_invalid line 1"

# "other" remains valid only with detail, including on generator handbacks.
make_case other-no-detail
add_span other-no-detail generator-subagent impl_handback fail other point-fix
expect_violation other-no-detail "generator_failure_class_other_no_detail line 1"

make_case other-with-detail
add_span other-with-detail generator-subagent impl_handback fail other point-fix "portable jq mismatch"
expect_clean other-with-detail

# Review verdicts are outside this trigger even when repeated.
make_case reviews-out-of-scope
add_span reviews-out-of-scope code-review-subagent review_verdict blocked complexity point-fix
add_span reviews-out-of-scope code-review-subagent review_verdict blocked complexity point-fix
expect_clean reviews-out-of-scope

# Emitter: valid generator class/disposition pass through, invalid values warn
# and omit, while the existing review-verdict class path remains intact.
E_DIR="${TMP_DIR}/emitter"
mkdir -p "${E_DIR}/.copilot-tracking/issues/issue-317"
(
  cd "$E_DIR"
  git init -q
  git checkout -b feature/issue-317-test >/dev/null 2>&1
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf '# Issue 317\n\n## Action Log\n\n' \
    > .copilot-tracking/issues/issue-317/progress.md
  git add -A
  git commit -q -m "test fixture"
)
E_TRACE="${E_DIR}/.copilot-tracking/issues/issue-317/trace.jsonl"
(
  cd "$E_DIR"
  TRACE_ISSUE=317 TRACE_FAILURE_CLASS=knowledge-gap TRACE_FAILURE_DISPOSITION=research \
    "$LOG_HANDBACK" generator-subagent impl_handback selected-feature fail "fixture" >/dev/null
)
jq -e 'select(.["gen_ai.agent.name"] == "generator-subagent")
  | .["harness.failure_class"] == "knowledge-gap"
    and .["harness.failure_disposition"] == "research"' "$E_TRACE" >/dev/null \
  || fail "emitter: valid generator class/disposition were not emitted"

(
  cd "$E_DIR"
  TRACE_ISSUE=317 TRACE_FAILURE_CLASS=not-a-class TRACE_FAILURE_DISPOSITION=not-a-route \
    "$LOG_HANDBACK" generator-subagent green_handback selected-feature blocked "fixture" \
    >/dev/null 2>"${TMP_DIR}/emitter-warning"
)
tail -n 1 "$E_TRACE" | jq -e '
  (has("harness.failure_class") | not)
  and (has("harness.failure_disposition") | not)' >/dev/null \
  || fail "emitter: invalid generator values must be omitted"
grep -Fq 'TRACE_FAILURE_CLASS' "${TMP_DIR}/emitter-warning" \
  || fail "emitter: invalid class warning missing"
grep -Fq 'TRACE_FAILURE_DISPOSITION' "${TMP_DIR}/emitter-warning" \
  || fail "emitter: invalid disposition warning missing"

# Prompt structure: the generator must inspect prior eligible handbacks and
# return class and separate disposition for conductor logging.
same_class_section="$(awk '
  /^## Same-Class Escalation$/ { capture=1; next }
  capture && /^## / { exit }
  capture { print }
' "$GENERATOR")"
[ -n "$same_class_section" ] \
  || fail "generator contract: missing ## Same-Class Escalation section"
for term in failure_class failure_disposition red_handback impl_handback green_handback \
  point-fix class-fix research research-requested decompose exemption override; do
  printf '%s\n' "$same_class_section" | grep -Fq "$term" \
    || fail "generator contract: Same-Class Escalation missing '${term}'"
done

if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'generator same-class trigger contract honored\n'
