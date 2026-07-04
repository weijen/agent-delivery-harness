#!/usr/bin/env bash
# test_trace_schema_docs.sh — regression sensor for trace-schema docs single
# source of truth (issue #92, feature trace-schema-docs-single-source).
#
# docs/evaluation/trace-schema.v1.json is the machine-readable authority for
# the trace vocabulary. The prose doc docs/evaluation/observability-and-trace-schema.md
# must defer to it instead of carrying a second, driftable copy. This sensor
# asserts:
#
#   1. The prose doc references trace-schema.v1.json (link or path mention).
#   2. No competing vocabulary in the prose doc:
#        - it does NOT duplicate the complete closed lifecycle-step
#          enumeration (a few illustrative step names are fine; all of them
#          reproduced is a second normative copy that can drift);
#        - every gen_ai.* / harness.* span-attribute name the doc still
#          mentions exists in the contract (exact name, or a namespace prefix
#          of a contract attribute, e.g. `gen_ai.usage.*`);
#        - the doc mentions the new mandatory fields `schema_version` and
#          `harness.version`, so the prose is not stale relative to v1.
#   3. docs/evaluation/trace-action-log-evals.md still points at the
#      observability page (pointer chain doc -> contract stays single).
#
# Deliberately NOT asserted (prose wording is free): section titles, table
# layout, example spans, or how the doc phrases the pointer to the contract.
#
# Exit codes: 0 docs defer to the contract · 1 a single-source obligation
# regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
DOC="${ROOT}/docs/evaluation/observability-and-trace-schema.md"
POINTER_DOC="${ROOT}/docs/evaluation/trace-action-log-evals.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# jq reads the contract's attribute and lifecycle vocabularies as data, so the
# sensor never hardcodes a third copy. Hard-require it (CI installs jq).
command -v jq >/dev/null 2>&1 \
  || { printf 'FAIL: jq is required to read the trace schema contract\n' >&2; exit 1; }

[ -f "$CONTRACT" ] \
  || { printf 'FAIL: contract not found at docs/evaluation/trace-schema.v1.json (%s)\n' "$CONTRACT" >&2; exit 1; }
[ -f "$DOC" ] \
  || { printf 'FAIL: prose doc not found at docs/evaluation/observability-and-trace-schema.md\n' >&2; exit 1; }
[ -f "$POINTER_DOC" ] \
  || { printf 'FAIL: docs/evaluation/trace-action-log-evals.md not found\n' >&2; exit 1; }

# --- 1. Prose doc defers to the frozen contract ------------------------------
grep -qF 'trace-schema.v1.json' "$DOC" \
  || fail "observability-and-trace-schema.md must reference trace-schema.v1.json as the vocabulary authority"

# --- 2a. No duplicated complete lifecycle-step enumeration -------------------
# A couple of illustrative step names are allowed; reproducing the entire
# closed vocabulary is a second normative copy that can drift.
lifecycle_total=0
lifecycle_in_doc=0
while IFS= read -r step; do
  [ -n "$step" ] || continue
  lifecycle_total=$((lifecycle_total + 1))
  if grep -qE "(^|[^A-Za-z0-9_])${step}([^A-Za-z0-9_]|$)" "$DOC"; then
    lifecycle_in_doc=$((lifecycle_in_doc + 1))
  fi
done < <(jq -r '.lifecycle_steps[]' "$CONTRACT")

[ "$lifecycle_total" -gt 0 ] \
  || fail "contract .lifecycle_steps is empty — cannot check for a duplicated enumeration"
if [ "$lifecycle_total" -gt 0 ] && [ "$lifecycle_in_doc" -eq "$lifecycle_total" ]; then
  fail "prose doc duplicates the complete ${lifecycle_total}-step lifecycle enumeration; the closed list must live only in trace-schema.v1.json"
fi

# --- 2b. Every attribute name still mentioned in the doc exists in the contract
# Extract gen_ai.* / harness.* dotted attribute mentions from the doc, then
# check each against the contract's attribute vocabulary (required_common +
# per-span required + optional fields). A doc token may also be a namespace
# prefix of a contract attribute (e.g. `gen_ai.usage.*` -> gen_ai.usage).
doc_attrs="$(grep -oE '(gen_ai|harness)(\.[a-z_][a-z0-9_]*)+' "$DOC" | sort -u || true)"
while IFS= read -r attr; do
  [ -n "$attr" ] || continue
  # Skip file-path-like mentions (e.g. harness.instructions.md) — not span attributes.
  case "$attr" in
    *.md | *.json | *.yml | *.yaml | *.sh) continue ;;
  esac
  jq -e --arg t "$attr" '
    (.required_common
     + ([.required_by_span[]] | add)
     + (.optional_fields | keys)) as $attrs
    | any($attrs[]; . == $t or startswith($t + "."))
  ' "$CONTRACT" >/dev/null \
    || fail "prose doc mentions attribute '${attr}' that is not in trace-schema.v1.json — vocabulary drift"
done <<< "$doc_attrs"

# --- 2c. Doc mentions the new mandatory fields (not stale vs. v1) ------------
grep -qF 'schema_version' "$DOC" \
  || fail "prose doc must mention the mandatory field schema_version introduced by trace schema v1"
grep -qF 'harness.version' "$DOC" \
  || fail "prose doc must mention the mandatory field harness.version introduced by trace schema v1"

# --- 3. Pointer chain: trace-action-log-evals.md -> observability page -------
grep -qF 'observability-and-trace-schema.md' "$POINTER_DOC" \
  || fail "trace-action-log-evals.md no longer points at observability-and-trace-schema.md — pointer chain to the contract is broken"

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-schema docs single-source violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace schema docs defer to the frozen contract\n'
