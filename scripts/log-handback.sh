#!/usr/bin/env bash
# log-handback.sh — current semantic writer for issue work.
#
# Usage:
#   scripts/log-handback.sh conductor \
#     <feature_start|deviation|review_verdict> \
#     <feature_id> <pass|fail|blocked> <summary...>
#
# Historical roles, handback steps, and their specialized environment channels
# remain schema-readable but are no longer accepted for new writes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: log-handback.sh conductor <lifecycle_step> <feature_id> <outcome> <summary...>
  lifecycle_step: feature_start|deviation|review_verdict
  outcome:        pass|fail|blocked
EOF
}

fail() {
  printf 'log-handback: error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'log-handback: warning: %s\n' "$*" >&2
}

# Frozen compatibility enums are retained for schema drift detection even
# though the current writer accepts only conductor-authored semantic spans.
# >>> trace-schema:roles (authority docs/evaluation/trace-schema.v1.json .roles)
# conductor
# planning-subagent
# generator-subagent
# implementation-subagent
# test-subagent
# code-review-subagent
# <<< trace-schema:roles
#
# >>> trace-schema:failure_classes (authority docs/evaluation/trace-schema.v1.json .failure_classes)
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
#
# >>> trace-schema:failure_dispositions (authority docs/evaluation/trace-schema.v1.json .failure_dispositions)
# point-fix
# class-fix
# research
# decompose
# exemption
# override
# research-requested
# <<< trace-schema:failure_dispositions

enum_valid() {
  local key="$1" value="$2" fallback="$3"
  local contract="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
  local values="" entry
  if [ -f "$contract" ] && command -v jq >/dev/null 2>&1; then
    values="$(jq -r --arg key "$key" '.[$key] // [] | .[]' "$contract" 2>/dev/null || true)"
  fi
  [ -n "$values" ] || values="$fallback"
  while IFS= read -r entry; do
    [ "$entry" = "$value" ] && return 0
  done <<< "$values"
  return 1
}

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

[ "$ROLE" = "conductor" ] \
  || { usage; fail "unknown role '${ROLE}' (current writer accepts conductor only)"; }
case "$STEP" in
  feature_start|deviation|review_verdict) ;;
  *) usage; fail "unknown lifecycle step '${STEP}' (current writer accepts feature_start, deviation, or review_verdict)" ;;
esac
case "$OUTCOME" in
  pass|fail|blocked) ;;
  *) usage; fail "unknown outcome '${OUTCOME}' (expected pass|fail|blocked)" ;;
esac
[[ "$FEATURE_ID" =~ ^[A-Za-z0-9._-]+$ ]] \
  || fail "invalid feature_id '${FEATURE_ID}' (expected a token of [A-Za-z0-9._-], or '-' when no feature applies)"
[ -n "$SUMMARY" ] || fail "summary must be non-empty"
SUMMARY="${SUMMARY//$'\r'/ }"
SUMMARY="${SUMMARY//$'\n'/ }"

