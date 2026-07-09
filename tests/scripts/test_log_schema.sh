#!/usr/bin/env bash
# test_log_schema.sh — regression sensor for the step-level log schema v1
# contract (issue #219, feature log-schema-contract).
#
# docs/evaluation/log-schema.v1.json is the machine-readable authority for the
# harness local step-level log stream (log.jsonl), a sibling of the frozen span
# schema (trace-schema.v1.json). It is a DISTINCT schema so a shared validator
# can never confuse a log line for a span: its version key is log_schema_version
# (not the span schema's schema_version). This sensor asserts:
#
#   1. The contract file exists, parses as JSON, is a top-level object, and
#      declares log_schema_version 1 as a NUMBER.
#   2. Closed vocabularies read from the contract, checked against hardcoded
#      backstops (so a contract edit cannot silently drift them):
#        .levels          — exactly info, warn, error
#        .required_common — exactly log_schema_version, timestamp, level,
#                           harness.issue, message
#   3. The log-file path contract: .log_file.path equals the issue-NN
#      placeholder form .copilot-tracking/issues/issue-NN/log.jsonl (mirroring
#      trace-schema.v1.json's .trace_file.path convention).
#   4. A redaction section/field indicating redact-before-cap (the stricter
#      free-form-text discipline the issue demands).
#   5. The prose doc docs/evaluation/observability-and-trace-schema.md carries a
#      "Step-level logs" (log.jsonl) section that references log-schema.v1.json.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/log-schema.v1.json"
DOC="${ROOT}/docs/evaluation/observability-and-trace-schema.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# jq is the subject of this sensor (the contract is jq-checkable by design), so
# hard-require it the way test_trace_schema.sh hard-requires jq.
command -v jq >/dev/null 2>&1 \
  || { printf 'FAIL: jq is required to validate the log schema contract\n' >&2; exit 1; }

# --- 1. Contract exists, is valid JSON, declares log_schema_version 1 --------
[ -f "$CONTRACT" ] \
  || { printf 'FAIL: contract not found at docs/evaluation/log-schema.v1.json (%s)\n' "$CONTRACT" >&2; exit 1; }
jq empty "$CONTRACT" 2>/dev/null \
  || { printf 'FAIL: contract is not valid JSON: %s\n' "$CONTRACT" >&2; exit 1; }
jq -e 'type == "object"' "$CONTRACT" >/dev/null \
  || fail "contract top level must be a JSON object"
# log_schema_version must be the NUMBER 1 and a DISTINCT key from the span
# schema's schema_version (so a shared validator never confuses a log line for a
# span). Assert the number, and assert the span key is absent.
jq -e '.log_schema_version == 1 and (.log_schema_version | type) == "number"' "$CONTRACT" >/dev/null \
  || fail "contract must declare top-level log_schema_version 1 as a number"
jq -e 'has("schema_version") | not' "$CONTRACT" >/dev/null \
  || fail "contract must NOT carry the span schema key schema_version (log_schema_version is its distinct version key)"

# --- 2. Closed vocabularies read from the contract, with hardcoded backstops -
# Backstop lists are intentionally duplicated here (sorted, order-insensitive
# compare) so a contract edit cannot silently weaken the frozen vocabulary.

expected_levels='["error","info","warn"]'
jq -e --argjson want "$expected_levels" \
  '(.levels | type) == "array" and (.levels | sort) == $want' "$CONTRACT" >/dev/null \
  || fail "contract .levels must be exactly the closed enum info, warn, error"

expected_required_common='["harness.issue","level","log_schema_version","message","timestamp"]'
jq -e --argjson want "$expected_required_common" \
  '(.required_common | type) == "array" and (.required_common | sort) == $want' "$CONTRACT" >/dev/null \
  || fail "contract .required_common must be exactly log_schema_version, timestamp, level, harness.issue, message"

# --- 3. Log-file path contract (issue-NN placeholder form) -------------------
jq -e '.log_file.path == ".copilot-tracking/issues/issue-NN/log.jsonl"' "$CONTRACT" >/dev/null \
  || fail "contract .log_file.path must be .copilot-tracking/issues/issue-NN/log.jsonl"

# --- 4. Redaction discipline: redact BEFORE cap -----------------------------
jq -e 'has("redaction")' "$CONTRACT" >/dev/null \
  || fail "contract must carry a redaction section/field"
# The free-form-text discipline is redact-before-cap: some string in the
# contract must state that ordering (redact ... cap / redact-before-cap).
jq -e '[.. | strings | select(test("redact.*cap"; "i"))] | length > 0' "$CONTRACT" >/dev/null \
  || fail "contract redaction must state the redact-before-cap ordering"

# --- 5. Prose doc: "Step-level logs" section references the contract ---------
[ -f "$DOC" ] \
  || { printf 'FAIL: prose doc not found at docs/evaluation/observability-and-trace-schema.md\n' >&2; exit 1; }
{ grep -qiE 'Step-level logs' "$DOC" && grep -qF 'log.jsonl' "$DOC"; } \
  || fail "prose doc must carry a Step-level logs (log.jsonl) section"
grep -qF 'log-schema.v1.json' "$DOC" \
  || fail "prose doc Step-level logs section must reference log-schema.v1.json as the vocabulary authority"

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d log-schema contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'log schema v1 contract honored\n'
