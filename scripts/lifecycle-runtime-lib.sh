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
