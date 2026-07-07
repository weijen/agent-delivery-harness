#!/usr/bin/env bash
# test_copilot_hook_interval_attribution.sh — regression sensor for
# scripts/copilot-trace-hook.sh git-first / interval-fallback issue
# attribution (issue #146, feature copilot-hook-interval-attribution).
#
# The Copilot adapter hook already resolves the issue for a span with the
# trace-lib precedence (TRACE_ISSUE → feature/issue-NN-* branch → issue-NN
# worktree basename — trace__resolve_issue). That GIT-FIRST rule is correct
# for the CLI-from-worktree topology and MUST stay exactly as today.
#
# But the primary VS Code agent-mode topology has the conductor running from
# the MAIN checkout on branch `main`: every PostToolUse payload carries
# `.cwd` = that main checkout, so git resolves NOTHING and the hook today
# silently no-ops — the whole run's tool spans are dropped. This feature adds
# an INTERVAL FALLBACK: when git resolves nothing, attribute the payload by
# its `.timestamp` against per-issue ACTIVE WINDOWS derived from the harness
# lifecycle spans already on disk under the main-root
# .copilot-tracking/issues/issue-*/trace.jsonl, then emit into that issue's
# own trace.jsonl.
#
# Window model (ground truth, encoded in the fixtures below):
#   * A lifecycle OPEN span is span=="lifecycle",
#     harness.lifecycle_step=="worktree_create"; a CLOSE span is
#     harness.lifecycle_step=="finish". Both carry an ISO-8601 UTC `...Z`
#     timestamp (directly string-comparable) and harness.issue.
#   * An issue's window is [worktree_create.timestamp, finish.timestamp].
#     With NO finish span the window is open-ended
#     [worktree_create.timestamp, +∞) — the issue is still active.
#   * trace_span writes to ${main_root}/.copilot-tracking/issues/issue-<PAD>/
#     trace.jsonl where <PAD> is the issue number formatted %02d (issue dirs
#     are issue-149, issue-201, … — a min-width-2, effectively-unpadded name).
#     trace__main_root resolves that main checkout from cwd=main via
#     `git rev-parse --git-common-dir`, so a fallback span still lands in the
#     one canonical per-issue file. Setting TRACE_ISSUE=NN forces
#     trace__resolve_issue to return NN — the natural emit primitive for the
#     matched-window case.
#
# Attribution decision (spec):
#   * Exactly ONE window contains the payload timestamp → emit into that
#     issue (git-first is skipped only because it resolved nothing).
#   * ZERO windows contain it, OR >1 windows contain it (ambiguous), OR the
#     payload has no/unparseable timestamp → NO-OP + a visible WARN on
#     stderr. Never now(), never mis-attribute, never fabricate.
#   * The hook stays exit-0 / stdout-clean on EVERY path (Copilot parses hook
#     stdout as JSON and fail-closes a tool call on a non-zero exit).
#
# The hook only surfaces stderr under COPILOT_TRACE_HOOK_DEBUG=1 (its own
# documented troubleshooting switch), so every run below sets it — that keeps
# the honest-omission WARN observable to the sensor WITHOUT relaxing the
# stdout-empty / exit-0 session-safety pins.
#
# Cases (each asserts hook exit 0 + empty stdout via assert_session_safe):
#   C1. Single-window hit: main checkout on `main`; issue-201 window
#       [T1,T2] and issue-202 window [T3,T4] disjoint. A snake PostToolUse
#       (cwd=main, session_id=S1, tool_name=bash) timestamped INSIDE 201's
#       window → exactly one NEW `tool` span appended to issue-201/trace.jsonl
#       carrying gen_ai.tool.name=bash + harness.session_id=S1; issue-202
#       UNCHANGED.
#   C2. Open-ended window: issue-203 has only a worktree_create (no finish);
#       a payload timestamped AFTER that open time lands in issue-203.
#   C3. No matching window → no-op + WARN: payload timestamped BEFORE all
#       windows → NO tool span appended to ANY issue trace (line counts
#       unchanged), exit 0, stdout empty, WARN on stderr.
#   C4. Ambiguous (overlapping) → no-op + WARN: two issues both open-ended
#       whose windows both contain the payload timestamp → NO span appended
#       to either, exit 0, stdout empty, WARN on stderr.
#   C5. Missing timestamp → no-op + WARN: valid single-window setup but the
#       payload has NO `timestamp` key → no span appended, exit 0, stdout
#       empty, WARN on stderr.
#   C6. Git-first still wins: cwd = a feature/issue-301-* branch checkout
#       (git resolves 301) even though an interval window for a DIFFERENT
#       issue would match the timestamp → the span lands in issue-301 via git
#       and the intervals are ignored (zero regression to CLI-from-worktree).
#
# RED proof: today the hook has no interval fallback — when git resolves
# nothing it drops through G4 and no-ops silently, so C1/C2 append ZERO spans
# and C3/C4/C5 emit no WARN. Each assertion below first confirms the fixture
# is sound (windows on disk, hook exits 0) so a failure points squarely at
# the missing interval behavior, not a broken fixture. C6 may already pass
# today (git path is unchanged) — it is the non-regression guard.
#
# Session ids, tool names, and timestamps here are SYNTHETIC test-only shapes.
#
# Exit codes: 0 interval-attribution contract honored · 1 an obligation
# regressed (or the feature is not implemented yet — the RED gate).

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
# C1 — single-window hit: disjoint windows for issue-201 and issue-202; a
# payload inside 201's window lands EXACTLY in issue-201, never issue-202.
# =============================================================================
MAIN1="${TMP_DIR}/main-c1"
make_main_repo "$MAIN1"
seed_lifecycle "$MAIN1" 201 worktree_create 2026-07-07T10:00:00Z
seed_lifecycle "$MAIN1" 201 finish          2026-07-07T10:30:00Z
seed_lifecycle "$MAIN1" 202 worktree_create 2026-07-07T11:00:00Z
seed_lifecycle "$MAIN1" 202 finish          2026-07-07T11:30:00Z
C1_T201="$(trace_path "$MAIN1" 201)"
C1_T202="$(trace_path "$MAIN1" 202)"
c1_before201="$(line_count "$C1_T201")"
c1_before202="$(line_count "$C1_T202")"
if ! { [ "$c1_before201" = "2" ] && [ "$c1_before202" = "2" ]; }; then
  fail "C1: fixture seed wrong (want 2 lifecycle lines per issue, got 201=${c1_before201} 202=${c1_before202})"
