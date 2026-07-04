#!/usr/bin/env bash
# test_log_handback.sh — regression sensor for scripts/log-handback.sh
# (issue #95, feature log-handback-helper, plan Phase 1).
#
# Contract under test (plan D1–D6 + conductor-resolved decisions 2026-07-04):
#
#   scripts/log-handback.sh <role> <lifecycle_step> <feature_id> <outcome> <summary...>
#
#   Turns ONE decision/handback event into (1) one agent span in the MAIN
#   checkout root's .copilot-tracking/issues/issue-NN/trace.jsonl and (2) one
#   derived Action Log bullet in the WORKTREE's
#   .copilot-tracking/issues/issue-NN/progress.md — both rendered from the
#   same argv (single-source), span first, then the log line.
#
#   PINNED CLI / ENV CONVENTIONS (spec for the implementer):
#
#   - Roles (closed enum, D1):
#       conductor | planning-subagent | implementation-subagent |
#       test-subagent | code-review-subagent
#   - Lifecycle steps (closed subset of the #92 enum, D2):
#       plan_handback | feature_start | red_handback | impl_handback |
#       green_handback | review_verdict | deviation
#   - Outcomes (closed enum): pass | fail | blocked
#   - <summary...> is variadic: all remaining args are joined with single
#     spaces into one summary line.
#   - Span shape (conductor-resolved): span=agent,
#     gen_ai.operation.name=invoke_agent, gen_ai.agent.name=<role>,
#     harness.lifecycle_step=<step>, harness.feature_id=<feature_id>,
#     harness.outcome=<outcome>, harness.summary=<summary>. Must pass the
#     #92 contract filter (agent spans require gen_ai.operation.name +
#     gen_ai.agent.name plus the common five).
#   - Action Log line format (D3), appended under the '## Action Log'
#     heading of the worktree progress.md:
#       - [<role>] <lifecycle_step> <feature_id> <outcome> — <summary>
#   - Token passthrough (D5, convention PINNED HERE as env — NOT trailing
#     args, to avoid ambiguity with the variadic summary):
#       TRACE_INPUT_TOKENS  → gen_ai.usage.input_tokens  (JSON number)
#       TRACE_OUTPUT_TOKENS → gen_ai.usage.output_tokens (JSON number)
#     Each is forwarded independently and ONLY when it is a pure decimal
#     integer; unset or non-numeric → the key is ABSENT (omit, never fake;
#     a non-numeric value is not an error — the call still succeeds).
#   - Failure-mode passthrough (issue #99, feature failure-mode-span-plumbing,
#     convention PINNED HERE — mirrors the token passthrough):
#       TRACE_FAILURE_MODE → harness.failure_mode (JSON string)
#     Forwarded ONLY when the value is a member of the contract's closed
#     failure_modes enum (docs/evaluation/trace-schema.v1.json). Unset →
#     key ABSENT. Out-of-enum → key OMITTED, stderr warning naming the
#     failure mode env/attribute, call still exits 0 (omit, never fake,
#     never hard-fail — soft input, unlike role/step/outcome).
#     PINNED: the passthrough attaches on ANY lifecycle step when set —
#     the deviation/failure convention is prose in
#     docs/evaluation/failure-mode-taxonomy.md; enforcement stays soft
#     (open-world optional field, no step gate). The Action Log bullet
#     format (D3) is UNCHANGED by the failure mode.
#   - Failure semantics (conductor-resolved: hard-fail on the Action Log):
#       * Validation failures (bad role/step/outcome, missing args) →
#         non-zero exit, NO span written, NO log line written.
#       * Validate everything first, THEN write the span, THEN append the
#         log line. If the append fails after the span was written
#         (progress.md missing, or its '## Action Log' section missing) →
#         non-zero exit, progress.md is not created/modified, and stderr
#         carries a warning naming the ORPHAN span (must mention
#         'progress.md' or 'Action Log', and the word 'orphan').
#       * trace-lib.sh absent → tracing degrades, the Action Log never
#         does: warn on stderr (mentioning trace-lib), STILL append the
#         Action Log line, exit 0. No trace file is created.
#   - Redaction (defense in depth): the span is redacted by trace-lib; the
#     helper must ALSO redact the Action Log line (secret shapes such as
#     ghp_… become [REDACTED] in progress.md, even though progress.md is
#     gitignored).
#   - Loop-2 hardening (pinned by the negative cases below):
#       * feature_id is a single token matching [A-Za-z0-9._-]+ ('-'
#         included); whitespace or ']' would corrupt the bullet shape and
#         tuple parsing → validation failure, nothing written.
#       * The summary is one-line by contract: embedded newlines/CRs are
#         flattened to spaces before EITHER artifact is rendered (one span,
#         one bullet, identical flattened text).
#       * Span-drop visibility: trace-lib is warn-never-fail, so when the
#         span write is dropped (e.g. unappendable trace file) while
#         progress.md IS writable, the helper warns 'span was dropped' on
#         stderr, STILL appends the Action Log line, and exits 0. The
#         ORPHAN wording is snapshot-gated — it may only appear when a
#         span verifiably landed, so the span-drop path never claims one.
#
# Fixture style follows test_trace_review_gate.sh: throwaway MAIN repo +
# linked feature/issue-NN-* worktrees, helper invoked FROM THE WORKTREE
# (conductor context), pinned PATH, contract filter lifted verbatim from
# test_trace_schema.sh.
#
# Exit codes: 0 handback contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${ROOT}/scripts/log-handback.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate log-handback span emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — prerequisite emitter from issue #93 missing"

