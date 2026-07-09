#!/usr/bin/env bash
# test_copilot_hook_subagent_start_span.sh — regression sensor for
# scripts/copilot-trace-hook.sh subagentStart handling (issue #227, feature
# subagent-start-span, Task 2).
#
# subagentStart carries the CONDUCTOR's sessionId + cwd plus agentName (no
# child id — see docs/runtime-adapters/github-copilot.subagent-spike.md §4d).
# The hook must emit ONE symmetric agent span carrying gen_ai.agent.name from
# the payload's agentName, and must NOT special-case the built-in
# general-purpose agent as silent (v1.0.69 measured it emitting the event).
#
# Session ids, agent names, and timestamps here are SYNTHETIC test-only shapes.
#
# Exit codes: 0 the subagentStart contract holds · 1 an obligation regressed
# (or the feature is unimplemented — the RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/copilot-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"
[ -f "$CONTRACT" ] || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] || fail "scripts/copilot-trace-hook.sh not found (${HOOK})"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Contract-driven span validation (lifted from the sibling hook tests) ----
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
JQ
validate_span() {
  printf '%s\n' "$1" | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}
line_count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else printf '0'; fi; }
nth_line() { sed -n "${2}p" "$1"; }
trace_path() { printf '%s/.copilot-tracking/issues/issue-%s/trace.jsonl' "$1" "$2"; }

# camelCase subagentStart payload — conductor sessionId + cwd + agentName; no
# child sessionId, no toolCallId (spike §4d).
# camel_subagent_start <cwd> <session_id> <agent_name> <timestamp>
camel_subagent_start() {
  local cwd="$1" sid="$2" agent="$3" ts="$4"
  jq -cn --arg cwd "$cwd" --arg sid "$sid" --arg agent "$agent" --arg ts "$ts" '{
    event: "subagentStart",
    cwd: $cwd,
    sessionId: $sid,
    transcriptPath: ($cwd + "/events.jsonl"),
    agentName: $agent,
    agentDisplayName: $agent,
    agentDescription: "synthetic test subagent",
    timestamp: $ts
  }'
}

# A single checkout parked ON a feature/issue-NN-* branch (git resolves NN).
make_issue_branch_repo() {
  local dir="$1" branch="$2"
  mkdir -p "${dir}/scripts"
  cp "$HOOK" "${dir}/scripts/copilot-trace-hook.sh"
  cp "$LIB" "${dir}/scripts/trace-lib.sh"
  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.name "Harness Test"
    git config user.email "harness-test@example.invalid"
    printf 'fixture\n' > README.md
    git add README.md scripts
    git commit -q -m initial
    git checkout -q -b "$branch"
  ) || fail "could not build issue-branch fixture at ${dir}"
}

FIXHOME="${TMP_DIR}/home"; mkdir -p "$FIXHOME"

HOOK_RC=0; HOOK_OUT=""; HOOK_ERR=""
run_hook() {
  local label="$1" workdir="$2" stdin_file="$3"
  HOOK_OUT="${TMP_DIR}/${label}.out"; HOOK_ERR="${TMP_DIR}/${label}.err"; HOOK_RC=0
  set +e
  ( cd "$workdir" || exit 97
    HOME="$FIXHOME" COPILOT_TRACE_HOOK_DEBUG=1 \
      bash "${workdir}/scripts/copilot-trace-hook.sh" < "$stdin_file"
  ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -ne 97 ] || fail "${label}: fixture workdir vanished (${workdir})"
}
assert_session_safe() {
  local label="$1"
  [ "$HOOK_RC" -eq 0 ] || fail "${label}: hook must ALWAYS exit 0 — got ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] || fail "${label}: hook stdout must be EMPTY, got: $(cat "$HOOK_OUT")"
}

# =============================================================================
# A1 — a custom subagent's subagentStart emits ONE agent span carrying the
# agentName and harness.session_id.
# =============================================================================
DIRA1="${TMP_DIR}/issue-701-repo"
make_issue_branch_repo "$DIRA1" "feature/issue-701-start"
A1_TRACE="$(trace_path "$DIRA1" 701)"
a1_before="$(line_count "$A1_TRACE")"
run_hook "a1" "$DIRA1" <(
  camel_subagent_start "$DIRA1" "8aa950ec-conductor-uuid" "spike226-probe" 2026-07-07T10:00:00Z
)
assert_session_safe "a1"
a1_after="$(line_count "$A1_TRACE")"
[ "$a1_after" = "$((a1_before + 1))" ] \
  || fail "A1: subagentStart must emit EXACTLY one agent span to issue-701 — before=${a1_before} after=${a1_after} (feature subagent-start-span unimplemented)"
a1_new="$(nth_line "$A1_TRACE" "$a1_after")"
validate_span "$a1_new" \
  || fail "A1: the appended span is rejected by the schema filter: ${a1_new}"
printf '%s\n' "$a1_new" | jq -e '
    .span == "agent"
    and .["gen_ai.operation.name"] == "invoke_agent"
    and .["gen_ai.agent.name"] == "spike226-probe"
    and .["harness.issue"] == 701
    and .["harness.session_id"] == "8aa950ec-conductor-uuid"' >/dev/null \
  || fail "A1: subagentStart must emit an invoke_agent span with gen_ai.agent.name=spike226-probe and harness.session_id from the payload: ${a1_new}"

# =============================================================================
# A2 — the built-in general-purpose agent is NOT special-cased silent: its
# subagentStart still emits an agent span (v1.0.69 measured, spike §4 bonus).
# =============================================================================
DIRA2="${TMP_DIR}/issue-702-repo"
make_issue_branch_repo "$DIRA2" "feature/issue-702-gp"
A2_TRACE="$(trace_path "$DIRA2" 702)"
a2_before="$(line_count "$A2_TRACE")"
run_hook "a2" "$DIRA2" <(
  camel_subagent_start "$DIRA2" "8bb62002-conductor-uuid" "general-purpose" 2026-07-07T10:00:00Z
)
assert_session_safe "a2"
a2_after="$(line_count "$A2_TRACE")"
[ "$a2_after" = "$((a2_before + 1))" ] \
  || fail "A2: general-purpose subagentStart must NOT be special-cased silent — it must emit one agent span (before=${a2_before} after=${a2_after})"
a2_new="$(nth_line "$A2_TRACE" "$a2_after")"
printf '%s\n' "$a2_new" | jq -e '
    .span == "agent" and .["gen_ai.agent.name"] == "general-purpose"' >/dev/null \
  || fail "A2: the general-purpose agent span must carry gen_ai.agent.name=general-purpose: ${a2_new}"

printf 'PASS: copilot-trace-hook.sh emits a symmetric agent span for subagentStart (custom + general-purpose), carrying agentName and harness.session_id\n'