fi
run_hook "c1" "$MAIN1" <(
  snake_post_ts "$MAIN1" "S1" "bash" '{"command":"echo hi"}' 2026-07-07T10:15:00Z
)
assert_session_safe "c1"
c1_after201="$(line_count "$C1_T201")"
c1_after202="$(line_count "$C1_T202")"
[ "$c1_after201" = "$((c1_before201 + 1))" ] \
  || fail "C1: a payload timestamped 10:15 (inside issue-201's [10:00,10:30] window) must append EXACTLY one tool span to issue-201/trace.jsonl — got before=${c1_before201} after=${c1_after201}; the hook does not yet do interval fallback when git resolves nothing (cwd=main on branch main)"
[ "$c1_after202" = "$c1_before202" ] \
  || fail "C1: issue-202 (disjoint [11:00,11:30] window) must NOT receive the span — got before=${c1_before202} after=${c1_after202} (mis-attribution)"
c1_new="$(nth_line "$C1_T201" "$c1_after201")"
validate_span "$c1_new" \
  || fail "C1: the appended span is rejected by the #92 contract filter (fixture broken, not an attribution regression): ${c1_new}"
printf '%s\n' "$c1_new" | jq -e '
    .span == "tool" and .["gen_ai.tool.name"] == "bash"
    and .["harness.session_id"] == "S1" and .["harness.issue"] == 201' >/dev/null \
  || fail "C1: the interval-attributed span must be a tool span for issue-201 carrying gen_ai.tool.name=bash and harness.session_id=S1: ${c1_new}"

