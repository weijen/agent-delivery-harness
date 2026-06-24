#!/usr/bin/env bash
# Regression sensor (issue #82): the functionality product-quality rubric must
# define blocking gates, scorecard dimensions, 0/1/2 scoring anchors, score
# interpretation (FAIL/NEEDS_REVISION/PASS/STRONG_PASS), and handback routing.
#
# This sensor fails if the rubric file is missing or lacks required sections so
# the rubric cannot silently lose its contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Subcommand dispatch (for future features: examples, test-subagent,
# code-review-subagent, lifecycle-docs, evaluation-readme, all).
subcommand="${1:-all}"

test_doc() {
  local fail=0
  local note_fn="$1"
  local doc="docs/evaluation/product-quality-rubric.md"

  [ -f "$doc" ] || { "$note_fn" "missing $doc"; return 1; }

  # Definition of functionality product quality.
  grep -Eqi 'functionality.*product quality|product quality.*functionality' "$doc" ||
    "$note_fn" "$doc must define 'functionality product quality'"

  # Blocking gates section with the four named gates.
  grep -Eqi 'blocking gate' "$doc" ||
    "$note_fn" "$doc must document blocking gates"
  grep -Eqi 'spec fidelity' "$doc" ||
    "$note_fn" "$doc must name 'spec fidelity' as a blocking gate"
  grep -Eqi 'executable verification' "$doc" ||
    "$note_fn" "$doc must name 'executable verification' as a blocking gate"
  grep -Eqi 'main workflow works' "$doc" ||
    "$note_fn" "$doc must name 'main workflow works' as a blocking gate"
  grep -Eqi 'no known critical breakage' "$doc" ||
    "$note_fn" "$doc must name 'no known critical breakage' as a blocking gate"

  # Scorecard with six dimensions.
  grep -Eqi 'scorecard|score ?card' "$doc" ||
    "$note_fn" "$doc must document a scorecard"
  grep -Eqi 'workflow completeness' "$doc" ||
    "$note_fn" "$doc scorecard must include 'workflow completeness' dimension"
  grep -Eqi 'failure.*edge handling|edge.*failure handling' "$doc" ||
    "$note_fn" "$doc scorecard must include 'failure and edge handling' dimension"
  grep -Eqi 'state.*data coherence|data.*state coherence' "$doc" ||
    "$note_fn" "$doc scorecard must include 'state and data coherence' dimension"
  grep -Eqi 'integration depth' "$doc" ||
    "$note_fn" "$doc scorecard must include 'integration depth' dimension"
  grep -Eqi 'recoverability.*operability|operability.*recoverability' "$doc" ||
    "$note_fn" "$doc scorecard must include 'recoverability and operability' dimension"
  grep -Eqi 'verification adequacy' "$doc" ||
    "$note_fn" "$doc scorecard must include 'verification adequacy' dimension"

  # 0/1/2 scoring or score anchors.
  if ! grep -Eqi '\b0\b.*\b1\b.*\b2\b|\b2\b.*\b1\b.*\b0\b' "$doc" &&
     ! grep -Eqi 'score anchor|scoring anchor' "$doc"; then
    "$note_fn" "$doc must document 0/1/2 scoring or score anchors"
  fi

  # Score interpretation with four outcomes.
  grep -Eqi 'scor(e|ing).*(interpretation|interpret)|(interpretation|interpret).*scor(e|ing)' "$doc" ||
    "$note_fn" "$doc must document score interpretation"
  grep -Eqi '\bFAIL\b' "$doc" ||
    "$note_fn" "$doc score interpretation must include FAIL"
  grep -Eqi 'NEEDS_REVISION|NEEDS REVISION' "$doc" ||
    "$note_fn" "$doc score interpretation must include NEEDS_REVISION"
  grep -Eqi '\bPASS\b' "$doc" ||
    "$note_fn" "$doc score interpretation must include PASS"
  grep -Eqi 'STRONG_PASS|STRONG PASS' "$doc" ||
    "$note_fn" "$doc score interpretation must include STRONG_PASS"

  # Handback routing to the three roles.
  grep -Eqi 'handback routing|routing handback' "$doc" ||
    "$note_fn" "$doc must document handback routing"
  grep -Eqi 'implementation-subagent' "$doc" ||
    "$note_fn" "$doc handback routing must mention implementation-subagent"
  grep -Eqi 'test-subagent' "$doc" ||
    "$note_fn" "$doc handback routing must mention test-subagent"
  grep -Eqi 'conductor.*human|human.*gate' "$doc" ||
    "$note_fn" "$doc handback routing must mention conductor/human gate"

  return "$fail"
}

