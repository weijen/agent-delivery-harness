#!/usr/bin/env bash
# test_copilot_adapter_docs.sh — regression sensor for the GitHub Copilot
# primary adapter guide (issue #114, feature copilot-adapter-guide, plan F3).
#
# GitHub Copilot is this repo's PRIMARY runtime target. The guide
# docs/runtime-adapters/github-copilot.md must sell the honest picture:
# what a Copilot run gets with ZERO setup, what the opt-in hooks adapter
# adds per surface, and exactly which capabilities are gaps (never papered
# over). Pins (grep-level, mirroring test_claude_adapter_docs.sh):
#
#   D1. Guide exists at docs/runtime-adapters/github-copilot.md.
#   D2. ZERO-SETUP layer documented: under Copilot the harness already
#       emits lifecycle spans (#94 scripts) and log-handback agent spans
#       (#95) with no adapter installed — the adapter only ADDS the
#       per-tool-call (`tool`) and token (`model`) layers. Requires
#       zero-setup language, the word lifecycle, handback language, and
#       all three adapter-relevant span names (tool / agent / model).
#   D3. THREE SURFACES with install steps referencing the hooks template
#       docs/runtime-adapters/github-copilot.hooks.example.json:
#         CLI            — .github/hooks (repo) / ~/.copilot/hooks (user)
#         VS Code        — agent mode, Preview, Claude-compatible hooks
#         cloud agent    — .github/hooks in the ephemeral sandbox
#       plus copy/merge install language.
#   D4. CAPABILITY MATRIX (a markdown table) with the honest gaps stated:
#         - no documented correlation id → harness.duration_ms omitted
#           (omit-never-fake doctrine named);
#         - VS Code token counts unavailable in v1;
#         - events.jsonl is an internal/undocumented format, its parsed
#           shape empirically unverified (stability caveat).
#   D5. preToolUse fail-closed DANGER warning: a non-zero exit from a
#       registered preToolUse hook DENIES the tool call — the guide must
#       say never to register it.
#   D6. PRIVACY note: harness.args_summary excerpts land in the trace; the
#       trace is local-only; never commit/upload trace files.
#   D7. Cross-link to claude-code.md as the labeled reference example of
#       the adapter pattern.
#   D8. The hooks template itself parses and registers ONLY the safe
#       events (postToolUse, postToolUseFailure, agentStop, subagentStop)
#       — never preToolUse/PreToolUse. (Also pinned by the tool-span
#       sensor; duplicated here so the docs feature regression-guards its
#       own install artifact.)
#
# Exit codes: 0 guide contract honored · 1 an obligation regressed (or the
# guide is missing — RED gate for this feature).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/runtime-adapters/github-copilot.md"
TEMPLATE="${ROOT}/docs/runtime-adapters/github-copilot.hooks.example.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate the hooks template"

# --- D1: guide exists (RED gate) --------------------------------------------------
[ -f "$DOC" ] \
  || fail "adapter guide not found (${DOC}) — feature copilot-adapter-guide (issue #114) is not implemented yet"

# --- D2: zero-setup layer ----------------------------------------------------------
grep -qiE 'zero[- ]setup|out[- ]of[- ]the[- ]box|no setup|without (the |an |any )?adapter' "$DOC" \
  || fail "guide must document the zero-setup layer (what a Copilot run already gets with no adapter installed) (D2)"
grep -qi 'lifecycle' "$DOC" \
  || fail "guide must state that lifecycle spans are emitted by the harness scripts themselves (#94 layer) (D2)"
grep -qiE 'handback' "$DOC" \
  || fail "guide must state that log-handback agent spans exist without the adapter (#95 layer) (D2)"
for span in tool agent model; do
  grep -qiE "\`?${span}\`? span" "$DOC" \
    || fail "guide must document the '${span}' span layer (D2)"
done

# --- D3: three surfaces + install steps referencing the template --------------------
grep -qF '.github/hooks' "$DOC" \
  || fail "guide must document the .github/hooks install location (CLI/cloud surface) (D3)"
grep -qE "(~|[$]HOME)/[.]copilot/hooks" "$DOC" \
  || fail "guide must document the user-level ~/.copilot/hooks install location (CLI surface) (D3)"
grep -qiE 'vs ?code' "$DOC" \
  || fail "guide must document the VS Code agent mode surface (D3)"
grep -qi 'preview' "$DOC" \
  || fail "guide must label the VS Code hooks surface as Preview (D3)"
grep -qiE 'claude-compatible|claude[- ]shaped|\.claude/settings\.json' "$DOC" \
  || fail "guide must note VS Code loads Claude-compatible hook config/payloads (D3)"
grep -qiE 'cloud (coding )?agent' "$DOC" \
  || fail "guide must document the Copilot cloud coding agent surface (D3)"
grep -qF 'github-copilot.hooks.example.json' "$DOC" \
  || fail "guide install steps must reference the hooks template github-copilot.hooks.example.json (D3)"
grep -qiE 'copy|merge' "$DOC" \
  || fail "guide must give copy/merge install language (opt-in act) (D3)"

# --- D4: capability matrix + honest gaps ---------------------------------------------
table_rows="$(grep -cE '^\|' "$DOC" || true)"
[ "$table_rows" -ge 4 ] \
  || fail "guide must carry a capability matrix as a markdown table (>=4 '|' rows, got ${table_rows}) (D4)"
grep -qiE 'correlation[- ]id' "$DOC" \
  || fail "guide must state that no Copilot payload documents a correlation id (D4)"
