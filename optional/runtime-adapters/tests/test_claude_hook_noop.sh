#!/usr/bin/env bash
# test_claude_hook_noop.sh — regression sensor for
# optional/runtime-adapters/claude-code-trace-hook.sh silent no-op guard
# (issue #96, feature claude-hook-noop-guard, plan Phase 1).
#
# The hook is wired into a user's LIVE Claude Code session via a copyable
# .claude/settings.json snippet and runs for EVERY tool call, in any repo.
# Claude Code interprets non-zero exit codes and stdout content, so the hook
# must be impossible to disturb a session with: outside a harness issue run
# it must exit 0, write NOTHING to stdout, and create no trace artifacts.
#
# PINNED GUARD-ORDER CONTRACT (plan D2, conductor-resolved):
#   G1. jq availability — `command -v jq` BEFORE any jq invocation. jq absent
#       must not even surface a "command not found"; the hook exits 0 silently.
#   G2. stdin parses as a JSON object (slurped once) — malformed / empty /
#       oversized garbage stdin → silent exit 0.
#   G3. trace-lib.sh exists beside the hook script — absent → silent exit 0.
#   G4. issue context resolves from the payload `cwd` (git -C <cwd>, fallback
#       $PWD) with trace-lib precedence: TRACE_ISSUE → feature/issue-NN-*
#       branch → issue-NN worktree basename. Unresolvable = "not a harness
#       run" → silent exit 0. A non-git cwd is unresolvable by definition.
#   G5. event dispatch — only PreToolUse / PostToolUse / Stop / SubagentStop
#       are handled; any other hook_event_name → silent exit 0.
#   Invariants across ALL paths: exit status 0, empty stdout, no crash text
#   on stderr (advisory warnings are tolerated), no trace.jsonl created.
#
# Sensor cases (fixtures: throwaway repos per test_trace_lib.sh pattern;
# payloads fed on stdin exactly as Claude Code delivers them):
#   1. Valid PostToolUse payload, cwd a plain git repo on `main` with no
#      TRACE_ISSUE (outside any harness issue context) → silent no-op,
#      no trace.jsonl anywhere in the fixture, no .copilot-tracking created.
#   2. cwd not a git repo at all → same silent no-op.
#   3. Malformed stdin — non-JSON text, empty stdin, a ~2MB garbage line —
#      run INSIDE a valid issue context so the parse guard (G2), not the
#      context guard, is what proves the no-op → silent no-op, no trace.
#   4. jq absent from PATH (stub PATH with git/coreutils but no jq), valid
#      payload, valid issue context → silent no-op with NO "command not
#      found" on stderr — proves G1 precedes any jq use.
#   5. trace-lib.sh missing beside the hook (hook copied to an isolated dir),
#      valid payload + context → silent no-op, no trace.
#   6. Unknown hook_event_name (SessionStart) in a valid issue context →
#      silent no-op, no trace (G5: only the four events dispatch).
#   7. POSITIVE-CONTROL BOUNDARY (pinned scope decision, documented per the
#      conductor's guard-chain resolution): a valid PostToolUse payload with
#      cwd inside an issue-worktree-shaped fixture must exit 0 with empty
#      stdout AND create the issue trace file with EXACTLY ONE line. This
#      deliberately forces feature 2 (claude-hook-tool-spans) to ship at
#      least a minimal PostToolUse emission and keeps this sensor's negative
#      cases meaningful (proves the in-context invocation does NOT hit the
#      no-op path). Span field/redaction/schema assertions belong to
#      test_claude_hook_tool_span.sh, not here.
#
# Mutation notes (for GREEN verification): removing any single guard must
# fail a case — G1 → case 4 stderr marker; G2 → case 3 (an impl that pipes
# raw stdin to jq unguarded emits parse errors or dies); G4 → cases 1/2
# (a context-blind impl writes a trace into the plain fixture); G5 → case 6;
# unconditional emission → cases 1-6 trace-absence checks.
#
# Exit codes: 0 no-op guard contract honored · 1 a guard obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/optional/runtime-adapters/claude-code-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# jq builds the fixture payloads and validates the positive-control line.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to build fixture hook payloads"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — hook fixtures need the real emitter beside the hook copy"

# RED gate: the hook under test must exist before anything can be exercised.
[ -f "$HOOK" ] \
  || fail "optional/runtime-adapters/claude-code-trace-hook.sh not found (${HOOK}) — the silent no-op guard for feature claude-hook-noop-guard (issue #96) is not implemented yet"

