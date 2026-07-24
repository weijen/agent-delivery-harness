#!/usr/bin/env bash
# Contract-v2 regression sensor for the live doctrine consumers.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEWER="${REVIEWER_OVERRIDE:-${ROOT}/.copilot/agents/code-review-subagent.agent.md}"
AGENTS="${ROOT}/AGENTS.md"
WORKFLOW="${ROOT}/.copilot/instructions/workflow-tiers.instructions.md"
EVALUATION="${ROOT}/docs/evaluation/README.md"
RUBRIC="${ROOT}/docs/evaluation/product-quality-rubric.md"
GETTING_STARTED="${ROOT}/docs/getting-started.md"

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
grep -qi 'authoritative' <<<"${trace_flat}" \
  || note "reviewer trace guidance lost the authoritative-evidence designation"
grep -qi 'corroborat' <<<"${trace_flat}" \
  || note "reviewer trace guidance lost the corroborating-evidence designation"
# Affirmative retired-requirement guard: sentence-scoped and subject-agnostic.
# Obligation verbs beyond "require" (verify/confirm/ensure/check/demand) are
# covered so the retired choreography cannot come back under another verb, and
# negated obligation phrases are STRIPPED (not whole-sentence exempted) so a
# decoy negation cannot shield an affirmative clause in the same sentence.
# Sentences split on terminator+whitespace+non-lowercase so neither file-path
# dots nor mid-sentence abbreviations ("e.g. legacy") fragment clauses.
retired_terms='retired[[:space:]]+(handback|choreography)|red_handback|impl_handback|green_handback'
obligation_verbs='requir(e|es|ed|ing)|verif(y|ies)|confirm(s|ed|ing)?|ensur(e|es|ing)?|check(s|ed|ing)?|demand(s|ed|ing)?|mandate[sd]?'
negation_strip='(do not|does not|must not|never|not to|without|no longer|not)[^!?]{0,60}(requir|verif|confirm|ensur|check|demand|mandat)[a-z]*'
affirmative_retired=0
while IFS= read -r sentence; do
  lower="$(tr '[:upper:]' '[:lower:]' <<<"${sentence}")"
  cleaned="$(sed -E "s/${negation_strip}//g" <<<"${lower}")"
  grep -qE "(${obligation_verbs})[^!?]{0,120}(${retired_terms})|(${retired_terms})[^!?]{0,120}(${obligation_verbs})" <<<"${cleaned}" || continue
  affirmative_retired=1
  break
done < <(awk '{
  s = $0
  while (match(s, /[.!?][ \t]+[^a-z \t]/)) {
    printf "%s\n", substr(s, 1, RSTART)
    s = substr(s, RSTART + RLENGTH - 1)
  }
  print s
}' <<<"${trace_flat}")
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
if grep -qiE 'routes? .*generator-subagent|owned by generator-subagent|to [`]?generator-subagent' \
  "${AGENTS}" "${WORKFLOW}" "${RUBRIC}" "${GETTING_STARTED}"; then
  note "live guidance still routes current work to generator-subagent"
fi
if grep -qiE 'Planner / implementer / tester / reviewer' "${EVALUATION}"; then
  note "evaluation layer map still presents the retired four-role topology"
fi
if grep -qiE 'subagents \(generator' "${GETTING_STARTED}"; then
  note "getting-started still presents generator/planner subagents as the current set"
fi

# Kill-check (mutation): prove the affirmative-requirement guard catches every
# prohibited form the repair reviews flagged — subject-prefixed, additive by
# span name, alternate obligation verb, and decoy-negation — and that benign
# historical/negated mentions stay exempt. A poisoned copy of the live reviewer
# prompt must make this sensor exit non-zero for exactly the guard's reason.
# Guarded so the child run does not recurse.
if [ -z "${DOCTRINE_SENSOR_KILL_CHECK:-}" ]; then
  kill_fixture="$(mktemp)"
  trap 'rm -f "${kill_fixture}"' EXIT
  for poison in \
    'The reviewer must require the retired handback choreography for every feature.' \
    'Additionally require red_handback spans for every completed feature.' \
    'Confirm the red_handback -> impl_handback -> green_handback ordering for every feature.' \
    'Require red_handback spans for each feature, but do not require green_handback.'; do
    awk -v poison="${poison}" '{print} /^## Trace \/ Process Evidence/ {print poison}' \
      "${REVIEWER}" >"${kill_fixture}"
    kill_out="$(DOCTRINE_SENSOR_KILL_CHECK=1 REVIEWER_OVERRIDE="${kill_fixture}" bash "${BASH_SOURCE[0]}" 2>&1)" \
      && note "kill-check: sensor passed a prohibited requirement: ${poison}"
    grep -qF 'affirmatively requires retired handback choreography' <<<"${kill_out}" \
      || note "kill-check: sensor rejected the poisoned prompt for the wrong reason: ${poison}"
  done
  for benign in \
    'Historical red_handback spans may appear as reader context.' \
    'The retired handback is not required for current runs.' \
    'Do not, per pre-#352 rules e.g. legacy traces, require red_handback.'; do
    awk -v poison="${benign}" '{print} /^## Trace \/ Process Evidence/ {print poison}' \
      "${REVIEWER}" >"${kill_fixture}"
    DOCTRINE_SENSOR_KILL_CHECK=1 REVIEWER_OVERRIDE="${kill_fixture}" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 \
      || note "kill-check: sensor false-positived on a benign mention: ${benign}"
  done
fi

if [ "${fail}" -ne 0 ]; then
  exit 1
fi

printf 'PASS: contract-v2 doctrine consumers use one delivering agent, one reviewer, and four gates.\n'
