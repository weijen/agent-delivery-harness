#!/usr/bin/env bash
# test_copilot_hook_session_binding.sh — regression sensor for
# scripts/copilot-trace-hook.sh session binding attribution precedence
# (issue #165, feature hook-session-binding).
#
# A session id bound to an issue must remain authoritative for later spans:
# git → binding → interval. In particular, a bound main-checkout span must
# never fall through to interval ambiguity when multiple active windows overlap.
#
# Session ids, tool names, and timestamps here are SYNTHETIC test-only shapes.
#
# Exit codes: 0 session-binding contract honored · 1 an obligation regressed
# (or the feature is not implemented yet — the RED gate).

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
command -v git >/dev/null 2>&1 \
  || fail "git is required to build the main-checkout / worktree fixtures"
[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — fixtures need the real emitter beside the hook copy"
[ -f "$HOOK" ] \
  || fail "scripts/copilot-trace-hook.sh not found (${HOOK}) — feature copilot-hook-interval-attribution (issue #146) has no hook to test"

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (lifted verbatim from test_trace_schema.sh)
# A span line is valid iff the filter outputs true (jq -e exit 0).
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

line_count() {
  if [ -f "$1" ]; then
    wc -l < "$1" | tr -d '[:space:]'
  else
    printf '0'
  fi
}
nth_line() { sed -n "${2}p" "$1"; }

# --- Payload builder ----------------------------------------------------------
# VS Code snake_case PostToolUse — the primary interval-fallback topology.
# session_id and timestamp are omitted when passed "-" (C5 exercises the
# missing-timestamp path). tool_input is a JSON object.
# snake_post_ts <cwd> <session_id|-> <tool_name> <tool_input-json> <timestamp|->
snake_post_ts() {
  local cwd="$1" sid="$2" tool="$3" input="$4" ts="$5"
  jq -cn \
    --arg cwd "$cwd" --arg sid "$sid" --arg tool "$tool" \
    --argjson input "$input" --arg ts "$ts" '
    {
      hook_event_name: "PostToolUse",
      cwd: $cwd,
      tool_name: $tool,
      tool_input: $input,
      transcript_path: "/nonexistent/fixture-transcript.jsonl"
    }
    + (if $sid == "-" then {} else {session_id: $sid} end)
    + (if $ts == "-" then {} else {timestamp: $ts} end)'
}

# CLI camelCase postToolUse — a subagent's tool/skill calls arrive on THIS
# dialect carrying a `toolu_`-prefixed sessionId (the spawning task tool-use
# id), per docs/runtime-adapters/github-copilot.subagent-spike.md §4. toolArgs
# is a JSON string (CLI dialect). sessionId/timestamp omitted when passed "-".
# camel_post_ts <cwd> <session_id|-> <tool_name> <tool_args-json-string> <timestamp|->
camel_post_ts() {
  local cwd="$1" sid="$2" tool="$3" args="$4" ts="$5"
  jq -cn \
    --arg cwd "$cwd" --arg sid "$sid" --arg tool "$tool" \
    --arg args "$args" --arg ts "$ts" '
    {
      event: "postToolUse",
      cwd: $cwd,
      toolName: $tool,
      toolArgs: $args,
      toolResult: { resultType: "success", textResultForLlm: "ok" }
    }
    + (if $sid == "-" then {} else {sessionId: $sid} end)
    + (if $ts == "-" then {} else {timestamp: $ts} end)'
}

# --- Fixture builders ---------------------------------------------------------
# A fresh MAIN checkout repo on branch `main` with the hook + emitter copied
# beside each other under scripts/. Checked out on `main` so
# trace__resolve_issue yields nothing and the interval fallback is the only
# path that can attribute a span (the VS Code conductor topology).
make_main_repo() {
  local dir="$1"
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
  ) || fail "could not build main-checkout fixture at ${dir}"
}

# A single checkout parked ON a feature/issue-NN-* branch (git resolves NN),
# for the git-first non-regression case.
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

# Append one lifecycle span (worktree_create | finish) to an issue's on-disk
# trace, defining/extending that issue's active window. Mirrors the real
# lifecycle span shape (span=lifecycle, harness.issue numeric,
# harness.lifecycle_step, ISO-8601 Z timestamp).
# seed_lifecycle <repo_root> <issue-number> <step> <timestamp>
seed_lifecycle() {
  local repo="$1" issue="$2" step="$3" ts="$4"
  local dir="${repo}/.copilot-tracking/issues/issue-${issue}"
  mkdir -p "$dir"
  jq -cn --arg ts "$ts" --arg step "$step" --argjson issue "$issue" '{
    schema_version: 1,
    timestamp: $ts,
    span: "lifecycle",
    "harness.issue": $issue,
    "harness.version": "0.0.0-dev",
    "harness.lifecycle_step": $step,
    span_id: ("seed-" + $step + "-" + ($issue | tostring))
  }' >> "${dir}/trace.jsonl" \
    || fail "seed_lifecycle: could not seed ${step} for issue-${issue}"
}