if [ "$STEP" = "review_verdict" ] && [ "$OUTCOME" = "fail" ]; then
  case "${TRACE_ACTIONABLE:-}" in
    true|false) ;;
    "")
      fail "TRACE_ACTIONABLE is required on review_verdict/fail but is unset/empty — set to 'true' or 'false'"
      ;;
    *)
      fail "TRACE_ACTIONABLE '${TRACE_ACTIONABLE}' is not in the closed enum {true,false} — set to 'true' or 'false'"
      ;;
  esac
  # Write-time #318 attribution gate (issue #443): every field the trace
  # checker would flag post-hoc is REQUIRED here, so a malformed fail verdict
  # is impossible to write rather than punishable one review round later.
  [ "$FEATURE_ID" != "-" ] \
    || fail "review_verdict/fail requires a real feature_id (or the literal 'unmapped'), not '-' (#318)"
  [ -n "${TRACE_FAILURE_CLASS:-}" ] \
    || fail "TRACE_FAILURE_CLASS is required on review_verdict/fail (#318) — pick one from the trace schema's closed failure_classes enum"
  [ -n "${TRACE_FINDING_FINGERPRINT:-}" ] \
    || fail "TRACE_FINDING_FINGERPRINT is required on review_verdict/fail (#318) — a stable finding identity label"
  case "${TRACE_FINDING_BASELINE_STATE:-}" in
    new|unchanged|updated|resolved) ;;
    "")
      fail "TRACE_FINDING_BASELINE_STATE is required on review_verdict/fail (#318) — one of new|unchanged|updated|resolved"
      ;;
    *)
      fail "TRACE_FINDING_BASELINE_STATE '${TRACE_FINDING_BASELINE_STATE}' is not in the closed enum {new,unchanged,updated,resolved} (#318)"
      ;;
  esac
  if [ "${TRACE_FAILURE_CLASS:-}" = "other" ] && [ -z "${TRACE_FAILURE_CLASS_DETAIL:-}" ]; then
    fail "TRACE_FAILURE_CLASS=other requires TRACE_FAILURE_CLASS_DETAIL (#318)"
  fi
  if [ "${TRACE_ACTIONABLE}" = "true" ] \
    && [ -z "${TRACE_FINDING_REPRODUCTION:-}" ] && [ -z "${TRACE_FINDING_PROPOSED_FIX:-}" ]; then
    fail "TRACE_ACTIONABLE=true requires TRACE_FINDING_REPRODUCTION or TRACE_FINDING_PROPOSED_FIX (#318 actionable-without-evidence)"
  fi
fi

HAVE_TRACE_LIB=0
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
  HAVE_TRACE_LIB=1
else
  warn "scripts/trace-lib.sh not found — agent span skipped"
fi

SPAN_ISSUE=""
if [ "$HAVE_TRACE_LIB" = "1" ]; then
  SPAN_ISSUE="$(trace__resolve_issue 2>/dev/null || true)"

  DEVIATION_ARGS=()
  if [ "$STEP" = "deviation" ] && [ -n "${TRACE_FAILURE_MODE:-}" ]; then
    failure_mode_valid() {
      local mode="$1" contract="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
      local enum="" entry
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
      while IFS= read -r entry; do
        [ "$entry" = "$mode" ] && return 0
      done <<< "$enum"
      return 1
    }
    if failure_mode_valid "${TRACE_FAILURE_MODE}"; then
      DEVIATION_ARGS+=("harness.failure_mode=${TRACE_FAILURE_MODE}")
    else
      warn "TRACE_FAILURE_MODE '${TRACE_FAILURE_MODE}' is not in the closed failure_modes enum — harness.failure_mode omitted"
    fi
  fi
  if [ "$STEP" = "deviation" ]; then
    failure_classes='spec-violation
validation-bypass
missing-coverage
regression
role-boundary
knowledge-gap
complexity
known-flaky
polling
other'
    failure_dispositions='point-fix
