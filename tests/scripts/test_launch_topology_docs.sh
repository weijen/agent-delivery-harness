#!/usr/bin/env bash
# test_launch_topology_docs.sh — regression sensor for the launch-topology
# documentation contract (issue #243, reconciled by issue #305).
#
# Contract under test (PINNED HERE as the executable spec): both start-of-session
# docs must keep the launch-topology guidance, but issue #305 retired the runtime
# capture layer, so the guidance is RECONCILED rather than a live imperative. The
# docs must:
#   1. Still name the repository root (the trusted folder under .github/hooks/) as
#      the historical launch folder and explain hook loading depended on the
#      session cwd, and still document the ~/.copilot/config.json trustedFolders
#      precondition.
#   2. Frame the runtime-capture hook as RETIRED/deprecated (issue #305) and defer
#      the reconciliation to the authoritative "Capture Retirement Boundary"
#      section, stating the kept semantic spine is emitted regardless of launch
#      cwd.
#   3. NO LONGER carry the retired doctrine as a live imperative — the "the
#      session becomes/is a dark run with zero runtime tool spans captured" loss
#      framing must be gone. This keeps the sensor consistent with
#      tests/scripts/test_start_issue_no_hook_seed.sh, which bans the same
#      framing in scripts/start-issue.sh.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing/violated
# (RED gate — the docs do not yet carry the reconciled launch-topology contract).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC_AGENTS="${ROOT}/AGENTS.md"
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

assert_launch_topology_contract() {
  local path="$1" label="$2"

  # 1. The launch-topology guidance is still present.
  grep -qiE 'repository root|repo root' "$path" \
    || fail "${label} must still name the repository root as the launch folder (launch-topology guidance kept)"
  grep -qF '.github/hooks' "$path" \
    || fail "${label} must still name where repo hooks live (.github/hooks/)"
  grep -qiE 'session.{0,40}cwd|cwd.{0,40}hook|hook.{0,40}cwd|launch cwd' "$path" \
    || fail "${label} must still explain that hook loading depended on the session cwd"
  grep -qF 'trustedFolders' "$path" \
    || fail "${label} must still document the ~/.copilot/config.json trustedFolders precondition"

  # 2. Reconciled (issue #305): the hook is framed RETIRED and the doc defers to
  #    the authoritative Capture Retirement Boundary section.
  grep -qiE 'retired|deprecated' "$path" \
    || fail "${label} must frame the runtime-capture hook as retired/deprecated (issue #305), not a live loss"
  grep -qiF 'capture retirement boundary' "$path" \
    || fail "${label} must defer the launch-topology reconciliation to the Capture Retirement Boundary section"
  grep -qiE 'regardless of .{0,12}cwd|semantic spine' "$path" \
    || fail "${label} must state the kept semantic spine is emitted regardless of launch cwd"

  # 3. The retired doctrine must no longer appear as a live imperative —
  #    consistent with test_start_issue_no_hook_seed.sh (which bans the same
  #    framing in scripts/start-issue.sh).
  if grep -qiE 'is a dark run|becomes a dark run|zero runtime tool spans captured' "$path"; then
    fail "${label} must not frame a non-root launch as a live dark run / zero-runtime-spans loss (retired, issue #305)"
  fi
}

if require_doc "$DOC_AGENTS" "AGENTS.md"; then
  assert_launch_topology_contract "$DOC_AGENTS" "AGENTS.md"
fi

if require_doc "$DOC_HARNESS" ".copilot/instructions/harness.instructions.md"; then
  assert_launch_topology_contract "$DOC_HARNESS" ".copilot/instructions/harness.instructions.md"
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d launch-topology-docs obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'launch-topology documentation contract honored (reconciled, issue #305)\n'
