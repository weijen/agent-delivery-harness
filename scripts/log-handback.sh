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
# Sensor-scope passthrough (issue #343 — omit, never fake): TRACE_SENSOR_SCOPE
# is forwarded as harness.sensor_scope only when it is `scoped` or `full`
# (out-of-enum → omit + warn, exit 0); TRACE_SENSOR_COUNT is forwarded as
# harness.sensor_count only when it is a pure decimal integer. Intended for
# green_handback spans so runs record which sensor tier executed, but attaches
# on any step when set.
#
# Research-provenance passthrough (issue #317): TRACE_RESEARCH_URL and
# TRACE_RESEARCH_SUMMARY are accepted only as a pair on generator handbacks
# for research that was actually performed. A research-requested disposition
# means web was unavailable and always rejects provenance. The URL must use
# HTTP(S), and the non-empty content summary must be one line. Missing or
# invalid provenance on a research disposition hard-fails before emission;
# research-requested input warns and omits both fields. Valid values are
# written to the span and the same Action Log row; fetched page content is
# never accepted as a trace field.
#
# Durable-rule passthrough (issue #317): TRACE_DURABLE_RULE_PATH and
# TRACE_DURABLE_RULE_SUMMARY are accepted only as a pair on a successful
# generator green handback carrying a class-repair disposition. The path must
# name an existing, non-symlinked AGENTS.md or
# .copilot/instructions/*.instructions.md file inside the actual repository;
# the summary must be a non-empty single line. Invalid pairs warn and omit.
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

# Research provenance fields are globally optional, but a generator research
# disposition requires their valid pair. Validate before either output is
# rendered so invalid input cannot emit a span or Action Log row.
RESEARCH_URL=""
RESEARCH_SUMMARY=""
research_eligible=0
research_unperformed=0
if [ "$ROLE" = "generator-subagent" ]; then
  case "$STEP" in
    red_handback|impl_handback|green_handback)
      case "${TRACE_FAILURE_DISPOSITION:-}" in
        research) research_eligible=1 ;;
        research-requested) research_unperformed=1 ;;
      esac
      ;;
  esac
fi
if [ "$research_unperformed" = "1" ] \
  && { [ -n "${TRACE_RESEARCH_URL:-}" ] || [ -n "${TRACE_RESEARCH_SUMMARY:-}" ]; }; then
  warn "research provenance requires performed research; research-requested consulted no source — both fields omitted"
