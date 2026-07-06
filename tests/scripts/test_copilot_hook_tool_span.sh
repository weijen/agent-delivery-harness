#!/usr/bin/env bash
# test_copilot_hook_tool_span.sh — regression sensor for
# scripts/copilot-trace-hook.sh guard contract + postToolUse tool-span
# emission (issue #114, feature copilot-hook-tool-spans, plan F1).
#
# GitHub Copilot ships lifecycle hooks on three surfaces (CLI, cloud coding
# agent, VS Code agent mode Preview) that shell one JSON payload to a local
# command on stdin — same integration shape as the Claude Code adapter
# (scripts/claude-code-trace-hook.sh, issue #96), whose sensors this file
# mirrors. Two payload dialects reach the SAME script:
#
#   CLI / cloud (camelCase, per the plan's spike sources —
#   docs.github.com/en/copilot/reference/hooks-reference and the CLI how-to
#   sample stdin {"timestamp":...,"cwd":...,"toolName":"bash",
#   "toolArgs":"{\"command\":\"ls\"}"}):
#     event ("postToolUse" / "postToolUseFailure" / ...), timestamp, cwd,
#     sessionId, toolName, toolArgs (JSON *as a string*),
#     toolResult{resultType,textResultForLlm}, transcriptPath
#   VS Code agent mode (snake_case, Claude-compatible):
#     hook_event_name ("PostToolUse" / ...), session_id, cwd, tool_name,
#     tool_input (JSON object), tool_result{result_type,text_result_for_llm},
#     transcript_path
#
# SAFETY IS HARSHER THAN THE CLAUDE HOOK: per the spike, Copilot treats a
# non-zero hook exit on preToolUse as a TOOL DENIAL (fail-closed), and
# stdout is parsed as JSON. So "exit 0 + empty stdout on EVERY path" is not
# politeness — it is the property that keeps the adapter from blocking a
# live session's tool calls. Every guard leg below pins it adversarially.
#
# PINNED CONVENTIONS (conductor-resolved for this feature; the
# implementation must match these exactly):
#   P1. Guard chain mirrors the Claude hook's G1-G5: jq present (checked
#       BEFORE any jq use) -> stdin (slurped once) parses as a JSON object
#       -> trace-lib.sh beside the hook -> issue context resolves from the
#       payload cwd (fallback $PWD; non-git cwd is unresolvable) -> known
#       event dispatches. Any failure: silent exit 0, empty stdout, no
#       artifacts.
#   P2. Dialect normalization: gen_ai.tool.name comes from `toolName`
#       (camelCase) or `tool_name` (snake_case); the event comes from
#       `event` (camelCase) or `hook_event_name` (snake_case).
#   P3. Args summary — key `harness.args_summary`: from `toolArgs` (CLI:
#       the reference types it `unknown`, "parsed from JSON when possible" —
#       a JSON-string is taken verbatim, an OBJECT is compacted via jq -c)
#       or `jq -c .tool_input` (VS Code, VERBATIM when short). REDACTED FIRST via trace_redact, THEN hard-capped at 200
#       chars TOTAL including the literal `...` marker (the #96 loop-2
#       redact-before-cap lesson is a day-one pin here: capping first can
#       slice a ghp_ token below trace_redact's 20-char pattern floor and
#       leave a redaction-proof fragment on disk).
#   P4. harness.duration_ms is NEVER emitted — no Copilot payload documents
#       a correlation id (plan key decision), so there is nothing honest to
#       correlate. Omit, never fake. Corollary: NO .hook-state directory is
#       ever created (no pre/post state machine exists to feed).
#   P5. harness.outcome only from unambiguous signals: event
#       postToolUseFailure -> fail; toolResult.resultType == "success"
#       (CLI) or tool_result.result_type == "success" (VS Code) -> pass;
#       anything else -> key ABSENT.
#   P6. preToolUse / PreToolUse is NOT handled: in a valid issue context it
#       must be a silent no-op with zero artifacts. Registering it buys no
#       telemetry (no correlation id) and its fail-closed exit semantics
#       add live-session risk — the hook must not even dispatch on it.
#   P7. Every emitted line: span type `tool`, gen_ai.operation.name =
#       execute_tool, valid against the #92 contract filter (lifted
#       verbatim below); exit 0 + empty stdout on every invocation.
#   P8. Hooks template docs/runtime-adapters/github-copilot.hooks.example.json
#       (`.github/hooks/*.json` format, "version": 1, works for CLI + cloud
#       + VS Code Preview per the plan): parses as JSON, registers
#       postToolUse, postToolUseFailure, agentStop, subagentStop pointing at
#       scripts/copilot-trace-hook.sh, and does NOT register preToolUse (or
#       PreToolUse) anywhere — the negative assertion IS the safety pin.
#
# Guard cases (fixtures: throwaway repos per test_claude_hook_noop.sh):
#   G1. Valid CLI postToolUse payload, cwd a plain git repo on `main`
#       (outside any harness issue context) -> silent no-op, no
#       .copilot-tracking created.
#   G2. cwd not a git repo at all -> silent no-op.
#   G3. Malformed stdin (non-JSON text, empty stdin, ~2MB garbage line)
#       INSIDE a valid issue context -> silent no-op, no trace.
#   G4. jq absent from PATH (stub PATH without jq), valid payload + context
#       -> silent no-op, NO "command not found" / jq mention on stderr.
#   G5. trace-lib.sh missing beside the hook copy -> silent no-op.
#   G6. Unknown event in both dialects (sessionStart / SessionStart) in a
#       valid context -> silent no-op.
#   G7. preToolUse (camelCase) and PreToolUse (snake_case) in a valid
#       context -> silent no-op, no trace, and NO .hook-state anywhere (P6).
#
# Emission cases (same issue-context fixture, trace line-counted):
#   E1. CLI postToolUse, toolName=bash, short toolArgs, resultType=success
#       -> one schema-valid tool span: gen_ai.tool.name=bash,
#       gen_ai.operation.name=execute_tool, args summary carries the
#       command, harness.outcome=pass, NO harness.duration_ms.
#   E2. CLI postToolUse WITHOUT toolResult -> harness.outcome ABSENT.
#   E3. CLI postToolUseFailure (error field) -> harness.outcome=fail.
#   E4. CLI postToolUse, toolArgs embedding a SYNTHETIC ghp_ token early
#       plus >500 chars padding -> summary <= 200 ending `...`; token
#       byte-absent from the whole trace file; [REDACTED] present.
#   E5. VS Code PostToolUse, tool_name=bash, short tool_input, no
#       tool_result -> schema-valid span, args summary == jq -c .tool_input
#       VERBATIM, outcome ABSENT.
#   E6. VS Code PostToolUse with tool_result.result_type=success ->
#       harness.outcome=pass (snake-side of P5).
#   E7. Redact-before-cap straddle (VS Code, deterministic math): compact
#       tool_input {"command":"<171 z's + 44-char ghp_ token>"} puts the
#       token at summary index 183; a cap-first implementation keeps 197
#       chars, cutting it to `ghp_`+10 — below trace_redact's
#       gh[pousr]_[A-Za-z0-9_]{20,} floor. NO `ghp_` may appear anywhere in
#       the on-disk trace (P3).
#   E8. LOOP-2 (review minor 1) — CLI postToolUse with OBJECT-typed
#       toolArgs: the official reference types toolArgs `unknown` ("parsed
#       from JSON when possible"), so the object form is a first-class
#       dialect variant, not drift. The span must carry
#       harness.args_summary == jq -c of the object (same redact-before-cap
#       path as P3) — NOT degrade to a summary-less span.
#   E9. Whole-file invariants: every line has span=tool, and NO line
#       carries harness.duration_ms; no .hook-state exists anywhere (P4).
#
# Template cases: per P8.
#
# Secrets are SYNTHETIC (test-only shapes, never real credentials).
#
# Exit codes: 0 contract honored · 1 an obligation regressed (or the
# feature is not implemented yet — RED gate below).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/copilot-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TEMPLATE="${ROOT}/docs/runtime-adapters/github-copilot.hooks.example.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to build fixture payloads and validate spans"
[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — fixtures need the real emitter beside the hook copy"

# RED gate: the hook under test must exist before anything can be exercised.
[ -f "$HOOK" ] \
  || fail "scripts/copilot-trace-hook.sh not found (${HOOK}) — feature copilot-hook-tool-spans (issue #114) is not implemented yet"

BASH_BIN="$(command -v bash)"

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (lifted verbatim from test_trace_schema.sh)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

line_count() { wc -l < "$1" | tr -d '[:space:]'; }
nth_line() { sed -n "${2}p" "$1"; }

# --- Payload builders ----------------------------------------------------------
# CLI / cloud camelCase dialect. toolArgs is JSON *as a string*, exactly as
# the CLI how-to sample stdin shows. toolResult is a JSON object or `null`
# (null -> key omitted).
# cli_payload <event> <cwd> <toolName> <toolArgs-string> <toolResult-json|null>
cli_payload() {
  jq -cn --arg event "$1" --arg cwd "$2" --arg tool "$3" --arg args "$4" \
    --argjson result "$5" '{
      event: $event,
      timestamp: "2026-07-05T12:00:00Z",
      sessionId: "copilot-sess-fixture-0001",
      cwd: $cwd,
      toolName: $tool,
      toolArgs: $args,
      transcriptPath: "/nonexistent/fixture-transcript.jsonl"
    } + (if $result == null then {} else {toolResult: $result} end)'
}

