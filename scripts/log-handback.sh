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
#   role:    conductor | planning-subagent | generator-subagent |
#            implementation-subagent | test-subagent | code-review-subagent
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
# Failure-mode passthrough (issue #99, feature failure-mode-span-plumbing —
# mirrors the token passthrough): TRACE_FAILURE_MODE is forwarded as
# harness.failure_mode (JSON string) ONLY when its value is a member of the
# contract's closed failure_modes enum (docs/evaluation/trace-schema.v1.json;
# a mirrored fallback list covers checkouts where the contract file is not
# readable). Unset → key absent. Out-of-enum → key omitted with a stderr
# warning, call still exits 0 (omit, never fake, never hard-fail). The
# passthrough attaches on ANY lifecycle step — the deviation/failure
# convention is prose in docs/evaluation/failure-mode-taxonomy.md, not a
# gate here. The Action Log bullet format is unchanged.
#
# Instruction-files passthrough (issue #300, feature instruction-files-span —
# mirrors the token/failure-mode passthrough): TRACE_INSTRUCTION_FILES is
# forwarded VERBATIM as harness.instruction_files (JSON string) whenever it is
# set and non-empty — a space/comma-separated list of the instruction files the
# conductor injected into a handback prompt. Unlike failure-mode there is NO
# closed enum: any non-empty value is accepted as-is and redacted by trace-lib
# like every other attribute. Unset or empty → key absent (omit, never fake);
# the call still exits 0. Informational only (no consistency gate). The Action
# Log bullet format is unchanged.
#
# Review-verdict provenance (issue #299, feature review-verdict-provenance):
# on the review_verdict step ONLY, two attributes are attached. (1)
# TRACE_REVIEW_MODE is forwarded as harness.review_mode against a CLOSED enum
# {full, concise, repair} — out-of-enum or empty → key omitted with a stderr
# warning, exit 0 (omit, never fake, mirroring the failure-mode shape; the enum
# is inline here, distinct from failure_modes). (2) harness.reviewed_sha is
# AUTO-captured at emit time from `git rev-parse HEAD` (NOT from any env var) and
# omitted when unresolvable. On every OTHER lifecycle step both attributes are
# absent even when TRACE_REVIEW_MODE is set in the ambient env. The Action Log
# bullet format is unchanged.
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
  role:    conductor|planning-subagent|generator-subagent|implementation-subagent|test-subagent|code-review-subagent
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
  # >>> trace-schema:roles (authority docs/evaluation/trace-schema.v1.json .roles; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
  conductor|planning-subagent|generator-subagent|implementation-subagent|test-subagent|code-review-subagent) ;;
  # <<< trace-schema:roles
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

  # Failure-mode passthrough (issue #99): forward TRACE_FAILURE_MODE as
  # harness.failure_mode only when it is a member of the contract's closed
  # failure_modes enum; out-of-enum → omit + warn (never fake, never fail).
  # The enum is read from the contract with jq when available; otherwise the
  # mirrored frozen v1 list below keeps the passthrough working in stripped
  # checkouts (scripts-only fixtures) without weakening the closed set.
  failure_mode_valid() {
    local mode="$1" contract="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
    local enum="" m
    if [ -f "$contract" ] && command -v jq >/dev/null 2>&1; then
      enum="$(jq -r '(.failure_modes // [])[]' "$contract" 2>/dev/null || true)"
    fi
    if [ -z "$enum" ]; then
      enum='missing-context
brittle-tool-interface
weak-sensor
token-thrash
premature-termination
permission-friction
flaky-environment
role-violation'
    fi
    while IFS= read -r m; do
      if [ "$m" = "$mode" ]; then
        return 0
      fi
    done <<< "$enum"
    return 1
  }
  FM_ARGS=()
  if [ -n "${TRACE_FAILURE_MODE:-}" ]; then
    if failure_mode_valid "${TRACE_FAILURE_MODE}"; then
      FM_ARGS+=("harness.failure_mode=${TRACE_FAILURE_MODE}")
    else
      warn "TRACE_FAILURE_MODE '${TRACE_FAILURE_MODE}' is not in the contract's closed failure_modes enum — harness.failure_mode omitted (omit, never fake)"
    fi
  fi

  # Instruction-files passthrough (issue #300): forward TRACE_INSTRUCTION_FILES
  # VERBATIM as harness.instruction_files whenever it is set and non-empty (a
  # space/comma-separated list of instruction-file paths). Unlike the failure
  # mode there is NO closed enum to validate against — any non-empty string is
  # forwarded as-is and redacted by trace-lib like every other attribute. Unset
  # or empty → the key is absent (omit, never fake); the call still exits 0.
  IF_ARGS=()
  if [ -n "${TRACE_INSTRUCTION_FILES:-}" ]; then
    IF_ARGS+=("harness.instruction_files=${TRACE_INSTRUCTION_FILES}")
  fi

  # Review-verdict provenance (issue #299): on the review_verdict step ONLY,
  # forward TRACE_REVIEW_MODE as harness.review_mode (closed enum {full,
  # concise, repair}; out-of-enum or empty → omit + warn, never fake, mirroring
  # the failure-mode shape) and AUTO-capture the reviewed HEAD as
  # harness.reviewed_sha from `git rev-parse HEAD` (NOT any env var). Both attrs
  # are absent on every other step even when TRACE_REVIEW_MODE is set.
  RM_ARGS=()
  if [ "$STEP" = "review_verdict" ]; then
    case "${TRACE_REVIEW_MODE:-}" in
      full|concise|repair)
        RM_ARGS+=("harness.review_mode=${TRACE_REVIEW_MODE}")
        ;;
      "")
        : # unset/empty → omit silently (control path, no warning)
        ;;
      *)
        warn "TRACE_REVIEW_MODE '${TRACE_REVIEW_MODE}' is not in the closed review_mode enum {full,concise,repair} — harness.review_mode omitted (omit, never fake)"
        ;;
    esac
    # Auto-capture the reviewed HEAD; under set -e the 2>/dev/null || true keeps
    # a detached/empty repo from aborting the call, and an empty sha is omitted.
    reviewed_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$reviewed_sha" ]; then
      RM_ARGS+=("harness.reviewed_sha=${reviewed_sha}")
    fi
  fi

  trace_span agent \
    "gen_ai.operation.name=invoke_agent" \
    "gen_ai.agent.name=${ROLE}" \
    "harness.lifecycle_step=${STEP}" \
    "harness.feature_id=${FEATURE_ID}" \
    "harness.outcome=${OUTCOME}" \
    "harness.summary=${SUMMARY}" \
    ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
    ${FM_ARGS[@]+"${FM_ARGS[@]}"} \
    ${IF_ARGS[@]+"${IF_ARGS[@]}"} \
    ${RM_ARGS[@]+"${RM_ARGS[@]}"}

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
# Redaction for the Action Log line. With trace-lib present the full trace_redact
# filter is reused so span and log line share one policy. When trace-lib.sh is
# unavailable, the degraded fallback below runs the IDENTICAL sed program so the
# Action Log never leaks a secret shape that trace_redact would have masked
# (issue #270). Parity between the two is guarded by
# tests/scripts/test_log_handback_redaction_parity.sh — keep this program a byte
# copy of trace_redact's.
redact_line() {
  if [ "$HAVE_TRACE_LIB" = "1" ]; then
    trace_redact
  else
      sed -E \
      -e 's/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
      -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
      -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
      -e 's/[Ii]nstrumentation[Kk]ey=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/InstrumentationKey=[REDACTED]/g' \
      -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
      -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED]/g' \
      -e 's/[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+[A-Za-z0-9._~+=-]+/Bearer [REDACTED]/g' \
      -e 's/(^|[^[:alnum:]_])(([sS][eE][cC][rR][eE][tT]|[tT][oO][kK][eE][nN]|[pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[aA][pP][iI]_?[kK][eE][yY]|[cC][rR][eE][dD][eE][nN][tT][iI][aA][lL])[[:alnum:]_.]*"[[:space:]]*:[[:space:]]*")[^"]*/\1\2[REDACTED]/g' \
      -e 's/(^|[^[:alnum:]_])(([sS][eE][cC][rR][eE][tT]|[tT][oO][kK][eE][nN]|[pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[aA][pP][iI]_?[kK][eE][yY]|[cC][rR][eE][dD][eE][nN][tT][iI][aA][lL])[[:alnum:]_.]*=)[^"\\[:space:]]+/\1\2[REDACTED]/g' \
      -e 's/([A-Z0-9_]*(SECRET|TOKEN|PASSWORD|ACCESS_KEY|API_KEY)S?=)[^"\\[:space:]]+/\1[REDACTED]/g' \
      -e 's/(([A-Za-z0-9]+-)+([Aa][Pp][Ii][-_]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[[:space:]]*:[[:space:]]*)[^"\\[:space:]]+/\1[REDACTED]/g' \
      -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED]/g' \
      -e 's/([?&][Ss][Ii][Gg]=)[^"&[:space:]]+/\1[REDACTED]/g' \
      -e 's/([Aa]ccount[Kk]ey=)[^";[:space:]]+/\1[REDACTED]/g' \
      -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END [A-Z ]*PRIVATE KEY-----/[REDACTED]/g'
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