class-fix
research
decompose
exemption
override
research-requested'
    if [ -n "${TRACE_FAILURE_CLASS:-}" ]; then
      # Invalid enum values REJECT the write (#443); missing stays allowed —
      # the writer cannot know whether a class is owed for this deviation.
      enum_valid failure_classes "${TRACE_FAILURE_CLASS}" "$failure_classes" \
        || fail "TRACE_FAILURE_CLASS '${TRACE_FAILURE_CLASS}' is not in the closed failure_classes enum — span not written"
      DEVIATION_ARGS+=("harness.failure_class=${TRACE_FAILURE_CLASS}")
    fi
    [ -z "${TRACE_FAILURE_CLASS_DETAIL:-}" ] \
      || DEVIATION_ARGS+=("harness.failure_class_detail=${TRACE_FAILURE_CLASS_DETAIL}")
    if [ -n "${TRACE_FAILURE_DISPOSITION:-}" ]; then
      enum_valid failure_dispositions "${TRACE_FAILURE_DISPOSITION}" "$failure_dispositions" \
        || fail "TRACE_FAILURE_DISPOSITION '${TRACE_FAILURE_DISPOSITION}' is not in the closed failure_dispositions enum — span not written"
      DEVIATION_ARGS+=("harness.failure_disposition=${TRACE_FAILURE_DISPOSITION}")
    fi
    [ -z "${TRACE_RESEARCH_URL:-}" ] \
      || DEVIATION_ARGS+=("harness.research_url=${TRACE_RESEARCH_URL}")
    [ -z "${TRACE_RESEARCH_SUMMARY:-}" ] \
      || DEVIATION_ARGS+=("harness.research_summary=${TRACE_RESEARCH_SUMMARY}")
    [ -z "${TRACE_DURABLE_RULE_PATH:-}" ] \
      || DEVIATION_ARGS+=("harness.durable_rule_path=${TRACE_DURABLE_RULE_PATH}")
    [ -z "${TRACE_DURABLE_RULE_SUMMARY:-}" ] \
      || DEVIATION_ARGS+=("harness.durable_rule_summary=${TRACE_DURABLE_RULE_SUMMARY}")
  fi

  REVIEW_ARGS=()
  if [ "$STEP" = "review_verdict" ]; then
    case "${TRACE_REVIEW_MODE:-}" in
      full|concise|repair)
        REVIEW_ARGS+=("harness.review_mode=${TRACE_REVIEW_MODE}")
        ;;
      "") ;;
      *)
        warn "TRACE_REVIEW_MODE '${TRACE_REVIEW_MODE}' is not in the closed review_mode enum — harness.review_mode omitted"
        ;;
    esac
    reviewed_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    [ -z "$reviewed_sha" ] || REVIEW_ARGS+=("harness.reviewed_sha=${reviewed_sha}")

    failure_classes='spec-violation
