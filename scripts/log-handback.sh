#!/usr/bin/env bash
# log-handback.sh — single-source recorder for conductor decisions and
# subagent handbacks (issue #95, feature log-handback-helper, plan Phase 1).
#
# Usage:
#   scripts/log-handback.sh <role> <lifecycle_step> <feature_id> <outcome> <summary...>
#
# Turns ONE decision/handback event into:
#   1. one `agent` span appended (via trace-lib.sh) to the MAIN checkout
#      root's .copilot-tracking/issues/issue-NN/trace.jsonl, and
#   2. one derived Action Log bullet appended under '## Action Log' in the
#      CURRENT worktree's .copilot-tracking/issues/issue-NN/progress.md:
#        - [<role>] <lifecycle_step> <feature_id> <outcome> — <summary>
# Both views are rendered from the same argv (single-source, plan D3); the
# span is written first, then the log line.
#
# Closed enums (plan D1/D2):
#   role:    conductor | planning-subagent | implementation-subagent |
#            test-subagent | code-review-subagent
#   step:    plan_handback | feature_start | red_handback | impl_handback |
#            green_handback | review_verdict | deviation
#   outcome: pass | fail | blocked
# <summary...> is variadic: remaining args are joined with single spaces.
#
# Token passthrough (plan D5 — omit, never fake): TRACE_INPUT_TOKENS /
# TRACE_OUTPUT_TOKENS env vars are forwarded independently as
# gen_ai.usage.input_tokens / gen_ai.usage.output_tokens (trace-lib types
# them as JSON numbers) ONLY when each is a pure decimal integer; unset or
# non-numeric values simply omit the key (never an error).
#
# Failure semantics (plan D4, conductor-resolved):
#   * Bad role/step/outcome or missing args → non-zero exit, nothing written.
#   * Validate first, THEN span, THEN log line. If the Action Log append
#     fails after the span was written (progress.md missing, or no
#     '## Action Log' section), exit non-zero and warn on stderr naming the
#     ORPHAN span; progress.md is never created or half-written.
#   * trace-lib.sh absent → tracing degrades, the Action Log never does:
#     warn (mentioning trace-lib), still append the line, exit 0.
#
# Redaction (defense in depth): the span is redacted by trace-lib; the
# Action Log line is redacted here too — via trace_redact when trace-lib is
# present, else a minimal local mask of GitHub-token shapes (the narrower
# fallback is a documented tradeoff of the degraded no-trace-lib mode).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: log-handback.sh <role> <lifecycle_step> <feature_id> <outcome> <summary...>
  role:    conductor|planning-subagent|implementation-subagent|test-subagent|code-review-subagent
  step:    plan_handback|feature_start|red_handback|impl_handback|green_handback|review_verdict|deviation
  outcome: pass|fail|blocked
EOF
}

fail() {
  printf 'log-handback: error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'log-handback: warning: %s\n' "$*" >&2
}

# --- 1. Validate everything before writing anything (plan D4) ----------------
if [ "$#" -lt 5 ]; then
  usage
  fail "expected at least 5 arguments (role, lifecycle_step, feature_id, outcome, summary...), got $#"
fi

ROLE="$1"
STEP="$2"
FEATURE_ID="$3"
OUTCOME="$4"
shift 4
SUMMARY="$*"

case "$ROLE" in
  conductor|planning-subagent|implementation-subagent|test-subagent|code-review-subagent) ;;
  *) usage; fail "unknown role '${ROLE}' (closed enum)" ;;
esac

case "$STEP" in
  plan_handback|feature_start|red_handback|impl_handback|green_handback|review_verdict|deviation) ;;
  *) usage; fail "unknown lifecycle step '${STEP}' (closed enum)" ;;
esac

case "$OUTCOME" in
  pass|fail|blocked) ;;
  *) usage; fail "unknown outcome '${OUTCOME}' (expected pass|fail|blocked)" ;;
esac

# feature_id is a single token: letters/digits/dot/underscore/hyphen (the
# literal '-' placeholder is covered by the class). Whitespace, ']', em-dashes
# and similar would corrupt the '- [role] step id outcome — summary' line shape.
[[ "$FEATURE_ID" =~ ^[A-Za-z0-9._-]+$ ]] \
  || fail "invalid feature_id '${FEATURE_ID}' (expected a token of [A-Za-z0-9._-], or '-' when no feature applies)"
[ -n "$SUMMARY" ] || fail "summary must be non-empty"
# The span summary and the Action Log bullet are one-line by contract:
# flatten any embedded newlines to spaces before either artifact is rendered.
SUMMARY="${SUMMARY//$'\r'/ }"
SUMMARY="${SUMMARY//$'\n'/ }"

# --- 2. Emit the agent span first (plan D3 ordering) --------------------------
# Guarded source: a missing trace-lib.sh degrades tracing but must never lose
# the Action Log line (the primary human artifact).
HAVE_TRACE_LIB=0
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
  HAVE_TRACE_LIB=1
else
  warn "scripts/trace-lib.sh not found — agent span skipped, Action Log line still recorded"
fi

