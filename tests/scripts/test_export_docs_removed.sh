#!/usr/bin/env bash
# Regression sensor for issue #272 feature `docs-and-infra-sweep`.
#
# The cloud trace/log export leg was deleted. This sensor pins the docs + infra
# sweep that must accompany that deletion:
#   1. The App Insights *workbook* Terraform is GONE (resource + serialized JSON)
#      and a dated decommission note is retained in its place.
#   2. The runtime-adapter export doc is reframed to "decommissioned by #272"
#      while it KEEPS the OTel attribute-name mapping (the exit-ramp contract).
#   3. The trace/log SCHEMAS stay documented — they are the future exit ramp and
#      must NOT be deleted with the export leg.
#
# RED before the sweep (workbook present / doc still claims a live exporter /
# schema deleted), GREEN once the sweep lands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

# --- 1. Workbook Terraform decommissioned ------------------------------------
[ ! -f infra/terraform/workbook.tf ] \
  || fail "infra/terraform/workbook.tf must be deleted (workbook decommissioned by #272)"
[ ! -f infra/terraform/harness-quality.workbook.json ] \
  || fail "infra/terraform/harness-quality.workbook.json must be deleted (workbook decommissioned by #272)"
if ! grep -rqiE 'decommission' infra/terraform/*.md 2>/dev/null; then
  fail "infra/terraform must retain a dated workbook decommission note (a *.md naming the decommission)"
fi

# --- 2. Export runtime-adapter doc reframed as decommissioned ----------------
OTLP="docs/runtime-adapters/otlp-azure-monitor.md"
if [ -f "$OTLP" ]; then
  grep -qiE 'decommissioned by #272|issue #272 removed' "$OTLP" \
    || fail "$OTLP must state the export leg was decommissioned by #272"
  grep -qiE 'attribute-name mapping|attribute name mapping|exit-ramp contract' "$OTLP" \
    || fail "$OTLP must retain the OTel attribute-name mapping / exit-ramp contract"
else
  fail "$OTLP missing — the attribute-name mapping exit ramp must be retained (not deleted)"
fi

# --- 3. Schemas retained (the exit ramp) -------------------------------------
[ -f docs/evaluation/trace-schema.v1.json ] \
  || fail "docs/evaluation/trace-schema.v1.json must be kept (exit-ramp schema)"

if [ "$fails" -ne 0 ]; then
  printf '\n%d export docs/infra sweep violation(s).\n' "$fails" >&2
  exit 1
fi
echo "export docs + infra decommission sweep verified"