grep -qiE 'duration' "$DOC" \
  || fail "guide must name the duration consequence of the missing correlation id (D4)"
grep -qiE 'omit(ted|s)?[-, ]+never[- ]fake|never fake' "$DOC" \
  || fail "guide must name the omit-never-fake doctrine for missing data (D4)"
grep -iE 'vs ?code' "$DOC" | grep -qi 'token' \
  || fail "guide must state the VS Code token gap (no token source in v1) on a line naming VS Code (D4)"
grep -qF 'events.jsonl' "$DOC" \
  || fail "guide must name the CLI events.jsonl token source (D4)"
grep -qiE 'internal|undocumented' "$DOC" \
  || fail "guide must label the events.jsonl format internal/undocumented (D4)"
grep -qiE 'unverified|may change|not documented|drift' "$DOC" \
  || fail "guide must carry the events.jsonl stability caveat (shape unverified / may drift) (D4)"

# --- D5: preToolUse fail-closed danger ------------------------------------------------
grep -qiE 'pretooluse' "$DOC" \
  || fail "guide must warn about preToolUse explicitly (D5)"
grep -qiE 'fail[- ]close|denie|denial|deny|blocks? the tool' "$DOC" \
  || fail "guide must explain the fail-closed tool-denial consequence of a failing preToolUse hook (D5)"
grep -qiE '(never|do not|don.t|must not) register' "$DOC" \
  || fail "guide must instruct never to register preToolUse (D5)"

# --- D6: privacy note -------------------------------------------------------------------
grep -qi 'privacy' "$DOC" \
  || fail "guide must carry a privacy note (D6)"
grep -qiE 'args_summary|argument summar|args summar' "$DOC" \
  || fail "privacy note must name the args-summary excerpts (D6)"
grep -qiE 'local[- ]only' "$DOC" \
  || fail "privacy note must state the trace is local-only (D6)"
grep -qiE '(never|do not|don.t) (commit|upload)' "$DOC" \
  || fail "privacy note must say never to commit/upload trace files (D6)"

# --- D7: cross-link to the reference example ----------------------------------------------
grep -qF 'claude-code.md' "$DOC" \
  || fail "guide must cross-link claude-code.md (D7)"
grep -qiE 'reference example' "$DOC" \
  || fail "guide must label claude-code.md as the reference example of the adapter pattern (D7)"

# --- D8: template registers only the safe events --------------------------------------------
[ -f "$TEMPLATE" ] \
  || fail "hooks template not found (${TEMPLATE}) (D8)"
jq -e . "$TEMPLATE" >/dev/null 2>&1 \
  || fail "hooks template is not valid JSON: ${TEMPLATE} (D8)"
for event in postToolUse postToolUseFailure agentStop subagentStop; do
  jq -e --arg ev "$event" '[.. | objects | keys[]] | index($ev) != null' \
      "$TEMPLATE" >/dev/null 2>&1 \
    || fail "hooks template must register the '${event}' event (D8)"
done
if jq -e 'tostring | test("preToolUse|PreToolUse")' "$TEMPLATE" >/dev/null 2>&1; then
  fail "hooks template registers (or mentions) preToolUse/PreToolUse — FORBIDDEN: fail-closed tool-denial risk (D8)"
fi

# --- D9: skill-span (harness.skill.name) preconditions and limits (issue #168) ----------
grep -qiE 'harness\.skill\.name' "$DOC" \
  || fail "guide must document the harness.skill.name skill span (D9)"
# Two preconditions: (1) fixed hook installed on main + seeded into the worktree
grep -qiE 'seed|seeded|installed on .?main|on .?main' "$DOC" \
  || fail "guide must state precondition 1: the fixed trace hook is installed on main and seeded into the worktree (D9)"
# (2) a new/fresh session whose runtime surfaces skills as toolName="skill" postToolUse
grep -qiE 'toolName ?= ?.?skill|tool\.name ?== ?.?skill|gen_ai\.tool\.name' "$DOC" \
  || fail "guide must state precondition 2: a fresh session must surface skills as a toolName=\"skill\" tool span (D9)"
grep -qiE 'fresh|new (CLI|runtime)? ?session' "$DOC" \
  || fail "guide must state precondition 2 requires a new/fresh runtime session (D9)"
# no-backfill limitation
grep -qiE 'backfill|retroactive|retroactively|after[- ]the[- ]fact' "$DOC" \
  || fail "guide must state skill spans cannot be backfilled retroactively (D9)"
# review_verdict agent span vs harness.skill.name skill span distinction
grep -qiE 'review_verdict' "$DOC" \
  || fail "guide must distinguish a review_verdict agent span from a harness.skill.name skill span (D9)"
# verification commands: jq selecting harness.skill.name + trace-report.sh
grep -qF "select(.[\"harness.skill.name\"])" "$DOC" \
  || fail "guide must give the jq verification command selecting harness.skill.name (D9)"
grep -qF 'trace-report.sh' "$DOC" \
  || fail "guide must give the trace-report.sh verification command (D9)"
# omit-never-fake honesty rule for absence
grep -qiE 'not (invoked|surfaced|captured)' "$DOC" \
  || fail "guide must state absence means not-invoked or not-surfaced, never fabricated (D9)"
# empirical, not official-contract framing (review note)
grep -qiE 'empirical|not (an )?official|repo[- ]owned' "$DOC" \
  || fail "guide must frame toolName=skill as repo-owned empirical evidence (#121/#138), not an official Copilot contract (D9)"

printf 'github-copilot adapter guide contract honored\n'