# RED gate: the helper under test must exist before anything can run.
[ -f "$HELPER" ] \
  || fail "scripts/log-handback.sh not found (${HELPER}) — the single-source handback helper for feature log-handback-helper (issue #95) is not implemented yet"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
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

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }
nth_line() { sed -n "${2}p" "$1"; }

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

# check_agent_span <label> <line> <role> <step> <feature_id> <outcome> <summary> <issue>
check_agent_span() {
  local label="$1" line="$2" role="$3" step="$4" fid="$5" outcome="$6" summary="$7" issue="$8"
  validate_span "$line" \
    || fail "${label}: span rejected by the contract-driven jq validation filter (#92): ${line}"
  printf '%s\n' "$line" | jq -e \
    --arg role "$role" --arg step "$step" --arg fid "$fid" \
    --arg outcome "$outcome" --arg summary "$summary" --argjson issue "$issue" '
      (.span == "agent")
      and (.["gen_ai.operation.name"] == "invoke_agent")
      and (.["gen_ai.agent.name"] == $role)
      and (.["harness.lifecycle_step"] == $step)
      and (.["harness.feature_id"] == $fid)
      and (.["harness.outcome"] == $outcome)
      and (.["harness.summary"] == $summary)
      and ((.["harness.issue"] | type) == "number")
      and (.["harness.issue"] == $issue)
    ' >/dev/null \
    || fail "${label}: agent span must carry gen_ai.operation.name=invoke_agent, gen_ai.agent.name=${role}, harness.lifecycle_step=${step}, harness.feature_id=${fid}, harness.outcome=${outcome}, harness.summary='${summary}', numeric harness.issue=${issue}: ${line}"
}

# expect_bullet <label> <progress-file> <bullet-line>
# The bullet must exist exactly once, verbatim (D3 format), positioned AFTER
# the '## Action Log' heading.
expect_bullet() {
  local label="$1" file="$2" bullet="$3" hits al_ln b_ln
  hits="$(grep -cF -- "$bullet" "$file" || true)"
  [ "$hits" = "1" ] \
    || fail "${label}: expected exactly one verbatim Action Log bullet '${bullet}' in ${file}, found ${hits}"
  al_ln="$(grep -n '^## Action Log' "$file" | head -1 | cut -d: -f1)"
  [ -n "$al_ln" ] || fail "${label}: fixture progress.md lost its '## Action Log' heading"
  b_ln="$(grep -nF -- "$bullet" "$file" | head -1 | cut -d: -f1)"
  [ "$b_ln" -gt "$al_ln" ] \
    || fail "${label}: the Action Log bullet must be appended UNDER the '## Action Log' heading (heading line ${al_ln}, bullet line ${b_ln})"
}

