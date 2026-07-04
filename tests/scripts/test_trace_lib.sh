#!/usr/bin/env bash
# test_trace_lib.sh — regression sensor for scripts/trace-lib.sh core span
# emission (issue #93, feature trace-lib-core-emit).
#
# scripts/trace-lib.sh is the single sourceable tracing primitive: it exposes
# `trace_span <type> <key=value>...`, which appends exactly one schema-v1 JSON
# line per call to .copilot-tracking/issues/issue-NN/trace.jsonl. This sensor
# builds a throwaway git repo fixture (mktemp + git init, branch
# feature/issue-07-*), sources the library under `set -euo pipefail`, and
# asserts the core emission contract:
#
#   1. Sourcing scripts/trace-lib.sh succeeds under strict mode.
#   2. One call per frozen span type (lifecycle, agent, model, tool, each with
#      its required_by_span fields) appends exactly one line each, creating
#      the tracking dir + trace.jsonl on first write.
#   3. Every emitted line passes the contract-driven jq filter lifted verbatim
#      from the TRACE SPAN VALIDATION FILTER block in test_trace_schema.sh,
#      and carries the auto-stamped fields: schema_version=1, ISO-8601 UTC
#      timestamp, harness.issue (JSON number), harness.version (the fixture
#      repo's short HEAD SHA), and a non-empty span_id unique per span.
#   4. Issue resolution precedence: TRACE_ISSUE env var wins over the
#      feature/issue-NN-* branch name; both paths are exercised.
#   5. parent_span_id passthrough via a parent_span_id=X argument and via the
#      TRACE_PARENT_SPAN_ID env var (plan D1).
#   6. Append-only: repeat calls append, never truncate; existing lines are
#      byte-for-byte unchanged.
#   7. key=value typing (plan D6): integer-looking values for the token-count
#      fields (gen_ai.usage.*) serialize as JSON numbers, harness.issue is
#      auto-stamped as a number, and every other value — including
#      digits-only free text like a short SHA — stays a JSON string.
#
# Redaction and failure-isolation behaviors are covered by their own sensors
# (test_trace_lib_redaction.sh, test_trace_lib_isolation.sh) — this sensor is
# scoped to core emission only.
#
# Exit codes: 0 emission contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# jq drives both the emitter (plan D4) and the contract validation filter, so
# hard-require it the way test_trace_schema.sh does.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace-lib span emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

