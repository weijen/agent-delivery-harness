#!/usr/bin/env bash
# Regression sensor (issue #46): the tester and reviewer subagent templates must
# encode STRICT, contract-guarding blocking criteria — not permissive,
# style-nitpick behaviour.
#
# This sensor fails if a future edit weakens either template below the
# guarantees issue #46 established:
#   - test-subagent: criterion->sensor mapping before passes:true; the three
#     blocking gap conditions; conductor-waiver-with-rationale-in-Action-Log.
#   - code-review-subagent: four separate verdicts (spec / sensor-adequacy /
#     code-quality / lifecycle+role-boundary); spec OR sensor-adequacy failure
#     blocks even when quality is clean; verify named sensors were actually run;
#     flag presence-only checks for behavioural requirements; BLOCKING tier with
#     blocking findings reported first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

test_agent=".copilot/agents/test-subagent.agent.md"
review=".copilot/agents/code-review-subagent.agent.md"

for f in "$test_agent" "$review"; do
  [ -f "$f" ] || note "missing $f"
done

# ---------------------------------------------------------------------------
# test-subagent — blocking criteria
# ---------------------------------------------------------------------------
if [ -f "$test_agent" ]; then
  # Acceptance-criterion / feature item -> concrete sensor mapping before passing.
  grep -Eqi 'map .*(acceptance criteri|feature.?list item).*sensor|(acceptance criteri|feature.?list item).*(map|mapped|mapping).*sensor' "$test_agent" ||
    note "$test_agent must require mapping each acceptance criterion/feature_list item to a concrete sensor before passes:true"

  # The three blocking gap conditions.
  grep -Eqi 'missing sensor coverage|no sensor coverage' "$test_agent" ||
    note "$test_agent must treat missing sensor coverage as blocking"
  grep -Eqi 'happy.?path.?only|only the happy path' "$test_agent" ||
    note "$test_agent must treat happy-path-only coverage of a required failure mode as blocking"
  grep -Eqi 'non.?executable|not runnable|non.?runnable|cannot be run' "$test_agent" ||
    note "$test_agent must treat non-executable validation as blocking"

  # These must be labelled BLOCKING.
  grep -q 'BLOCKING' "$test_agent" ||
    note "$test_agent must label these gaps as BLOCKING"

  # Waiver only by the conductor, with rationale in the Action Log.
  grep -Eqi 'waiv(e|ed|er)' "$test_agent" ||
    note "$test_agent must describe the conductor waiver path for a blocking gap"
  grep -Eqi 'rationale .*Action Log|Action Log .*rationale' "$test_agent" ||
    note "$test_agent must require the waiver rationale to be recorded in the Action Log"
fi

# ---------------------------------------------------------------------------
# code-review-subagent — four-verdict structure and blocking rules
# ---------------------------------------------------------------------------
if [ -f "$review" ]; then
  # Four separate, named verdicts — anchored to the actual headings so the
  # structure cannot be deleted while a loose substring (e.g. the frontmatter
  # description) keeps the sensor green.
  grep -Eqi '^### Verdict 1 .* Spec Compliance' "$review" ||
    note "$review must produce a spec-compliance verdict (Verdict 1 heading)"
  grep -Eqi '^### Verdict 2 .* (Sensor Adequacy|Test ?/ ?Sensor Adequacy)' "$review" ||
    note "$review must produce a test/sensor-adequacy verdict (Verdict 2 heading)"
  grep -Eqi '^### Verdict 3 .* (Code Quality|Maintainab)' "$review" ||
    note "$review must produce a code-quality/maintainability verdict (Verdict 3 heading)"
  grep -Eqi '^### Verdict 4 .* (Lifecycle|Role.?[Bb]oundary)' "$review" ||
    note "$review must produce a harness-lifecycle & role-boundary verdict (Verdict 4 heading)"
  grep -Eqi 'four .*verdict|four separate verdict' "$review" ||
    note "$review must state the verdicts are separate/four"

  # Spec OR sensor-adequacy failure blocks even when code quality is clean.
  grep -Eqi 'even (when|if).*(quality|code quality).*(clean|otherwise)|quality.*clean.*block|block.*quality.*clean' "$review" ||
    note "$review must state a failed spec OR sensor-adequacy verdict blocks approval even when code quality is clean"

  # Verify named sensors were actually RUN and results recorded.
  grep -Eqi 'actually (run|ran|executed)|were (run|ran|executed)|whether .*sensors? .*(run|ran|executed)' "$review" ||
    note "$review must require checking whether named sensors were actually run"
  grep -Eqi 'results? .*recorded|recorded .*(Action Log|result)' "$review" ||
    note "$review must require checking whether sensor results are recorded"

  # Presence-only checks are insufficient for behavioural requirements.
  grep -Eqi 'presence.?only' "$review" ||
    note "$review must flag presence-only checks as insufficient for behavioural requirements"
  grep -Eqi 'lifecycle order' "$review" ||
    note "$review presence-only flag must name lifecycle ordering"
  grep -Eqi 'hard.?(vs|-).?warn' "$review" ||
    note "$review presence-only flag must name hard-vs-warn exit semantics"
  # Scope review-gate to the enforcement context so the long-standing
  # "HEAD-bound review gate consumes" sentence cannot satisfy this check.
  grep -Eqi 'review.?gate[^A-Za-z]*enforcement|enforcement[^A-Za-z]*review.?gate' "$review" ||
    note "$review presence-only flag must name review-gate enforcement"
  grep -Eqi 'worktree cleanup' "$review" ||
    note "$review presence-only flag must name worktree cleanup"

  # BLOCKING severity tier, reported first.
  grep -q 'BLOCKING' "$review" ||
    note "$review must define a BLOCKING severity tier"
  grep -Eqi 'blocking .*(first|listed first)|listed first|blocking items first' "$review" ||
    note "$review must require blocking findings to be listed first"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "tester/reviewer blocking-criteria checks passed"