BASH_BIN="$(command -v bash)"

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Payload builder (shape per the Claude Code hook stdin contract) -----------
# One JSON object on stdin: hook_event_name, session_id, cwd, tool_name,
# tool_input, tool_response, tool_use_id, transcript_path.
make_payload() {
  local event="$1" cwd="$2"
  jq -cn --arg event "$event" --arg cwd "$cwd" '{
    hook_event_name: $event,
    session_id: "sess-fixture-0001",
    cwd: $cwd,
    tool_name: "Bash",
    tool_input: {command: "echo fixture"},
    tool_response: {stdout: "fixture", is_error: false},
    tool_use_id: "toolu_fixture_0001",
    transcript_path: "/nonexistent/fixture-transcript.jsonl"
  }'
}

# --- Hook runner ----------------------------------------------------------------
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

# A silent no-op: exit 0, empty stdout, no crash text on stderr, and not a
# single trace.jsonl anywhere under the given fixture root.
assert_silent_noop() {
  local label="$1" fixture_root="$2"
  local found=""
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 (a non-zero exit disturbs the live Claude Code session), got exit ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] \
    || fail "${label}: hook stdout must be EMPTY (Claude Code interprets stdout), got: $(cat "$HOOK_OUT")"
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
cp "$HOOK" "${PLAIN_REPO}/optional/runtime-adapters/claude-code-trace-hook.sh"
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
cp "$HOOK" "${NONREPO}/optional/runtime-adapters/claude-code-trace-hook.sh"
cp "$LIB" "${NONREPO}/scripts/trace-lib.sh"

# --- Fixture C: issue-worktree-shaped repo (valid harness context) ---------------
ISSUE_REPO="${TMP_DIR}/issuerepo"
mkdir -p "${ISSUE_REPO}/scripts"
cp "$HOOK" "${ISSUE_REPO}/optional/runtime-adapters/claude-code-trace-hook.sh"
cp "$LIB" "${ISSUE_REPO}/scripts/trace-lib.sh"
(
  cd "$ISSUE_REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
  git checkout -q -b feature/issue-07-hook-fixture
) || fail "could not build the issue-context fixture"
ISSUE_HOOK="${ISSUE_REPO}/optional/runtime-adapters/claude-code-trace-hook.sh"
ISSUE_TRACE="${ISSUE_REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"

# --- Fixture D: stub PATH with everything EXCEPT jq (guard G1) --------------------
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
  fail "stub PATH fixture leaked a resolvable jq — the G1 case would be vacuous"
fi

# --- Payload files ----------------------------------------------------------------
PAYLOAD_PLAIN="${TMP_DIR}/payload-plain.json"
make_payload "PostToolUse" "$PLAIN_REPO" > "$PAYLOAD_PLAIN"
PAYLOAD_NONREPO="${TMP_DIR}/payload-nonrepo.json"
make_payload "PostToolUse" "$NONREPO" > "$PAYLOAD_NONREPO"
PAYLOAD_ISSUE="${TMP_DIR}/payload-issue.json"
make_payload "PostToolUse" "$ISSUE_REPO" > "$PAYLOAD_ISSUE"
PAYLOAD_UNKNOWN="${TMP_DIR}/payload-unknown-event.json"
make_payload "SessionStart" "$ISSUE_REPO" > "$PAYLOAD_UNKNOWN"

NOT_JSON="${TMP_DIR}/stdin-not-json.txt"
printf 'this is not json { definitely [ not\n' > "$NOT_JSON"
EMPTY_STDIN="${TMP_DIR}/stdin-empty.txt"
: > "$EMPTY_STDIN"
HUGE_GARBAGE="${TMP_DIR}/stdin-huge-garbage.txt"
head -c 2000000 /dev/zero | tr '\0' 'x' > "$HUGE_GARBAGE"
printf '\n' >> "$HUGE_GARBAGE"

# =============================================================================
# Case 1 — valid PostToolUse payload, cwd OUTSIDE any harness issue context
# =============================================================================
run_hook "case1-out-of-context" "$PLAIN_REPO" \
  "${PLAIN_REPO}/optional/runtime-adapters/claude-code-trace-hook.sh" "$PAYLOAD_PLAIN"
assert_silent_noop "case1-out-of-context" "$PLAIN_REPO"
[ ! -e "${PLAIN_REPO}/.copilot-tracking" ] \
  || fail "case1-out-of-context: no .copilot-tracking dir may be created outside a harness run"

