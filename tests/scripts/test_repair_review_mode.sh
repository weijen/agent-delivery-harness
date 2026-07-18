#!/usr/bin/env bash
# test_repair_review_mode.sh — regression sensor for the repair review-mode
# documentation contract (issue #300, feature repair-review-mode).
#
# Contract under test (PINNED HERE as the executable spec): the code-review
# subagent must document a THIRD review mode named `repair`, alongside the
# existing `full` and `concise`. The `repair` mode still runs Verdicts 1-4 plus
# the adversarial pass, but SKIPS the whole-diff skill battery (numbered
# code-quality checks #6-#11: find-brute-force, find-duplicates,
# find-over-design, dead-code-detection, sync-docs, public-exposure-audit) and
# DEFERS those checks — including the public-exposure-audit security sweep — to
# the pre-PR review, which runs the full battery. The harness Loop-2 doctrine
# must wire repair-loop reviews to the `repair` profile while the pre-PR review
# runs the full battery, so nothing is permanently skipped.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the docs do not yet carry the repair review-mode contract).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC_AGENT="${ROOT}/.copilot/agents/code-review-subagent.agent.md"
DOC_HARNESS="${ROOT}/.copilot/instructions/harness.instructions.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

require_doc() {
  local path="$1" label="$2"
  if [ ! -f "$path" ]; then
    fail "${label} not found (${path})"
    return 1
  fi
  return 0
}

assert_agent_contract() {
  local path="$1" label="$2"

  grep -qiE '^#+ .*repair' "$path" \
    || fail "${label} must carry a repair review-mode heading in Review Modes"
  grep -qiE 'repair' "$path" \
    || fail "${label} must name the repair review mode"
  grep -qiE 'skip(s|ped)?.{0,60}(whole-diff|skill battery|#6.?.?#11)' "$path" \
    || fail "${label} repair mode must state it SKIPS the whole-diff skill battery (checks #6-#11)"
  grep -qiE '#6.{0,5}#11|checks? #6' "$path" \
    || fail "${label} repair mode must reference the numbered code-quality checks #6-#11"
  grep -qiE 'defer(red|s)?.{0,80}pre-?PR' "$path" \
    || fail "${label} repair mode must DEFER the skipped battery to the pre-PR review"
  grep -qiE 'public-exposure-audit' "$path" \
    || fail "${label} repair mode must state the public-exposure-audit sweep is deferred to pre-PR"
  grep -qiE 'Review mode:.{0,60}repair' "$path" \
    || fail "${label} must add repair to the enumerated review-mode list (Review mode: full/concise/repair)"
}

assert_harness_contract() {
  local path="$1" label="$2"

  grep -qiE 'repair.{0,40}(review )?profile' "$path" \
    || fail "${label} Loop 2 must reference the repair review profile"
  grep -qiE 'repair-loop.{0,80}repair|repair.{0,80}whole-diff|repair.{0,80}skill battery' "$path" \
    || fail "${label} Loop 2 must state repair-loop reviews use the repair profile (skipping the whole-diff battery)"
  grep -qiE 'pre-?PR.{0,80}(full|whole-diff|battery)' "$path" \
    || fail "${label} Loop 2 must state the pre-PR review runs the full battery"
}

if require_doc "$DOC_AGENT" "code-review-subagent.agent.md"; then
  assert_agent_contract "$DOC_AGENT" "code-review-subagent.agent.md"
fi

if require_doc "$DOC_HARNESS" ".copilot/instructions/harness.instructions.md"; then
  assert_harness_contract "$DOC_HARNESS" ".copilot/instructions/harness.instructions.md"
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d repair-review-mode obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'repair review-mode documentation contract honored\n'
