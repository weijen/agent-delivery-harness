#!/usr/bin/env bash
# test_log_schema_single_source.sh — meta drift sensor for issue #221,
# feature log-schema-drift-sensor (Approach A: key-coverage, no schema change).
#
# The step-level log schema (docs/evaluation/log-schema.v1.json) is the single
# machine-readable authority for the harness log.jsonl stream. Two consumers now
# reach into that stream by field name:
#
#   * the review prompt — .copilot/agents/code-review-subagent.agent.md quotes
#     the log.jsonl failure record: the `error`-level record with
#     `harness.outcome == "fail"` for a `harness.stage`, and cites its `payload`;
#   * the trace reporter — scripts/trace-report.sh derives `log_failures` with a
#     jq predicate selecting `level == "error"` AND `harness.outcome == "fail"`,
#     grouped by `harness.stage`.
#
# Every log.jsonl field/enum those consumers reference MUST already be documented
# in the schema authority. This sensor pins that coverage: it reads the schema
# with jq (the harness is jq-first) and fails if any referenced field or enum
# value is missing — a rename in the schema, or a field referenced by the
# prompt/report but not documented, trips it. Mirrors the key-coverage style of
# tests/meta/test_trace_schema_single_source.sh.
#
# Referenced field set (conductor-resolved OQ4 for issue #221):
#   level          — with the `error` enum value present in .levels
#   harness.outcome — with the `fail` enum value present in its documented enum
#   harness.stage  — documented
#   payload        — documented
#   message        — documented
#
# Exit codes: 0 every referenced field/enum is documented · 1 a gap exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCHEMA="$ROOT/docs/evaluation/log-schema.v1.json"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate the log schema single-source contract"
[ -f "$SCHEMA" ] \
  || fail "log schema authority not found: $SCHEMA"
jq empty "$SCHEMA" 2>/dev/null \
  || fail "log schema authority is not valid JSON: $SCHEMA"

# --- Documented vocabulary: every field name the schema names ----------------
# A field is "documented" if it is a required_common member OR an optional_fields
# key. (levels/redaction live under their own keys and are checked separately.)
documented_has() {
  jq -e --arg f "$1" '
    ((.required_common // []) | index($f)) != null
    or ((.optional_fields // {}) | has($f))
  ' "$SCHEMA" >/dev/null 2>&1
}

# --- A field's documented enum must contain a given value --------------------
# For .levels (a JSON array of strings) the value must be an array member.
levels_has() {
  jq -e --arg v "$1" '((.levels // []) | index($v)) != null' "$SCHEMA" >/dev/null 2>&1
}

# harness.outcome documents its enum as prose ("enum: pass | fail | blocked.")
# in optional_fields; require the value to appear as a whitespace/pipe-delimited
# token so a substring (e.g. "failed") cannot spuriously satisfy it.
outcome_enum_has() {
  jq -er '.optional_fields["harness.outcome"] // empty' "$SCHEMA" 2>/dev/null \
    | grep -qE "(^|[^a-z])$1([^a-z]|$)"
}

# --- 1. level, with the `error` enum value -----------------------------------
documented_has "level" \
  || fail "referenced field 'level' is not documented in log-schema.v1.json (required_common/optional_fields) — the review prompt and trace-report.sh both select on it"
levels_has "error" \
  || fail "the 'error' level enum value is missing from .levels in log-schema.v1.json — trace-report.sh selects level==\"error\" and the review prompt quotes the error-level record"

# --- 2. harness.outcome, with the `fail` enum value --------------------------
documented_has "harness.outcome" \
  || fail "referenced field 'harness.outcome' is not documented in log-schema.v1.json — trace-report.sh and the review prompt both select on it"
outcome_enum_has "fail" \
  || fail "the 'fail' value is missing from the documented harness.outcome enum in log-schema.v1.json — trace-report.sh selects harness.outcome==\"fail\""

# --- 3. harness.stage --------------------------------------------------------
documented_has "harness.stage" \
  || fail "referenced field 'harness.stage' is not documented in log-schema.v1.json — trace-report.sh groups log failures by it and the review prompt cites it"

# --- 4. payload --------------------------------------------------------------
documented_has "payload" \
  || fail "referenced field 'payload' is not documented in log-schema.v1.json — the review prompt cites the failure record's payload"

# --- 5. message --------------------------------------------------------------
documented_has "message" \
  || fail "referenced field 'message' is not documented in log-schema.v1.json — it carries the log record's free-form detail line"

printf 'log-schema single-source contract honored (level[error], harness.outcome[fail], harness.stage, payload, message documented)\n'
