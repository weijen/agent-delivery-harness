#!/usr/bin/env bash
# test_copilot_hook_skill_payload_hypotheses.sh — CHARACTERIZATION sensor for
# scripts/copilot-trace-hook.sh under HYPOTHESIZED skill-shaped postToolUse
# payloads (issue #121, feature spike-static).
#
# WHAT THIS TEST IS (read before editing):
#   (a) It PINS how the hook behaves *under a hypothesis about payload shape*:
#       given a postToolUse whose toolName/toolArgs look like a skill
#       invocation, the hook — being TOOL-NAME-AGNOSTIC (see the closed event
#       dispatch in scripts/copilot-trace-hook.sh hook__main, and the
#       tool-name-blind hook__on_post_tool_use handler) — emits exactly one
#       schema-valid `tool` span, no different from any other tool call.
#   (b) It DOES NOT prove Copilot actually sends these shapes when a skill is
#       invoked. Whether a skill invocation surfaces as a distinct tool call
#       at all — and if so under what literal toolName, with what toolArgs,
#       and with any success/failure signal — is the UNRESOLVED Spike-Live
#       question. Answering it requires a real Copilot CLI session with the
#       hook installed (see docs/runtime-adapters/github-copilot.skill-spike.md,
#       "TODO(human): Spike-Live capture"). The payloads below are INVENTED
#       hypotheses, not measured captures.
#   (c) Its VALUE is a REGRESSION GUARD: it prevents a future path-A edit
#       (teaching the hook to special-case a skill toolName) from silently
#       breaking plain tool-span emission for skill-shaped calls. If someone
#       adds a skill branch that drops, renames, or suppresses the span for a
#       skill-looking toolName, one of the assertions below turns RED.
#
# HONESTY NOTE — this is NOT a RED->GREEN feature test. The behavior it pins
# ALREADY EXISTS (the hook has been tool-name-agnostic since #114), so this
# test is GREEN the moment it lands. There is no fabricated RED gate here
# beyond the pre-existing "hook file must exist" guard; do not read its
# green-from-start status as "feature already implemented" — the skill-span
# FEATURE (a first-class `skill` kind) is deliberately NOT built here and is
# gated on the Spike-Live capture.
#
# Fixture pattern is lifted from tests/scripts/test_copilot_hook_tool_span.sh:
# throwaway git repos, an isolated COPY of the hook + trace-lib beside it (the
# real-repo files are never invoked), and line-counted trace assertions.
#
# The camelCase (CLI) dialect is the only surface #114 claims verified, so the
# hypotheses use it. Secrets, if any, would be SYNTHETIC — none are needed.
#
# Exit codes: 0 characterization holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/copilot-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
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
[ -f "$HOOK" ] \
  || fail "scripts/copilot-trace-hook.sh not found (${HOOK}) — the hook under characterization is absent"

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Contract-driven span validation (lifted from the #92 filter) --------------
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

# --- Payload builder (CLI camelCase; toolArgs is JSON *as a string*) ------------
# cli_payload <event> <cwd> <toolName> <toolArgs-string> <toolResult-json|null>
cli_payload() {
  jq -cn --arg event "$1" --arg cwd "$2" --arg tool "$3" --arg args "$4" \
    --argjson result "$5" '{
      event: $event,
      timestamp: "2026-07-05T12:00:00Z",
      sessionId: "copilot-sess-skillhypo-0001",
      cwd: $cwd,
      toolName: $tool,
      toolArgs: $args,
      transcriptPath: "/nonexistent/fixture-transcript.jsonl"
    } + (if $result == null then {} else {toolResult: $result} end)'
}

# --- Hook runner ----------------------------------------------------------------
HOOK_RC=0
HOOK_OUT=""
HOOK_ERR=""
run_hook() {
  local label="$1" workdir="$2" hook_path="$3" stdin_file="$4"
  HOOK_OUT="${TMP_DIR}/${label}.out"
  HOOK_ERR="${TMP_DIR}/${label}.err"
  HOOK_RC=0
  set +e
  (
    cd "$workdir" || exit 97
    bash "$hook_path" < "$stdin_file"
  ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -ne 97 ] || fail "${label}: fixture workdir vanished (${workdir})"
}

# Session-safety invariants shared by every invocation: exit 0, empty stdout.
assert_session_safe() {
  local label="$1"
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 (Copilot treats hook failure as a tool DENIAL on some surfaces) — got exit ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] \
    || fail "${label}: hook stdout must be EMPTY (Copilot parses hook stdout as JSON), got: $(cat "$HOOK_OUT")"
}

