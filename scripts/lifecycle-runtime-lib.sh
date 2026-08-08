#!/usr/bin/env bash
# Shared terminal and optional tracing helpers for lifecycle entrypoints.
# shellcheck disable=SC2329 # Fallback functions are invoked by sourcing callers.

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

lifecycle_runtime_trace_init() {
  LIFECYCLE_RUNTIME_CALLER="$1"
  local runtime_dir
  runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [ -f "${runtime_dir}/trace-lib.sh" ]; then
    # shellcheck source=scripts/trace-lib.sh
    source "${runtime_dir}/trace-lib.sh"
  fi
  if ! declare -F trace_span >/dev/null 2>&1; then
    TRACE_NOOP_WARNED=0
    trace_span() {
      if [ "${TRACE_NOOP_WARNED}" = "0" ]; then
        printf '%s: warning: scripts/trace-lib.sh not found — trace spans disabled\n' \
          "$LIFECYCLE_RUNTIME_CALLER" >&2
        TRACE_NOOP_WARNED=1
      fi
      return 0
    }
    trace_now_ms() { printf '%s000' "$(date +%s 2>/dev/null || printf '0')"; }
    trace_lifecycle_init() { :; }
    trace_lifecycle_arm() { :; }
  fi
}

# --- Post-PR termination guardrail state (issue #450) -------------------------
# Shared by create-pr.sh (G1 round budget, G3 freeze check) and merge-pr.sh
# (G2 structural-red history, G3 freeze write/clear). All state lives in the
# main-root tracking dir beside the trace. Prints the dir; returns 1 when no
# issue context resolves — callers degrade to a skip so the guardrails never
# block a non-issue repository.
guardrail_state_dir() {
  local issue_num issue_pad common root
  declare -F trace__resolve_issue >/dev/null 2>&1 || return 1
  issue_num="$(trace__resolve_issue 2>/dev/null)" || return 1
  issue_pad="$(printf '%02d' "$((10#$issue_num))")"
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) ;;
    *)  common="$(pwd)/$common" ;;
  esac
  root="$(cd "$(dirname "$common")" 2>/dev/null && pwd)" || return 1
  printf '%s/.copilot-tracking/issues/issue-%s' "$root" "$issue_pad"
}