elif [ "$research_eligible" = "1" ]; then
  if [ -z "${TRACE_RESEARCH_URL:-}" ] || [ -z "${TRACE_RESEARCH_SUMMARY:-}" ]; then
    fail "research disposition requires both TRACE_RESEARCH_URL and TRACE_RESEARCH_SUMMARY"
  elif ! [[ "${TRACE_RESEARCH_URL}" =~ ^https?://[^/?#[:space:]]+[^[:space:]]*$ ]]; then
    fail "research provenance URL must be a non-empty HTTP(S) URL"
  elif [[ "${TRACE_RESEARCH_SUMMARY}" == *$'\n'* \
    || "${TRACE_RESEARCH_SUMMARY}" == *$'\r'* \
    || ! "${TRACE_RESEARCH_SUMMARY}" =~ [^[:space:]] ]]; then
    fail "research provenance summary must be a non-empty one-line value"
  else
    RESEARCH_URL="${TRACE_RESEARCH_URL}"
    RESEARCH_SUMMARY="${TRACE_RESEARCH_SUMMARY}"
  fi
fi

DURABLE_RULE_PATH=""
DURABLE_RULE_SUMMARY=""
durable_rule_eligible=0
if [ "$ROLE" = "generator-subagent" ] \
  && [ "$STEP" = "green_handback" ] \
  && [ "$OUTCOME" = "pass" ]; then
  case "${TRACE_FAILURE_CLASS:-}:${TRACE_FAILURE_DISPOSITION:-}" in
    knowledge-gap:research|complexity:decompose \
      |known-flaky:override|polling:override \
      |spec-violation:class-fix|spec-violation:override \
      |validation-bypass:class-fix|validation-bypass:override \
      |missing-coverage:class-fix|missing-coverage:override \
      |regression:class-fix|regression:override \
      |role-boundary:class-fix|role-boundary:override \
      |other:class-fix|other:override)
      durable_rule_eligible=1
      ;;
  esac
fi
if [ "$durable_rule_eligible" = "1" ] \
  && { [ -n "${TRACE_DURABLE_RULE_PATH:-}" ] \
    || [ -n "${TRACE_DURABLE_RULE_SUMMARY:-}" ]; }; then
  durable_rule_valid=1
  durable_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "${TRACE_DURABLE_RULE_PATH:-}" ] \
    || [ -z "${TRACE_DURABLE_RULE_SUMMARY:-}" ]; then
    durable_rule_valid=0
  elif [[ "${TRACE_DURABLE_RULE_SUMMARY}" == *$'\n'* \
    || "${TRACE_DURABLE_RULE_SUMMARY}" == *$'\r'* \
    || ! "${TRACE_DURABLE_RULE_SUMMARY}" =~ [^[:space:]] ]]; then
    durable_rule_valid=0
  elif [ "${TRACE_DURABLE_RULE_PATH}" = "AGENTS.md" ]; then
    if [ -z "$durable_repo_root" ] \
      || [ ! -f "${durable_repo_root}/AGENTS.md" ] \
      || [ -L "${durable_repo_root}/AGENTS.md" ]; then
      durable_rule_valid=0
    fi
  elif [[ "${TRACE_DURABLE_RULE_PATH}" =~ ^\.copilot/instructions/[A-Za-z0-9._-]+\.instructions\.md$ ]]; then
    if [ -z "$durable_repo_root" ] \
      || [ -L "${durable_repo_root}/.copilot" ] \
      || [ -L "${durable_repo_root}/.copilot/instructions" ] \
      || [ ! -f "${durable_repo_root}/${TRACE_DURABLE_RULE_PATH}" ] \
      || [ -L "${durable_repo_root}/${TRACE_DURABLE_RULE_PATH}" ]; then
      durable_rule_valid=0
    fi
  else
    durable_rule_valid=0
  fi

  if [ "$durable_rule_valid" = "1" ]; then
    DURABLE_RULE_PATH="${TRACE_DURABLE_RULE_PATH}"
    DURABLE_RULE_SUMMARY="${TRACE_DURABLE_RULE_SUMMARY}"
  else
    warn "durable rule evidence requires an existing non-symlinked repository rule path and non-empty one-line summary — both fields omitted"
  fi
fi

# --- 1b. Actionability hard-fail gate (issue #318, feature actionable-rejects) --
# A new review_verdict/fail MUST set TRACE_ACTIONABLE (true|false). Missing or
# invalid values HARD-FAIL before either span or Action Log append — the emitter
# can distinguish new calls, so this is a hard gate (not warn+omit). Pass
# verdicts may omit TRACE_ACTIONABLE silently.
if [ "$STEP" = "review_verdict" ] && [ "$OUTCOME" = "fail" ]; then
  case "${TRACE_ACTIONABLE:-}" in
    true|false) ;;  # valid closed enum
    "")
      fail "TRACE_ACTIONABLE is required on review_verdict/fail but is unset/empty — set to 'true' or 'false'"
      ;;
    *)
      fail "TRACE_ACTIONABLE '${TRACE_ACTIONABLE}' is not in the closed enum {true,false} — set to 'true' or 'false'"
      ;;
  esac
