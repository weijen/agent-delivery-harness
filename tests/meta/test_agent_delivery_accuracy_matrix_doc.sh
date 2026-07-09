#!/usr/bin/env bash
# Regression sensor (issue #158): the agent-delivery accuracy matrix must
# distinguish delivery completion from correctness and map dashboard panels to
# the layered accuracy model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

matrix="docs/evaluation/agent-delivery-accuracy-matrix.md"
dashboard_readme="docs/evaluation/dashboards/README.md"

if [ ! -f "$matrix" ]; then
  note "missing $matrix"
  echo "agent-delivery accuracy matrix doc sensor FAILED"
  exit 1
fi

# Delivery completion is not the same as correctness/accuracy.
grep -Eiq 'merged' "$matrix" \
  || note "$matrix must use the literal token: merged"
grep -Eiq '(not[[:space:][:punct:]]+correct|not.*accuracy|completed,[[:space:]]*not|distinct from)' "$matrix" \
  || note "$matrix must distinguish merge completion from correctness/accuracy"

# Names the four metric layers.
grep -Eiq 'direct' "$matrix"      || note "$matrix must name the direct label layer"
grep -Eiq 'proxy' "$matrix"       || note "$matrix must name the proxy label layer"
grep -Eiq 'degradation' "$matrix" || note "$matrix must name the degradation signal layer"
grep -Eiq 'efficiency' "$matrix"  || note "$matrix must name the efficiency-after-quality layer"

# References the existing contract sources by exact filename.
for contract in \
  'trace-summary.v1.json' \
  'trace-scorecard.v1.json' \
  'evaluation-matrix.md' \
  'outcome-evals.md' \
  'product-quality-rubric.md' \
  'trajectory-evals.md' \
  'cost-efficiency-evals.md'; do
  grep -Fq "$contract" "$matrix" || note "$matrix must reference contract: $contract"
done

# Points to the machine-readable companion.
grep -Fq 'agent-delivery-accuracy-matrix.v1.json' "$matrix" \
  || note "$matrix must reference agent-delivery-accuracy-matrix.v1.json"

# Registers step-level logs (log.jsonl / log-schema.v1.json) as a per-run
# failure-detail evidence source with an explicit can/cannot-prove boundary.
{ grep -Fq 'log.jsonl' "$matrix" && grep -Fq 'log-schema.v1.json' "$matrix"; } \
  || note "$matrix must register log.jsonl (schema log-schema.v1.json) as an evidence source"
grep -Eiq 'failure.detail' "$matrix" \
  || note "$matrix must describe log.jsonl as a failure-detail evidence source"
grep -Eiq 'actual failing output' "$matrix" \
  || note "$matrix must say log.jsonl supplies the actual failing output behind a process/gate finding"
grep -Fiq 'detail stream' "$matrix" \
  || note "$matrix must describe log.jsonl as a detail stream"
grep -Eiq 'not itself a correctness label' "$matrix" \
  || note "$matrix must say the log stream is not itself a correctness label"
grep -Fiq 'log evidence unavailable' "$matrix" \
  || note "$matrix must say log absence is null (log evidence unavailable)"
grep -Eiq 'never zero failures' "$matrix" \
  || note "$matrix must say log absence is never zero failures"

# Anti-Goodhart rule: cost or merge-rate gains cannot offset quality regressions.
grep -Eiq 'goodhart' "$matrix" || note "$matrix must state the anti-Goodhart rule"
grep -Eiq 'cost.*(cannot|offset)|(cannot|offset).*cost' "$matrix" \
  || note "$matrix must say lower cost cannot offset quality regressions"
grep -Eiq 'merge' "$matrix" \
  || note "$matrix must say higher merge rate cannot offset quality regressions"

# Metric documentation requirements.
grep -Eiq 'numerator' "$matrix"   || note "$matrix must document metric numerators"
grep -Eiq 'denominator' "$matrix" || note "$matrix must document metric denominators"
grep -Eiq 'absence|coverage' "$matrix" \
  || note "$matrix must document absence/coverage handling"

# Blocking vs diagnostic policy.
grep -Eiq 'blocking' "$matrix"   || note "$matrix must document blocking policy"
grep -Eiq 'diagnostic' "$matrix" || note "$matrix must document diagnostic policy"

# Deferred metrics are honestly labeled.
grep -Eiq 'deferred' "$matrix" || note "$matrix must label deferred metrics"
grep -Eiq 'post_merge_bug_rate|review_blocking_finding_rate' "$matrix" \
  || note "$matrix must name at least one deferred metric"

# finish vs pr_merge distinction.
grep -Eiq 'finish' "$matrix"   || note "$matrix must distinguish finish"
grep -Eiq 'pr_merge' "$matrix" || note "$matrix must distinguish pr_merge"

if [ ! -f "$dashboard_readme" ]; then
  note "missing $dashboard_readme"
else
  grep -Eiq 'agent-delivery-accuracy-matrix' "$dashboard_readme" \
    || note "$dashboard_readme must reference agent-delivery-accuracy-matrix"
fi

if [ "$fail" -ne 0 ]; then
  echo "agent-delivery accuracy matrix doc sensor FAILED"
  exit 1
fi
echo "agent-delivery accuracy matrix doc checks passed"
