#!/usr/bin/env bash
# test_trace_authority_docs.sh — regression sensor for the trace evidence
# authority split documentation (issue #144, feature trace-authority-docs).
#
# Contract under test (PINNED HERE as the executable spec): the docs must
# explain the authority split between handback evidence, runtime hook spans,
# local hook seeding, and the decommissioned cloud export leg — plus the
# unregistered-named-subagent fallback. Each obligation is pinned against a
# SPECIFIC doc with distinctive, prose-tolerant substrings.
#
#   A — docs/HARNESS.md documents the PR-path red-first evidence obligation
#       and the governed red_first_waiver (with its allowed kinds).
#   B — docs/evaluation/observability-and-trace-schema.md documents the
#       evidence authority split: handback agent spans are the accepted
#       red-first proof; runtime hook tool spans are NOT yet accepted without
#       deterministic per-feature/sensor attribution.
#   C — docs/runtime-adapters/github-copilot.md documents local hook seeding:
#       start-issue seeds .github/hooks/harness-trace.json into a new
#       worktree when present; absent is a clean no-op.
#   D — docs/runtime-adapters/otlp-azure-monitor.md documents that issue #272
#       decommissioned the cloud export leg and retains only the OTel/App
#       Insights attribute-name mapping / exit-ramp contract.
#   E — docs/HARNESS.md documents the unregistered-named-subagent fallback:
#       when a repo defines an agent file but the runner does not register
#       that agentName, invoke a blank/current subagent with the full role
#       contract and record the handback under the intended role.
#
# Multi-word phrase pins run against a newline-flattened copy of each doc so a
# line break inside a phrase cannot dodge them.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED
# gate — the docs do not yet carry these additions).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC_HARNESS="${ROOT}/docs/HARNESS.md"
DOC_OBS="${ROOT}/docs/evaluation/observability-and-trace-schema.md"
DOC_COPILOT="${ROOT}/docs/runtime-adapters/github-copilot.md"
DOC_OTLP="${ROOT}/docs/runtime-adapters/otlp-azure-monitor.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# Newline-flattened working copies live here; the trap wipes the whole dir.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# require_doc <path> <label> — hard gate: the doc must exist before its pins
# can run. Returns 1 (and records a failure) when missing.
require_doc() {
  local path="$1" label="$2"
  if [ ! -f "$path" ]; then
    fail "${label} not found (${path}) — feature trace-authority-docs is not implemented yet"
    return 1
  fi
  return 0
}

# flat <path> — echo a path under TMP_DIR holding a newline-flattened copy of
# the doc, so multi-word phrase pins survive Markdown line wrapping.
flat() {
  local src="$1"
  local out
  out="${TMP_DIR}/$(basename "$src").flat"
  tr '\n' ' ' < "$src" > "$out"
  printf '%s' "$out"
}

# ==============================================================================
# A. docs/HARNESS.md — PR-path red-first evidence obligation + governed waiver.
# ==============================================================================
if require_doc "$DOC_HARNESS" "docs/HARNESS.md"; then
  A_FLAT="$(flat "$DOC_HARNESS")"

  # A1. Red-first evidence obligation gates the PR path.
  grep -qiF 'red-first' "$A_FLAT" \
    || fail "docs/HARNESS.md must document the red-first evidence obligation (A: passes:true needs role-correct red-first handback evidence)"
  grep -qF 'red_first_waiver' "$A_FLAT" \
    || fail "docs/HARNESS.md must name the governed red_first_waiver alongside the red-first obligation (A)"
  grep -qiE 'review-gate|create-pr' "$A_FLAT" \
    || fail "docs/HARNESS.md must tie the red-first obligation to the PR path (review-gate approve/check or create-pr) (A)"

  # A2. Governed red_first_waiver with its allowed kinds (>=2 of the four).
  waiver_kinds=0
  for kind in bootstrap visual-only doc-only justified; do
    if grep -qiF "$kind" "$A_FLAT"; then
      waiver_kinds=$((waiver_kinds + 1))
    fi
  done
  [ "$waiver_kinds" -ge 2 ] \
    || fail "docs/HARNESS.md must document the red_first_waiver allowed kinds (at least two of: bootstrap, visual-only, doc-only, justified) (A)"
fi