# VS Code snake_case dialect (Claude-compatible shape). tool_input is a JSON
# object; tool_result is a JSON object or `null` (null -> key omitted).
# vsc_payload <hook_event_name> <cwd> <tool_name> <tool_input-json> <tool_result-json|null>
vsc_payload() {
  jq -cn --arg event "$1" --arg cwd "$2" --arg tool "$3" \
    --argjson input "$4" --argjson result "$5" '{
      hook_event_name: $event,
      session_id: "copilot-sess-fixture-0001",
      cwd: $cwd,
      tool_name: $tool,
      tool_input: $input,
      transcript_path: "/nonexistent/fixture-transcript.jsonl"
    } + (if $result == null then {} else {tool_result: $result} end)'
}

# --- Hook runner -----------------------------------------------------------------
# run_hook <label> <workdir> <hook-path> <stdin-file> [PATH-override]
# Captures HOOK_RC / HOOK_OUT / HOOK_ERR. The hook is always an isolated COPY
# inside a fixture — never the real-repo file — so no case can write into the
# developer's checkout.
HOOK_RC=0
HOOK_OUT=""
HOOK_ERR=""
run_hook() {
  local label="$1" workdir="$2" hook_path="$3" stdin_file="$4"
  local path_override="${5:-}"
  HOOK_OUT="${TMP_DIR}/${label}.out"
  HOOK_ERR="${TMP_DIR}/${label}.err"
  HOOK_RC=0
  set +e
  if [ -n "$path_override" ]; then
    (
      cd "$workdir" || exit 97
      PATH="$path_override" "$BASH_BIN" "$hook_path" < "$stdin_file"
    ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  else
    (
      cd "$workdir" || exit 97
      bash "$hook_path" < "$stdin_file"
    ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  fi
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -ne 97 ] || fail "${label}: fixture workdir vanished (${workdir})"
}

# Session-safety invariants shared by every invocation (P1/P7): exit 0 and
# empty stdout. On some Copilot surfaces a non-zero exit DENIES the tool
# call, and stdout is parsed as JSON — both must be pinned on every path.
assert_session_safe() {
  local label="$1"
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 — Copilot treats hook failure as a tool DENIAL on some surfaces — got exit ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] \
    || fail "${label}: hook stdout must be EMPTY (Copilot parses hook stdout as JSON), got: $(cat "$HOOK_OUT")"
}