trace_path() {
  printf '%s/.copilot-tracking/issues/issue-%s/trace.jsonl' "$1" "$2"
}

# Throwaway HOME so no case can touch the developer's real ~/.copilot.
FIXHOME="${TMP_DIR}/home"
mkdir -p "$FIXHOME"

# --- Hook runner --------------------------------------------------------------
# run_hook <label> <workdir> <stdin-file>. Runs the workdir's OWN hook copy
# with process cwd = workdir; COPILOT_TRACE_HOOK_DEBUG=1 keeps the
# honest-omission WARN observable on stderr while stdout stays JSON-clean.
HOOK_RC=0
HOOK_OUT=""
HOOK_ERR=""
run_hook() {
  local label="$1" workdir="$2" stdin_file="$3"
  HOOK_OUT="${TMP_DIR}/${label}.out"
  HOOK_ERR="${TMP_DIR}/${label}.err"
  HOOK_RC=0
  set +e
  (
    cd "$workdir" || exit 97
    HOME="$FIXHOME" COPILOT_TRACE_HOOK_DEBUG=1 \
      bash "${workdir}/scripts/copilot-trace-hook.sh" < "$stdin_file"
  ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -ne 97 ] || fail "${label}: fixture workdir vanished (${workdir})"
}

# Session-safety invariants on every invocation: exit 0 + empty stdout.
assert_session_safe() {
  local label="$1"
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 — Copilot treats hook failure as a tool DENIAL on some surfaces — got exit ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] \
    || fail "${label}: hook stdout must be EMPTY (Copilot parses hook stdout as JSON), got: $(cat "$HOOK_OUT")"
}

# A visible WARN reached stderr (honest-omission path). trace_warn prints
# "trace-lib: warning: …"; a hook-local warning may say ambiguous/attribute/
# window — accept any of them, case-insensitive.
assert_warn_on_stderr() {
  local label="$1"
  grep -iqE 'warn|ambig|attribut|window|no-op|noop' "$HOOK_ERR" \
    || fail "${label}: a no-op attribution decision must surface a visible WARN on stderr (never silently mis-attribute) — feature copilot-hook-interval-attribution is unimplemented (no warning emitted). stderr was: $(cat "$HOOK_ERR")"
}

# =============================================================================
# B1 — bound session wins over overlapping open-ended windows.
# =============================================================================
MAINB1="${TMP_DIR}/main-b1"
make_main_repo "$MAINB1"
seed_lifecycle "$MAINB1" 501 worktree_create 2026-07-07T09:00:00Z
seed_lifecycle "$MAINB1" 502 worktree_create 2026-07-07T09:05:00Z
mkdir -p "${MAINB1}/.copilot-tracking/sessions"
printf '%s' "501" > "${MAINB1}/.copilot-tracking/sessions/S-BIND"
B1_T501="$(trace_path "$MAINB1" 501)"
B1_T502="$(trace_path "$MAINB1" 502)"
b1_before501="$(line_count "$B1_T501")"
b1_before502="$(line_count "$B1_T502")"
if ! { [ "$b1_before501" = "1" ] && [ "$b1_before502" = "1" ]; }; then
  fail "B1: fixture seed wrong (want 1 lifecycle line per issue, got 501=${b1_before501} 502=${b1_before502})"
fi
run_hook "b1" "$MAINB1" <(
  snake_post_ts "$MAINB1" "S-BIND" "bash" '{"command":"echo bound"}' 2026-07-07T10:00:00Z
)
assert_session_safe "b1"
b1_after501="$(line_count "$B1_T501")"
b1_after502="$(line_count "$B1_T502")"
[ "$b1_after501" = "$((b1_before501 + 1))" ] \
  || fail "B1: bound session S-BIND must append EXACTLY one tool span to issue-501/trace.jsonl even though issue-501 and issue-502 have overlapping open-ended windows — got before=${b1_before501} after=${b1_after501}; the hook did not honor binding before interval attribution"
[ "$b1_after502" = "$b1_before502" ] \
  || fail "B1: issue-502 must remain unchanged when S-BIND is bound to issue-501 — got before=${b1_before502} after=${b1_after502} (binding did not win over interval ambiguity)"
