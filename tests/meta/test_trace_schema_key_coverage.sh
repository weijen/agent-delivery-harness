#!/usr/bin/env bash
# test_trace_schema_key_coverage.sh — regression sensor for issue #132,
# feature schema-key-coverage.
#
# The frozen trace schema contract (docs/evaluation/trace-schema.v1.json) is
# the single vocabulary authority, but it is open-world: trace-lib appends
# unknown keys without complaint, so the DOCUMENTED vocabulary can silently
# drift below what the harness actually EMITS. This sensor closes that gap:
# every harness.* / gen_ai.* attribute key emitted by a trace_span call under
# scripts/ (lifecycle scripts AND both runtime hooks) MUST be documented in
# the contract as one of
#   - a .required_common member,
#   - a value in .required_by_span (a per-span required attribute), or
#   - a .optional_fields key.
#
# When a new emission introduces an undocumented key, this test fails and
# names it, so the author either documents it in the contract or justifies a
# deny-list entry. gen_ai.usage.* token buckets are documented explicitly in
# required_by_span, so no prefix special-casing is needed here.
#
# Exit codes: 0 every emitted key is documented · 1 an undocumented key exists.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
SCRIPTS="${ROOT}/scripts"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

command -v jq >/dev/null 2>&1 \
  || { printf 'FAIL: jq is required to read the trace schema contract\n' >&2; exit 1; }
[ -f "$CONTRACT" ] \
  || { printf 'FAIL: contract not found (%s)\n' "$CONTRACT" >&2; exit 1; }
jq empty "$CONTRACT" 2>/dev/null \
  || { printf 'FAIL: contract is not valid JSON (%s)\n' "$CONTRACT" >&2; exit 1; }
[ -d "$SCRIPTS" ] \
  || { printf 'FAIL: scripts dir not found (%s)\n' "$SCRIPTS" >&2; exit 1; }

# --- Documented vocabulary: everything the contract names --------------------
documented="${TMP_DIR}/documented"
jq -r '
  (.required_common[]),
  (.required_by_span | to_entries[] | .value[]),
  (.optional_fields | keys[])
' "$CONTRACT" | sort -u > "$documented"

# --- Emitted vocabulary: every harness.*/gen_ai.* key on a trace_span attr ---
# Match the literal "<key>= shape that trace_span attribute arguments use
# across the lifecycle scripts and both runtime hooks. Strip the leading
# quote and the trailing =<value...>.
emitted="${TMP_DIR}/emitted"
grep -rhoE '"(harness|gen_ai)\.[a-z_.]+=' "$SCRIPTS" \
  | sed -E 's/^"//; s/=.*$//' \
  | sort -u > "$emitted"

if [ ! -s "$emitted" ]; then
  printf 'FAIL: no emitted harness.*/gen_ai.* keys found under scripts/ — the grep contract broke\n' >&2
  exit 1
fi

# --- Every emitted key must be documented ------------------------------------
undocumented="$(comm -23 "$emitted" "$documented" || true)"

if [ -n "$undocumented" ]; then
  printf 'FAIL: emitted trace keys missing from the contract (add to optional_fields or justify):\n' >&2
  printf '%s\n' "$undocumented" | sed 's/^/  /' >&2
  exit 1
fi

printf 'PASS: all %s emitted trace keys are documented in the contract\n' "$(wc -l < "$emitted" | tr -d ' ')"
exit 0
