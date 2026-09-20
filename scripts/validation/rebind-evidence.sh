#!/usr/bin/env bash
# rebind-evidence.sh — read-only compatibility check for existing gate evidence.
#
# Usage:
#   scripts/validation/rebind-evidence.sh [--gate pre-review|pre-pr]   # default pre-pr
#
# Never executes sensors or rewrites evidence. Historical pre-review rows remain
# readable, but approval no longer calls this helper. Missing/stale/invalid final
# evidence requires an explicit pre-PR gate after review, not automatic recovery.
# Exit: 0 evidence current or no issue context · 1 invalid/missing evidence · 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { printf 'usage: rebind-evidence.sh [--gate pre-review|pre-pr] (verification only; default pre-pr)\n' >&2; }

GATE="pre-pr"
while [ $# -gt 0 ]; do
  case "$1" in
    --gate) [ "$#" -ge 2 ] || { usage; exit 2; }; GATE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
case "$GATE" in
  pre-review|pre-pr) ;;
  *) usage; exit 2 ;;
esac

# Guarded source: issue resolution reuses the trace-lib precedence.
if [ -f "${SCRIPT_DIR}/lib/trace-lib.sh" ]; then
  # shellcheck source=scripts/lib/trace-lib.sh
  source "${SCRIPT_DIR}/lib/trace-lib.sh"
fi
declare -F trace__resolve_issue >/dev/null 2>&1 \
  || { printf 'rebind-evidence: trace-lib.sh unavailable — cannot resolve the issue\n' >&2; exit 1; }
# Outside an issue context there is no per-issue evidence contract to bind:
# reviews (and their evidence audits) only exist for issue branches, so
# nothing is owed here — warn and succeed rather than blocking approve paths
# in non-issue repositories.
if ! ISSUE="$(trace__resolve_issue)"; then
  printf 'rebind-evidence: no issue context (branch/worktree/TRACE_ISSUE) — no per-issue evidence owed\n' >&2
  exit 0
fi
HEAD_SHA="$(git rev-parse HEAD)"

# Compatibility verification cannot silently create a replacement result.
verify_out=""
if [ -f "${SCRIPT_DIR}/validation/verify-sensor-evidence.sh" ] \
  && verify_out="$(bash "${SCRIPT_DIR}/validation/verify-sensor-evidence.sh" "$ISSUE" \
       --head "$HEAD_SHA" --mode "$GATE" 2>&1)"; then
  printf 'rebind-evidence: OK evidence current for head %s (mode %s) — carried\n' \
    "$HEAD_SHA" "$GATE"
  exit 0
fi

if [ -n "$verify_out" ]; then
  printf 'rebind-evidence: %s\n' "$verify_out" >&2
else
  printf 'rebind-evidence: verify-sensor-evidence.sh is missing; restore the verifier\n' >&2
fi
printf 'rebind-evidence: no valid %s evidence for head %s; no sensors were executed\n' \
  "$GATE" "$HEAD_SHA" >&2
printf 'rebind-evidence: after review approval, run ./scripts/run-sensors.sh --gate pre-pr for the final candidate\n' >&2
exit 1
