#!/usr/bin/env bash
# Regression sensor for issue #317, feature generator-durable-rule.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
LOG_HANDBACK="${ROOT}/scripts/log-handback.sh"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
GENERATOR="${ROOT}/.copilot/agents/generator-subagent.agent.md"
HARNESS_DOC="${ROOT}/docs/HARNESS.md"
TMP_BASE="${ROOT}/.test-artifacts"
mkdir -p "$TMP_BASE"
TMP_DIR="$(mktemp -d "${TMP_BASE}/durable-rule.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"; rmdir "${TMP_BASE}" 2>/dev/null || true' EXIT

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
  local name="$1" repo
  repo="${TMP_DIR}/${name}"
  mkdir -p "${repo}/.copilot-tracking/issues/issue-317" \
    "${repo}/.copilot/instructions" "${repo}/docs"
  printf '# Repository rules\n' > "${repo}/AGENTS.md"
  printf '%s\n' '---' "applyTo: '**/*.sh'" '---' '# Bash rules' \
    > "${repo}/.copilot/instructions/bash.instructions.md"
  printf '# Ordinary documentation\n' > "${repo}/docs/lesson.md"
  printf '# Issue 317\n\n## Action Log\n\n' \
    > "${repo}/.copilot-tracking/issues/issue-317/progress.md"
  : > "${repo}/.copilot-tracking/issues/issue-317/trace.jsonl"
}

add_span() {
  local name="$1" role="$2" step="$3" outcome="$4" cls="$5" disposition="$6"
  local path="${7:-}" summary="${8:-}"
  local repo="${TMP_DIR}/${name}"
  jq -cn \
    --arg role "$role" --arg step "$step" --arg outcome "$outcome" \
    --arg cls "$cls" --arg disposition "$disposition" \
    --arg path "$path" --arg summary "$summary" '
      {
        schema_version: 1,
        timestamp: "2026-07-21T00:00:00Z",
        span: "agent",
        "harness.issue": 317,
        "harness.version": "0.0.0-dev",
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": $role,
        "harness.lifecycle_step": $step,
        "harness.feature_id": "generator-durable-rule",
        "harness.outcome": $outcome
      }
      + (if $cls == "" then {} else {"harness.failure_class": $cls} end)
      + (if $disposition == "" then {} else {"harness.failure_disposition": $disposition} end)
      + (if $path == "" then {} else {"harness.durable_rule_path": $path} end)
      + (if $summary == "" then {} else {"harness.durable_rule_summary": $summary} end)
    ' >> "${repo}/.copilot-tracking/issues/issue-317/trace.jsonl"
  printf -- '- [%s] %s generator-durable-rule %s — fixture\n' \
    "$role" "$step" "$outcome" \
    >> "${repo}/.copilot-tracking/issues/issue-317/progress.md"
}

add_escalation() {
  local name="$1" cls="${2:-regression}" route="${3:-class-fix}"
  add_span "$name" generator-subagent impl_handback fail "$cls" point-fix
  add_span "$name" generator-subagent impl_handback blocked "$cls" "$route"
}