validation-bypass
missing-coverage
regression
role-boundary
knowledge-gap
complexity
known-flaky
polling
other'
    if [ -n "${TRACE_FAILURE_CLASS:-}" ]; then
      # Invalid enum values REJECT the write (#443): a warn-and-omit here is
      # exactly the malformed span the checker would flag one round later.
      enum_valid failure_classes "${TRACE_FAILURE_CLASS}" "$failure_classes" \
        || fail "TRACE_FAILURE_CLASS '${TRACE_FAILURE_CLASS}' is not in the closed failure_classes enum — span not written"
      REVIEW_ARGS+=("harness.failure_class=${TRACE_FAILURE_CLASS}")
    fi
    [ -z "${TRACE_FAILURE_CLASS_DETAIL:-}" ] \
      || REVIEW_ARGS+=("harness.failure_class_detail=${TRACE_FAILURE_CLASS_DETAIL}")
    [ -z "${TRACE_FINDING_FINGERPRINT:-}" ] \
      || REVIEW_ARGS+=("harness.finding_fingerprint=${TRACE_FINDING_FINGERPRINT}")
    if [ "$OUTCOME" = "fail" ] && [ -n "${TRACE_REPEAT_OF:-}" ]; then
      REVIEW_ARGS+=("harness.repeat_of=${TRACE_REPEAT_OF}")
    fi
    [ -z "${TRACE_REVIEW_EVENT_ID:-}" ] \
      || REVIEW_ARGS+=("harness.review_event_id=${TRACE_REVIEW_EVENT_ID}")

    case "${TRACE_FINDING_BASELINE_STATE:-}" in
      new|unchanged|updated|resolved)
        REVIEW_ARGS+=("harness.finding_baseline_state=${TRACE_FINDING_BASELINE_STATE}")
        ;;
      "") ;;
      *)
        # Unreachable for fail verdicts (pre-validated above); pass verdicts
        # with an invalid value also reject rather than silently omit (#443).
        fail "TRACE_FINDING_BASELINE_STATE '${TRACE_FINDING_BASELINE_STATE}' is not in the closed enum {new,unchanged,updated,resolved} — span not written"
        ;;
    esac

    if [ "${TRACE_REVIEW_MODE:-}" = "repair" ]; then
      # Repair verdicts owe the #318 repair-verdict-scope family at write time
      # (#443): a missing/invalid scope or an out-of-scope feature_id is what
      # the checker would flag as repair_scope_missing/mismatch one round
      # later — reject it here instead.
      [ -n "${TRACE_REPAIR_SCOPE:-}" ] \
        || fail "TRACE_REPAIR_SCOPE is required on repair-mode review verdicts (#318) — comma-separated feature ids"
      repair_scope_valid=0
      if [[ "${TRACE_REPAIR_SCOPE}" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
        repair_scope_valid=1
        IFS=',' read -ra repair_tokens <<< "${TRACE_REPAIR_SCOPE}"
        seen=$'\n'
        for token in "${repair_tokens[@]}"; do
          if [[ "$seen" == *$'\n'"$token"$'\n'* ]]; then
            repair_scope_valid=0
            break
          fi
          seen="${seen}${token}"$'\n'
        done
      fi
      [ "$repair_scope_valid" = "1" ] \
        || fail "TRACE_REPAIR_SCOPE '${TRACE_REPAIR_SCOPE}' is not valid canonical format (comma-separated unique tokens) — span not written"
      # No unmapped/'-' carve-out: the checker requires exact scope
      # membership for every repair verdict, and an out-of-scope discovery
      # belongs in a separate non-repair review event (reviewer contract).
      scope_member=0
      for token in "${repair_tokens[@]}"; do
        [ "$token" = "$FEATURE_ID" ] && { scope_member=1; break; }
      done
      [ "$scope_member" = "1" ] \
        || fail "feature_id '${FEATURE_ID}' is not in TRACE_REPAIR_SCOPE '${TRACE_REPAIR_SCOPE}' (#318) — repair verdicts bind to named in-scope features; emit out-of-scope findings as a separate non-repair review event"
      REVIEW_ARGS+=("harness.repair_scope=${TRACE_REPAIR_SCOPE}")
    fi

    case "${TRACE_ACTIONABLE:-}" in
      true|false) REVIEW_ARGS+=("harness.actionable=${TRACE_ACTIONABLE}") ;;
    esac
    [ -z "${TRACE_FINDING_REPRODUCTION:-}" ] \
      || REVIEW_ARGS+=("harness.finding_reproduction=${TRACE_FINDING_REPRODUCTION}")
    [ -z "${TRACE_FINDING_PROPOSED_FIX:-}" ] \
      || REVIEW_ARGS+=("harness.finding_proposed_fix=${TRACE_FINDING_PROPOSED_FIX}")
  fi

  trace_span agent \
    "gen_ai.operation.name=invoke_agent" \
    "gen_ai.agent.name=${ROLE}" \
    "harness.lifecycle_step=${STEP}" \
    "harness.feature_id=${FEATURE_ID}" \
    "harness.outcome=${OUTCOME}" \
    "harness.summary=${SUMMARY}" \
    ${DEVIATION_ARGS[@]+"${DEVIATION_ARGS[@]}"} \
    ${REVIEW_ARGS[@]+"${REVIEW_ARGS[@]}"}
fi

RENDER_ISSUE="$SPAN_ISSUE"
if [ -z "$RENDER_ISSUE" ]; then
  RENDER_RAW="${TRACE_ISSUE:-}"
  if [ -z "$RENDER_RAW" ]; then
    RENDER_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    RENDER_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ "$RENDER_BRANCH" =~ ^feature/issue-([0-9]+)- ]]; then
      RENDER_RAW="${BASH_REMATCH[1]}"
    elif [[ "$(basename "$RENDER_TOPLEVEL")" =~ issue-([0-9]+) ]]; then
      RENDER_RAW="${BASH_REMATCH[1]}"
    fi
  fi
  [[ "$RENDER_RAW" =~ ^[0-9]+$ ]] && RENDER_ISSUE="$RENDER_RAW"
fi
if [ -n "$RENDER_ISSUE" ] && [ -f "${SCRIPT_DIR}/render-action-log.sh" ]; then
  "${SCRIPT_DIR}/render-action-log.sh" "$RENDER_ISSUE" || true
fi