# RED gate: the library under test must exist before anything can be sourced.
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — the trace_span emitter for feature trace-lib-core-emit (issue #93) is not implemented yet"

# --- Contract-driven span validation ------------------------------------------
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

# --- Helpers -------------------------------------------------------------------
line_count() { wc -l < "$1" | tr -d '[:space:]'; }

nth_line() { sed -n "${2}p" "$1"; }

# Assert the auto-stamped common fields on one emitted line:
# schema_version==1, harness.issue == <want> as a JSON number, non-empty
# harness.version matching the fixture repo's short HEAD, non-empty string
# span_id, and an ISO-8601 UTC timestamp.
check_stamps() {
  local label="$1" line="$2" want_issue="$3" ts version
  printf '%s\n' "$line" | jq -e --argjson issue "$want_issue" '
      (.schema_version == 1)
      and ((.["harness.issue"] | type) == "number")
      and (.["harness.issue"] == $issue)
      and ((.["harness.version"] | type) == "string")
      and ((.["harness.version"] | length) > 0)
      and ((.span_id | type) == "string")
      and ((.span_id | length) > 0)
    ' >/dev/null \
    || fail "${label}: auto-stamped fields wrong (need schema_version=1, numeric harness.issue=${want_issue}, non-empty harness.version and span_id): ${line}"
  version="$(printf '%s\n' "$line" | jq -r '.["harness.version"]')"
  [ "$version" = "$HEAD_SHORT" ] \
    || fail "${label}: harness.version should be the fixture repo short HEAD SHA '${HEAD_SHORT}', got '${version}'"
  ts="$(printf '%s\n' "$line" | jq -r '.timestamp')"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "${label}: timestamp is not ISO-8601 UTC (date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ), got '${ts}'"
}

# --- Fixture: throwaway git repo faking an issue-07 worktree -------------------
REPO="${TMP_DIR}/myrepo"
mkdir -p "${REPO}/scripts"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
cd "$REPO"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf 'fixture\n' > README.md
git add README.md scripts/trace-lib.sh
git commit -q -m initial
git checkout -q -b feature/issue-07-trace-fixture
HEAD_SHORT="$(git rev-parse --short HEAD)"

# The fixture must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"

# --- 1. Sourcing works under set -euo pipefail ---------------------------------
# This script already runs under strict mode; a library that trips -e/-u on
# source would abort here.
# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh" \
  || fail "sourcing scripts/trace-lib.sh failed under set -euo pipefail"
declare -F trace_span >/dev/null \
  || fail "sourcing scripts/trace-lib.sh did not define a trace_span function"

# --- 2. First write creates dir + file with exactly one line -------------------
trace_span lifecycle "harness.lifecycle_step=preflight" "harness.outcome=pass" \
  || fail "trace_span lifecycle returned non-zero"
[ -f "$TRACE_FILE" ] \
  || fail "first trace_span call did not create .copilot-tracking/issues/issue-07/trace.jsonl"
[ "$(line_count "$TRACE_FILE")" = "1" ] \
  || fail "first trace_span call must append exactly one line (got $(line_count "$TRACE_FILE"))"

# --- 3. One span per frozen type, each appending exactly one line --------------
trace_span agent "gen_ai.operation.name=invoke_agent" "gen_ai.agent.name=implementation-subagent" \
  || fail "trace_span agent returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "2" ] || fail "agent span did not append exactly one line"

trace_span model "gen_ai.request.model=example-model" "gen_ai.usage.input_tokens=18000" "gen_ai.usage.output_tokens=4000" \
  || fail "trace_span model returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "3" ] || fail "model span did not append exactly one line"

trace_span tool "gen_ai.tool.name=git" "harness.review_gate_sha=1234567" \
  || fail "trace_span tool returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "4" ] || fail "tool span did not append exactly one line"

# Every emitted line passes the contract filter and carries the auto-stamps.
n=0
while IFS= read -r line; do
  n=$((n + 1))
  validate_span "$line" \
    || fail "emitted line ${n} rejected by the contract-driven jq validation filter: ${line}"
  check_stamps "line ${n}" "$line" 7
done < "$TRACE_FILE"
[ "$n" = "4" ] || fail "expected to validate 4 emitted lines, saw ${n}"

# span_id must be unique per span: 4 spans -> 4 distinct ids.
distinct_ids="$(jq -r '.span_id' "$TRACE_FILE" | sort -u | wc -l | tr -d '[:space:]')"
[ "$distinct_ids" = "4" ] \
  || fail "span_id must be unique per span: 4 spans yielded ${distinct_ids} distinct span_id values"

# The declared span type and caller-provided attributes land verbatim.
printf '%s\n' "$(nth_line "$TRACE_FILE" 1)" \
  | jq -e '.span == "lifecycle" and .["harness.lifecycle_step"] == "preflight" and .["harness.outcome"] == "pass"' >/dev/null \
  || fail "lifecycle span lost its declared type or key=value attributes"
printf '%s\n' "$(nth_line "$TRACE_FILE" 2)" \
  | jq -e '.span == "agent" and .["gen_ai.agent.name"] == "implementation-subagent"' >/dev/null \
  || fail "agent span lost its declared type or key=value attributes"

# --- 4. Numeric vs string typing (plan D6) --------------------------------------
model_line="$(nth_line "$TRACE_FILE" 3)"
printf '%s\n' "$model_line" | jq -e '
    ((.["gen_ai.usage.input_tokens"] | type) == "number")
    and (.["gen_ai.usage.input_tokens"] == 18000)
    and ((.["gen_ai.usage.output_tokens"] | type) == "number")
    and (.["gen_ai.usage.output_tokens"] == 4000)
    and ((.["gen_ai.request.model"] | type) == "string")
  ' >/dev/null \
  || fail "gen_ai.usage.* token counts must serialize as JSON numbers (18000/4000) and free-text values as strings: ${model_line}"

# Digits-only free text outside the token-count fields must STAY a string.
tool_line="$(nth_line "$TRACE_FILE" 4)"
printf '%s\n' "$tool_line" | jq -e '.["harness.review_gate_sha"] == "1234567" and ((.["harness.review_gate_sha"] | type) == "string")' >/dev/null \
  || fail "digits-only non-token value harness.review_gate_sha=1234567 must stay a JSON string: ${tool_line}"

# --- 5. Append-only: repeat calls append, never truncate ------------------------
first_line_before="$(nth_line "$TRACE_FILE" 1)"
trace_span lifecycle "harness.lifecycle_step=feature_start" \
  || fail "second lifecycle trace_span returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "5" ] \
  || fail "trace.jsonl must be append-only: expected 5 lines after a repeat call, got $(line_count "$TRACE_FILE")"
[ "$(nth_line "$TRACE_FILE" 1)" = "$first_line_before" ] \
  || fail "append truncated or rewrote existing lines: line 1 changed after a later trace_span call"

# --- 6. parent_span_id passthrough (plan D1) ------------------------------------
trace_span tool "gen_ai.tool.name=gh" "parent_span_id=arg-parent-0001" \
  || fail "trace_span with parent_span_id=... argument returned non-zero"
printf '%s\n' "$(nth_line "$TRACE_FILE" 6)" \
  | jq -e '.parent_span_id == "arg-parent-0001"' >/dev/null \
  || fail "parent_span_id=X passed as key=value must land verbatim on the span"
validate_span "$(nth_line "$TRACE_FILE" 6)" \
  || fail "span carrying parent_span_id was rejected by the contract filter"

(
  export TRACE_PARENT_SPAN_ID="env-parent-0002"
  trace_span tool "gen_ai.tool.name=jq"
) || fail "trace_span under TRACE_PARENT_SPAN_ID returned non-zero"
printf '%s\n' "$(nth_line "$TRACE_FILE" 7)" \
  | jq -e '.parent_span_id == "env-parent-0002"' >/dev/null \
  || fail "TRACE_PARENT_SPAN_ID env var must be stamped as parent_span_id"

# --- 7. Issue resolution precedence: TRACE_ISSUE beats the branch name ----------
# The branch is still feature/issue-07-*, so any line landing in issue-12 with
# harness.issue==12 proves the env override wins.
OVERRIDE_FILE="${REPO}/.copilot-tracking/issues/issue-12/trace.jsonl"
(
  export TRACE_ISSUE=12
  trace_span lifecycle "harness.lifecycle_step=preflight"
) || fail "trace_span under TRACE_ISSUE=12 returned non-zero"
[ -f "$OVERRIDE_FILE" ] \
  || fail "TRACE_ISSUE=12 must win over the feature/issue-07-* branch and write .copilot-tracking/issues/issue-12/trace.jsonl"
[ "$(line_count "$OVERRIDE_FILE")" = "1" ] \
  || fail "TRACE_ISSUE override call must append exactly one line to the issue-12 trace"
override_line="$(nth_line "$OVERRIDE_FILE" 1)"
validate_span "$override_line" \
  || fail "TRACE_ISSUE-override span rejected by the contract-driven jq filter: ${override_line}"
check_stamps "TRACE_ISSUE override" "$override_line" 12

# Branch-derived resolution stayed untouched by the override (still 7 issue-07
# lines, none of them stamped with issue 12).
[ "$(line_count "$TRACE_FILE")" = "7" ] \
  || fail "TRACE_ISSUE override must not write into the branch-resolved issue-07 trace"
jq -e '.["harness.issue"] == 7' "$TRACE_FILE" >/dev/null \
  || fail "branch-name resolution (feature/issue-NN-*) must stamp harness.issue=7 on every issue-07 line"

printf 'trace-lib core emission contract honored\n'
