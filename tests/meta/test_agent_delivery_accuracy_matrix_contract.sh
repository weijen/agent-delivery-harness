#!/usr/bin/env bash
# RED sensor (issue #158): the agent-delivery accuracy matrix must be a
# machine-readable, self-describing contract with honest denominator and
# absence semantics for every metric.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CONTRACT="$ROOT/docs/archive/evaluation/agent-delivery-accuracy-matrix.v1.json"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf 'NOTE: %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate the agent-delivery accuracy matrix contract"

[ -f "$CONTRACT" ] \
  || fail "accuracy matrix contract not found: $CONTRACT"

jq empty "$CONTRACT" >/dev/null \
  || fail "accuracy matrix contract is not valid JSON: $CONTRACT"

jq -e '.matrix_schema_version == 1' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix .matrix_schema_version must equal 1"

jq -e '
  . as $root
  | (.required_top_level | type == "array" and length > 0)
    and all($root.required_top_level[]; . as $key | $root | has($key))
' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix .required_top_level must be non-empty and every named key must exist at top level"

allowed_layers_json='["direct_label","proxy_label","degradation_signal","efficiency_after_quality"]'

jq -e --argjson allowed "$allowed_layers_json" '
  def layer_id:
    if type == "string" then .
    elif type == "object" then (.id // .layer // empty)
    else empty
    end;
  def sorted_unique: sort | unique;
  (.layers // .notes.layers) as $layers
  | ($layers | type == "array")
    and ([$layers[] | layer_id] | sorted_unique) == ($allowed | sorted_unique)
' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix layers must contain exactly direct_label, proxy_label, degradation_signal, efficiency_after_quality"

jq -e '.metrics | type == "array" and length >= 12' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix .metrics must be an array with at least 12 metric entries"

metric_missing_key() {
  local key="$1"
  jq -r --arg key "$key" '
    def nonempty:
      if type == "string" then length > 0
      elif type == "array" then length > 0
      elif type == "object" then length > 0
      elif . == null then false
      else true
      end;
    .metrics[]
    | select((has($key) | not) or (.[$key] | nonempty | not))
    | (.id // "<missing-id>")
  ' "$CONTRACT" | head -n 1
}

required_metric_keys=(
  id
  layer
  numerator
  denominator
  source
  coverage_required
  absence_semantics
  blocking_policy
  goodhart_guard
)

for key in "${required_metric_keys[@]}"; do
  offender="$(metric_missing_key "$key")"
  [ -z "$offender" ] \
    || fail "accuracy matrix metric '$offender' lacks non-empty '$key'"
done

jq -e --argjson allowed "$allowed_layers_json" '
  all(.metrics[]; (.layer as $layer | $allowed | index($layer) != null))
' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix metric layer values must be one of the four allowed layer ids"

jq -e '[.metrics[].id] as $ids | ($ids | length) == ($ids | unique | length)' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix metric ids must be unique across .metrics[]"

jq -e --argjson allowed "$allowed_layers_json" '
  .metrics as $metrics
  | all($allowed[]; . as $layer | any($metrics[]; .layer == $layer))
' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix metrics must include at least one metric for each allowed layer"

jq -e '
  all(.metrics[]; (.blocking_policy | tostring | ascii_downcase | test("^(blocking|diagnostic|deferred)$")))
' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix metric blocking_policy values must match blocking, diagnostic, or deferred"

jq -e '
  any(.metrics[]; (.blocking_policy | tostring | ascii_downcase | test("deferred")))
' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix must mark at least one metric blocking_policy as deferred"

jq -e '
  (.notes | type == "object")
  and any(.notes | keys[]; test("goodhart"; "i"))
  and any(.notes | keys[]; test("absence"; "i"))
' "$CONTRACT" >/dev/null \
  || fail "accuracy matrix .notes must include keys covering anti-Goodhart and absence semantics"

note "validated $CONTRACT"
printf 'PASS: agent-delivery accuracy matrix contract honored\n'
