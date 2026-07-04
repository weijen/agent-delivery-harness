#!/usr/bin/env bash
# test_claude_adapter_docs.sh — regression sensor for the Claude Code
# runtime-adapter template + documentation and core decoupling
# (issue #96, feature claude-adapter-template-docs, plan Phase 4 / D6).
#
# The adapter is OPT-IN: it ships as a copyable settings template and a doc
# under docs/runtime-adapters/, never as a tracked .claude/settings.json,
# and no core harness script may depend on it. This sensor pins:
#
#   T1. Template — docs/runtime-adapters/claude-code.settings.example.json
#       exists, parses with jq, and wires ALL FOUR events (PreToolUse,
#       PostToolUse, Stop, SubagentStop) to scripts/claude-code-trace-hook.sh
#       in the Claude Code settings hook shape:
#         .hooks.<Event> = [ { (optional) matcher: <string>,
#                              hooks: [ {type:"command",
#                                        command:<non-empty string>} ... ] } ]
#       Every hooks[] entry is type=="command" with a non-empty command, any
#       matcher present is a string, and for each event at least one command
#       references scripts/claude-code-trace-hook.sh.
#   T2. Doc — docs/runtime-adapters/claude-code.md exists and documents:
#       (a) opt-in install: mentions .claude/settings.json with copy/merge
#           language and an explicit never-overwrite statement;
#       (b) what each event emits: names all four events and all three
#           adapter span types (tool, agent, model);
#       (c) the no-adapter degradation statement: without the adapter the
#           harness behavior is unchanged and the trace lacks tool/model
#           spans;
#       (d) the transcript-shape compatibility caveat (token extraction
#           depends on the Claude Code transcript JSONL shape and may vary
#           across runtime versions);
#       (e) the adapter pattern for other runtimes (e.g. a future Copilot
#           adapter).
#   T3. Zero core coupling (plan D6) — no file under scripts/*.sh other than
#       the hook itself contains the string 'claude-code' (which covers
#       claude-code-trace-hook.sh references too), and git tracks NO
#       .claude/settings.json (the repo never ships live hook config).
#
# Exit codes: 0 template/doc/decoupling contract honored · 1 an obligation
# regressed (or the assets are missing — RED gate for this feature).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="${ROOT}/docs/runtime-adapters/claude-code.settings.example.json"
DOC="${ROOT}/docs/runtime-adapters/claude-code.md"
HOOK_REL="scripts/claude-code-trace-hook.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate the settings template"

# --- T1: template exists, parses, wires all four events to the hook -------------
[ -f "$TEMPLATE" ] \
  || fail "settings template not found (${TEMPLATE}) — feature claude-adapter-template-docs (issue #96) is not implemented yet"
jq -e . "$TEMPLATE" >/dev/null 2>&1 \
  || fail "settings template is not valid JSON: ${TEMPLATE}"

for event in PreToolUse PostToolUse Stop SubagentStop; do
  jq -e --arg e "$event" '
      (.hooks[$e] | type) == "array" and (.hooks[$e] | length) > 0
    ' "$TEMPLATE" >/dev/null \
    || fail "template must define a non-empty .hooks.${event} array (T1)"
  jq -e --arg e "$event" '
      [ .hooks[$e][]
        | ((has("matcher") | not) or ((.matcher | type) == "string"))
          and ((.hooks | type) == "array") and ((.hooks | length) > 0)
          and ([ .hooks[]
                 | (.type == "command")
                   and ((.command | type) == "string")
                   and ((.command | length) > 0)
               ] | all)
      ] | all
    ' "$TEMPLATE" >/dev/null \
    || fail "every .hooks.${event}[] entry must be Claude Code shaped: optional string matcher + hooks[] of {type:\"command\", command:<non-empty>} (T1)"
  jq -e --arg e "$event" --arg hook "$HOOK_REL" '
      [ .hooks[$e][].hooks[].command | contains($hook) ] | any
    ' "$TEMPLATE" >/dev/null \
    || fail "no .hooks.${event} command references ${HOOK_REL} (T1)"
done

# --- T2: adapter doc exists with the pinned content -------------------------------
[ -f "$DOC" ] \
  || fail "adapter doc not found (${DOC}) — feature claude-adapter-template-docs (issue #96) is not implemented yet"

grep -qF '.claude/settings.json' "$DOC" \
  || fail "doc must name the install target .claude/settings.json (T2a)"
grep -qiE 'copy|merge' "$DOC" \
  || fail "doc must give copy/merge install language (T2a)"
grep -qiE 'never overwrite|do not overwrite|without overwriting|must not overwrite' "$DOC" \
  || fail "doc must state the template is merged, never overwriting existing user settings (T2a)"

for token in PreToolUse PostToolUse Stop SubagentStop; do
  grep -qF "$token" "$DOC" \
    || fail "doc must document the ${token} event (T2b)"
done
for span in tool agent model; do
  grep -qiE "\`?${span}\`? span" "$DOC" \
    || fail "doc must document the '${span}' span emission (T2b)"
done

grep -qiE 'without (the |an )?adapter' "$DOC" \
  || fail "doc must carry the no-adapter degradation statement (T2c)"
grep -qiE 'unchanged' "$DOC" \
  || fail "doc must state harness behavior is unchanged without the adapter (T2c)"
grep -qiE 'lack|missing|absent|no tool.{0,30}model' "$DOC" \
  || fail "doc must state the trace lacks tool/model spans without the adapter (T2c)"

grep -qi 'transcript' "$DOC" \
  || fail "doc must carry the transcript-shape compatibility caveat (T2d)"
grep -qiE 'compatib|version|shape' "$DOC" \
  || fail "doc must note transcript extraction depends on the runtime transcript shape/version (T2d)"

grep -qiE 'other runtime|future runtime|another runtime|copilot' "$DOC" \
  || fail "doc must describe the adapter pattern for other runtimes (T2e)"

# --- T3: zero core coupling (plan D6) ----------------------------------------------
coupled=""
for script in "${ROOT}"/scripts/*.sh; do
  if [ "$(basename "$script")" = "claude-code-trace-hook.sh" ]; then
    continue
  fi
  if grep -q 'claude-code' "$script"; then
    coupled="${coupled} $(basename "$script")"
  fi
done
[ -z "$coupled" ] \
  || fail "core scripts must not reference the adapter (D6):${coupled}"

tracked_claude="$(git -C "$ROOT" ls-files '.claude/settings.json' '.claude/settings.local.json' 2>/dev/null || true)"
[ -z "$tracked_claude" ] \
  || fail "the repo must not track live Claude Code settings (adapter is opt-in): ${tracked_claude}"

printf 'claude-code adapter template/docs contract honored\n'