# A silent no-op: session-safe, no crash text on stderr, and not a single
# trace.jsonl anywhere under the given fixture root.
assert_silent_noop() {
  local label="$1" fixture_root="$2"
  local found=""
  assert_session_safe "$label"
  if grep -Eq 'command not found|No such file or directory|syntax error|unbound variable' "$HOOK_ERR"; then
    fail "${label}: stderr must stay free of crash/error text (empty or minimal advisory only), got: $(cat "$HOOK_ERR")"
  fi
  found="$(find "$fixture_root" -name 'trace.jsonl' 2>/dev/null || true)"
  [ -z "$found" ] \
    || fail "${label}: a no-op path must not create any trace file, found: ${found}"
}

# --- Fixture A: plain git repo on main — NOT a harness issue context ------------
PLAIN_REPO="${TMP_DIR}/plainrepo"
mkdir -p "${PLAIN_REPO}/scripts"
cp "$HOOK" "${PLAIN_REPO}/scripts/copilot-trace-hook.sh"
cp "$LIB" "${PLAIN_REPO}/scripts/trace-lib.sh"
(
  cd "$PLAIN_REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
) || fail "could not build the plain-repo fixture"

# --- Fixture B: directory that is not a git repo at all --------------------------
NONREPO="${TMP_DIR}/nonrepo"
mkdir -p "${NONREPO}/scripts"
cp "$HOOK" "${NONREPO}/scripts/copilot-trace-hook.sh"
cp "$LIB" "${NONREPO}/scripts/trace-lib.sh"

# --- Fixture C: issue-worktree-shaped repo (valid harness context) ---------------
ISSUE_REPO="${TMP_DIR}/issuerepo"
mkdir -p "${ISSUE_REPO}/scripts"
cp "$HOOK" "${ISSUE_REPO}/scripts/copilot-trace-hook.sh"
cp "$LIB" "${ISSUE_REPO}/scripts/trace-lib.sh"
(
  cd "$ISSUE_REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
  git checkout -q -b feature/issue-07-copilot-hook-fixture
) || fail "could not build the issue-context fixture"
ISSUE_HOOK="${ISSUE_REPO}/scripts/copilot-trace-hook.sh"
TRACE_FILE="${ISSUE_REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"

# --- Fixture D: stub PATH with everything EXCEPT jq (guard G4) --------------------
STUBBIN="${TMP_DIR}/stubbin"
mkdir -p "$STUBBIN"
ln -s "$BASH_BIN" "${STUBBIN}/bash"
for tool in git sed grep date od tr mkdir dirname basename cat wc head tail \
    env sh ls rm mv cp find sort uniq cut awk printf sleep chmod; do
  tool_src="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$tool_src" ] && [ ! -e "${STUBBIN}/${tool}" ]; then
    ln -s "$tool_src" "${STUBBIN}/${tool}"
  fi
done
[ ! -e "${STUBBIN}/jq" ] || fail "stub PATH fixture must not contain jq"
if PATH="$STUBBIN" "$BASH_BIN" -c 'command -v jq' >/dev/null 2>&1; then
  fail "stub PATH fixture leaked a resolvable jq — the jq-guard case would be vacuous"
fi

# --- Guard payload files -----------------------------------------------------------
PAYLOAD_PLAIN="${TMP_DIR}/payload-plain.json"
cli_payload "postToolUse" "$PLAIN_REPO" "bash" '{"command":"echo fixture"}' \
  '{"resultType":"success","textResultForLlm":"fixture"}' > "$PAYLOAD_PLAIN"
PAYLOAD_NONREPO="${TMP_DIR}/payload-nonrepo.json"
cli_payload "postToolUse" "$NONREPO" "bash" '{"command":"echo fixture"}' \
  '{"resultType":"success","textResultForLlm":"fixture"}' > "$PAYLOAD_NONREPO"
PAYLOAD_ISSUE="${TMP_DIR}/payload-issue.json"
cli_payload "postToolUse" "$ISSUE_REPO" "bash" '{"command":"echo fixture"}' \
  '{"resultType":"success","textResultForLlm":"fixture"}' > "$PAYLOAD_ISSUE"
PAYLOAD_UNKNOWN_CLI="${TMP_DIR}/payload-unknown-cli.json"
cli_payload "sessionStart" "$ISSUE_REPO" "bash" '{"command":"noop"}' null \
  > "$PAYLOAD_UNKNOWN_CLI"
PAYLOAD_UNKNOWN_VSC="${TMP_DIR}/payload-unknown-vsc.json"
vsc_payload "SessionStart" "$ISSUE_REPO" "bash" '{"command":"noop"}' null \
  > "$PAYLOAD_UNKNOWN_VSC"
