#!/usr/bin/env bash
# test_launch_topology_docs.sh — regression sensor for the launch-topology
# documentation contract (issue #243, feature launch-topology-docs).
#
# Contract under test (PINNED HERE as the executable spec): both start-of-session
# docs must say Copilot CLI conductor sessions start from the repository root,
# because .github/hooks load from the session cwd; launching elsewhere can skip
# hooks and produce a dark run / zero runtime spans. They must also document the
# ~/.copilot/config.json trustedFolders precondition for new machines.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the docs do not yet carry the launch-topology contract).

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

  grep -qiE 'repository root|repo root' "$path" \
    || fail "${label} must document starting Copilot CLI conductor sessions from the repository root"
  grep -qF '.github/hooks' "$path" \
    || fail "${label} must document that repo hooks live under .github/hooks/"
  grep -qiE 'session.{0,40}cwd|cwd.{0,40}hook|hook.{0,40}cwd' "$path" \
    || fail "${label} must explain that hook loading depends on the session cwd"
  grep -qiE 'zero runtime spans|dark run|skip(s|ped)? .{0,40}hooks' "$path" \
    || fail "${label} must explain the dark-run failure mode when launched outside the trusted repo cwd"
  grep -qF 'trustedFolders' "$path" \
    || fail "${label} must document the ~/.copilot/config.json trustedFolders precondition"
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

printf 'launch-topology documentation contract honored\n'
