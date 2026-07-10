#!/usr/bin/env bash
# Regression sensor: recurring failure-review template (issue #99,
# feature failure-review-template, plan Phase 4).
#
# docs/evaluation/failure-review-template.md is the repeatable
# observe→diagnose ritual that clusters recent failure spans by the frozen
# taxonomy (docs/evaluation/failure-mode-taxonomy.md) and produces
# issue-ready diagnoses. This sensor pins the template's load-bearing
# sections (grep-style, prose wording otherwise free):
#
#   * a review-window section (date range / issues covered);
#   * data-pull instructions naming the two real data sources —
#     scripts/trace-report.sh (deviations rollup) and
#     scripts/validate-trace.sh — and the harness.failure_mode attribute;
#   * a cluster table with mode | count | issues | diagnosis columns;
#   * per-cluster diagnosis prompting;
#   * a filed-follow-ups section: every proposed harness change is a NORMAL
#     GitHub issue citing taxonomy evidence;
#   * a Non-Goals footer restating the governance stance: human-gated,
#     no automated harness mutation;
#   * a cross-link to failure-mode-taxonomy.md (vocabulary authority).
#
# It also pins the one-line governance cross-ref: dataset-governance.md
# must reference the fixture flow (tests/evals/fixtures/traces/) so the
# failure-corpus cadence points at the mechanism that feeds it.
#
# This sensor fails if the template is missing, later drops a section, or
# the governance cross-ref disappears.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

TEMPLATE="docs/evaluation/failure-review-template.md"
GOVERNANCE="docs/evaluation/dataset-governance.md"

# --- 1. Template exists with its load-bearing sections ------------------------
if [ ! -f "$TEMPLATE" ]; then
	note "missing $TEMPLATE (feature failure-review-template: the recurring failure-review ritual has no template)"
else
	# Review window: what period / which issues the review covers.
	if ! grep -qiE 'review[- ]window' "$TEMPLATE"; then
		note "$TEMPLATE must contain a review-window section (date range / issues covered)"
	fi

	# Data pull: the rollup comes from the existing tooling, not ad-hoc greps.
	if ! grep -q 'trace-report\.sh' "$TEMPLATE"; then
		note "$TEMPLATE must name scripts/trace-report.sh as the deviations/failure_mode rollup source"
	fi
	if ! grep -q 'validate-trace\.sh' "$TEMPLATE"; then
		note "$TEMPLATE must name scripts/validate-trace.sh as a data source (violation findings feed the review)"
	fi
	if ! grep -q 'harness\.failure_mode' "$TEMPLATE"; then
		note "$TEMPLATE must reference the harness.failure_mode span attribute the clustering keys on"
	fi
	if ! grep -qi 'deviation' "$TEMPLATE"; then
		note "$TEMPLATE must reference deviation spans (the failure signal being clustered)"
	fi

	# Cluster table: mode | count | issues | diagnosis on one table row.
	if ! grep -iE '^\|' "$TEMPLATE" | grep -i 'mode' | grep -i 'count' | grep -i 'issue' | grep -qi 'diagnos'; then
		note "$TEMPLATE must contain a cluster table with mode | count | issues | diagnosis columns"
	fi

	# Per-cluster diagnosis prompting.
	if ! grep -qiE '(per[- ]cluster|each cluster).*diagnos|diagnos.*(per[- ]cluster|each cluster)' "$TEMPLATE"; then
		note "$TEMPLATE must prompt for a diagnosis per cluster (observe→diagnose is the point of the ritual)"
	fi

	# Filed follow-ups: normal GitHub issues citing taxonomy evidence.
	if ! grep -qiE 'follow[- ]ups?' "$TEMPLATE"; then
		note "$TEMPLATE must contain a filed-follow-ups section"
	fi
	if ! grep -qiE 'github issue' "$TEMPLATE"; then
		note "$TEMPLATE must state that proposed harness changes are filed as normal GitHub issues"
	fi
	if ! grep -qi 'evidence' "$TEMPLATE"; then
		note "$TEMPLATE must state that filed issues cite taxonomy/trace evidence"
	fi

	# Non-Goals footer: the governance stance travels with the ritual.
	if ! grep -qiE 'non[- ]goals' "$TEMPLATE"; then
		note "$TEMPLATE must carry a Non-Goals footer"
	fi
	if ! grep -qiE 'automated harness mutation' "$TEMPLATE"; then
		note "$TEMPLATE Non-Goals must restate: no automated harness mutation"
	fi
	if ! grep -qiE 'human[- ]gated' "$TEMPLATE"; then
		note "$TEMPLATE must restate the human-gated governance stance"
	fi

	# Vocabulary authority cross-link.
	if ! grep -qF 'failure-mode-taxonomy.md' "$TEMPLATE"; then
		note "$TEMPLATE must cross-link failure-mode-taxonomy.md (the taxonomy prose authority)"
	fi
fi

# --- 2. Governance cross-ref: dataset-governance.md -> fixture flow ---
if [ ! -f "$GOVERNANCE" ]; then
	note "missing $GOVERNANCE"
elif ! grep -qE 'tests/evals/fixtures/traces' "$GOVERNANCE"; then
	note "$GOVERNANCE must cross-reference the fixture flow (tests/evals/fixtures/traces/) from its failure-corpus cadence"
fi

if [ "$fail" -ne 0 ]; then
	echo "failure-review-template contract regressed"
	exit 1
fi
echo "✓ failure-review template + governance cross-ref honored"