# Pinned PATH for the scripts under test (real tools, no gh needed).
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cp mv cat sed awk tr cut grep printf head tail sort jq date od wc cksum

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  TRACE_FAILURE_MODE 2>/dev/null || true

# --- Fixture: MAIN repo + linked issue worktrees ---------------------------------
MAIN="${TMP_DIR}/main-repo"
mkdir -p "${MAIN}/scripts"
cp "$HELPER" "${MAIN}/scripts/log-handback.sh"
cp "$LIB" "${MAIN}/scripts/trace-lib.sh"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.name "Harness Test"
git -C "$MAIN" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > "${MAIN}/.gitignore"
printf 'fixture\n' > "${MAIN}/README.md"
git -C "$MAIN" add .gitignore README.md scripts
git -C "$MAIN" commit -q -m initial

# scaffold_progress <worktree> <NN>: minimal start-issue.sh-shaped progress.md
# with an '## Action Log' section, in the WORKTREE's tracking dir.
scaffold_progress() {
  local wt="$1" nn="$2"
  mkdir -p "${wt}/.copilot-tracking/issues/issue-${nn}"
  cat > "${wt}/.copilot-tracking/issues/issue-${nn}/progress.md" <<MD
# Issue ${nn} progress

Status: in progress.

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
MD
}

# Worktree A (issue 13): the happy-path conductor context.
WTA="${TMP_DIR}/wt-issue-13"
git -C "$MAIN" worktree add -q -b feature/issue-13-fixture "$WTA"
scaffold_progress "$WTA" 13
TRACE_A="${MAIN}/.copilot-tracking/issues/issue-13/trace.jsonl"
PROG_A="${WTA}/.copilot-tracking/issues/issue-13/progress.md"

run_hb() { # run_hb <worktree> <out-file> <args...>  (stdout+stderr combined)
  local wt="$1" out="$2"; shift 2
  (cd "$wt" && PATH="$BIN" ./scripts/log-handback.sh "$@") > "$out" 2>&1
}

# ============================================================================
# 1. Happy path: one call → one agent span (MAIN root) + one Action Log
#    bullet (worktree progress.md), field-for-field from the same argv.
#    Variadic summary args are space-joined.
# ============================================================================
SUMMARY1="RED sensor authored; fails for the right reason"
prog_before="$(line_count "$PROG_A")"
run_hb "$WTA" "${TMP_DIR}/a1.out" \
  test-subagent red_handback log-handback-helper pass \
  "RED sensor authored;" "fails for the right reason" \
  || { cat "${TMP_DIR}/a1.out"; fail "happy-path handback call must exit 0"; }
[ -f "$TRACE_A" ] \
  || fail "happy path: no span emitted — main-root trace file missing (${TRACE_A})"
[ "$(line_count "$TRACE_A")" = "1" ] \
  || fail "happy path: expected exactly 1 agent span, got $(line_count "$TRACE_A")"
a1="$(nth_line "$TRACE_A" 1)"
check_agent_span "happy path" "$a1" test-subagent red_handback log-handback-helper pass "$SUMMARY1" 13
printf '%s\n' "$a1" | jq -e '
    (has("gen_ai.usage.input_tokens") | not)
    and (has("gen_ai.usage.output_tokens") | not)
  ' >/dev/null \
  || fail "happy path: token env unset → gen_ai.usage.* keys must be ABSENT (omit, never fake): ${a1}"

# Span lands at the MAIN root, never inside the worktree (trace-lib D1).
[ ! -e "${WTA}/.copilot-tracking/issues/issue-13/trace.jsonl" ] \
  || fail "spans from the worktree must land at the MAIN root, not ${WTA}/.copilot-tracking"

# Exactly one line appended to the WORKTREE progress.md, under ## Action Log,
# in the pinned D3 format, carrying the SAME summary as the span.
[ "$(line_count "$PROG_A")" = "$((prog_before + 1))" ] \
  || fail "happy path: exactly one line must be appended to the worktree progress.md (before=${prog_before}, after=$(line_count "$PROG_A"))"
BULLET1="- [test-subagent] red_handback log-handback-helper pass — ${SUMMARY1}"
expect_bullet "happy path" "$PROG_A" "$BULLET1"

