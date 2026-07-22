#!/usr/bin/env bash
# test_runtime_adapters_docs.sh — regression sensor for the runtime-adapters
# doc set framing (issue #114, feature claude-adapter-reframe, plan F4).
#
# GitHub Copilot analysis uses native records while the Claude Code adapter
# remains a labeled reference example. Pins:
#
#   R1. docs/runtime-adapters/claude-code.md carries a clearly-labeled
#       reference-example statement NEAR THE TOP (within the first 15
#       lines) and cross-links github-copilot.md somewhere in the doc.
#   R2. Core docs link the Copilot page, which points to the semantic-spine
#       authority and native-record review skill.
#   R3. No Copilot reconstruction hook/template or live hook config exists.
#       The Claude reference adapter remains isolated from other core scripts.
# Exit codes: 0 framing contract honored · 1 an obligation regressed (or
# the reframe is not implemented yet — RED gate: R1's label/cross-link).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_DOC="${ROOT}/docs/runtime-adapters/claude-code.md"
COPILOT_DOC_REL="runtime-adapters/github-copilot.md"
HARNESS_DOC="${ROOT}/docs/HARNESS.md"
OBS_DOC="${ROOT}/docs/evaluation/observability-and-trace-schema.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$CLAUDE_DOC" ] \
  || fail "docs/runtime-adapters/claude-code.md not found (${CLAUDE_DOC})"
[ -f "$HARNESS_DOC" ] \
  || fail "docs/HARNESS.md not found (${HARNESS_DOC})"
[ -f "$OBS_DOC" ] \
  || fail "observability page not found (${OBS_DOC})"

# --- R1: claude-code.md is a labeled reference example (RED gate) -----------------
head -n 15 "$CLAUDE_DOC" | grep -qiE 'reference example' \
  || fail "claude-code.md must carry a clearly-labeled reference-example statement within its first 15 lines — feature claude-adapter-reframe (issue #114) is not implemented yet (R1)"
grep -qF 'github-copilot.md' "$CLAUDE_DOC" \
  || fail "claude-code.md must cross-link github-copilot.md (R1)"

# --- R2: core docs point to the native-record/semantic-spine boundary --------------
for doc in "$HARNESS_DOC" "$OBS_DOC"; do
  grep -qF "$COPILOT_DOC_REL" "$doc" \
    || fail "$(basename "$doc"): the runtime-adapters pointer must link ${COPILOT_DOC_REL} (R2)"
done
grep -qF 'copilot-log-review' "${ROOT}/docs/runtime-adapters/github-copilot.md" \
  || fail "github-copilot.md must point to native-record analysis (R2)"
grep -qiF 'semantic spine' "${ROOT}/docs/runtime-adapters/github-copilot.md" \
  || fail "github-copilot.md must point to the kept semantic spine (R2)"

# --- R3: no Copilot capture; Claude reference remains isolated ---------------------
check_coupling() {
  local marker="$1" exempt="$2"
  local coupled="" script=""
  for script in "${ROOT}"/scripts/*.sh; do
    if [ "$(basename "$script")" = "$exempt" ]; then
      continue
    fi
    if grep -q "$marker" "$script"; then
      coupled="${coupled} $(basename "$script")"
    fi
  done
  [ -z "$coupled" ] \
    || fail "core scripts must not reference '${marker}' (only ${exempt} may):${coupled} (R3)"
}
check_coupling 'claude-code' 'claude-code-trace-hook.sh'
[ ! -e "${ROOT}/scripts/copilot-trace-hook.sh" ] \
  || fail "retired Copilot reconstruction hook must not exist (R3)"
[ ! -e "${ROOT}/docs/runtime-adapters/github-copilot.hooks.example.json" ] \
  || fail "retired Copilot hook template must not exist (R3)"

tracked_live="$(git -C "$ROOT" ls-files \
    '.claude/settings.json' '.claude/settings.local.json' \
    '.github/hooks/*' 2>/dev/null || true)"
[ -z "$tracked_live" ] \
  || fail "the repo must not track live hook config (R3): ${tracked_live}"

printf 'runtime-adapters framing contract honored\n'
