#!/usr/bin/env bash
# test_trace_schema.sh — regression sensor for the frozen trace schema v1
# contract (issue #92, feature trace-schema-v1-contract).
#
# docs/evaluation/trace-schema.v1.json is the machine-readable authority for the
# harness trace vocabulary (span types, required fields, closed lifecycle-step
# enum, trace-file path contract, redaction-by-reference). This sensor:
#
#   1. Asserts the contract file exists, parses as JSON, and declares
#      schema_version 1.
#   2. Reads the contract's constraint sections as data and checks them against
#      hardcoded backstop lists (so editing the contract cannot silently shrink
#      the frozen vocabulary):
#        .span_types        — exactly agent, model, tool, lifecycle
#        .required_common   — includes schema_version, timestamp, span,
#                             harness.issue, harness.version
#        .lifecycle_steps   — exactly the 13 frozen steps
#   3. Proves machine-checkability with a self-contained jq validation filter
#      that is driven entirely by the contract file (see the delimited
#      TRACE SPAN VALIDATION FILTER block — issue #97's standalone validator
#      should lift it unchanged): valid sample spans of all four types are
#      ACCEPTED, and each malformed case is REJECTED.
#   4. Asserts the contract declares the trace file path contract
#      (.copilot-tracking/issues/issue-NN/trace.jsonl) and references the
#      redaction authorities (security-evals.md, dataset-governance.md), and
#      that .gitignore still carries the covering local-only rule.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# jq is the subject of this sensor (the contract is jq-checkable by design), so
# hard-require it the way test_harness_contract.sh hard-requires awk.
command -v jq >/dev/null 2>&1 \
  || { printf 'FAIL: jq is required to validate the trace schema contract\n' >&2; exit 1; }

# --- 1. Contract exists, is valid JSON, declares schema_version 1 ------------
[ -f "$CONTRACT" ] \
  || { printf 'FAIL: contract not found at docs/evaluation/trace-schema.v1.json (%s)\n' "$CONTRACT" >&2; exit 1; }
jq empty "$CONTRACT" 2>/dev/null \
  || { printf 'FAIL: contract is not valid JSON: %s\n' "$CONTRACT" >&2; exit 1; }
jq -e 'type == "object"' "$CONTRACT" >/dev/null \
  || fail "contract top level must be a JSON object"
jq -e '.schema_version == 1' "$CONTRACT" >/dev/null \
  || fail "contract must declare top-level schema_version 1"

# --- 2. Closed vocabularies read from the contract, with hardcoded backstops -
# Backstop lists are intentionally duplicated here (sorted, order-insensitive
# compare) so a contract edit cannot silently weaken the frozen vocabulary.

expected_span_types='["agent","lifecycle","model","tool"]'
jq -e --argjson want "$expected_span_types" \
  '(.span_types | sort) == $want' "$CONTRACT" >/dev/null \
  || fail "contract .span_types must be exactly the 4 frozen span types: agent, model, tool, lifecycle"

expected_lifecycle_steps='["deviation","feature_start","finish","green_handback","impl_handback","plan_handback","pr_create","pr_merge","preflight","red_handback","review_gate_approve","review_verdict","worktree_create"]'
jq -e --argjson want "$expected_lifecycle_steps" \
  '(.lifecycle_steps | sort) == $want' "$CONTRACT" >/dev/null \
  || fail "contract .lifecycle_steps must be exactly the 13 frozen lifecycle steps"

required_common_backstop='["schema_version","timestamp","span","harness.issue","harness.version"]'
jq -e --argjson want "$required_common_backstop" \
  '(.required_common | type) == "array" and (($want - .required_common) | length == 0)' "$CONTRACT" >/dev/null \
  || fail "contract .required_common must include schema_version, timestamp, span, harness.issue, harness.version"

# Span linkage fields (issue #93, feature trace-schema-linkage-fields): the v1
# contract must declare span_id/parent_span_id as optional fields so the
# trace-lib emitter can stamp span linkage without a schema bump.
jq -e '(.optional_fields | type) == "object" and (.optional_fields | has("span_id") and has("parent_span_id"))' \
  "$CONTRACT" >/dev/null \
  || fail "contract .optional_fields must include the span linkage fields span_id and parent_span_id"

# --- 3. jq validation filter: contract-driven span accept/reject -------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

must_accept() {
  local label="$1" span="$2"
  validate_span "$span" || fail "valid ${label} span was rejected by the contract-driven jq filter"
}

must_reject() {
  local label="$1" span="$2"
  if validate_span "$span"; then
    fail "malformed span (${label}) was accepted by the contract-driven jq filter"
  fi
}

# Accept: one valid sample span per frozen span type.
must_accept "agent" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"agent","harness.issue":92,"harness.version":"0f3c1a2","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"implementation-subagent"}'
must_accept "model" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"model","harness.issue":92,"harness.version":"0f3c1a2","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000}'
must_accept "tool" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:02Z","span":"tool","harness.issue":92,"harness.version":"0f3c1a2","gen_ai.tool.name":"git"}'
must_accept "lifecycle" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:03Z","span":"lifecycle","harness.issue":92,"harness.version":"0f3c1a2","harness.lifecycle_step":"review_gate_approve"}'
# Span linkage (issue #93): optional span_id/parent_span_id ride the open-world
# extra-fields rule, so a span carrying both must stay accepted.
must_accept "tool with span linkage fields" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:08Z","span":"tool","harness.issue":93,"harness.version":"0f3c1a2","gen_ai.tool.name":"git","span_id":"20260704T120008-a1b2c3","parent_span_id":"20260704T120000-9f8e7d"}'

# Reject: each frozen failure mode must be refused.
must_reject "missing schema_version" \
  '{"timestamp":"2026-07-04T12:00:04Z","span":"tool","harness.issue":92,"harness.version":"0f3c1a2","gen_ai.tool.name":"gh"}'
must_reject "missing harness.version" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:05Z","span":"tool","harness.issue":92,"gen_ai.tool.name":"gh"}'
must_reject "unknown span type" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:06Z","span":"telemetry","harness.issue":92,"harness.version":"0f3c1a2"}'
must_reject "out-of-vocabulary lifecycle step" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:07Z","span":"lifecycle","harness.issue":92,"harness.version":"0f3c1a2","harness.lifecycle_step":"coffee_break"}'
must_reject "non-JSON line" \
  'this is not a json span line'

# --- 4. Trace file path contract, redaction references, gitignore rule -------
jq -e '[.. | strings | select(contains(".copilot-tracking/issues/issue-NN/trace.jsonl"))] | length > 0' \
  "$CONTRACT" >/dev/null \
  || fail "contract must declare the trace file path contract .copilot-tracking/issues/issue-NN/trace.jsonl"

jq -e '[.. | strings | select(contains("security-evals.md"))] | length > 0' "$CONTRACT" >/dev/null \
  || fail "contract must reference the redaction authority security-evals.md"
jq -e '[.. | strings | select(contains("dataset-governance.md"))] | length > 0' "$CONTRACT" >/dev/null \
  || fail "contract must reference the redaction authority dataset-governance.md"

grep -qF '.copilot-tracking/issues/issue-*/' "${ROOT}/.gitignore" \
  || fail ".gitignore no longer carries the .copilot-tracking/issues/issue-*/ local-only rule covering trace.jsonl"

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-schema contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace schema v1 contract honored\n'