PAYLOAD_PRE_CLI="${TMP_DIR}/payload-pre-cli.json"
cli_payload "preToolUse" "$ISSUE_REPO" "bash" '{"command":"echo pre"}' null \
  > "$PAYLOAD_PRE_CLI"
PAYLOAD_PRE_VSC="${TMP_DIR}/payload-pre-vsc.json"
vsc_payload "PreToolUse" "$ISSUE_REPO" "bash" '{"command":"echo pre"}' null \
  > "$PAYLOAD_PRE_VSC"

NOT_JSON="${TMP_DIR}/stdin-not-json.txt"
printf 'this is not json { definitely [ not\n' > "$NOT_JSON"
EMPTY_STDIN="${TMP_DIR}/stdin-empty.txt"
: > "$EMPTY_STDIN"
HUGE_GARBAGE="${TMP_DIR}/stdin-huge-garbage.txt"
head -c 2000000 /dev/zero | tr '\0' 'x' > "$HUGE_GARBAGE"
printf '\n' >> "$HUGE_GARBAGE"

# =============================================================================
# Guard G1 — valid CLI postToolUse payload, cwd OUTSIDE any harness context
# =============================================================================
run_hook "g1-out-of-context" "$PLAIN_REPO" \
  "${PLAIN_REPO}/scripts/copilot-trace-hook.sh" "$PAYLOAD_PLAIN"
assert_silent_noop "g1-out-of-context" "$PLAIN_REPO"
[ ! -e "${PLAIN_REPO}/.copilot-tracking" ] \
  || fail "g1-out-of-context: no .copilot-tracking dir may be created outside a harness run"

# =============================================================================
# Guard G2 — cwd is not a git repo at all
# =============================================================================
run_hook "g2-not-a-repo" "$NONREPO" \
  "${NONREPO}/scripts/copilot-trace-hook.sh" "$PAYLOAD_NONREPO"
assert_silent_noop "g2-not-a-repo" "$NONREPO"
[ ! -e "${NONREPO}/.copilot-tracking" ] \
  || fail "g2-not-a-repo: no .copilot-tracking dir may be created in a non-repo cwd"

# =============================================================================
# Guard G3 — malformed stdin INSIDE a valid issue context (the parse guard,
# not the context guard, proves the no-op): non-JSON, empty, ~2MB garbage
# =============================================================================
run_hook "g3a-not-json" "$ISSUE_REPO" "$ISSUE_HOOK" "$NOT_JSON"
assert_silent_noop "g3a-not-json" "$ISSUE_REPO"

run_hook "g3b-empty-stdin" "$ISSUE_REPO" "$ISSUE_HOOK" "$EMPTY_STDIN"
assert_silent_noop "g3b-empty-stdin" "$ISSUE_REPO"

run_hook "g3c-huge-garbage" "$ISSUE_REPO" "$ISSUE_HOOK" "$HUGE_GARBAGE"
assert_silent_noop "g3c-huge-garbage" "$ISSUE_REPO"

# =============================================================================
# Guard G4 — jq absent from PATH, valid payload + valid context: must not
# even attempt a jq call, so no "command not found" / jq mention may appear
# =============================================================================
run_hook "g4-no-jq" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_ISSUE" "$STUBBIN"
assert_silent_noop "g4-no-jq" "$ISSUE_REPO"
if grep -q 'jq' "$HOOK_ERR"; then
  fail "g4-no-jq: stderr mentions jq — the jq guard must run BEFORE any jq use (got: $(cat "$HOOK_ERR"))"
fi

# =============================================================================
# Guard G5 — trace-lib.sh missing beside the hook copy, valid context
# =============================================================================
LIBLESS="${TMP_DIR}/libless"
mkdir -p "${LIBLESS}/scripts"
cp "$HOOK" "${LIBLESS}/scripts/copilot-trace-hook.sh"
run_hook "g5-no-trace-lib" "$ISSUE_REPO" \
  "${LIBLESS}/scripts/copilot-trace-hook.sh" "$PAYLOAD_ISSUE"
assert_silent_noop "g5-no-trace-lib" "$ISSUE_REPO"
assert_silent_noop "g5-no-trace-lib(libless-root)" "$LIBLESS"

# =============================================================================
# Guard G6 — unknown event name in a valid context, BOTH dialects
# =============================================================================
run_hook "g6a-unknown-event-cli" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_UNKNOWN_CLI"
assert_silent_noop "g6a-unknown-event-cli" "$ISSUE_REPO"

run_hook "g6b-unknown-event-vsc" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_UNKNOWN_VSC"
assert_silent_noop "g6b-unknown-event-vsc" "$ISSUE_REPO"

# =============================================================================
# Guard G7 — preToolUse / PreToolUse in a valid context (P6): NOT handled.
# No trace line, no .hook-state, no artifacts of any kind — there is no
# correlation id in any Copilot payload, so a pre-event state machine would
# only exist to fake durations, and registering preToolUse at all risks
# fail-closed tool denials.
# =============================================================================
run_hook "g7a-pretooluse-cli" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_PRE_CLI"
assert_silent_noop "g7a-pretooluse-cli" "$ISSUE_REPO"

run_hook "g7b-pretooluse-vsc" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_PRE_VSC"
assert_silent_noop "g7b-pretooluse-vsc" "$ISSUE_REPO"

state_dirs="$(find "$ISSUE_REPO" -type d -name '.hook-state' 2>/dev/null || true)"
[ -z "$state_dirs" ] \
  || fail "g7: pre-events must leave NO .hook-state behind (P4/P6 — no correlation id exists to consume it), found: ${state_dirs}"