b1_new="$(nth_line "$B1_T501" "$b1_after501")"
validate_span "$b1_new" \
  || fail "B1: the appended span is rejected by the #92 contract filter (fixture broken, not a binding regression): ${b1_new}"
printf '%s\n' "$b1_new" | jq -e '
    .span == "tool" and .["gen_ai.tool.name"] == "bash"
    and .["harness.session_id"] == "S-BIND" and .["harness.issue"] == 501' >/dev/null \
  || fail "B1: the binding-attributed span must be a tool span for issue-501 carrying gen_ai.tool.name=bash and harness.session_id=S-BIND: ${b1_new}"

# =============================================================================
# B2 — binding written on git-resolves path.
# =============================================================================
DIRB2="${TMP_DIR}/issue-503-repo"
make_issue_branch_repo "$DIRB2" "feature/issue-503-bind"
run_hook "b2" "$DIRB2" <(
  snake_post_ts "$DIRB2" "S-WRITE" "bash" '{"command":"echo write"}' 2026-07-07T10:00:00Z
)
assert_session_safe "b2"
B2_BINDING="${DIRB2}/.copilot-tracking/sessions/S-WRITE"
[ -f "$B2_BINDING" ] \
  || fail "B2: git-resolved issue-503 span with session S-WRITE must persist ${B2_BINDING}"
[ "$(cat "$B2_BINDING")" = "503" ] \
  || fail "B2: ${B2_BINDING} must contain exactly unpadded issue number 503, got: $(cat "$B2_BINDING")"

# =============================================================================
# B3 — no binding preserves interval fallback.
# =============================================================================
MAINB3="${TMP_DIR}/main-b3"
make_main_repo "$MAINB3"
seed_lifecycle "$MAINB3" 504 worktree_create 2026-07-07T10:00:00Z
seed_lifecycle "$MAINB3" 504 finish          2026-07-07T10:30:00Z
B3_T504="$(trace_path "$MAINB3" 504)"
b3_before504="$(line_count "$B3_T504")"
run_hook "b3" "$MAINB3" <(
  snake_post_ts "$MAINB3" "S-NOBIND" "bash" '{"command":"echo x"}' 2026-07-07T10:15:00Z
)
assert_session_safe "b3"
b3_after504="$(line_count "$B3_T504")"
[ "$b3_after504" = "$((b3_before504 + 1))" ] \
  || fail "B3: with no session binding, a payload inside issue-504's interval window must still append one span via interval fallback — got before=${b3_before504} after=${b3_after504}"
b3_new="$(nth_line "$B3_T504" "$b3_after504")"
validate_span "$b3_new" \
  || fail "B3: the appended span is rejected by the #92 contract filter: ${b3_new}"
printf '%s\n' "$b3_new" | jq -e '
    .span == "tool" and .["harness.issue"] == 504' >/dev/null \
  || fail "B3: the no-binding interval-fallback span must be attributed to issue-504: ${b3_new}"

# =============================================================================
# B4 — garbage binding ignored, session-safe, interval fallback still works.
# =============================================================================
MAINB4="${TMP_DIR}/main-b4"
make_main_repo "$MAINB4"
seed_lifecycle "$MAINB4" 505 worktree_create 2026-07-07T10:00:00Z
seed_lifecycle "$MAINB4" 505 finish          2026-07-07T10:30:00Z
mkdir -p "${MAINB4}/.copilot-tracking/sessions"
printf '%s' "not-a-number" > "${MAINB4}/.copilot-tracking/sessions/S-GARBAGE"
B4_T505="$(trace_path "$MAINB4" 505)"
b4_before505="$(line_count "$B4_T505")"
run_hook "b4" "$MAINB4" <(
  snake_post_ts "$MAINB4" "S-GARBAGE" "bash" '{"command":"echo garbage"}' 2026-07-07T10:15:00Z
)
assert_session_safe "b4"
b4_after505="$(line_count "$B4_T505")"
[ "$b4_after505" = "$((b4_before505 + 1))" ] \
  || fail "B4: garbage binding content must be ignored safely and fall back to issue-505's interval window — got before=${b4_before505} after=${b4_after505}"
b4_new="$(nth_line "$B4_T505" "$b4_after505")"
validate_span "$b4_new" \
  || fail "B4: the appended span is rejected by the #92 contract filter: ${b4_new}"
