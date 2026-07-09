#!/usr/bin/env bash
# Regression sensor (issue #213, P-1 / #173 drift-sensor pattern): the terminal
# lifecycle-span EXIT-trap boilerplate — previously copy-pasted into every
# lifecycle script — now has ONE home in scripts/trace-lib.sh
# (trace_lifecycle_init / trace_lifecycle_arm). This sensor forbids a fresh
# inline copy of that trap template creeping back into a lifecycle script.
#
# Two directions, both must hold:
#   1. Single source — trace-lib.sh defines trace_lifecycle_init + trace_lifecycle_arm.
#   2. No fork — each of the four terminal-span lifecycle scripts uses the helper
#      (calls trace_lifecycle_init) and does NOT define its own `trace__*_exit`
#      EXIT-trap function that emits a `harness.lifecycle_step` terminal span.
#
# review-gate.sh is intentionally NOT in the list: its EXIT trap is
# command-dispatched (approve -> lifecycle span, check/status-doc/ci-gate -> tool
# spans, trace -> inline), so it is a genuinely different shape, not a copy of
# the single-step terminal template this sensor guards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

lib="scripts/trace-lib.sh"
# The four scripts that emit exactly ONE terminal lifecycle span from an EXIT trap.
lifecycle_scripts="start-issue.sh create-pr.sh merge-pr.sh finish-issue.sh"

fail=0
note() { echo "✗ $*"; fail=1; }

[ -f "$lib" ] || { echo "✗ missing $lib"; exit 1; }

# --- Direction 1: the shared helper exists in trace-lib.sh --------------------
grep -qE '^trace_lifecycle_init\(\)' "$lib" ||
  note "${lib} must define the shared helper trace_lifecycle_init()"
grep -qE '^trace_lifecycle_arm\(\)' "$lib" ||
  note "${lib} must define the shared helper trace_lifecycle_arm()"

# --- Direction 2: no lifecycle script carries an inline terminal-trap copy ----
for base in $lifecycle_scripts; do
  f="scripts/${base}"
  [ -f "$f" ] || { note "expected lifecycle script ${f} is missing"; continue; }

  # Must route through the shared helper.
  grep -qE '\btrace_lifecycle_init\b' "$f" ||
    note "${f} must call trace_lifecycle_init (use the shared helper, not an inline trap)"
  grep -qE '\btrace_lifecycle_arm\b' "$f" ||
    note "${f} must call trace_lifecycle_arm (arm the shared helper's terminal span)"

  # Must NOT define its own terminal EXIT-trap function ...
  if grep -qE '^trace__[A-Za-z0-9_]*_exit\(\)' "$f"; then
    note "${f} defines an inline trace__*_exit() trap function — extract it into trace-lib.sh trace_lifecycle_init instead"
  fi
  # ... nor install one via trap.
  if grep -qE 'trap[[:space:]]+.*trace__[A-Za-z0-9_]*_exit.*EXIT' "$f"; then
    note "${f} installs an inline trace__*_exit EXIT trap — use trace_lifecycle_init instead"
  fi
  # ... nor emit a lifecycle terminal span outside the helper via a hand-rolled trap.
  if grep -qE 'trace_span[[:space:]]+lifecycle' "$f" &&
     grep -qE '^trace__[A-Za-z0-9_]*_exit\(\)' "$f"; then
    note "${f} emits a lifecycle span from an inline trap — route it through trace_lifecycle_init"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "lifecycle-trap drift sensor FAILED"
  exit 1
fi
echo "lifecycle-trap drift checks passed"