# trace_span is warn-and-return-0 by contract (#93 plan D2), so a dropped
# span would otherwise be silent here. Snapshot the trace file around the
# call and warn explicitly when no span landed, so the caller knows the
# Action Log line has no matching span (the consistency sensor catches the
# divergence post-hoc; exit semantics are unchanged).
SPAN_WRITTEN=0
if [ "$HAVE_TRACE_LIB" = "1" ]; then
  # Resolve the same trace file trace_span will target, via the lib's own
  # helpers so the two paths cannot disagree. Unresolvable → the span will
  # be dropped anyway; leave TRACE_FILE empty.
  TRACE_FILE=""
  if MAIN_ROOT="$(trace__main_root 2>/dev/null)" \
    && SPAN_ISSUE="$(trace__resolve_issue 2>/dev/null)"; then
    TRACE_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-$(printf '%02d' "$SPAN_ISSUE")/trace.jsonl"
  fi
  SPANS_BEFORE=0
  if [ -n "$TRACE_FILE" ] && [ -f "$TRACE_FILE" ]; then
    SPANS_BEFORE="$(wc -l < "$TRACE_FILE" | tr -d '[:space:]')"
  fi

  # Token passthrough: forward each env var independently, only when it is a
  # pure decimal integer (omit, never fake — plan D5).
  TOKEN_ARGS=()
  if [[ "${TRACE_INPUT_TOKENS:-}" =~ ^[0-9]+$ ]]; then
    TOKEN_ARGS+=("gen_ai.usage.input_tokens=${TRACE_INPUT_TOKENS}")
  fi
  if [[ "${TRACE_OUTPUT_TOKENS:-}" =~ ^[0-9]+$ ]]; then
    TOKEN_ARGS+=("gen_ai.usage.output_tokens=${TRACE_OUTPUT_TOKENS}")
  fi
  trace_span agent \
    "gen_ai.operation.name=invoke_agent" \
    "gen_ai.agent.name=${ROLE}" \
    "harness.lifecycle_step=${STEP}" \
    "harness.feature_id=${FEATURE_ID}" \
    "harness.outcome=${OUTCOME}" \
    "harness.summary=${SUMMARY}" \
    ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}

  SPANS_AFTER=0
  if [ -n "$TRACE_FILE" ] && [ -f "$TRACE_FILE" ]; then
    SPANS_AFTER="$(wc -l < "$TRACE_FILE" | tr -d '[:space:]')"
  fi
  if [ -n "$TRACE_FILE" ] && [ "$SPANS_AFTER" -gt "$SPANS_BEFORE" ]; then
    SPAN_WRITTEN=1
  else
    warn "agent span was dropped by trace-lib — Action Log line has no matching span"
  fi
fi

# --- 3. Append the derived Action Log line (hard-fails, plan D4) --------------
# Minimal fallback redaction for the degraded no-trace-lib mode: mask GitHub
# token shapes only (the sensor-planted secret class). With trace-lib present
# the full trace_redact filter is reused so span and log line share one policy.
redact_line() {
  if [ "$HAVE_TRACE_LIB" = "1" ]; then
    trace_redact
  else
    sed -E \
      -e 's/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
      -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g'
  fi
}

# The append-failure message names the orphan span only when one was
# verifiably written (the snapshot above), not merely when the lib loaded.
append_fail() {
  if [ "$SPAN_WRITTEN" = "1" ]; then
    fail "$* — the agent span already written to trace.jsonl is now an ORPHAN (no matching Action Log line)"
  else
    fail "$*"
  fi
}

TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || append_fail "not inside a git worktree — cannot locate progress.md for the Action Log"

# Issue resolution mirrors trace-lib's D5 precedence: TRACE_ISSUE env, then
# the feature/issue-NN-* branch, then an issue-NN worktree basename.
ISSUE_RAW=""
if [ -n "${TRACE_ISSUE:-}" ]; then
  ISSUE_RAW="${TRACE_ISSUE}"
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$BRANCH" =~ ^feature/issue-([0-9]+)- ]]; then
    ISSUE_RAW="${BASH_REMATCH[1]}"
  elif [[ "$(basename "$TOPLEVEL")" =~ issue-([0-9]+) ]]; then
    ISSUE_RAW="${BASH_REMATCH[1]}"
  fi
fi
[[ "$ISSUE_RAW" =~ ^[0-9]+$ ]] \
  || append_fail "cannot resolve the issue number (set TRACE_ISSUE, or use a feature/issue-NN-* branch or issue-NN worktree) — cannot locate progress.md for the Action Log"
ISSUE_PAD="$(printf '%02d' "$((10#$ISSUE_RAW))")"

PROGRESS="${TOPLEVEL}/.copilot-tracking/issues/issue-${ISSUE_PAD}/progress.md"
[ -f "$PROGRESS" ] \
  || append_fail "progress.md not found at ${PROGRESS} — Action Log line not recorded"
grep -q '^## Action Log' "$PROGRESS" \
  || append_fail "progress.md at ${PROGRESS} has no '## Action Log' section — Action Log line not recorded"

BULLET="$(printf -- '- [%s] %s %s %s — %s' \
  "$ROLE" "$STEP" "$FEATURE_ID" "$OUTCOME" "$SUMMARY" | redact_line)" \
  || append_fail "redaction of the Action Log line failed — line not recorded"
[ -n "$BULLET" ] \
  || append_fail "redaction produced an empty Action Log line — line not recorded"

printf '%s\n' "$BULLET" >> "$PROGRESS" \
  || append_fail "cannot append to ${PROGRESS} — Action Log line not recorded"

exit 0