# ==============================================================================
# B. observability-and-trace-schema.md — evidence authority split.
# ==============================================================================
if require_doc "$DOC_OBS" "docs/evaluation/observability-and-trace-schema.md"; then
  B_FLAT="$(flat "$DOC_OBS")"

  # B1. Handback agent spans are the accepted initial red-first proof.
  grep -qiF 'red-first' "$B_FLAT" \
    || fail "observability-and-trace-schema.md must frame handback agent spans as the accepted red-first proof (B)"
  grep -qiF 'handback' "$B_FLAT" \
    || fail "observability-and-trace-schema.md must reference handback evidence as the accepted authority (B)"
  grep -qiE 'agent spans?' "$B_FLAT" \
    || fail "observability-and-trace-schema.md must name handback 'agent span(s)' as the accepted red-first proof (B)"

  # B2. Runtime hook tool spans are NOT yet accepted without deterministic
  #     per-feature/sensor attribution. Kept tolerant: require the three
  #     load-bearing tokens (tool span, deterministic, attribution).
  grep -qiE 'tool spans?' "$B_FLAT" \
    || fail "observability-and-trace-schema.md must discuss runtime hook 'tool span(s)' in the authority split (B)"
  grep -qiF 'deterministic' "$B_FLAT" \
    || fail "observability-and-trace-schema.md must state tool spans need deterministic attribution before they count as proof (B)"
  grep -qiF 'attribution' "$B_FLAT" \
    || fail "observability-and-trace-schema.md must require per-feature/sensor attribution for tool spans (B)"
fi

# ==============================================================================
# C. github-copilot.md — local hook seeding into a new worktree.
# ==============================================================================
if require_doc "$DOC_COPILOT" "docs/runtime-adapters/github-copilot.md"; then
  C_FLAT="$(flat "$DOC_COPILOT")"

  grep -qF '.github/hooks/harness-trace.json' "$C_FLAT" \
    || fail "github-copilot.md must name the local hook file .github/hooks/harness-trace.json (C)"
  grep -qiE 'seed(s|ed)?' "$C_FLAT" \
    || fail "github-copilot.md must document that start-issue seeds the local hook file (C)"
  grep -qiF 'worktree' "$C_FLAT" \
    || fail "github-copilot.md must document seeding into a new worktree (C)"
  grep -qiE 'when present|when it exists|no-op|absent' "$C_FLAT" \
    || fail "github-copilot.md must document the when-present / absent-is-a-clean-no-op semantics (C)"
fi

# ==============================================================================
# D. otlp-azure-monitor.md — decommissioned export leg / exit-ramp contract.
# ==============================================================================
if require_doc "$DOC_OTLP" "docs/runtime-adapters/otlp-azure-monitor.md"; then
  D_FLAT="$(flat "$DOC_OTLP")"

  grep -qiE 'decommissioned by #272|issue #272 removed' "$D_FLAT" \
    || fail "otlp-azure-monitor.md must state the cloud export leg was decommissioned by issue #272 (D)"
  grep -qiE 'no in-loop export consumer|no longer ships spans or logs|no tracked harness script currently posts' "$D_FLAT" \
    || fail "otlp-azure-monitor.md must state the harness no longer ships spans/logs through an in-loop export path (D)"
  grep -qiE 'attribute-name mapping|exit-ramp contract' "$D_FLAT" \
    || fail "otlp-azure-monitor.md must retain the OTel/App Insights attribute-name mapping / exit-ramp contract framing (D)"
  grep -qF 'COPILOT_OTEL_' "$D_FLAT" \
    || fail "otlp-azure-monitor.md must keep the COPILOT_OTEL_* vocabulary reference while the export leg is dormant (D)"
fi

# ==============================================================================
# E. docs/HARNESS.md — unregistered-named-subagent fallback (roles area).
# ==============================================================================
if [ -f "$DOC_HARNESS" ]; then
  E_FLAT="${A_FLAT:-$(flat "$DOC_HARNESS")}"

  grep -qF '.agent.md' "$E_FLAT" \
    || fail "docs/HARNESS.md must reference the agent file (.agent.md) in the unregistered-named-subagent fallback (E)"
  grep -qiE 'agent ?name' "$E_FLAT" \
    || fail "docs/HARNESS.md must describe the runner not registering the agentName (E)"
  grep -qiE 'not registered|fallback|role contract' "$E_FLAT" \
    || fail "docs/HARNESS.md must document the fallback: invoke a blank/current subagent with the full role contract when the agentName is not registered (E)"
fi

# ==============================================================================
# Verdict.
# ==============================================================================
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-authority-docs obligation(s) missing.\n' "$fails" >&2
  exit 1
fi
printf 'trace-authority-docs authority-split documentation contract honored\n'
exit 0