printf '%s\n' "$b4_new" | jq -e '
    .span == "tool" and .["harness.issue"] == 505' >/dev/null \
  || fail "B4: the garbage-binding fallback span must be attributed to issue-505: ${b4_new}"

# =============================================================================
# B5 — git resolution wins over stale competing binding and refreshes binding.
# =============================================================================
DIRB5="${TMP_DIR}/issue-505-repo"
make_issue_branch_repo "$DIRB5" "feature/issue-505-gitwin"
mkdir -p "${DIRB5}/.copilot-tracking/sessions"
printf '%s' "999" > "${DIRB5}/.copilot-tracking/sessions/S-GITWIN"
B5_T505="$(trace_path "$DIRB5" 505)"
B5_T999="$(trace_path "$DIRB5" 999)"
b5_before505="$(line_count "$B5_T505")"
run_hook "b5" "$DIRB5" <(
  snake_post_ts "$DIRB5" "S-GITWIN" "bash" '{"command":"echo git-wins"}' 2026-07-07T10:00:00Z
)
assert_session_safe "b5"
b5_after505="$(line_count "$B5_T505")"
[ "$b5_after505" = "$((b5_before505 + 1))" ] \
  || fail "B5: git resolution is authoritative and must win over a stale competing binding (999) — binding must NOT override an unambiguous git resolution (issue #165 AC1 / CLI-from-worktree unchanged); got issue-505 before=${b5_before505} after=${b5_after505}"
b5_new="$(nth_line "$B5_T505" "$b5_after505")"
validate_span "$b5_new" \
  || fail "B5: the appended span is rejected by the #92 contract filter: ${b5_new}"
printf '%s\n' "$b5_new" | jq -e '
    .span == "tool" and .["gen_ai.tool.name"] == "bash"
    and .["harness.session_id"] == "S-GITWIN" and .["harness.issue"] == 505' >/dev/null \
  || fail "B5: git resolution is authoritative and must win over a stale competing binding (999) — binding must NOT override an unambiguous git resolution (issue #165 AC1 / CLI-from-worktree unchanged); expected tool span for issue-505 with gen_ai.tool.name=bash and harness.session_id=S-GITWIN: ${b5_new}"
[ "$(cat "${DIRB5}/.copilot-tracking/sessions/S-GITWIN")" = "505" ] \
  || fail "B5: the git-resolves path must refresh the binding to the current git issue so the map always reflects the latest git-resolved issue"
[ "$(line_count "$B5_T999")" = "0" ] \
  || fail "B5: stale issue-999 binding must not receive a span when git resolves issue-505; issue-999 line count is $(line_count "$B5_T999")"

printf 'PASS: copilot-trace-hook.sh honors session binding before interval attribution, writes/refreshes git-resolved bindings, keeps git-over-stale-binding precedence, and safely falls back when absent or garbage\n'

# =============================================================================
# T-block (#227 feature toolu-bind-and-stamp) — a subagent's tool/skill calls
# arrive with a `toolu_`-prefixed sessionId. They must be recognized as a
# subagent session (harness.subagent=true), attributed via the still-valid
# conductor context, persist a binding keyed by the toolu_ id, and still DROP
# when unbindable + interval-ambiguous (never mis-attribute).
# =============================================================================

# seed_marker <repo_root> <issue> <start-ts>  — the #216 active-issue marker.
seed_marker() {
  local repo="$1" issue="$2" ts="$3"
  mkdir -p "${repo}/.copilot-tracking/active-issues"
  printf '%s' "$ts" > "${repo}/.copilot-tracking/active-issues/${issue}"
}

# T1 — git-resolved worktree: toolu_ tool span attributed to the branch issue,
# harness.subagent=true stamped, harness.skill.name kept, binding persisted
# keyed by the toolu_ id.
DIRT1="${TMP_DIR}/issue-601-repo"
make_issue_branch_repo "$DIRT1" "feature/issue-601-subagent"
T1_TRACE="$(trace_path "$DIRT1" 601)"
t1_before="$(line_count "$T1_TRACE")"
run_hook "t1" "$DIRT1" <(
  camel_post_ts "$DIRT1" "toolu_01AaBbCc" "skill" '{"skill":"find-over-design"}' 2026-07-07T10:00:00Z
)
assert_session_safe "t1"
t1_after="$(line_count "$T1_TRACE")"
[ "$t1_after" = "$((t1_before + 1))" ] \
  || fail "T1(#227): a toolu_ subagent postToolUse in a git-resolved worktree must append EXACTLY one tool span to issue-601 — before=${t1_before} after=${t1_after}"