# =============================================================================
# Emission E1 — CLI camelCase postToolUse, resultType=success: one
# schema-valid tool span; name/operation/summary/outcome pinned; no duration
# =============================================================================
E1_ARGS='{"command":"echo fixture-ok"}'
run_hook "e1-cli-success" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  cli_payload "postToolUse" "$ISSUE_REPO" "bash" "$E1_ARGS" \
    '{"resultType":"success","textResultForLlm":"fixture-ok"}'
)
assert_session_safe "e1-cli-success"
[ -f "$TRACE_FILE" ] \
  || fail "e1: postToolUse in a valid issue context must append a tool span (${TRACE_FILE} missing)"
[ "$(line_count "$TRACE_FILE")" = "1" ] \
  || fail "e1: exactly one line expected after one postToolUse, got $(line_count "$TRACE_FILE")"
span1="$(nth_line "$TRACE_FILE" 1)"
validate_span "$span1" \
  || fail "e1: span rejected by the #92 contract filter: ${span1}"
printf '%s\n' "$span1" | jq -e '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "bash")
    and (.["gen_ai.operation.name"] == "execute_tool")
    and ((.["harness.args_summary"] | type) == "string")
    and (.["harness.args_summary"] | contains("echo fixture-ok"))
  ' >/dev/null \
  || fail "e1: expected gen_ai.tool.name=bash (from camelCase toolName), gen_ai.operation.name=execute_tool, and an args summary carrying the command from toolArgs (P2/P3): ${span1}"
printf '%s\n' "$span1" | jq -e '.["harness.outcome"] == "pass"' >/dev/null \
  || fail "e1: toolResult.resultType=success must stamp harness.outcome=pass (P5): ${span1}"
printf '%s\n' "$span1" | jq -e 'has("harness.duration_ms") | not' >/dev/null \
  || fail "e1: NO Copilot payload documents a correlation id — harness.duration_ms must NEVER be emitted, omit-never-fake (P4): ${span1}"
printf '%s\n' "$span1" | jq -e '.["harness.result_summary"] == "fixture-ok"' >/dev/null \
  || fail "e1: toolResult.textResultForLlm must become harness.result_summary (#130 camel path): ${span1}"

# =============================================================================
# Emission E2 — CLI postToolUse WITHOUT toolResult: outcome ABSENT (honest
# omission — success is not proven by the payload)
# =============================================================================
run_hook "e2-cli-ambiguous" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  cli_payload "postToolUse" "$ISSUE_REPO" "bash" '{"command":"true"}' null
)
assert_session_safe "e2-cli-ambiguous"
[ "$(line_count "$TRACE_FILE")" = "2" ] \
  || fail "e2: expected a second trace line, got $(line_count "$TRACE_FILE")"
span2="$(nth_line "$TRACE_FILE" 2)"
validate_span "$span2" || fail "e2: span rejected by the contract filter: ${span2}"
printf '%s\n' "$span2" | jq -e 'has("harness.outcome") | not' >/dev/null \
  || fail "e2: without an unambiguous toolResult.resultType the harness.outcome key must be OMITTED, never guessed (P5): ${span2}"

# =============================================================================
# Emission E3 — CLI postToolUseFailure: harness.outcome=fail
# =============================================================================
run_hook "e3-cli-failure" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  jq -cn --arg cwd "$ISSUE_REPO" '{
    event: "postToolUseFailure",
    timestamp: "2026-07-05T12:00:01Z",
    sessionId: "copilot-sess-fixture-0001",
    cwd: $cwd,
    toolName: "bash",
    toolArgs: "{\"command\":\"false\"}",
    error: "exit status 1",
    transcriptPath: "/nonexistent/fixture-transcript.jsonl"
  }'
)
assert_session_safe "e3-cli-failure"
[ "$(line_count "$TRACE_FILE")" = "3" ] \
  || fail "e3: expected a third trace line, got $(line_count "$TRACE_FILE")"
span3="$(nth_line "$TRACE_FILE" 3)"
validate_span "$span3" || fail "e3: span rejected by the contract filter: ${span3}"
printf '%s\n' "$span3" | jq -e '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "bash")
    and (.["harness.outcome"] == "fail")
  ' >/dev/null \
  || fail "e3: postToolUseFailure must emit a tool span with harness.outcome=fail (P5): ${span3}"

# =============================================================================
# Emission E4 — CLI oversized toolArgs with a SYNTHETIC ghp_ token planted
# early: cap at 200 with `...`; token byte-absent; [REDACTED] present
# =============================================================================
SYNTH_SECRET="ghp_CopilotFixtureSecret00000000000000000000"
PADDING="$(printf 'x%.0s' $(seq 1 520))"
# toolArgs is JSON *as a string* on the CLI dialect: jq -cn emits exactly
# the compact JSON text that the real CLI stuffs into the toolArgs field.
E4_ARGS="$(jq -cn --arg secret "$SYNTH_SECRET" --arg pad "$PADDING" \
  '{command: ("export GITHUB_TOKEN=" + $secret + " && echo " + $pad)}')"
run_hook "e4-cli-secret-oversize" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  cli_payload "postToolUse" "$ISSUE_REPO" "bash" "$E4_ARGS" \
    '{"resultType":"success","textResultForLlm":""}'
)
assert_session_safe "e4-cli-secret-oversize"
[ "$(line_count "$TRACE_FILE")" = "4" ] \
  || fail "e4: expected a fourth trace line, got $(line_count "$TRACE_FILE")"
span4="$(nth_line "$TRACE_FILE" 4)"
validate_span "$span4" \
  || fail "e4: oversized/redacted span rejected by the contract filter: ${span4}"
