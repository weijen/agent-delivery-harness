#!/usr/bin/env bash
# Meta guard for issue #272 feature `delete-orphaned-tests`.
#
# The cloud export leg (trace/log export + trace-reconstruct + the trace_tools
# Python pilot) was deleted. This guard fails if any test under tests/ still
# references a deleted script or a removed finish-lib helper — a stale reference
# would mean an orphaned test that can never pass, or dead coupling that would
# re-grow the leg.
#
# The two deletion GUARDS themselves legitimately name the removed artifacts (to
# assert their absence); they are the only allowed references.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Basenames / symbols that must no longer appear in any non-guard test.
patterns='trace-export\.sh|log-export\.sh|gen-export-env\.sh|sanitize-trace\.sh|trace-reconstruct\.sh|trace_tools|best_effort_trace_export|best_effort_log_export|best_effort_trace_reconstruct'

# Guards allowed to name the removed artifacts.
allow='tests/scripts/test_export_leg_removed.sh|tests/meta/test_no_deleted_export_refs.sh'

offenders="$(grep -rlE "$patterns" tests/ --include='*.sh' 2>/dev/null | grep -vE "$allow" || true)"

if [ -n "$offenders" ]; then
  echo "FAIL: these tests still reference the deleted export/reconstruct leg:"
  printf '%s\n' "$offenders" | sed 's/^/  /'
  exit 1
fi

echo "no test references a deleted export/reconstruct script or removed finish-lib helper"
