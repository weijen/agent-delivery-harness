#!/usr/bin/env bash
# Regression sensor (issue #181): the create-pr skill must codify THIS repo's
# issue-driven harness conventions, not the generic PR advice it shipped with.
# Guards against a future edit reverting to `<type>/<short-description>` branches
# or dropping the CI-green merge discipline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

f=".copilot/skills/create-pr/SKILL.md"
[ -f "$f" ] || { echo "✗ missing $f"; exit 1; }

# --- Repo-specific conventions are named ---
grep -Eq 'feature/issue-<?NN>?-' "$f"        || note "$f must name the feature/issue-<NN>-<slug> branch convention"
grep -Eq 'start-issue\.sh' "$f"              || note "$f must reference scripts/start-issue.sh"
grep -Eq 'feat\(#|fix\(#' "$f"               || note "$f must show the issue-scoped Conventional Commit style (e.g. feat(#NN))"
grep -Eiq 'merge-pr\.sh' "$f"                || note "$f must reference scripts/merge-pr.sh"
grep -Eiq 'gh pr checks|CI (run )?is green|green CI' "$f" \
                                             || note "$f must state the CI-green merge precondition"
grep -Eiq 'Closes #' "$f"                    || note "$f must keep the Closes #<NN> issue link"

# --- Generic advice that #177/#181 removed must not creep back ---
grep -Eq '<type>/<short-description>' "$f"   && note "$f must not reintroduce the generic <type>/<short-description> branch advice"
grep -Eiq 'git add -A' "$f" && ! grep -Eiq 'never blanket-stage|never .*git add -A' "$f" \
                                             && note "$f must not advocate git add -A (public-exposure hygiene)"

if [ "$fail" -ne 0 ]; then
  echo "create-pr conventions sensor FAILED"
  exit 1
fi
echo "create-pr conventions checks passed"