printf '%s\n' "$span4" | jq -e '
    ((.["harness.args_summary"] | type) == "string")
    and ((.["harness.args_summary"] | length) <= 200)
    and (.["harness.args_summary"] | endswith("..."))
  ' >/dev/null \
  || fail "e4: harness.args_summary must be capped at 200 chars TOTAL and end with the pinned ASCII marker '...' (P3): ${span4}"
if grep -qF "$SYNTH_SECRET" "$TRACE_FILE"; then
  fail "e4: the synthetic ghp_ token reached disk — redaction breached: $(cat "$TRACE_FILE")"
fi
grep -qF '[REDACTED]' "$TRACE_FILE" \
  || fail "e4: expected [REDACTED] in the trace file after planting a ghp_ token: $(cat "$TRACE_FILE")"

# =============================================================================
# Emission E5 — VS Code snake_case PostToolUse, no tool_result: verbatim
# compact tool_input as the summary, outcome ABSENT, no duration
# =============================================================================
E5_INPUT='{"command":"echo vscode-fixture"}'
E5_COMPACT="$(printf '%s' "$E5_INPUT" | jq -c .)"
run_hook "e5-vsc-posttooluse" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  vsc_payload "PostToolUse" "$ISSUE_REPO" "bash" "$E5_INPUT" null
)
assert_session_safe "e5-vsc-posttooluse"
[ "$(line_count "$TRACE_FILE")" = "5" ] \
  || fail "e5: expected a fifth trace line, got $(line_count "$TRACE_FILE")"
span5="$(nth_line "$TRACE_FILE" 5)"
validate_span "$span5" || fail "e5: span rejected by the contract filter: ${span5}"
printf '%s\n' "$span5" | jq -e --arg want "$E5_COMPACT" '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "bash")
    and (.["gen_ai.operation.name"] == "execute_tool")
    and (.["harness.args_summary"] == $want)
  ' >/dev/null \
  || fail "e5: snake_case dialect must map tool_name -> gen_ai.tool.name and jq -c .tool_input VERBATIM -> harness.args_summary (P2/P3), wanted summary '${E5_COMPACT}': ${span5}"
printf '%s\n' "$span5" | jq -e 'has("harness.outcome") | not' >/dev/null \
  || fail "e5: PostToolUse without tool_result carries no unambiguous outcome — key must be OMITTED (P5): ${span5}"
printf '%s\n' "$span5" | jq -e 'has("harness.duration_ms") | not' >/dev/null \
  || fail "e5: harness.duration_ms must NEVER be emitted in the snake dialect either (P4): ${span5}"

# =============================================================================
# Emission E6 — VS Code PostToolUse with tool_result.result_type=success:
# the snake-side outcome signal maps to pass
# =============================================================================
run_hook "e6-vsc-success" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  vsc_payload "PostToolUse" "$ISSUE_REPO" "bash" '{"command":"true"}' \
    '{"result_type":"success","text_result_for_llm":"ok"}'
)
assert_session_safe "e6-vsc-success"
[ "$(line_count "$TRACE_FILE")" = "6" ] \
  || fail "e6: expected a sixth trace line, got $(line_count "$TRACE_FILE")"
span6="$(nth_line "$TRACE_FILE" 6)"
validate_span "$span6" || fail "e6: span rejected by the contract filter: ${span6}"
printf '%s\n' "$span6" | jq -e '.["harness.outcome"] == "pass"' >/dev/null \
  || fail "e6: tool_result.result_type=success (snake dialect) must stamp harness.outcome=pass (P5): ${span6}"
printf '%s\n' "$span6" | jq -e '.["harness.result_summary"] == "ok"' >/dev/null \
  || fail "e6: tool_result.text_result_for_llm must become harness.result_summary (#130 snake path): ${span6}"

# =============================================================================
# Emission E7 — redact-before-cap straddle (#96 loop-2 finding #1, pinned
# day one here): compact tool_input serializes as {"command":"<content>"} —
# a 12-char JSON prefix. With 171 filler chars the 44-char token starts at
# summary index 183; a cap-first implementation keeps 197 chars, cutting it
# to `ghp_` + 10 chars — below trace_redact's gh[pousr]_[A-Za-z0-9_]{20,}
# floor. NO ghp_ fragment may reach disk.
# =============================================================================
STRADDLE_SECRET="ghp_StraddleLeak0000000000000000000000000000"
STRADDLE_FILLER="$(printf 'z%.0s' $(seq 1 171))"
E7_INPUT="$(jq -cn --arg c "${STRADDLE_FILLER}${STRADDLE_SECRET}" '{command: $c}')"
run_hook "e7-straddle-leak" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  vsc_payload "PostToolUse" "$ISSUE_REPO" "bash" "$E7_INPUT" null
)
assert_session_safe "e7-straddle-leak"
[ "$(line_count "$TRACE_FILE")" = "7" ] \
  || fail "e7: expected a seventh trace line, got $(line_count "$TRACE_FILE")"
span7="$(nth_line "$TRACE_FILE" 7)"
validate_span "$span7" || fail "e7: span rejected by the contract filter: ${span7}"
printf '%s\n' "$span7" | jq -e '
    ((.["harness.args_summary"] | type) == "string")
    and ((.["harness.args_summary"] | length) <= 200)
  ' >/dev/null \
  || fail "e7: straddle span must still carry a capped args summary (P3): ${span7}"
