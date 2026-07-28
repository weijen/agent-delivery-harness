#!/usr/bin/env bash
# rebind-evidence.sh — keep HEAD-bound gate evidence current across repair
# commits (issue #442).
#
# Usage:
#   scripts/rebind-evidence.sh [--gate pre-review|pre-pr]   # default pre-review
#
# The repair-loop catch-22 this removes: fixing a review finding creates a
# commit, which silently invalidates the previous gate evidence; the staleness
# used to surface one review round later as a BLOCKING stale-evidence finding
# (#383 "pre-verdict dependency cycle", foundry issue-48). Re-binding is a
# deterministic script action at the moment it is owed, never a finding.
#
# Carry rule (deterministic — the agent never reasons about staleness):
#   * a green (failed=0, ran>0) recorded row already bound to the CURRENT HEAD
#     with the requested gate mode → evidence is current, exit 0, no re-run;
#   * anything else (repair commit, rebase, first run, tampered rows) →
#     re-run `run-sensors.sh --gate <gate>`, which re-records the row (#441).
#
# Exit: 0 evidence current (carried or freshly re-bound) · 1 sensors red or
#       no issue context · 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }

GATE="pre-review"
while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
case "$GATE" in
  pre-review|pre-pr) ;;
  *) usage; exit 2 ;;
esac

# Guarded source: issue resolution reuses the trace-lib precedence.
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi
declare -F trace__resolve_issue >/dev/null 2>&1 \
  || { printf 'rebind-evidence: trace-lib.sh unavailable — cannot resolve the issue\n' >&2; exit 1; }
ISSUE="$(trace__resolve_issue)" \
  || { printf 'rebind-evidence: no issue context (branch/worktree/TRACE_ISSUE)\n' >&2; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"

# Carry: evidence already bound to this HEAD at this gate → nothing owed.
if [ -x "${SCRIPT_DIR}/verify-sensor-evidence.sh" ] \
  && "${SCRIPT_DIR}/verify-sensor-evidence.sh" "$ISSUE" \
       --head "$HEAD_SHA" --mode "$GATE" >/dev/null 2>&1; then
  printf 'rebind-evidence: OK evidence current for head %s (mode %s) — carried\n' \
    "$HEAD_SHA" "$GATE"
  exit 0
fi

# Re-bind: run the owed gate at the current HEAD; #441 records the row.
printf 'rebind-evidence: evidence stale or absent for head %s — re-running --gate %s\n' \
  "$HEAD_SHA" "$GATE"
"${SCRIPT_DIR}/run-sensors.sh" --gate "$GATE"