# --- Fixture: issue-worktree-shaped repo (valid harness context) ----------------
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
  git checkout -q -b feature/issue-21-copilot-skill-hypothesis
) || fail "could not build the issue-context fixture"
ISSUE_HOOK="${ISSUE_REPO}/scripts/copilot-trace-hook.sh"
TRACE_FILE="${ISSUE_REPO}/.copilot-tracking/issues/issue-21/trace.jsonl"

# --- Hypotheses -----------------------------------------------------------------
# Each row is a GUESS at how a skill invocation *might* be shaped as a
# postToolUse tool call. NONE is a measured capture. The assertion is uniform:
# the hook must produce exactly one schema-valid `tool` span carrying the
# hypothesized toolName as gen_ai.tool.name, with the skill name reflected in
# harness.args_summary — proving the hook stays tool-name-agnostic.
#
# H1 — toolName is the literal string "skill" (generic skill-dispatch guess),
#      the invoked skill named inside toolArgs.
# H2 — toolName is "invoke_skill" (verb-style dispatch guess), skill named in
#      toolArgs.
# H3 — toolName IS the skill's own name ("find-over-design"), one of the real
#      .copilot/skills/*/SKILL.md skills, with a matching skill-shaped arg.
#
# HYPO_ROWS: label|toolName|skillName (skillName is what we expect to see
# reflected in the args summary).
HYPO_ROWS=(
  "h1-toolname-skill|skill|find-over-design"
  "h2-toolname-invoke-skill|invoke_skill|security-audit"
  "h3-toolname-is-skill-name|find-over-design|find-over-design"
)

expected_line=0
for row in "${HYPO_ROWS[@]}"; do
  IFS='|' read -r label tool_name skill_name <<< "$row"
  expected_line=$((expected_line + 1))

  # A skill-shaped toolArgs: names the skill under a plausible key. Taken as a
  # JSON string on the CLI dialect (verbatim into harness.args_summary).
  args_str="$(jq -cn --arg s "$skill_name" '{skill: $s}')"

  run_hook "$label" "$ISSUE_REPO" "$ISSUE_HOOK" <(
    cli_payload "postToolUse" "$ISSUE_REPO" "$tool_name" "$args_str" \
      '{"resultType":"success","textResultForLlm":"skill fixture"}'
  )
  assert_session_safe "$label"

  [ -f "$TRACE_FILE" ] \
    || fail "${label}: a skill-shaped postToolUse in a valid issue context must append a tool span (${TRACE_FILE} missing) — hook regressed to non-tool-name-agnostic"
  [ "$(line_count "$TRACE_FILE")" = "$expected_line" ] \
    || fail "${label}: expected ${expected_line} trace line(s) after ${expected_line} skill-shaped postToolUse call(s), got $(line_count "$TRACE_FILE") — the hook must emit exactly one tool span per skill-shaped call, no more, no fewer"

  span="$(nth_line "$TRACE_FILE" "$expected_line")"
  validate_span "$span" \
    || fail "${label}: the tool span for a skill-shaped call must still validate against the #92 contract (span=tool, no special skill kind): ${span}"
  printf '%s\n' "$span" | jq -e --arg tn "$tool_name" --arg sn "$skill_name" '
      (.span == "tool")
      and (.["gen_ai.tool.name"] == $tn)
      and (.["gen_ai.operation.name"] == "execute_tool")
      and ((.["harness.args_summary"] | type) == "string")
      and (.["harness.args_summary"] | contains($sn))
    ' >/dev/null \
    || fail "${label}: expected a tool-name-agnostic tool span — gen_ai.tool.name=='${tool_name}', operation=execute_tool, args summary carrying the skill name '${skill_name}'. If this failed, a path-A edit likely special-cased a skill toolName and broke plain tool-span emission: ${span}"

  # A skill invocation is NOT (yet) a first-class span kind: the hook must NOT
  # invent a `skill` span or a harness.skill.* attribute in this feature. That
  # is gated on the Spike-Live capture + schema commit (issue #121 feature
  # skill-span-schema), deliberately not built here.
  printf '%s\n' "$span" | jq -e '
      (.span != "skill") and (has("harness.skill.name") | not)
    ' >/dev/null \
    || fail "${label}: this feature must NOT emit a first-class skill span or harness.skill.name — that is gated on the Spike-Live capture (feature skill-span-schema). The hook should still produce a plain tool span: ${span}"
done

# Whole-file invariant: every emitted line is a plain tool span (no skill kind
# leaked in), matching the characterized tool-name-agnostic behavior.
while IFS= read -r line; do
  printf '%s\n' "$line" | jq -e '.span == "tool"' >/dev/null \
    || fail "whole-file: every line emitted for a skill-shaped call must be a plain tool span under the current (characterized) behavior, got: ${line}"
done < "$TRACE_FILE"

printf 'copilot hook skill-payload HYPOTHESES characterized (tool-name-agnostic, no skill kind) — Spike-Live still required to confirm real payload shapes\n'