# =============================================================================
# C2 — open-ended window: issue-203 has only a worktree_create (still active);
# a payload timestamped after that open time lands in issue-203.
# =============================================================================
MAIN2="${TMP_DIR}/main-c2"
make_main_repo "$MAIN2"
seed_lifecycle "$MAIN2" 203 worktree_create 2026-07-07T12:00:00Z
C2_T203="$(trace_path "$MAIN2" 203)"
c2_before203="$(line_count "$C2_T203")"
[ "$c2_before203" = "1" ] \
  || fail "C2: fixture seed wrong (want 1 lifecycle line for issue-203, got ${c2_before203})"
run_hook "c2" "$MAIN2" <(
  snake_post_ts "$MAIN2" "S2" "python" '{"command":"pytest"}' 2026-07-07T12:30:00Z
)
assert_session_safe "c2"
c2_after203="$(line_count "$C2_T203")"
[ "$c2_after203" = "$((c2_before203 + 1))" ] \
  || fail "C2: a payload after an OPEN-ENDED worktree_create (no finish) must land in the still-active issue-203 — got before=${c2_before203} after=${c2_after203}; the open-ended [12:00,+∞) window is not honored"
c2_new="$(nth_line "$C2_T203" "$c2_after203")"
validate_span "$c2_new" \
  || fail "C2: the appended span is rejected by the #92 contract filter: ${c2_new}"
printf '%s\n' "$c2_new" | jq -e '
    .span == "tool" and .["gen_ai.tool.name"] == "python"
    and .["harness.issue"] == 203' >/dev/null \
  || fail "C2: the span must be a tool span attributed to issue-203: ${c2_new}"

# =============================================================================
# C3 — no matching window → no-op + WARN: payload BEFORE all windows.
# =============================================================================
MAIN3="${TMP_DIR}/main-c3"
make_main_repo "$MAIN3"
seed_lifecycle "$MAIN3" 204 worktree_create 2026-07-07T10:00:00Z
seed_lifecycle "$MAIN3" 204 finish          2026-07-07T10:30:00Z
seed_lifecycle "$MAIN3" 205 worktree_create 2026-07-07T11:00:00Z
seed_lifecycle "$MAIN3" 205 finish          2026-07-07T11:30:00Z
C3_T204="$(trace_path "$MAIN3" 204)"
C3_T205="$(trace_path "$MAIN3" 205)"
c3_before204="$(line_count "$C3_T204")"
c3_before205="$(line_count "$C3_T205")"
run_hook "c3" "$MAIN3" <(
  snake_post_ts "$MAIN3" "S3" "bash" '{"command":"echo early"}' 2026-07-07T08:00:00Z
)
assert_session_safe "c3"
[ "$(line_count "$C3_T204")" = "$c3_before204" ] \
  || fail "C3: a payload BEFORE every window must NOT append a span to issue-204 (never guess) — line count changed from ${c3_before204}"
[ "$(line_count "$C3_T205")" = "$c3_before205" ] \
  || fail "C3: a payload BEFORE every window must NOT append a span to issue-205 — line count changed from ${c3_before205}"
assert_warn_on_stderr "c3"

# =============================================================================
# C4 — ambiguous (overlapping) → no-op + WARN: two open-ended windows both
# contain the timestamp, so the issue is undecidable.
# =============================================================================
MAIN4="${TMP_DIR}/main-c4"
make_main_repo "$MAIN4"
seed_lifecycle "$MAIN4" 206 worktree_create 2026-07-07T09:00:00Z
seed_lifecycle "$MAIN4" 207 worktree_create 2026-07-07T09:05:00Z
C4_T206="$(trace_path "$MAIN4" 206)"
C4_T207="$(trace_path "$MAIN4" 207)"
c4_before206="$(line_count "$C4_T206")"
c4_before207="$(line_count "$C4_T207")"
run_hook "c4" "$MAIN4" <(
  snake_post_ts "$MAIN4" "S4" "bash" '{"command":"echo ambiguous"}' 2026-07-07T10:00:00Z
)
assert_session_safe "c4"
[ "$(line_count "$C4_T206")" = "$c4_before206" ] \
  || fail "C4: two overlapping open-ended windows must be treated as AMBIGUOUS — issue-206 must NOT receive the span (never mis-attribute), line count changed from ${c4_before206}"
