#!/usr/bin/env bash
# Regression sensor (issue #242, feature F1): §7 of the Copilot subagent
# spike doc must record the CLI v1.0.70 MEASURED Path O exporter contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

doc="docs/runtime-adapters/github-copilot.subagent-spike.md"

if [ ! -f "$doc" ]; then
  note "missing $doc"
  echo "copilot spike doc v1.0.70 measured checks FAILED"
  exit 1
fi

sec7="$(awk '
  /^## §7[[:space:]]/ { in_sec = 1 }
  /^## / && in_sec && $0 !~ /^## §7[[:space:]]/ { exit }
  in_sec { print }
' "$doc")"
sec7_flat="$(printf '%s\n' "$sec7" | tr '\n' ' ')"
measured_v1070='(v1\.0\.70.*MEASURED|MEASURED.*v1\.0\.70)'

require_sec7_pattern() {
  local label="$1"
  local pattern="$2"

  if ! printf '%s\n' "$sec7_flat" | grep -Eq "$pattern"; then
    note "$doc §7 must document: $label"
  fi
}

if [ -z "$sec7" ]; then
  note "$doc must contain a §7 Path O section"
else
  require_sec7_pattern \
    "a v1.0.70 version stamp and literal MEASURED token" \
    "$measured_v1070"

  require_sec7_pattern \
    "v1.0.70 MEASURED span-line attributes object and metric dataPoints/no .attributes contract" \
    "($measured_v1070.*attributes.*object.*metric.*(no|not|without).*\.attributes.*dataPoints|$measured_v1070.*attributes.*object.*metric.*dataPoints.*(no|not|without).*\.attributes|attributes.*object.*metric.*(no|not|without).*\.attributes.*dataPoints.*$measured_v1070|attributes.*object.*metric.*dataPoints.*(no|not|without).*\.attributes.*$measured_v1070)"

  require_sec7_pattern \
    "v1.0.70 MEASURED flush order: append order equals span-END order, children before parent" \
    "($measured_v1070.*append order.*span-?END.*children.*before.*parents?|$measured_v1070.*span-?END.*append order.*children.*before.*parents?|append order.*span-?END.*children.*before.*parents?.*$measured_v1070|span-?END.*append order.*children.*before.*parents?.*$measured_v1070)"

  require_sec7_pattern \
    "v1.0.70 MEASURED structural join toolu_ → execute_tool gen_ai.tool.call.id → child invoke_agent parentSpanId → gen_ai.agent.name" \
    "($measured_v1070.*toolu_.*gen_ai\.tool\.call\.id.*invoke_agent.*parentSpanId.*gen_ai\.agent\.name|$measured_v1070.*toolu_.*gen_ai\.tool\.call\.id.*parentSpanId.*invoke_agent.*gen_ai\.agent\.name|toolu_.*gen_ai\.tool\.call\.id.*invoke_agent.*parentSpanId.*gen_ai\.agent\.name.*$measured_v1070|toolu_.*gen_ai\.tool\.call\.id.*parentSpanId.*invoke_agent.*gen_ai\.agent\.name.*$measured_v1070)"
fi

if [ "$fail" -ne 0 ]; then
  echo "copilot spike doc v1.0.70 measured checks FAILED"
  exit 1
fi
echo "copilot spike doc v1.0.70 measured checks passed"
