#!/usr/bin/env bash
# Structural references used by the review evidence contract, not English semantics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEWER="${ROOT}/.copilot/agents/code-review-subagent.agent.md"
fail() { printf 'doctrine-consumers: %s\n' "$*" >&2; exit 1; }

trace_section="$(sed -n '/^## Trace \/ Process Evidence$/,/^## What You Do NOT Check$/p' "$REVIEWER")"
[ -n "$trace_section" ] || fail "review evidence section missing"
for reference in scripts/check-trace-consistency.sh scripts/validation/verify-sensor-evidence.sh; do
	grep -Fq "$reference" <<<"$trace_section" || fail "missing evidence-tool reference: $reference"
	[ -x "$ROOT/$reference" ] || fail "broken evidence-tool reference: $reference"
done
for token in gate_start gate_sensors gate_review gate_merge_closeout sensor-evidence.jsonl; do
	grep -Fq "$token" <<<"$trace_section" || fail "missing evidence vocabulary: $token"
done
# Executable ordering/evidence guards live in test_review_first_lifecycle.sh,
# test_sensor_evidence_verify.sh and test_log_handback_write_gate.sh. Reviewer
# topology is covered by test_reviewer_end_of_issue_contract.sh. Natural-language
# meaning belongs to focused review, not obligation/negation parsing or synonyms.
printf 'PASS: review evidence section references current executable authorities.\n'