OUT="${TMP_DIR}/checker.out"
ERR="${TMP_DIR}/checker.err"
run_checker() {
  local name="$1" rc=0
  "$CHECKER" "${TMP_DIR}/${name}/.copilot-tracking/issues/issue-317/trace.jsonl" \
    >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

expect_clean() {
  local name="$1" rc
  rc="$(run_checker "$name")"
  [ "$rc" = "0" ] \
    || fail "${name}: expected clean exit, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
}

expect_violation() {
  local name="$1" finding="$2" rc
  rc="$(run_checker "$name")"
  [ "$rc" = "1" ] \
    || fail "${name}: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
  grep -Fq "VIOLATION consistency: ${finding}" "$OUT" \
    || fail "${name}: missing ${finding} ($(tr '\n' '|' < "$OUT"))"
}

# A successful escalated repair is a generator GREEN/pass whose class and
# non-exemption route match a second-or-later prior same-class failure.
make_case missing
add_escalation missing
add_span missing generator-subagent green_handback pass regression class-fix
expect_violation missing "generator_durable_rule_missing line 3"

make_case agents
add_escalation agents
add_span agents generator-subagent green_handback pass regression class-fix \
  AGENTS.md "Regression class fixes must preserve the failing fixture."
expect_clean agents

make_case instruction
add_escalation instruction complexity decompose
add_span instruction generator-subagent green_handback pass complexity decompose \
  .copilot/instructions/bash.instructions.md \
  "Decomposed shell repairs retain one behavioral assertion per helper."
expect_clean instruction

for invalid_case in docs arbitrary absolute traversal missing-file empty-summary multiline-summary; do
  make_case "$invalid_case"
  add_escalation "$invalid_case"
  path="AGENTS.md"
  summary="A local one-line lesson."
  case "$invalid_case" in
    docs) path="docs/lesson.md" ;;
    arbitrary) path="README.md" ;;
    absolute) path="${TMP_DIR}/${invalid_case}/AGENTS.md" ;;
    traversal) path=".copilot/instructions/../instructions/bash.instructions.md" ;;
    missing-file) path=".copilot/instructions/missing.instructions.md" ;;
    empty-summary) summary="" ;;
    multiline-summary) summary=$'first line\nsecond line' ;;
  esac
  add_span "$invalid_case" generator-subagent green_handback pass regression class-fix \
    "$path" "$summary"
  expect_violation "$invalid_case" "generator_durable_rule_invalid line 3"
done

make_case symlink-file
ln -s "${TMP_DIR}/symlink-file/AGENTS.md" \
  "${TMP_DIR}/symlink-file/.copilot/instructions/linked.instructions.md"
add_escalation symlink-file
add_span symlink-file generator-subagent green_handback pass regression class-fix \
  .copilot/instructions/linked.instructions.md "Symlinks are not durable rule targets."
expect_violation symlink-file "generator_durable_rule_invalid line 3"

# First-occurrence point fixes, arbitrary pass spans, blocked research requests,
# exemptions, and review verdicts are not successful escalated class fixes.
make_case first-point-fix
add_span first-point-fix generator-subagent impl_handback fail regression point-fix
add_span first-point-fix generator-subagent green_handback pass regression point-fix
expect_clean first-point-fix

make_case arbitrary-pass
add_span arbitrary-pass generator-subagent green_handback pass regression class-fix
expect_clean arbitrary-pass

make_case research-requested
add_span research-requested generator-subagent impl_handback fail knowledge-gap point-fix
add_span research-requested generator-subagent green_handback blocked knowledge-gap research-requested
expect_clean research-requested

# A later successful research repair remains escalated even when the immediately
# preceding blocked route was research-requested, and must persist its lesson.
make_case research-after-request
add_span research-after-request generator-subagent impl_handback fail knowledge-gap point-fix
add_span research-after-request generator-subagent green_handback blocked knowledge-gap research-requested
add_span research-after-request generator-subagent green_handback pass knowledge-gap research
expect_violation research-after-request "generator_durable_rule_missing line 3"

make_case exemption
add_escalation exemption known-flaky exemption
add_span exemption generator-subagent green_handback pass known-flaky exemption
expect_clean exemption

make_case review
add_escalation review
add_span review code-review-subagent review_verdict pass regression class-fix
expect_clean review

# The single-source emitter forwards only a validated pair on a semantically
# eligible generator GREEN/pass and validates the target in the real repo.
E_REPO="${TMP_DIR}/emitter"
mkdir -p "${E_REPO}/.copilot-tracking/issues/issue-317" \
  "${E_REPO}/.copilot/instructions"
(
  cd "$E_REPO"
  git init -q
  git checkout -q -b feature/issue-317-durable
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf '# Rules\n' > AGENTS.md
  printf '# Shell rules\n' > .copilot/instructions/bash.instructions.md
  printf '# Issue 317\n\n## Action Log\n\n' \
    > .copilot-tracking/issues/issue-317/progress.md
  git add -A
  git commit -q -m "test fixture"
)
E_TRACE="${E_REPO}/.copilot-tracking/issues/issue-317/trace.jsonl"
(
  cd "$E_REPO"
  TRACE_ISSUE=317 TRACE_FAILURE_CLASS=regression \
    TRACE_FAILURE_DISPOSITION=class-fix \
    TRACE_DURABLE_RULE_PATH=.copilot/instructions/bash.instructions.md \
    TRACE_DURABLE_RULE_SUMMARY="Shell class fixes retain a negative fixture." \
    "$LOG_HANDBACK" generator-subagent green_handback \
    generator-durable-rule pass "fixture"
) >/dev/null
jq -e '
  .["harness.durable_rule_path"] == ".copilot/instructions/bash.instructions.md"
  and .["harness.durable_rule_summary"] == "Shell class fixes retain a negative fixture."