if grep -q 'ghp_' "$TRACE_FILE"; then
  fail "e7: a ghp_ fragment reached disk — the 200-char cap cut the token below trace_redact's 20-char floor and leaked a redaction-proof secret prefix (cap-before-redact defect, P3): $(grep -n 'ghp_' "$TRACE_FILE")"
fi

# =============================================================================
# Emission E8 — LOOP-2 (review minor 1): CLI postToolUse with OBJECT-typed
# toolArgs (reference type `unknown`, "parsed from JSON when possible") —
# the span must carry harness.args_summary == jq -c of the object, not
# degrade to a summary-less span
# =============================================================================
E8_ARGS_OBJ='{"command":"echo object-dialect-ok"}'
E8_COMPACT="$(printf '%s' "$E8_ARGS_OBJ" | jq -c .)"
run_hook "e8-object-toolargs" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  jq -cn --arg cwd "$ISSUE_REPO" --argjson args "$E8_ARGS_OBJ" '{
    event: "postToolUse",
    timestamp: "2026-07-05T12:00:02Z",
    sessionId: "copilot-sess-fixture-0001",
    cwd: $cwd,
    toolName: "bash",
    toolArgs: $args,
    toolResult: {resultType: "success", textResultForLlm: "object-dialect-ok"},
    transcriptPath: "/nonexistent/fixture-transcript.jsonl"
  }'
)
assert_session_safe "e8-object-toolargs"
[ "$(line_count "$TRACE_FILE")" = "8" ] \
  || fail "e8: expected an eighth trace line, got $(line_count "$TRACE_FILE")"
span8="$(nth_line "$TRACE_FILE" 8)"
validate_span "$span8" || fail "e8: object-toolArgs span rejected by the contract filter: ${span8}"
printf '%s\n' "$span8" | jq -e --arg want "$E8_COMPACT" '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "bash")
    and (.["gen_ai.operation.name"] == "execute_tool")
    and (.["harness.args_summary"] == $want)
  ' >/dev/null \
  || fail "e8: OBJECT-typed toolArgs is a first-class CLI variant (reference: toolArgs is \`unknown\`, parsed from JSON when possible) — the span must carry harness.args_summary == jq -c of the object ('${E8_COMPACT}'), not a summary-less span (P3, loop-2 minor 1): ${span8}"

# =============================================================================
# Emission E8b (#130) — harness.result_summary from an oversized textResultForLlm
# carrying a SYNTHETIC ghp_ token: redact-before-cap at 500, token byte-absent,
# [REDACTED] present. Proves the new result field gets the same treatment as
# args_summary. Line 9; read dynamically so later edits stay robust.
# =============================================================================
R_SECRET="ghp_ResultFixtureSecret0000000000000000000000"
R_PAD="$(printf 'y%.0s' $(seq 1 720))"
E8B_RESULT="$(jq -cn --arg s "$R_SECRET" --arg p "$R_PAD" \
  '{resultType: "success", textResultForLlm: ("leak=" + $s + " " + $p)}')"
run_hook "e8b-result-secret-oversize" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  cli_payload "postToolUse" "$ISSUE_REPO" "bash" '{"command":"echo r"}' "$E8B_RESULT"
)
assert_session_safe "e8b-result-secret-oversize"
E8B_LINE="$(line_count "$TRACE_FILE")"
span8b="$(nth_line "$TRACE_FILE" "$E8B_LINE")"
validate_span "$span8b" || fail "e8b: result-summary span rejected by the contract filter: ${span8b}"
printf '%s\n' "$span8b" | jq -e '
    ((.["harness.result_summary"] | type) == "string")
    and ((.["harness.result_summary"] | length) <= 500)
    and (.["harness.result_summary"] | endswith("..."))
  ' >/dev/null \
  || fail "e8b: harness.result_summary must be capped at 500 chars TOTAL and end with '...' (#130): ${span8b}"
if grep -qF "$R_SECRET" "$TRACE_FILE"; then
  fail "e8b: the synthetic ghp_ token reached disk via the result summary — redaction breached: $(grep -n "$R_SECRET" "$TRACE_FILE")"
fi

# =============================================================================
# Emission E10 (#137) — event-LESS CLI v1.0.69 success: the real CLI payload
# carries NO event / hook_event_name field. Dispatch must infer a camel
# post-tool-use from shape (toolName + toolResult) and emit a tool span with
# outcome=pass AND harness.result_summary (retroactive #130 — result only
# lands once dispatch fires). Read the appended line dynamically.
# =============================================================================
E10_BEFORE="$(line_count "$TRACE_FILE")"
run_hook "e10-eventless-success" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  jq -cn --arg cwd "$ISSUE_REPO" '{
    sessionId: "copilot-sess-fixture-0001",
    timestamp: 1783345245587,
    cwd: $cwd,
    toolName: "bash",
    toolArgs: "{\"command\":\"echo eventless-ok\"}",
    toolResult: {resultType: "success", textResultForLlm: "eventless-ok"}
  }'
)
assert_session_safe "e10-eventless-success"
[ "$(line_count "$TRACE_FILE")" = "$((E10_BEFORE + 1))" ] \
  || fail "e10: an event-less CLI v1.0.69 postToolUse payload (no event field) must still emit exactly one tool span — the hook's dispatch must infer post-tool-use from shape (#137 Gap 1), got $(line_count "$TRACE_FILE") lines from ${E10_BEFORE}"
