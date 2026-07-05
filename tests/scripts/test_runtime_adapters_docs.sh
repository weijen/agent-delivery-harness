#!/usr/bin/env bash
# test_runtime_adapters_docs.sh — regression sensor for the runtime-adapters
# doc set framing (issue #114, feature claude-adapter-reframe, plan F4).
#
# After #114, GitHub Copilot is the repo's PRIMARY runtime target and the
# Claude Code adapter doc becomes a LABELED REFERENCE EXAMPLE of the adapter
# pattern — with cross-links both ways and the core docs' runtime-adapters
# pointers updated. No mechanical content changes to claude-code.md beyond
# the framing, so its own sensor must keep passing. Pins:
#
#   R1. docs/runtime-adapters/claude-code.md carries a clearly-labeled
#       reference-example statement NEAR THE TOP (within the first 15
#       lines) and cross-links github-copilot.md somewhere in the doc.
#   R2. The core docs' runtime-adapters pointers — docs/HARNESS.md ("Trace
#       emission" section) and
#       docs/evaluation/observability-and-trace-schema.md — link
#       runtime-adapters/github-copilot.md and name Copilot as the primary
#       runtime target (the word "primary" on a Copilot-naming line).
#   R3. Zero-core-coupling greps hold for BOTH hooks, symmetric and strict:
#       the string 'claude-code' appears in no scripts/*.sh except
#       claude-code-trace-hook.sh itself, and 'copilot-trace' appears in no
#       scripts/*.sh except copilot-trace-hook.sh itself. Git tracks NO
#       live hook config: no .claude/settings.json and no .github/hooks/*
#       (both adapters stay opt-in templates under docs/runtime-adapters/).
#   R4. test_claude_adapter_docs.sh STAYS GREEN after the reframe — run
#       in-process here so the reframe can never silently break the
#       reference doc's own contract.
#
# Exit codes: 0 framing contract honored · 1 an obligation regressed (or
# the reframe is not implemented yet — RED gate: R1's label/cross-link).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_DOC="${ROOT}/docs/runtime-adapters/claude-code.md"
COPILOT_DOC_REL="runtime-adapters/github-copilot.md"
HARNESS_DOC="${ROOT}/docs/HARNESS.md"
OBS_DOC="${ROOT}/docs/evaluation/observability-and-trace-schema.md"
CLAUDE_DOCS_SENSOR="${ROOT}/tests/scripts/test_claude_adapter_docs.sh"

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

# --- R2: core docs name Copilot as the primary runtime target ----------------------
for doc in "$HARNESS_DOC" "$OBS_DOC"; do
  grep -qF "$COPILOT_DOC_REL" "$doc" \
    || fail "$(basename "$doc"): the runtime-adapters pointer must link ${COPILOT_DOC_REL} (R2)"
  grep -iE 'copilot' "$doc" | grep -qiE 'primar' \
    || fail "$(basename "$doc"): must name Copilot as the primary runtime target ('primary' on a Copilot-naming line) (R2)"
done

# --- R3: zero core coupling, both hooks, symmetric ----------------------------------
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
check_coupling 'copilot-trace' 'copilot-trace-hook.sh'

tracked_live="$(git -C "$ROOT" ls-files \
    '.claude/settings.json' '.claude/settings.local.json' \
    '.github/hooks/*' 2>/dev/null || true)"
[ -z "$tracked_live" ] \
  || fail "the repo must not track live hook config — both adapters are opt-in templates (R3): ${tracked_live}"

# --- R4: the reference doc's own sensor stays green ------------------------------------
[ -f "$CLAUDE_DOCS_SENSOR" ] \
  || fail "tests/scripts/test_claude_adapter_docs.sh not found — the reframe must keep the reference doc's sensor in the suite (R4)"
bash "$CLAUDE_DOCS_SENSOR" >/dev/null 2>&1 \
  || fail "test_claude_adapter_docs.sh regressed — the reframe must not break the reference doc's own contract (R4)"

printf 'runtime-adapters framing contract honored\n'