# Single-source agreement: the summary string ON THE SPAN appears verbatim in
# the Action Log line (both views rendered from the same argv, D3).
span_summary="$(printf '%s\n' "$a1" | jq -r '.["harness.summary"]')"
grep -qF -- "$span_summary" "$PROG_A" \
  || fail "single-source: the span's harness.summary ('${span_summary}') must appear verbatim in the progress.md Action Log line"

# ============================================================================
# 2. Token passthrough (pinned convention: env vars) → JSON numbers.
# ============================================================================
run_hb2() { # like run_hb but with the token env exported
  local wt="$1" out="$2" itok="$3" otok="$4"; shift 4
  (cd "$wt" && TRACE_INPUT_TOKENS="$itok" TRACE_OUTPUT_TOKENS="$otok" \
     PATH="$BIN" ./scripts/log-handback.sh "$@") > "$out" 2>&1
}
run_hb2 "$WTA" "${TMP_DIR}/a2.out" 1234 56 \
  conductor feature_start log-handback-helper pass "selected next passes:false feature" \
  || { cat "${TMP_DIR}/a2.out"; fail "handback with token env must exit 0"; }
[ "$(line_count "$TRACE_A")" = "2" ] || fail "token call must append exactly one span"
a2="$(nth_line "$TRACE_A" 2)"
check_agent_span "tokens" "$a2" conductor feature_start log-handback-helper pass \
  "selected next passes:false feature" 13
printf '%s\n' "$a2" | jq -e '
    ((.["gen_ai.usage.input_tokens"] | type) == "number")
    and (.["gen_ai.usage.input_tokens"] == 1234)
    and ((.["gen_ai.usage.output_tokens"] | type) == "number")
    and (.["gen_ai.usage.output_tokens"] == 56)
  ' >/dev/null \
  || fail "TRACE_INPUT_TOKENS/TRACE_OUTPUT_TOKENS must land as JSON numbers 1234/56: ${a2}"

# Non-numeric token env → omit, never fake (call still succeeds, keys absent).
run_hb2 "$WTA" "${TMP_DIR}/a3.out" "lots" "" \
  conductor plan_handback - pass "plan approved at the human gate" \
  || { cat "${TMP_DIR}/a3.out"; fail "non-numeric token env must not fail the call (omit, never fake)"; }
[ "$(line_count "$TRACE_A")" = "3" ] || fail "non-numeric-token call must still append exactly one span"
a3="$(nth_line "$TRACE_A" 3)"
printf '%s\n' "$a3" | jq -e '
    (has("gen_ai.usage.input_tokens") | not)
    and (has("gen_ai.usage.output_tokens") | not)
  ' >/dev/null \
  || fail "non-numeric/empty token env must OMIT gen_ai.usage.* (never fake, never stringify): ${a3}"

# ============================================================================
# 3. Deviation: step=deviation with feature_id='-' and outcome=blocked.
# ============================================================================
run_hb "$WTA" "${TMP_DIR}/a4.out" \
  conductor deviation - blocked "stop/report: sensor conflicts with contract" \
  || { cat "${TMP_DIR}/a4.out"; fail "deviation handback (feature_id='-', outcome=blocked) must exit 0"; }
[ "$(line_count "$TRACE_A")" = "4" ] || fail "deviation call must append exactly one span"
a4="$(nth_line "$TRACE_A" 4)"
check_agent_span "deviation" "$a4" conductor deviation - blocked \
  "stop/report: sensor conflicts with contract" 13
expect_bullet "deviation" "$PROG_A" \
  "- [conductor] deviation - blocked — stop/report: sensor conflicts with contract"

# ============================================================================
# 4. Redaction: a planted synthetic ghp_ token is masked in BOTH artifacts.
# ============================================================================
GHP="ghp_FAKE0FIXTURE0SECRET0TOKEN0ABCDEFGH"
run_hb "$WTA" "${TMP_DIR}/a5.out" \
  test-subagent green_handback log-handback-helper pass "rotated ${GHP} credential" \
  || { cat "${TMP_DIR}/a5.out"; fail "handback with a secret-shaped summary must still exit 0"; }
