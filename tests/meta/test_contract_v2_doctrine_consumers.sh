#!/usr/bin/env bash
# Contract-v2 regression sensor for the four live doctrine consumers.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEWER="${REVIEWER_OVERRIDE:-${ROOT}/.copilot/agents/code-review-subagent.agent.md}"
AGENTS="${ROOT}/AGENTS.md"
WORKFLOW="${ROOT}/.copilot/instructions/workflow-tiers.instructions.md"
EVALUATION="${ROOT}/docs/evaluation/README.md"

fail=0
note() {
  printf 'FAIL: %s\n' "$*" >&2
  fail=$((fail + 1))
}

for file in "${REVIEWER}" "${AGENTS}" "${WORKFLOW}" "${EVALUATION}"; do
  for gate in gate_start gate_sensors gate_review gate_merge_closeout; do
    grep -qF "${gate}" "${file}" || note "${file} lacks ${gate}"
  done
done

trace_section="$(sed -n '/^## Trace \/ Process Evidence/,/^## /p' "${REVIEWER}")"
trace_flat="$(printf '%s\n' "${trace_section}" | tr '\n' ' ')"
for historical_name in red_handback impl_handback green_handback; do
  grep -qF "${historical_name}" <<<"${trace_flat}" \
    || note "reviewer trace guidance lacks historical compatibility for ${historical_name}"
done
grep -qiE 'reader.{0,80}historical|historical.{0,80}reader' <<<"${trace_flat}" \
  || note "reviewer trace guidance does not scope historical names to reader compatibility"
grep -qiE '(do not|must not|never).{0,80}require.{0,80}retired choreography' <<<"${trace_flat}" \
  || note "reviewer trace guidance does not forbid retired choreography as current evidence"
grep -qiE '(this review|review handback).{0,120}(supplies|produces|records).{0,80}review_verdict|review_verdict.{0,120}(this review|review handback)' <<<"${trace_flat}" \
  || note "reviewer trace guidance does not identify the current handback as gate_review verdict evidence"
grep -qiE '(approval|approved-head).{0,120}(after|following).{0,80}(review verdict|review handback|APPROVED)' <<<"${trace_flat}" \
  || note "reviewer trace guidance does not defer approval evidence until after the review verdict"
# Affirmative retired-requirement guard: sentence-scoped and subject-agnostic,
# so "The reviewer must require the retired handback ..." is caught even with a
# subject prefix, and additive reintroductions by historical span name
# ("require red_handback spans ...") are caught without the word "retired".
# Negated sentences (the prohibition itself) stay exempt.
retired_terms='retired[[:space:]]+(handback|choreography)|red_handback|impl_handback|green_handback'
affirmative_retired=0
while IFS= read -r sentence; do
  grep -qiE "requir(e|es|ed|ing)[^.!?]{0,120}(${retired_terms})|(${retired_terms})[^.!?]{0,120}requir(e|es|ed|ing)" <<<"${sentence}" || continue
  grep -qiE '(do[[:space:]]+not|does[[:space:]]+not|must[[:space:]]+not|never|not[[:space:]]+to|without)[[:space:]]+requir' <<<"${sentence}" && continue
  affirmative_retired=1
  break
done < <(printf '%s\n' "${trace_flat}" | tr '.!?' '\n')
if [ "${affirmative_retired}" -eq 1 ]; then
  note "reviewer trace guidance affirmatively requires retired handback choreography"
fi
if grep -qiE 'require.{0,120}(pre-existing|existing).{0,80}(review_verdict|approval evidence)|(review_verdict|approval evidence).{0,80}(before|prior to).{0,80}(this review|review handback)' <<<"${trace_flat}"; then
  note "reviewer trace guidance requires gate-review evidence before the review can produce it"
fi

grep -qiE 'one (delivering )?agent' "${AGENTS}" \
  || note "AGENTS.md lacks the one-delivering-agent topology"
grep -qiE 'one (delivering )?agent' "${WORKFLOW}" \
  || note "workflow tiers lack the one-delivering-agent topology"
grep -qiE 'Delivering agent / independent reviewer' "${EVALUATION}" \
  || note "evaluation layer map lacks the current two-role topology"

# Historical trace names remain schema-valid, but current instructions must
# address the delivering agent rather than a retired implementation role.
if grep -qiE '\b(the )?implementer\b' "${REVIEWER}"; then
  note "reviewer prompt still addresses a retired implementer role"
fi
if grep -qiE 'routes? .*generator-subagent|owned by generator-subagent' "${AGENTS}" "${WORKFLOW}"; then
  note "live guidance still routes current work to generator-subagent"
fi
if grep -qiE 'Planner / implementer / tester / reviewer' "${EVALUATION}"; then
  note "evaluation layer map still presents the retired four-role topology"
fi

# Kill-check (mutation): prove the affirmative-requirement guard catches a
# subject-prefixed sentence — the gap flagged by the #383 repair review. A
# poisoned copy of the live reviewer prompt must make this sensor exit non-zero
# for exactly that reason. Guarded so the child run does not recurse.
if [ -z "${DOCTRINE_SENSOR_KILL_CHECK:-}" ]; then
  kill_fixture="$(mktemp)"
  trap 'rm -f "${kill_fixture}"' EXIT
  for poison in \
    'The reviewer must require the retired handback choreography for every feature.' \
    'Additionally require red_handback spans for every completed feature.'; do
    awk -v poison="${poison}" '{print} /^## Trace \/ Process Evidence/ {print poison}' \
      "${REVIEWER}" >"${kill_fixture}"
    kill_out="$(DOCTRINE_SENSOR_KILL_CHECK=1 REVIEWER_OVERRIDE="${kill_fixture}" bash "${BASH_SOURCE[0]}" 2>&1)" \
      && note "kill-check: sensor passed a prohibited requirement: ${poison}"
    grep -qF 'affirmatively requires retired handback choreography' <<<"${kill_out}" \
      || note "kill-check: sensor rejected the poisoned prompt for the wrong reason: ${poison}"
  done
fi

if [ "${fail}" -ne 0 ]; then
  exit 1
fi

printf 'PASS: contract-v2 doctrine consumers use one delivering agent, one reviewer, and four gates.\n'
