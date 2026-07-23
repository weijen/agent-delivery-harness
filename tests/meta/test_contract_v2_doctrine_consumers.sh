#!/usr/bin/env bash
# Contract-v2 regression sensor for the four live doctrine consumers.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEWER="${ROOT}/.copilot/agents/code-review-subagent.agent.md"
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

if [ "${fail}" -ne 0 ]; then
  exit 1
fi

printf 'PASS: contract-v2 doctrine consumers use one delivering agent, one reviewer, and four gates.\n'