# =============================================================================
# Case 2 — cwd is not a git repo at all
# =============================================================================
run_hook "case2-not-a-repo" "$NONREPO" \
  "${NONREPO}/optional/runtime-adapters/claude-code-trace-hook.sh" "$PAYLOAD_NONREPO"
assert_silent_noop "case2-not-a-repo" "$NONREPO"
[ ! -e "${NONREPO}/.copilot-tracking" ] \
  || fail "case2-not-a-repo: no .copilot-tracking dir may be created in a non-repo cwd"

# =============================================================================
# Case 3 — malformed stdin, run INSIDE a valid issue context (G2 proves the
# no-op, not the context guard): non-JSON, empty, ~2MB garbage line
# =============================================================================
run_hook "case3a-not-json" "$ISSUE_REPO" "$ISSUE_HOOK" "$NOT_JSON"
assert_silent_noop "case3a-not-json" "$ISSUE_REPO"

run_hook "case3b-empty-stdin" "$ISSUE_REPO" "$ISSUE_HOOK" "$EMPTY_STDIN"
assert_silent_noop "case3b-empty-stdin" "$ISSUE_REPO"

run_hook "case3c-huge-garbage" "$ISSUE_REPO" "$ISSUE_HOOK" "$HUGE_GARBAGE"
assert_silent_noop "case3c-huge-garbage" "$ISSUE_REPO"

# =============================================================================
# Case 4 — jq absent from PATH, valid payload + valid context (guard G1):
# must not even attempt a jq call, so no "command not found" may appear
# =============================================================================
run_hook "case4-no-jq" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_ISSUE" "$STUBBIN"
assert_silent_noop "case4-no-jq" "$ISSUE_REPO"
if grep -q 'jq' "$HOOK_ERR"; then
  fail "case4-no-jq: stderr mentions jq — the jq guard must run BEFORE any jq use (got: $(cat "$HOOK_ERR"))"
fi

# =============================================================================
# Case 5 — trace-lib.sh missing beside the hook (guard G3), valid context
# =============================================================================
LIBLESS="${TMP_DIR}/libless"
mkdir -p "${LIBLESS}/scripts"
cp "$HOOK" "${LIBLESS}/optional/runtime-adapters/claude-code-trace-hook.sh"
run_hook "case5-no-trace-lib" "$ISSUE_REPO" \
  "${LIBLESS}/optional/runtime-adapters/claude-code-trace-hook.sh" "$PAYLOAD_ISSUE"
assert_silent_noop "case5-no-trace-lib" "$ISSUE_REPO"
assert_silent_noop "case5-no-trace-lib(libless-root)" "$LIBLESS"

# =============================================================================
# Case 6 — unknown hook_event_name in a valid context (guard G5): only
# PreToolUse / PostToolUse / Stop / SubagentStop dispatch
# =============================================================================
run_hook "case6-unknown-event" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_UNKNOWN"
assert_silent_noop "case6-unknown-event" "$ISSUE_REPO"

# =============================================================================
# Case 7 — positive-control boundary (pinned decision, see header): valid
# PostToolUse in a valid issue context exits 0, stays stdout-silent, and
# creates the issue trace with EXACTLY ONE line
# =============================================================================
run_hook "case7-positive-control" "$ISSUE_REPO" "$ISSUE_HOOK" "$PAYLOAD_ISSUE"
[ "$HOOK_RC" -eq 0 ] \
  || fail "case7-positive-control: in-context hook run must still exit 0, got ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
[ ! -s "$HOOK_OUT" ] \
  || fail "case7-positive-control: stdout must stay empty even in-context, got: $(cat "$HOOK_OUT")"
[ -f "$ISSUE_TRACE" ] \
  || fail "case7-positive-control: a valid in-context PostToolUse must NOT hit the no-op path — expected ${ISSUE_TRACE} to be created (feature 2 owns the span's field contract; this sensor pins minimal emission)"
line_total="$(wc -l < "$ISSUE_TRACE" | tr -d '[:space:]')"
[ "$line_total" = "1" ] \
  || fail "case7-positive-control: expected exactly one trace line from one PostToolUse, got ${line_total}"
jq -e . "$ISSUE_TRACE" >/dev/null 2>&1 \
  || fail "case7-positive-control: the emitted trace line is not valid JSON: $(cat "$ISSUE_TRACE")"

printf 'claude-code hook silent no-op guard contract honored\n'