[ "$(line_count "$TRACE_A")" = "5" ] || fail "redaction call must append exactly one span"
a5="$(nth_line "$TRACE_A" 5)"
printf '%s' "$a5" | grep -qF -- "$GHP" \
  && fail "SPAN must not carry the raw ghp_ token (trace-lib redaction bypassed): ${a5}"
printf '%s\n' "$a5" | jq -e '.["harness.summary"] | contains("[REDACTED]")' >/dev/null \
  || fail "span harness.summary must carry [REDACTED] in place of the ghp_ token: ${a5}"
grep -qF -- "$GHP" "$PROG_A" \
  && fail "progress.md Action Log line must not carry the raw ghp_ token (helper must redact the log line too)"
grep -q 'green_handback.*\[REDACTED\]' "$PROG_A" \
  || fail "progress.md green_handback line must carry [REDACTED] in place of the ghp_ token"

# ============================================================================
# 5. Closed-enum validation: bad step / role / outcome and missing args →
#    non-zero exit, NO span, NO log line (nothing written).
# ============================================================================
prog_sum_before="$(cksum "$PROG_A")"

if run_hb "$WTA" "${TMP_DIR}/a6.out" test-subagent banana log-handback-helper pass "oops"; then
  cat "${TMP_DIR}/a6.out"; fail "out-of-vocabulary lifecycle step 'banana' must hard-fail (non-zero exit)"
fi
if run_hb "$WTA" "${TMP_DIR}/a7.out" intern red_handback log-handback-helper pass "oops"; then
  cat "${TMP_DIR}/a7.out"; fail "unknown role 'intern' must hard-fail (closed role enum)"
fi
if run_hb "$WTA" "${TMP_DIR}/a8.out" conductor review_verdict log-handback-helper maybe "oops"; then
  cat "${TMP_DIR}/a8.out"; fail "unknown outcome 'maybe' must hard-fail (pass|fail|blocked only)"
fi
if run_hb "$WTA" "${TMP_DIR}/a9.out" conductor feature_start log-handback-helper; then
  cat "${TMP_DIR}/a9.out"; fail "missing outcome/summary args must hard-fail (usage error)"
fi
# feature_id shape (loop-2 hardening): a single [A-Za-z0-9._-]+ token only —
# whitespace or ']' would corrupt the '- [role] step id outcome — summary'
# bullet shape and the span/log tuple parsing.
if run_hb "$WTA" "${TMP_DIR}/a10.out" conductor feature_start "two words" pass "oops"; then
  cat "${TMP_DIR}/a10.out"; fail "feature_id containing a space must hard-fail (single-token shape)"
fi
if run_hb "$WTA" "${TMP_DIR}/a11.out" conductor feature_start "bad]id" pass "oops"; then
  cat "${TMP_DIR}/a11.out"; fail "feature_id containing ']' must hard-fail (would corrupt the bullet shape)"
fi

[ "$(line_count "$TRACE_A")" = "5" ] \
  || fail "validation failures must write NO span (expected 5 lines, got $(line_count "$TRACE_A"))"
[ "$(cksum "$PROG_A")" = "$prog_sum_before" ] \
  || fail "validation failures must write NO Action Log line (progress.md changed)"

# ============================================================================
# 5b. Newline-containing summary (loop-2 hardening): flattened to spaces —
#     ONE span and ONE single-line bullet, identical flattened text.
# ============================================================================
prog_before_nl="$(line_count "$PROG_A")"
run_hb "$WTA" "${TMP_DIR}/a12.out" \
  implementation-subagent impl_handback log-handback-helper pass \
  $'first line\nsecond line' \
  || { cat "${TMP_DIR}/a12.out"; fail "newline-containing summary must still exit 0 (flattened, not rejected)"; }
[ "$(line_count "$TRACE_A")" = "6" ] \
  || fail "newline-summary call must append exactly one span (got $(line_count "$TRACE_A") lines)"
a12="$(nth_line "$TRACE_A" 6)"
check_agent_span "newline-flatten" "$a12" implementation-subagent impl_handback \
  log-handback-helper pass "first line second line" 13
[ "$(line_count "$PROG_A")" = "$((prog_before_nl + 1))" ] \
  || fail "newline-containing summary must append exactly ONE flattened progress.md line (before=${prog_before_nl}, after=$(line_count "$PROG_A"))"