[ "$(line_count "$C4_T207")" = "$c4_before207" ] \
  || fail "C4: two overlapping open-ended windows must be treated as AMBIGUOUS — issue-207 must NOT receive the span, line count changed from ${c4_before207}"
assert_warn_on_stderr "c4"

# =============================================================================
# C5 — missing timestamp → no-op + WARN: a valid single window, but the
# payload carries no `timestamp` key, so there is nothing honest to match.
# =============================================================================
MAIN5="${TMP_DIR}/main-c5"
make_main_repo "$MAIN5"
seed_lifecycle "$MAIN5" 208 worktree_create 2026-07-07T10:00:00Z
seed_lifecycle "$MAIN5" 208 finish          2026-07-07T10:30:00Z
C5_T208="$(trace_path "$MAIN5" 208)"
c5_before208="$(line_count "$C5_T208")"
run_hook "c5" "$MAIN5" <(
  snake_post_ts "$MAIN5" "S5" "bash" '{"command":"echo no-ts"}' "-"
)
assert_session_safe "c5"
[ "$(line_count "$C5_T208")" = "$c5_before208" ] \
  || fail "C5: a payload with NO timestamp must NOT be attributed to any window (never now(), never guess) — issue-208 line count changed from ${c5_before208}"
assert_warn_on_stderr "c5"

# =============================================================================
# C6 — git-first still wins: cwd is a feature/issue-301-* checkout (git
# resolves 301). An interval window for a DIFFERENT issue (401) would match
# the timestamp, but the git path must be authoritative and the intervals
# ignored — proving zero regression to the CLI-from-worktree topology.
# =============================================================================
ISSUE301="${TMP_DIR}/issue-301-repo"
make_issue_branch_repo "$ISSUE301" "feature/issue-301-interval-noreg"
# A competing window that WOULD swallow the timestamp under interval rules.
seed_lifecycle "$ISSUE301" 401 worktree_create 2026-07-07T10:00:00Z
seed_lifecycle "$ISSUE301" 401 finish          2026-07-07T10:30:00Z
C6_T301="$(trace_path "$ISSUE301" 301)"
C6_T401="$(trace_path "$ISSUE301" 401)"
c6_before401="$(line_count "$C6_T401")"
run_hook "c6" "$ISSUE301" <(
  snake_post_ts "$ISSUE301" "S6" "bash" '{"command":"echo git-first"}' 2026-07-07T10:15:00Z
)
assert_session_safe "c6"
[ "$(line_count "$C6_T301")" = "1" ] \
  || fail "C6: git resolved issue-301 from the feature/issue-301-* branch — the tool span must land in issue-301/trace.jsonl via the unchanged git-first path, got $(line_count "$C6_T301") line(s)"
[ "$(line_count "$C6_T401")" = "$c6_before401" ] \
  || fail "C6: the competing interval window for issue-401 must be IGNORED when git resolves an issue — issue-401 line count changed from ${c6_before401} (interval fallback wrongly overrode git-first)"
c6_new="$(nth_line "$C6_T301" 1)"
validate_span "$c6_new" \
  || fail "C6: the git-attributed span is rejected by the #92 contract filter: ${c6_new}"
printf '%s\n' "$c6_new" | jq -e '
    .span == "tool" and .["gen_ai.tool.name"] == "bash"
    and .["harness.issue"] == 301' >/dev/null \
  || fail "C6: the span must be a tool span attributed to issue-301 (git-first): ${c6_new}"

printf 'PASS: copilot-trace-hook.sh attributes runtime spans git-first, falls back to per-issue interval windows, and no-ops+WARNs on no-match / ambiguity / missing timestamp\n'
