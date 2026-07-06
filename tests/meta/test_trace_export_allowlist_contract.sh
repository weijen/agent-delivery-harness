#!/usr/bin/env bash
# test_trace_export_allowlist_contract.sh — regression sensor for issue #132,
# feature export-allowlist-contract.
#
# scripts/trace-export.sh ships an allowlisted subset of span attributes to
# Application Insights (customDimensions / measurements). Deny-by-default keeps
# free-text and unknown keys out, but an allowlisted key that is NOT documented
# in the frozen contract is a silent drift: it reaches the sink without ever
# being reviewed against docs/evaluation/trace-schema.v1.json. This sensor
# asserts the invariant allowlist ⊆ documented-contract-keys, so no key can be
# shipped that the contract does not name.
#
# The complementary direction (every EMITTED key is documented) is covered by
# test_trace_schema_key_coverage.sh; the two guard independent drifts.
#
# Exit codes: 0 allowlist is a subset of the documented vocabulary · 1 an
# allowlisted key is undocumented.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
EXPORT="${ROOT}/scripts/trace-export.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

command -v jq >/dev/null 2>&1 \
  || { printf 'FAIL: jq is required to read the trace schema contract\n' >&2; exit 1; }
[ -f "$CONTRACT" ] \
  || { printf 'FAIL: contract not found (%s)\n' "$CONTRACT" >&2; exit 1; }
[ -f "$EXPORT" ] \
  || { printf 'FAIL: trace-export.sh not found (%s)\n' "$EXPORT" >&2; exit 1; }

# --- Documented vocabulary: everything the contract names --------------------
documented="${TMP_DIR}/documented"
jq -r '
  (.required_common[]),
  (.required_by_span | to_entries[] | .value[]),
  (.optional_fields | keys[])
' "$CONTRACT" | sort -u > "$documented"

# --- Allowlist: the concrete quoted keys in trace-export.sh's `def allowlist` -
# Slice from `def allowlist:` to the first `];` and pull the quoted tokens.
# The gen_ai.usage.* PREFIX rule lives in shippable_key (startswith), not in
# this array, and its concrete keys are documented via required_by_span, so
# the array holds only concrete keys that must each be documented.
allowlist="${TMP_DIR}/allowlist"
sed -n '/def allowlist:/,/\];/p' "$EXPORT" \
  | grep -oE '"[A-Za-z0-9_.]+"' \
  | tr -d '"' \
  | sort -u > "$allowlist"

if [ ! -s "$allowlist" ]; then
  printf 'FAIL: could not extract the allowlist from scripts/trace-export.sh — the def allowlist shape changed\n' >&2
  exit 1
fi

# --- allowlist ⊆ documented --------------------------------------------------
undocumented="$(comm -23 "$allowlist" "$documented" || true)"

if [ -n "$undocumented" ]; then
  printf 'FAIL: trace-export allowlist entries not documented in the contract (document them or drop from the allowlist):\n' >&2
  printf '%s\n' "$undocumented" | sed 's/^/  /' >&2
  exit 1
fi

printf 'PASS: all %s trace-export allowlist keys are documented in the contract\n' "$(wc -l < "$allowlist" | tr -d ' ')"
exit 0