expect_bullet "newline-flatten" "$PROG_A" \
  "- [implementation-subagent] impl_handback log-handback-helper pass — first line second line"

# ============================================================================
# 6. Append failure — progress.md MISSING: validate-then-span-then-log means
#    the span IS written, then the append hard-fails: non-zero exit, no
#    progress.md created, stderr names the orphan span.
# ============================================================================
WTB="${TMP_DIR}/wt-issue-14"
git -C "$MAIN" worktree add -q -b feature/issue-14-noprogress "$WTB"
TRACE_B="${MAIN}/.copilot-tracking/issues/issue-14/trace.jsonl"

if run_hb "$WTB" "${TMP_DIR}/b1.out" conductor impl_handback some-feature pass "impl done"; then
  cat "${TMP_DIR}/b1.out"; fail "missing progress.md must hard-fail the helper (non-zero exit, conductor-resolved D4)"
fi
[ ! -e "${WTB}/.copilot-tracking/issues/issue-14/progress.md" ] \
  || fail "hard-fail path must NOT scaffold/create progress.md"
if [ ! -f "$TRACE_B" ] || [ "$(line_count "$TRACE_B")" != "1" ]; then
  fail "pinned ordering (validate, then span, then log): the agent span must already be written when the append fails (expected exactly 1 line in ${TRACE_B})"
fi
check_agent_span "orphan-span" "$(nth_line "$TRACE_B" 1)" conductor impl_handback some-feature pass "impl done" 14
grep -Eqi 'progress\.md|action log' "${TMP_DIR}/b1.out" \
  || { cat "${TMP_DIR}/b1.out"; fail "append-failure error must name progress.md / the Action Log section"; }
grep -qi 'orphan' "${TMP_DIR}/b1.out" \
  || { cat "${TMP_DIR}/b1.out"; fail "append failure after the span was written must print a warning naming the ORPHAN span"; }

# ============================================================================
# 7. Append failure — progress.md present but NO '## Action Log' section:
#    same hard-fail contract, file left byte-identical.
# ============================================================================
WTC="${TMP_DIR}/wt-issue-15"
git -C "$MAIN" worktree add -q -b feature/issue-15-nosection "$WTC"
mkdir -p "${WTC}/.copilot-tracking/issues/issue-15"
printf '# Issue 15 progress\n\nStatus: garbled scaffold without the log section.\n' \
  > "${WTC}/.copilot-tracking/issues/issue-15/progress.md"
PROG_C="${WTC}/.copilot-tracking/issues/issue-15/progress.md"
TRACE_C="${MAIN}/.copilot-tracking/issues/issue-15/trace.jsonl"
progc_sum_before="$(cksum "$PROG_C")"

if run_hb "$WTC" "${TMP_DIR}/c1.out" code-review-subagent review_verdict some-feature fail "needs rework"; then
  cat "${TMP_DIR}/c1.out"; fail "progress.md without an '## Action Log' section must hard-fail (non-zero exit)"
fi
[ "$(cksum "$PROG_C")" = "$progc_sum_before" ] \
  || fail "hard-fail path must leave the garbled progress.md byte-identical (no half-written line)"
if [ ! -f "$TRACE_C" ] || [ "$(line_count "$TRACE_C")" != "1" ]; then
  fail "pinned ordering: the span must already be written when the Action Log section is missing (expected exactly 1 line in ${TRACE_C})"
fi
grep -qi 'orphan' "${TMP_DIR}/c1.out" \
  || { cat "${TMP_DIR}/c1.out"; fail "missing '## Action Log' section: stderr must warn about the orphan span"; }

# ============================================================================
# 8. trace-lib.sh ABSENT: tracing degrades, the Action Log never does —
#    warn (mentioning trace-lib), still append the line, exit 0, no trace file.
# ============================================================================
R2="${TMP_DIR}/r2-nolib"
mkdir -p "${R2}/scripts"
cp "$HELPER" "${R2}/scripts/log-handback.sh"
git -C "$R2" init -q -b feature/issue-21-nolib
git -C "$R2" config user.name "Harness Test"
git -C "$R2" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${R2}/README.md"
git -C "$R2" add README.md scripts
git -C "$R2" commit -q -m initial
scaffold_progress "$R2" 21
[ ! -e "${R2}/scripts/trace-lib.sh" ] || fail "fixture bug: R2 must not contain trace-lib.sh"

