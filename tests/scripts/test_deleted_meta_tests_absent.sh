#!/usr/bin/env bash
# Regression sensor (issue #273, feature deletions-executed): the DELETE-class
# phrase-pinning / doc-snapshot meta-tests must be gone, and no surviving test,
# lib helper, or fixture may still reference a removed test. This is a machine
# guard (no prose), consistent with the triage rubric.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

# Files removed by #273 (basenames, no path — they must not exist under tests/).
deleted_meta=(
  test_instructions_no_stale_repetition
  test_instructions_product_generic
  test_no_antiderailment_scaffolding
  test_copilot_spike_doc_measured_v1_0_70
  test_devcontainer_optional
  test_planner_web_fallback
  test_agent_delivery_accuracy_matrix_doc
  test_docs_health_check_superseded
  test_failure_review_template
  test_scripts_language_policy_doc
)
deleted_scripts=(
  test_trace_scorecard_docs
  test_claude_adapter_docs
  test_copilot_adapter_docs
  test_ci_coverage_docs
  test_docs_profile_boundaries
)

# 1. The files themselves must be absent.
for b in "${deleted_meta[@]}"; do
  [ -e "tests/meta/${b}.sh" ] && note "tests/meta/${b}.sh must be deleted (#273)"
done
for b in "${deleted_scripts[@]}"; do
  [ -e "tests/scripts/${b}.sh" ] && note "tests/scripts/${b}.sh must be deleted (#273)"
done

# 2. No surviving file under tests/ may reference a deleted test by basename.
#    (This sensor references them only inside the arrays above; allowlist self.)
self="$(basename "${BASH_SOURCE[0]}")"
for b in "${deleted_meta[@]}" "${deleted_scripts[@]}"; do
  hits="$(grep -rlF "${b}" tests/ 2>/dev/null | grep -vF "$self" || true)"
  if [ -n "$hits" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] && note "stale reference to deleted ${b} in $h"
    done <<<"$hits"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "deleted-meta-tests sensor FAILED"
  exit 1
fi
echo "deleted-meta-tests sensor passed (15 DELETE-class files absent, no stale refs)"