t1_new="$(nth_line "$T1_TRACE" "$t1_after")"
validate_span "$t1_new" \
  || fail "T1(#227): the appended span is rejected by the #92 contract filter (fixture broken): ${t1_new}"
printf '%s\n' "$t1_new" | jq -e '
    .span == "tool" and .["gen_ai.tool.name"] == "skill"
    and .["harness.issue"] == 601
    and .["harness.subagent"] == "true"
    and .["harness.skill.name"] == "find-over-design"' >/dev/null \
  || fail "T1(#227): the toolu_ tool span must carry harness.subagent=\"true\" and keep harness.skill.name=find-over-design: ${t1_new}"
T1_BIND="${DIRT1}/.copilot-tracking/sessions/toolu_01AaBbCc"
[ -f "$T1_BIND" ] && [ "$(cat "$T1_BIND" 2>/dev/null)" = "601" ] \
  || fail "T1(#227): the toolu_ session must persist a binding keyed by the toolu_ id (=601) so later calls skip the scan; got: $(cat "$T1_BIND" 2>/dev/null)"

# T2 — main-checkout topology, single #216 marker: the toolu_ session resolves
# via the marker, stamps harness.subagent=true, and PERSISTS a binding keyed by
# the toolu_ id so a subsequent call is bound (skips the interval scan).
MAINT2="${TMP_DIR}/main-t2"
make_main_repo "$MAINT2"
seed_lifecycle "$MAINT2" 602 worktree_create 2026-07-07T09:00:00Z
seed_marker "$MAINT2" 602 2026-07-07T09:00:00Z
T2_TRACE="$(trace_path "$MAINT2" 602)"
t2_before="$(line_count "$T2_TRACE")"
run_hook "t2" "$MAINT2" <(
  camel_post_ts "$MAINT2" "toolu_02MarkerX" "view" '{"path":"README.md"}' 2026-07-07T10:00:00Z
)
assert_session_safe "t2"
t2_after="$(line_count "$T2_TRACE")"
[ "$t2_after" = "$((t2_before + 1))" ] \
  || fail "T2(#227): a toolu_ session in the main checkout must resolve via the #216 marker and append one tool span to issue-602 — before=${t2_before} after=${t2_after}"
t2_new="$(nth_line "$T2_TRACE" "$t2_after")"
printf '%s\n' "$t2_new" | jq -e '
    .span == "tool" and .["harness.issue"] == 602 and .["harness.subagent"] == "true"' >/dev/null \
  || fail "T2(#227): the marker-resolved toolu_ span must be attributed to issue-602 with harness.subagent=\"true\": ${t2_new}"
T2_BIND="${MAINT2}/.copilot-tracking/sessions/toolu_02MarkerX"
[ -f "$T2_BIND" ] && [ "$(cat "$T2_BIND" 2>/dev/null)" = "602" ] \
  || fail "T2(#227): a toolu_ session resolved via marker/interval must persist a binding keyed by the toolu_ id (=602) so later calls skip the scan; got: $(cat "$T2_BIND" 2>/dev/null)"

# T3 — unbindable + interval-ambiguous toolu_ session STILL DROPS (never
# mis-attribute), with a visible warn on stderr.
MAINT3="${TMP_DIR}/main-t3"
make_main_repo "$MAINT3"
seed_lifecycle "$MAINT3" 603 worktree_create 2026-07-07T09:00:00Z
seed_lifecycle "$MAINT3" 604 worktree_create 2026-07-07T09:05:00Z
T3_T603="$(trace_path "$MAINT3" 603)"
T3_T604="$(trace_path "$MAINT3" 604)"
t3_before603="$(line_count "$T3_T603")"
t3_before604="$(line_count "$T3_T604")"
run_hook "t3" "$MAINT3" <(
  camel_post_ts "$MAINT3" "toolu_03Ambig" "bash" '{"command":"echo x"}' 2026-07-07T10:00:00Z
)
assert_session_safe "t3"
[ "$(line_count "$T3_T603")" = "$t3_before603" ] && [ "$(line_count "$T3_T604")" = "$t3_before604" ] \
  || fail "T3(#227): an unbindable, interval-ambiguous toolu_ session must DROP (append no span to either overlapping window) — 603 ${t3_before603}->$(line_count "$T3_T603"), 604 ${t3_before604}->$(line_count "$T3_T604")"
assert_warn_on_stderr "t3"

printf 'PASS: copilot-trace-hook.sh binds+stamps toolu_ subagent sessions (git/marker), persists a toolu_-keyed binding, and drops unbindable+ambiguous toolu_ sessions\n'