(cd "$R2" && PATH="$BIN" ./scripts/log-handback.sh \
   planning-subagent plan_handback - pass "plan drafted, two open questions") \
  > "${TMP_DIR}/r2.out" 2>&1 \
  || { cat "${TMP_DIR}/r2.out"; fail "trace-lib absent: the helper must still exit 0 (tracing degrades, the Action Log never does)"; }
grep -qi 'trace-lib' "${TMP_DIR}/r2.out" \
  || { cat "${TMP_DIR}/r2.out"; fail "trace-lib absent: the helper must warn on stderr mentioning trace-lib"; }
expect_bullet "no-trace-lib" "${R2}/.copilot-tracking/issues/issue-21/progress.md" \
  "- [planning-subagent] plan_handback - pass — plan drafted, two open questions"
[ ! -e "${R2}/.copilot-tracking/issues/issue-21/trace.jsonl" ] \
  || fail "trace-lib absent: no trace file may be created"

# ============================================================================
# 9. Span DROPPED by trace-lib while progress.md is writable (loop-2
#    hardening): trace.jsonl is made unappendable (a directory squats on the
#    path), so trace_span warn-drops. The helper must surface it — stderr
#    contains 'span was dropped' — still append the Action Log line, and
#    exit 0. The ORPHAN wording is snapshot-gated: no span landed, so it
#    must NOT appear.
# ============================================================================
WTD="${TMP_DIR}/wt-issue-16"
git -C "$MAIN" worktree add -q -b feature/issue-16-spandrop "$WTD"
scaffold_progress "$WTD" 16
mkdir -p "${MAIN}/.copilot-tracking/issues/issue-16/trace.jsonl"
[ -d "${MAIN}/.copilot-tracking/issues/issue-16/trace.jsonl" ] \
  || fail "fixture bug: issue-16 trace.jsonl must be a directory (unappendable)"

run_hb "$WTD" "${TMP_DIR}/d1.out" \
  test-subagent green_handback log-handback-helper pass "verified with dropped span" \
  || { cat "${TMP_DIR}/d1.out"; fail "span-drop path must exit 0 (tracing degrades, the Action Log never does)"; }
grep -qi 'span was dropped' "${TMP_DIR}/d1.out" \
  || { cat "${TMP_DIR}/d1.out"; fail "span-drop path must warn 'span was dropped' on stderr (silent drop forbidden)"; }
grep -qi 'orphan' "${TMP_DIR}/d1.out" \
  && { cat "${TMP_DIR}/d1.out"; fail "span-drop path must NOT claim an ORPHAN span (snapshot-gated wording: no span landed)"; }
expect_bullet "span-drop" "${WTD}/.copilot-tracking/issues/issue-16/progress.md" \
  "- [test-subagent] green_handback log-handback-helper pass — verified with dropped span"
[ -d "${MAIN}/.copilot-tracking/issues/issue-16/trace.jsonl" ] \
  || fail "span-drop fixture: the unappendable trace.jsonl directory must be untouched"

# ============================================================================
# 10. TRACE_FAILURE_MODE passthrough (issue #99, feature
#     failure-mode-span-plumbing). See the pinned convention in the header:
#     enum-valid value → harness.failure_mode lands as a JSON string on the
#     span; unset → key absent; out-of-enum → key omitted + stderr warning,
#     exit 0; attaches on ANY step (soft convention, no step gate); the
#     Action Log bullet format is unchanged.
# ============================================================================
run_hb_fm() { # like run_hb but with TRACE_FAILURE_MODE exported
  local wt="$1" out="$2" mode="$3"; shift 3
  (cd "$wt" && TRACE_FAILURE_MODE="$mode" PATH="$BIN" ./scripts/log-handback.sh "$@") > "$out" 2>&1
}