fi

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

  # Sensor-scope passthrough (issue #343): forward TRACE_SENSOR_SCOPE as
  # harness.sensor_scope only when it is `scoped` or `full` (closed enum;
  # out-of-enum → omit + warn, never fake, never fail — mirrors the
  # failure-mode shape), and TRACE_SENSOR_COUNT as harness.sensor_count only
  # when it is a pure decimal integer. Each is forwarded independently so a
  # scoped run without a count (or vice versa) still records what it can.
  SS_ARGS=()
  if [ -n "${TRACE_SENSOR_SCOPE:-}" ]; then
    case "${TRACE_SENSOR_SCOPE}" in
      scoped|full)
        SS_ARGS+=("harness.sensor_scope=${TRACE_SENSOR_SCOPE}")
        ;;
      *)
        warn "TRACE_SENSOR_SCOPE '${TRACE_SENSOR_SCOPE}' is not in the closed enum {scoped, full} — harness.sensor_scope omitted (omit, never fake)"
        ;;
    esac
  fi
  if [[ "${TRACE_SENSOR_COUNT:-}" =~ ^[0-9]+$ ]]; then
    SS_ARGS+=("harness.sensor_count=${TRACE_SENSOR_COUNT}")
  elif [ -n "${TRACE_SENSOR_COUNT:-}" ]; then
    warn "TRACE_SENSOR_COUNT '${TRACE_SENSOR_COUNT}' is not a pure decimal integer — harness.sensor_count omitted (omit, never fake)"
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

  # Failure-class passthrough (issues #318/#317): on review_verdict or a
  # generator red/implementation/green handback,
  # forward TRACE_FAILURE_CLASS as harness.failure_class (closed enum from
  # docs/evaluation/trace-schema.v1.json .failure_classes; out-of-enum or empty
  # → omit + warn, never fake, mirroring the failure-mode shape). Also forward
  # TRACE_FAILURE_CLASS_DETAIL as harness.failure_class_detail (free-text,
  # non-empty → forward, empty → omit). Both are absent outside those steps.
  FC_ARGS=()
  failure_fields_eligible=0
  if [ "$STEP" = "review_verdict" ]; then
    failure_fields_eligible=1
  elif [ "$ROLE" = "generator-subagent" ]; then
    case "$STEP" in
      red_handback|impl_handback|green_handback) failure_fields_eligible=1 ;;
    esac
  fi
  if [ "$failure_fields_eligible" = "1" ]; then
    # Validate TRACE_FAILURE_CLASS against the contract's closed enum.
    failure_class_valid() {
      local cls="$1" contract="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
      local fc_list="" fc_entry
      if [ -f "$contract" ] && command -v jq >/dev/null 2>&1; then
        fc_list="$(jq -r '(.failure_classes // [])[]' "$contract" 2>/dev/null || true)"
      fi
      if [ -z "$fc_list" ]; then
        # Frozen v1 fallback. Slug list is the drift-guarded authority copy.
        # >>> trace-schema:failure_classes (authority docs/evaluation/trace-schema.v1.json .failure_classes; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
        # spec-violation
        # validation-bypass
        # missing-coverage
        # regression
        # role-boundary
        # knowledge-gap
        # complexity
        # known-flaky
        # polling
        # other
        # <<< trace-schema:failure_classes
        fc_list='spec-violation
validation-bypass
missing-coverage
regression
role-boundary
knowledge-gap
complexity
known-flaky
polling
other'
      fi
      while IFS= read -r fc_entry; do
        [ "$fc_entry" = "$cls" ] && return 0
      done <<< "$fc_list"
      return 1
    }
    if [ -n "${TRACE_FAILURE_CLASS:-}" ]; then
      if failure_class_valid "${TRACE_FAILURE_CLASS}"; then
        FC_ARGS+=("harness.failure_class=${TRACE_FAILURE_CLASS}")
      else
        warn "TRACE_FAILURE_CLASS '${TRACE_FAILURE_CLASS}' is not in the closed failure_classes enum — harness.failure_class omitted (omit, never fake)"
      fi
    fi
    if [ -n "${TRACE_FAILURE_CLASS_DETAIL:-}" ]; then
      FC_ARGS+=("harness.failure_class_detail=${TRACE_FAILURE_CLASS_DETAIL}")
    fi
  fi

  # Generator failure disposition (issue #317): a route is deliberately
  # separate from failure_class. Forward only on generator handbacks and only
  # from the closed schema enum; invalid values warn and omit.
  FD_ARGS=()
  if [ "$ROLE" = "generator-subagent" ]; then
    case "$STEP" in
      red_handback|impl_handback|green_handback)
        if [ -n "${TRACE_FAILURE_DISPOSITION:-}" ]; then
          failure_disposition_valid() {
            local value="$1" contract="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
            local dispositions="" entry
            if [ -f "$contract" ] && command -v jq >/dev/null 2>&1; then
              dispositions="$(jq -r '(.failure_dispositions // [])[]' "$contract" 2>/dev/null || true)"
            fi
            if [ -z "$dispositions" ]; then
              # >>> trace-schema:failure_dispositions (authority docs/evaluation/trace-schema.v1.json .failure_dispositions; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
              # point-fix
              # class-fix
              # research
              # decompose
              # exemption
              # override
              # research-requested
              # <<< trace-schema:failure_dispositions
              dispositions='point-fix
class-fix
research
decompose
exemption
override
research-requested'
            fi
            while IFS= read -r entry; do
              [ "$entry" = "$value" ] && return 0
            done <<< "$dispositions"
            return 1
          }
          if failure_disposition_valid "${TRACE_FAILURE_DISPOSITION}"; then
            FD_ARGS+=("harness.failure_disposition=${TRACE_FAILURE_DISPOSITION}")
          else
            warn "TRACE_FAILURE_DISPOSITION '${TRACE_FAILURE_DISPOSITION}' is not in the closed failure_dispositions enum — harness.failure_disposition omitted (omit, never fake)"
          fi
        fi
        ;;
    esac
  fi

  # Finding-fingerprint passthrough (issue #318): on the review_verdict step
  # ONLY, forward TRACE_FINDING_FINGERPRINT as harness.finding_fingerprint
  # (free-text stable identity; non-empty → forward, empty → omit; omit-never-
  # fake). Absent on non-review_verdict steps.
  FP_ARGS=()
  if [ "$STEP" = "review_verdict" ]; then
    if [ -n "${TRACE_FINDING_FINGERPRINT:-}" ]; then
      FP_ARGS+=("harness.finding_fingerprint=${TRACE_FINDING_FINGERPRINT}")
    fi
  fi

  # Review-event-ID passthrough (issue #318, feature finding-identity): on the
  # review_verdict step ONLY, forward TRACE_REVIEW_EVENT_ID as
  # harness.review_event_id (free-text event grouping identity; non-empty →
  # forward, empty → omit; omit-never-fake). Absent on non-review_verdict steps.
  EID_ARGS=()
  if [ "$STEP" = "review_verdict" ]; then
    if [ -n "${TRACE_REVIEW_EVENT_ID:-}" ]; then
      EID_ARGS+=("harness.review_event_id=${TRACE_REVIEW_EVENT_ID}")
    fi
  fi

  # Finding-baseline-state passthrough (issue #318, feature finding-identity):
  # on the review_verdict step ONLY, forward TRACE_FINDING_BASELINE_STATE as
  # harness.finding_baseline_state against a CLOSED enum {new, unchanged,
  # updated, resolved}; out-of-enum or empty → omit + warn (never fake,
  # mirroring the failure-mode shape). Absent on non-review_verdict steps.
  BS_ARGS=()
  if [ "$STEP" = "review_verdict" ]; then
    case "${TRACE_FINDING_BASELINE_STATE:-}" in
      new|unchanged|updated|resolved)
        BS_ARGS+=("harness.finding_baseline_state=${TRACE_FINDING_BASELINE_STATE}")
        ;;
      "")
        : # unset/empty → omit silently
        ;;
      *)
        warn "TRACE_FINDING_BASELINE_STATE '${TRACE_FINDING_BASELINE_STATE}' is not in the closed finding_baseline_states enum {new,unchanged,updated,resolved} — harness.finding_baseline_state omitted (omit, never fake)"
        ;;
    esac
  fi

  # Repair-scope passthrough (issue #318, feature repair-verdict-scope): on the
  # review_verdict step ONLY and ONLY when TRACE_REVIEW_MODE is "repair",
  # forward TRACE_REPAIR_SCOPE as harness.repair_scope after validating
  # canonical format: comma-separated list of [A-Za-z0-9._-]+ tokens, no
  # whitespace, no empty tokens, no duplicate tokens. Invalid values → omit +
  # warn (omit, never fake). Absent on non-review_verdict steps, on
  # non-repair review modes, and when the env var is unset/empty.
  RS_ARGS=()
  if [ "$STEP" = "review_verdict" ] && [ "${TRACE_REVIEW_MODE:-}" = "repair" ]; then
    if [ -n "${TRACE_REPAIR_SCOPE:-}" ]; then
      # Anchored whole-string grammar check BEFORE splitting: catches boundary
      # commas (leading "," or trailing ",") that bash's IFS=',' read -ra
      # silently discards as empty trailing fields, letting "feat-a," pass
      # the per-token loop. Must match ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$.
      rs_valid=0
      if [[ "${TRACE_REPAIR_SCOPE}" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
        rs_valid=1
        IFS=',' read -ra rs_tokens <<< "${TRACE_REPAIR_SCOPE}"
        rs_seen=$'\n'
        for rs_tok in "${rs_tokens[@]}"; do
          if ! [[ "$rs_tok" =~ ^[A-Za-z0-9._-]+$ ]]; then
            rs_valid=0
            break
          fi
          if [[ "$rs_seen" == *$'\n'"$rs_tok"$'\n'* ]]; then
            rs_valid=0
            break
          fi
          rs_seen="${rs_seen}${rs_tok}"$'\n'
        done
      fi
      if [ "$rs_valid" = "1" ]; then
        RS_ARGS+=("harness.repair_scope=${TRACE_REPAIR_SCOPE}")
      else
        warn "TRACE_REPAIR_SCOPE '${TRACE_REPAIR_SCOPE}' is not valid canonical format (comma-separated [A-Za-z0-9._-]+ tokens, no whitespace/empty/duplicates) — harness.repair_scope omitted (omit, never fake)"
      fi
    fi
  fi

  # Actionability passthrough (issue #318, feature actionable-rejects): on the
  # review_verdict step ONLY, forward TRACE_ACTIONABLE as harness.actionable
  # (closed enum {true,false}). Fail verdicts already validated in §1b above;
  # pass verdicts silently omit. Forward TRACE_FINDING_REPRODUCTION and
  # TRACE_FINDING_PROPOSED_FIX as harness.finding_reproduction /
  # harness.finding_proposed_fix (non-empty free text; redacted by trace-lib).
  # Unset/empty → key absent (omit, never fake).
  ACT_ARGS=()
  if [ "$STEP" = "review_verdict" ]; then
    case "${TRACE_ACTIONABLE:-}" in
      true|false)
        ACT_ARGS+=("harness.actionable=${TRACE_ACTIONABLE}")
        ;;
    esac
    if [ -n "${TRACE_FINDING_REPRODUCTION:-}" ]; then
      ACT_ARGS+=("harness.finding_reproduction=${TRACE_FINDING_REPRODUCTION}")
    fi
    if [ -n "${TRACE_FINDING_PROPOSED_FIX:-}" ]; then
      ACT_ARGS+=("harness.finding_proposed_fix=${TRACE_FINDING_PROPOSED_FIX}")
    fi
  fi

  RESEARCH_ARGS=()
  if [ -n "$RESEARCH_URL" ]; then
    RESEARCH_ARGS+=("harness.research_url=${RESEARCH_URL}")
    RESEARCH_ARGS+=("harness.research_summary=${RESEARCH_SUMMARY}")
  fi
  DURABLE_RULE_ARGS=()
  if [ -n "$DURABLE_RULE_PATH" ]; then
    DURABLE_RULE_ARGS+=("harness.durable_rule_path=${DURABLE_RULE_PATH}")
    DURABLE_RULE_ARGS+=("harness.durable_rule_summary=${DURABLE_RULE_SUMMARY}")
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
    ${SS_ARGS[@]+"${SS_ARGS[@]}"} \
    ${RM_ARGS[@]+"${RM_ARGS[@]}"} \
    ${FC_ARGS[@]+"${FC_ARGS[@]}"} \
    ${FD_ARGS[@]+"${FD_ARGS[@]}"} \
    ${FP_ARGS[@]+"${FP_ARGS[@]}"} \
    ${EID_ARGS[@]+"${EID_ARGS[@]}"} \
    ${BS_ARGS[@]+"${BS_ARGS[@]}"} \
    ${RS_ARGS[@]+"${RS_ARGS[@]}"} \
    ${ACT_ARGS[@]+"${ACT_ARGS[@]}"} \
    ${RESEARCH_ARGS[@]+"${RESEARCH_ARGS[@]}"} \
    ${DURABLE_RULE_ARGS[@]+"${DURABLE_RULE_ARGS[@]}"}

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

RESEARCH_SUFFIX=""
if [ -n "$RESEARCH_URL" ]; then
  RESEARCH_SUFFIX=" [research: ${RESEARCH_URL} — ${RESEARCH_SUMMARY}]"
fi
DURABLE_RULE_SUFFIX=""
if [ -n "$DURABLE_RULE_PATH" ]; then
  DURABLE_RULE_SUFFIX=" [durable rule: ${DURABLE_RULE_PATH} — ${DURABLE_RULE_SUMMARY}]"
fi
BULLET="$(printf -- '- [%s] %s %s %s — %s%s' \
  "$ROLE" "$STEP" "$FEATURE_ID" "$OUTCOME" "$SUMMARY" \
  "${RESEARCH_SUFFIX}${DURABLE_RULE_SUFFIX}" | redact_line)" \
  || append_fail "redaction of the Action Log line failed — line not recorded"
[ -n "$BULLET" ] \
  || append_fail "redaction produced an empty Action Log line — line not recorded"

printf '%s\n' "$BULLET" >> "$PROGRESS" \
  || append_fail "cannot append to ${PROGRESS} — Action Log line not recorded"

exit 0