test_examples() {
  local fail=0
  local note_fn="$1"
  local doc="docs/evaluation/product-quality-rubric.md"

  [ -f "$doc" ] || { "$note_fn" "missing $doc"; return 1; }

  # Examples or calibration section.
  if ! grep -Eqi 'example|calibration' "$doc"; then
    "$note_fn" "$doc must include examples or calibration section"
  fi

  # Good evaluation example.
  if ! grep -Eqi 'good.*example|example.*good|strong.*example|example.*strong' "$doc"; then
    "$note_fn" "$doc must include a good/strong evaluation example"
  fi

  # Bad evaluation example.
  if ! grep -Eqi 'bad.*example|example.*bad|weak.*example|example.*weak|fail.*example|example.*fail' "$doc"; then
    "$note_fn" "$doc must include a bad/weak/fail evaluation example"
  fi

  # Edge-case or waiver example.
  if ! grep -Eqi 'edge.*example|example.*edge|waiver.*example|example.*waiver|needs.revision.*example|example.*needs.revision' "$doc"; then
    "$note_fn" "$doc must include an edge-case or waiver example"
  fi

  # Examples include feature/acceptance context.
  if ! grep -Eqi 'feature.*context|acceptance.*criteri|issue.*\#[0-9]|F[0-9]+' "$doc"; then
    "$note_fn" "$doc examples must include feature or acceptance context"
  fi

  # Examples include sensors and results or sensor evidence.
  if ! grep -Eqi 'sensor|test.*result|regression.*sensor|e2e.*sensor' "$doc"; then
    "$note_fn" "$doc examples must include sensors and run results or sensor evidence"
  fi

  # Examples include blocking gate results.
  if ! grep -Eqi 'gate.*pass|gate.*fail|gate.*result|spec fidelity.*pass|spec fidelity.*fail|executable verification.*pass|executable verification.*fail' "$doc"; then
    "$note_fn" "$doc examples must include blocking gate results"
  fi

  # Examples include scorecard results or dimension scores.
  if ! grep -Eqi 'scorecard.*[0-2]|dimension.*score|workflow completeness.*[0-2]|total.*score' "$doc"; then
    "$note_fn" "$doc examples must include scorecard results or dimension scores"
  fi

  # Examples include routeable handbacks.
  if ! grep -Eqi 'handback.*implementation|handback.*test|handback.*conductor' "$doc"; then
    "$note_fn" "$doc examples must include routeable handbacks"
  fi

  # Calibration guidance for 0/1/2 score boundaries.
  if ! grep -Eqi 'calibration|score.*anchor|0.*vs.*1|1.*vs.*2|distinguish.*[0-2]|boundary.*[0-2]' "$doc"; then
    "$note_fn" "$doc must include calibration guidance for 0/1/2 score boundaries"
  fi

  return "$fail"
}

case "$subcommand" in
  doc)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_doc note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric doc checks pass"
    ;;
  examples)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_examples note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric examples checks pass"
    ;;
  all)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_doc note
    test_examples note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ all product-quality rubric checks pass"
    ;;
  *)
    echo "unknown subcommand: $subcommand" >&2
    echo "usage: $0 {doc|examples|all}" >&2
    exit 1
    ;;
esac