# 10a. Valid mode on a deviation handback → span carries harness.failure_mode.
run_hb_fm "$WTA" "${TMP_DIR}/f1.out" token-thrash \
  conductor deviation - blocked "same files re-read in a loop, no convergence" \
  || { cat "${TMP_DIR}/f1.out"; fail "deviation handback with TRACE_FAILURE_MODE=token-thrash must exit 0"; }
[ "$(line_count "$TRACE_A")" = "7" ] \
  || fail "failure-mode deviation call must append exactly one span (got $(line_count "$TRACE_A") lines)"
f1="$(nth_line "$TRACE_A" 7)"
check_agent_span "failure-mode deviation" "$f1" conductor deviation - blocked \
  "same files re-read in a loop, no convergence" 13
printf '%s\n' "$f1" | jq -e '.["harness.failure_mode"] == "token-thrash"' >/dev/null \
  || fail "TRACE_FAILURE_MODE=token-thrash on a deviation must land as harness.failure_mode=\"token-thrash\" (JSON string): ${f1}"
expect_bullet "failure-mode deviation" "$PROG_A" \
  "- [conductor] deviation - blocked — same files re-read in a loop, no convergence"

# 10b. Out-of-enum mode → key OMITTED, stderr warning naming the failure
#      mode, call still exits 0 (omit, never fake, never hard-fail).
run_hb_fm "$WTA" "${TMP_DIR}/f2.out" banana \
  conductor deviation - blocked "deviation with a bogus failure mode" \
  || { cat "${TMP_DIR}/f2.out"; fail "out-of-enum TRACE_FAILURE_MODE=banana must NOT fail the call (omit, never fake)"; }
[ "$(line_count "$TRACE_A")" = "8" ] \
  || fail "bogus-failure-mode call must still append exactly one span (got $(line_count "$TRACE_A") lines)"
f2="$(nth_line "$TRACE_A" 8)"
check_agent_span "bogus failure mode" "$f2" conductor deviation - blocked \
  "deviation with a bogus failure mode" 13
printf '%s\n' "$f2" | jq -e 'has("harness.failure_mode") | not' >/dev/null \
  || fail "out-of-enum TRACE_FAILURE_MODE=banana must OMIT harness.failure_mode (never fake, never forward): ${f2}"
grep -qiE 'failure[_ -]mode' "${TMP_DIR}/f2.out" \
  || { cat "${TMP_DIR}/f2.out"; fail "out-of-enum TRACE_FAILURE_MODE must warn on stderr naming the failure mode (silent omit forbidden)"; }

# 10c. Env unset → key absent (control for 10a).
run_hb "$WTA" "${TMP_DIR}/f3.out" \
  conductor deviation - blocked "deviation without a failure mode" \
  || { cat "${TMP_DIR}/f3.out"; fail "deviation handback without TRACE_FAILURE_MODE must exit 0"; }
[ "$(line_count "$TRACE_A")" = "9" ] \
  || fail "no-failure-mode deviation call must append exactly one span (got $(line_count "$TRACE_A") lines)"
f3="$(nth_line "$TRACE_A" 9)"
printf '%s\n' "$f3" | jq -e 'has("harness.failure_mode") | not' >/dev/null \
  || fail "TRACE_FAILURE_MODE unset → harness.failure_mode must be ABSENT: ${f3}"

# 10d. Valid mode on a NON-deviation step attaches too (pinned soft rule:
#      the deviation convention is prose, not a passthrough gate).
run_hb_fm "$WTA" "${TMP_DIR}/f4.out" weak-sensor \
  test-subagent green_handback log-handback-helper pass "green despite a sensor that did not bite" \
  || { cat "${TMP_DIR}/f4.out"; fail "TRACE_FAILURE_MODE on a non-deviation step must not fail the call (soft convention, no step gate)"; }
[ "$(line_count "$TRACE_A")" = "10" ] \
  || fail "non-deviation failure-mode call must append exactly one span (got $(line_count "$TRACE_A") lines)"
f4="$(nth_line "$TRACE_A" 10)"
printf '%s\n' "$f4" | jq -e '.["harness.failure_mode"] == "weak-sensor"' >/dev/null \
  || fail "TRACE_FAILURE_MODE=weak-sensor must attach on ANY step when set (pinned soft rule): ${f4}"

printf 'log-handback single-source handback contract honored\n'