span10="$(nth_line "$TRACE_FILE" "$((E10_BEFORE + 1))")"
validate_span "$span10" || fail "e10: event-less span rejected by the contract filter: ${span10}"
printf '%s\n' "$span10" | jq -e '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "bash")
    and (.["harness.outcome"] == "pass")
    and (.["harness.result_summary"] == "eventless-ok")
    and (has("harness.duration_ms") | not)
  ' >/dev/null \
  || fail "e10: event-less success must map toolName->gen_ai.tool.name, resultType->pass, and textResultForLlm->harness.result_summary (retroactive #130): ${span10}"

# =============================================================================
# Emission E11 (#137) — event-LESS CLI failure: no event field, no toolResult,
# a top-level `error` string. Outcome must be fail (Gap 2 — the hook must read
# the top-level error, not only postToolUseFailure/resultType).
# =============================================================================
E11_BEFORE="$(line_count "$TRACE_FILE")"
run_hook "e11-eventless-failure" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  jq -cn --arg cwd "$ISSUE_REPO" '{
    sessionId: "copilot-sess-fixture-0001",
    timestamp: 1783345550461,
    cwd: $cwd,
    toolName: "bash",
    toolArgs: "{\"command\":\"false\"}",
    error: "exit status 1"
  }'
)
assert_session_safe "e11-eventless-failure"
[ "$(line_count "$TRACE_FILE")" = "$((E11_BEFORE + 1))" ] \
  || fail "e11: an event-less failure payload (top-level error, no toolResult) must still emit one tool span (#137), got $(line_count "$TRACE_FILE") from ${E11_BEFORE}"
span11="$(nth_line "$TRACE_FILE" "$((E11_BEFORE + 1))")"
validate_span "$span11" || fail "e11: event-less failure span rejected by the contract filter: ${span11}"
printf '%s\n' "$span11" | jq -e '
    (.span == "tool") and (.["harness.outcome"] == "fail")
  ' >/dev/null \
  || fail "e11: a top-level error string must stamp harness.outcome=fail (#137 Gap 2): ${span11}"

# =============================================================================
# Emission E12 (#137) — event-LESS stop-shaped payload (no event, no toolName):
# must NOT be misclassified as a tool call. No new span, session-safe.
# =============================================================================
E12_BEFORE="$(line_count "$TRACE_FILE")"
run_hook "e12-eventless-notool" "$ISSUE_REPO" "$ISSUE_HOOK" <(
  jq -cn --arg cwd "$ISSUE_REPO" '{
    sessionId: "copilot-sess-fixture-0001",
    timestamp: 1783345560000,
    cwd: $cwd
  }'
)
assert_session_safe "e12-eventless-notool"
[ "$(line_count "$TRACE_FILE")" = "$E12_BEFORE" ] \
  || fail "e12: an event-less payload with NO toolName must NOT be inferred as a tool call (stop-shaped/unknown) — no span may be appended (#137), got $(line_count "$TRACE_FILE") from ${E12_BEFORE}"

# =============================================================================
# Emission E9 — whole-file invariants: every emitted line is a tool span
# with NO harness.duration_ms key, and no .hook-state exists anywhere (P4)
# =============================================================================
while IFS= read -r line; do
  printf '%s\n' "$line" | jq -e '
      (.span == "tool") and (has("harness.duration_ms") | not)
    ' >/dev/null \
    || fail "e9: every line this feature emits must be a tool span WITHOUT harness.duration_ms (P4/P7), got: ${line}"
done < "$TRACE_FILE"
state_dirs="$(find "$ISSUE_REPO" -type d -name '.hook-state' 2>/dev/null || true)"
[ -z "$state_dirs" ] \
  || fail "e9: the Copilot hook must never create .hook-state — no correlation id exists to justify pre/post state (P4), found: ${state_dirs}"

# =============================================================================
# Template T1-T4 — docs/runtime-adapters/github-copilot.hooks.example.json
# (P8): the .github/hooks/*.json-format template the user copies (opt-in;
# the repo tracks NO active .github/hooks file)
# =============================================================================
[ -f "$TEMPLATE" ] \
  || fail "T1: hooks template not found (${TEMPLATE}) — the opt-in install artifact for feature copilot-hook-tool-spans is missing"
jq -e . "$TEMPLATE" >/dev/null 2>&1 \
  || fail "T1: hooks template is not valid JSON: ${TEMPLATE}"
jq -e '.version == 1' "$TEMPLATE" >/dev/null 2>&1 \
  || fail "T2: hooks template must carry \"version\": 1 (Copilot CLI hooks-file format, per the plan's spike sources)"
for event in postToolUse postToolUseFailure agentStop subagentStop; do
  jq -e --arg ev "$event" '[.. | objects | keys[]] | index($ev) != null' \
      "$TEMPLATE" >/dev/null 2>&1 \
    || fail "T3: hooks template must register the '${event}' event (P8)"
done
jq -e 'tostring | contains("copilot-trace-hook.sh")' "$TEMPLATE" >/dev/null 2>&1 \
  || fail "T3: hooks template must point its commands at scripts/copilot-trace-hook.sh"
# NEGATIVE pin (the fail-closed danger): preToolUse must NOT be registered.
# A non-zero exit from a registered preToolUse hook DENIES the tool call on
# Copilot surfaces; the adapter gains nothing from it (no correlation id) —
# its absence is a safety property, not an omission.
if jq -e 'tostring | test("preToolUse|PreToolUse")' "$TEMPLATE" >/dev/null 2>&1; then
  fail "T4: hooks template registers (or even mentions) preToolUse/PreToolUse — pinned FORBIDDEN: a failing preToolUse hook fail-closes into tool DENIALS and the adapter has no telemetry use for it (P8)"
fi

printf 'copilot hook tool-span + guard + template contract honored\n'