' "$E_TRACE" >/dev/null || fail "emitter: valid durable-rule evidence was not emitted"

before="$(wc -l < "$E_TRACE" | tr -d '[:space:]')"
(
  cd "$E_REPO"
  TRACE_ISSUE=317 TRACE_FAILURE_CLASS=regression \
    TRACE_FAILURE_DISPOSITION=class-fix \
    TRACE_DURABLE_RULE_PATH=../AGENTS.md \
    TRACE_DURABLE_RULE_SUMMARY=$'bad\nsummary' \
    "$LOG_HANDBACK" generator-subagent green_handback \
    generator-durable-rule pass "fixture"
) >"${TMP_DIR}/emitter-invalid.out" 2>&1
[ "$(wc -l < "$E_TRACE" | tr -d '[:space:]')" -eq $((before + 1)) ] \
  || fail "emitter: malformed optional evidence must still log one handback"
tail -n 1 "$E_TRACE" | jq -e '
  (has("harness.durable_rule_path") | not)
  and (has("harness.durable_rule_summary") | not)
' >/dev/null || fail "emitter: invalid durable evidence must emit both-or-neither"
grep -Fqi 'durable rule' "${TMP_DIR}/emitter-invalid.out" \
  || fail "emitter: invalid durable evidence omission must warn"

(
  cd "$E_REPO"
  TRACE_ISSUE=317 TRACE_FAILURE_CLASS=regression \
    TRACE_FAILURE_DISPOSITION=class-fix \
    TRACE_DURABLE_RULE_PATH=AGENTS.md \
    TRACE_DURABLE_RULE_SUMMARY="Must not leak onto blocked handbacks." \
    "$LOG_HANDBACK" generator-subagent green_handback \
    generator-durable-rule blocked "fixture"
) >/dev/null
tail -n 1 "$E_TRACE" | jq -e '
  (has("harness.durable_rule_path") | not)
  and (has("harness.durable_rule_summary") | not)
' >/dev/null || fail "emitter: durable evidence must be limited to GREEN/pass"

(
  cd "$E_REPO"
  TRACE_ISSUE=317 TRACE_FAILURE_CLASS=complexity \
    TRACE_FAILURE_DISPOSITION=class-fix \
    TRACE_DURABLE_RULE_PATH=AGENTS.md \
    TRACE_DURABLE_RULE_SUMMARY="Must not leak onto a mismatched class route." \
    "$LOG_HANDBACK" generator-subagent green_handback \
    generator-durable-rule pass "fixture"
) >/dev/null
tail -n 1 "$E_TRACE" | jq -e '
  (has("harness.durable_rule_path") | not)
  and (has("harness.durable_rule_summary") | not)
' >/dev/null || fail "emitter: durable evidence must require a class-correct repair route"

jq -e '
  .optional_fields["harness.durable_rule_path"]
  and .optional_fields["harness.durable_rule_summary"]
' "$SCHEMA" >/dev/null || fail "schema must document durable-rule path and summary"

grep -Fq '## Durable Class Lessons' "$GENERATOR" \
  || fail "generator contract: missing Durable Class Lessons section"
if ! grep -Fq 'AGENTS.md' "$GENERATOR" \
  || ! grep -Fq '.copilot/instructions/*.instructions.md' "$GENERATOR"; then
  fail "generator contract: allowed durable targets are unclear"
fi
grep -Fq 'TRACE_DURABLE_RULE_PATH' "$GENERATOR" \
  || fail "generator contract: path payload metadata is absent"
grep -Fq 'TRACE_DURABLE_RULE_SUMMARY' "$GENERATOR" \
  || fail "generator contract: summary payload metadata is absent"
tr '\n' ' ' < "$HARNESS_DOC" \
  | grep -Ei 'trace carries only (the )?path[[:space:]]+and (one-line )?summary' >/dev/null \
  || fail "HARNESS docs: durable repository lesson and narrow trace evidence are absent"

if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'generator durable-rule contract honored\n'
