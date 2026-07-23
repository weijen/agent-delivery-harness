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
#      timestamp, harness.issue (JSON number), harness.version (the SemVer
#      release from VERSION, here the 0.0.0-dev fallback because the fixture
#      seeds no VERSION file), harness.commit (the fixture repo's short HEAD
#      SHA — the "which code" signal), and a non-empty span_id unique per span.
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
#   8. Reserved-key protection (issue #93 loop-2 review hardening): caller
#      key=value pairs must not overwrite the auto-stamped fields (span,
#      schema_version, timestamp, harness.issue, harness.version, span_id) —
#      reserved keys are dropped with a warning, the span is still written
#      with the remaining attributes, and parent_span_id stays caller-winnable.
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

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts trace-lib.sh
TMP_DIR="$FIXTURE_TMP_DIR"

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
# harness.version (the 0.0.0-dev fallback, since the fixture seeds no VERSION),
# harness.commit == the fixture repo's short HEAD, non-empty string span_id,
# and an ISO-8601 UTC timestamp.
check_stamps() {
  local label="$1" line="$2" want_issue="$3" ts version commit
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
  [ "$version" = "0.0.0-dev" ] \
    || fail "${label}: harness.version should be the 0.0.0-dev fallback (the fixture seeds no VERSION file), got '${version}'"
  commit="$(printf '%s\n' "$line" | jq -r '.["harness.commit"] // ""')"
  [ "$commit" = "$HEAD_SHORT" ] \
    || fail "${label}: harness.commit should be the fixture repo short HEAD SHA '${HEAD_SHORT}', got '${commit}'"
  ts="$(printf '%s\n' "$line" | jq -r '.timestamp')"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "${label}: timestamp is not ISO-8601 UTC (date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ), got '${ts}'"
}

# --- Fixture: throwaway git repo faking an issue-07 worktree -------------------
REPO="$FIXTURE_REPO"
cd "$REPO"
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

# --- 8. Reserved-key protection (issue #93 loop-2 review hardening) --------------
# A caller must not be able to spoof the auto-stamped identity fields. Pinned
# contract (the SAFER of the two candidates): each reserved key (span,
# schema_version, timestamp, harness.issue, harness.version, span_id) is
# dropped with a trace-lib warning on stderr, the span is STILL written
# carrying the remaining legitimate attributes, and parent_span_id is NOT
# reserved (caller-winnable, section 6).
RESERVED_ERR="${TMP_DIR}/reserved.err"
trace_span tool \
  "span=telemetry" \
  "schema_version=99" \
  "timestamp=1999-01-01T00:00:00Z" \
  "harness.issue=99" \
  "harness.version=deadbee" \
  "span_id=forced-span-id" \
  "parent_span_id=rk-parent-01" \
  "gen_ai.tool.name=git" 2> "$RESERVED_ERR" \
  || fail "trace_span with reserved-key overrides returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "8" ] \
  || fail "reserved-key call must still append exactly one span with the legit attrs (got $(line_count "$TRACE_FILE") lines)"
reserved_line="$(nth_line "$TRACE_FILE" 8)"
printf '%s\n' "$reserved_line" | jq -e '
    (.span == "tool")
    and (.schema_version == 1)
    and (.["gen_ai.tool.name"] == "git")
    and (.parent_span_id == "rk-parent-01")
    and (.span_id != "forced-span-id")
  ' >/dev/null \
  || fail "reserved keys (span/schema_version/timestamp/harness.issue/harness.version/span_id) must be dropped — auto-stamps win, span still written with legit attrs, parent_span_id caller-winnable: ${reserved_line}"
check_stamps "reserved-key span" "$reserved_line" 7
[ "$(printf '%s\n' "$reserved_line" | jq -r '.timestamp')" != "1999-01-01T00:00:00Z" ] \
  || fail "reserved timestamp override must not land on the span: ${reserved_line}"
validate_span "$reserved_line" \
  || fail "reserved-key span rejected by the contract-driven jq filter: ${reserved_line}"
grep -q 'trace-lib' "$RESERVED_ERR" \
  || fail "dropping reserved keys must emit a trace-lib warning on stderr (got: $(cat "$RESERVED_ERR"))"

# --- 9. TRACE_LAST_SPAN_ID exposes success and clears on drop ------------------
TRACE_LAST_SPAN_ID=""
trace_span tool "gen_ai.tool.name=git" \
  || fail "trace_span tool for TRACE_LAST_SPAN_ID success returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "9" ] \
  || fail "TRACE_LAST_SPAN_ID success probe must append exactly one span (got $(line_count "$TRACE_FILE") lines)"
last_span_line="$(nth_line "$TRACE_FILE" 9)"
last_span_id="$(printf '%s\n' "$last_span_line" | jq -r '.span_id')"
[ -n "$TRACE_LAST_SPAN_ID" ] \
  || fail "TRACE_LAST_SPAN_ID must be non-empty after a successful trace_span append"
[ "$TRACE_LAST_SPAN_ID" = "$last_span_id" ] \
  || fail "TRACE_LAST_SPAN_ID must equal the appended span_id '${last_span_id}', got '${TRACE_LAST_SPAN_ID}'"

trace__span_id() {
  printf ''
}
trace_span tool "gen_ai.tool.name=git" \
  || fail "trace_span missing-span-id drop returned non-zero"
[ "$(line_count "$TRACE_FILE")" = "9" ] \
  || fail "missing-span-id drop must not append a span"
[ -z "$TRACE_LAST_SPAN_ID" ] \
  || fail "TRACE_LAST_SPAN_ID must be cleared after a dropped span, got stale id '${TRACE_LAST_SPAN_ID}'"

printf 'trace-lib core emission contract honored\n'

(
cd "$ROOT"

LIB="${TRACE_LIB_UNDER_TEST:-${ROOT}/scripts/trace-lib.sh}"
TMP_DIR="$(mktemp -d)"
trap 'chmod -R u+w "${TMP_DIR}" 2>/dev/null || true; rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace-lib failure isolation"

[ -f "$LIB" ] \
  || fail "trace-lib not found (${LIB}) — the emitter for feature trace-lib-failure-isolation (issue #93) is not available"

# --- Fixture: throwaway git repo whose dir name is NOT issue-NN -----------------
REPO="${TMP_DIR}/myrepo"
git clone -q "$FIXTURE_REPO" "$REPO"
git -C "$REPO" remote remove origin
git -C "$REPO" checkout -q -B main
cd "$REPO"
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"

# The fixture must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

TRACKING_DIR="${REPO}/.copilot-tracking"
TRACE_FILE="${TRACKING_DIR}/issues/issue-07/trace.jsonl"

# Run one strict-mode child caller: must exit 0, print exactly the survival
# marker on stdout (so no warning leaked to stdout), and warn on stderr.
run_case() {
  local label="$1" script="$2" rc=0
  local out="${TMP_DIR}/${label}.out" err="${TMP_DIR}/${label}.err"
  set +e
  bash "$script" > "$out" 2> "$err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "${label}: set -euo pipefail caller died with exit ${rc} — trace failure propagated (stderr: $(cat "$err"))"
  [ "$(cat "$out")" = "SURVIVED" ] \
    || fail "${label}: caller stdout must be exactly the survival marker (warnings belong on stderr), got: $(cat "$out")"
  grep -q 'trace-lib' "$err" \
    || fail "${label}: expected a trace-lib warning on stderr, got: $(cat "$err")"
}

# No failure case may create the tracking dir or append any line.
assert_no_write() {
  local label="$1"
  [ ! -e "$TRACE_FILE" ] \
    || fail "${label}: a failure path must not write trace.jsonl (found ${TRACE_FILE}: $(cat "$TRACE_FILE"))"
}

# Child preamble shared by every case (REPO expands at generation time).
child_preamble() {
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${REPO}"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh"
EOF
}

# --- 4. Unresolvable issue: branch 'main', worktree dir 'myrepo' ----------------
{ child_preamble; cat <<'EOF'
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-unresolvable.sh"
run_case "unresolvable-issue" "${TMP_DIR}/case-unresolvable.sh"
[ ! -e "$TRACKING_DIR" ] \
  || fail "unresolvable-issue: no tracking dir may be created when the issue cannot be resolved"

# Remaining cases run on a valid feature/issue-NN-* branch so resolution
# would succeed — proving each failure is caught by its own guard.
git checkout -q -b feature/issue-07-isolation-fixture

# --- 5. Non-numeric TRACE_ISSUE: warn + drop, NO fallback to the branch ----------
{ child_preamble; cat <<'EOF'
export TRACE_ISSUE=abc
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-bad-issue.sh"
run_case "non-numeric-TRACE_ISSUE" "${TMP_DIR}/case-bad-issue.sh"
[ ! -e "$TRACKING_DIR" ] \
  || fail "non-numeric-TRACE_ISSUE: TRACE_ISSUE=abc must warn+drop with NO fallback to the valid feature/issue-07-* branch (found ${TRACKING_DIR})"

# --- 2. Unknown span type ---------------------------------------------------------
{ child_preamble; cat <<'EOF'
trace_span telemetry "harness.note=bogus"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-bad-type.sh"
run_case "unknown-span-type" "${TMP_DIR}/case-bad-type.sh"
assert_no_write "unknown-span-type"

# --- 3. Malformed key=value: missing '=' and empty key ----------------------------
{ child_preamble; cat <<'EOF'
trace_span tool "gen_ai.tool.name=git" "not-a-key-value-pair"
trace_span tool "gen_ai.tool.name=git" "=value-with-empty-key"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-malformed-kv.sh"
run_case "malformed-key-value" "${TMP_DIR}/case-malformed-kv.sh"
assert_no_write "malformed-key-value"

# --- 6. jq missing from PATH -------------------------------------------------------
mkdir -p "${TMP_DIR}/emptybin"
{ child_preamble; cat <<EOF
PATH="${TMP_DIR}/emptybin"
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-no-jq.sh"
run_case "missing-jq" "${TMP_DIR}/case-no-jq.sh"
assert_no_write "missing-jq"

# --- 1. Unwritable tracking dir ------------------------------------------------------
mkdir -p "$TRACKING_DIR"
chmod 555 "$TRACKING_DIR"
{ child_preamble; cat <<'EOF'
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-unwritable.sh"
run_case "unwritable-tracking-dir" "${TMP_DIR}/case-unwritable.sh"
[ ! -e "${TRACKING_DIR}/issues" ] \
  || fail "unwritable-tracking-dir: nothing may be written under an unwritable .copilot-tracking"
chmod 755 "$TRACKING_DIR"
rmdir "$TRACKING_DIR"

# --- 7. A successful call AFTER all failures still works ---------------------------
{ child_preamble; cat <<'EOF'
trace_span lifecycle "harness.lifecycle_step=preflight" "harness.outcome=pass"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-recovery.sh"
set +e
bash "${TMP_DIR}/case-recovery.sh" > "${TMP_DIR}/recovery.out" 2> "${TMP_DIR}/recovery.err"
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "recovery: successful call after failures exited ${rc} (stderr: $(cat "${TMP_DIR}/recovery.err"))"
[ "$(cat "${TMP_DIR}/recovery.out")" = "SURVIVED" ] \
  || fail "recovery: unexpected stdout: $(cat "${TMP_DIR}/recovery.out")"
[ -f "$TRACE_FILE" ] \
  || fail "recovery: a valid trace_span call after the failure cases did not create ${TRACE_FILE}"
[ "$(wc -l < "$TRACE_FILE" | tr -d '[:space:]')" = "1" ] \
  || fail "recovery: expected exactly 1 line in trace.jsonl, got $(wc -l < "$TRACE_FILE")"
jq -e '.span == "lifecycle" and .["harness.lifecycle_step"] == "preflight" and .schema_version == 1' \
  "$TRACE_FILE" >/dev/null \
  || fail "recovery: the post-failure span is not a valid lifecycle line: $(cat "$TRACE_FILE")"

printf 'trace-lib failure-isolation contract honored\n'
)

(
cd "$ROOT"

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
  || fail "jq is required to validate trace-lib main-root span emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB})"

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

# Validate every line of one trace file against the #92 contract filter.
validate_file() {
  local label="$1" file="$2" n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    validate_span "$line" \
      || fail "${label}: line ${n} rejected by the contract-driven jq validation filter: ${line}"
  done < "$file"
  [ "$n" -gt 0 ] || fail "${label}: trace file is empty (${file})"
}

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Fixture A: MAIN repo + LINKED WORKTREE -------------------------------------
# trace-lib.sh is committed in the main repo so the linked worktree shares it
# via git (real deployment shape: one scripts/ tree, many worktrees).
MAIN="${TMP_DIR}/main-repo"
WT="${TMP_DIR}/wt"
git clone -q "$FIXTURE_REPO" "$MAIN"
git -C "$MAIN" remote remove origin
git -C "$MAIN" checkout -q -B main
git -C "$MAIN" config user.name "Harness Test"
git -C "$MAIN" config user.email "harness-test@example.invalid"
git -C "$MAIN" worktree add -q -b feature/issue-05-fixture "$WT" \
  || fail "fixture: could not create linked worktree at ${WT}"
[ -f "${WT}/scripts/trace-lib.sh" ] \
  || fail "fixture: linked worktree does not share scripts/trace-lib.sh"

MAIN_TRACE="${MAIN}/.copilot-tracking/issues/issue-05/trace.jsonl"
WT_TRACE="${WT}/.copilot-tracking/issues/issue-05/trace.jsonl"

# --- 1. Spans emitted FROM the linked worktree land at the MAIN root ------------
# Source inside the worktree (exactly how review-gate/create-pr/merge-pr run)
# and emit one lifecycle span + one tool span carrying the D4-typed attrs.
(
  cd "$WT"
  # shellcheck source=/dev/null
  source "./scripts/trace-lib.sh"
  trace_span lifecycle \
    "harness.lifecycle_step=preflight" \
    "harness.outcome=pass" \
    "harness.exit_status=0" \
    "harness.duration_ms=123"
  trace_span tool \
    "gen_ai.tool.name=check-feature-list" \
    "harness.outcome=pass" \
    "harness.exit_status=0" \
    "harness.duration_ms=123" \
    "harness.incomplete_count=2" \
    "harness.stage=push"
) || fail "sourcing trace-lib.sh and calling trace_span inside the linked worktree returned non-zero"

[ ! -e "$WT_TRACE" ] \
  || fail "main-root pinning (plan D1): trace_span called from a linked worktree must NOT write to the worktree's own root (found ${WT_TRACE})"
[ -f "$MAIN_TRACE" ] \
  || fail "main-root pinning (plan D1): trace_span called from a linked worktree must write to the MAIN checkout root (${MAIN_TRACE} missing)"
[ "$(line_count "$MAIN_TRACE")" = "2" ] \
  || fail "expected exactly 2 spans in the main-root trace file, got $(line_count "$MAIN_TRACE")"

# harness.issue still resolves from the WORKTREE's branch name (issue 5).
jq -e '(.["harness.issue"] == 5) and ((.["harness.issue"] | type) == "number")' \
  "$MAIN_TRACE" >/dev/null \
  || fail "spans emitted from the worktree must stamp harness.issue=5 (JSON number) from the feature/issue-05-* branch name"

validate_file "worktree-emitted main-root trace" "$MAIN_TRACE"

# --- 2. Plain-repo behavior unchanged --------------------------------------------
# In a plain (non-linked) repo, dirname(git-common-dir) == toplevel: spans keep
# landing at that repo's own root, exactly as every existing trace-lib fixture.
PLAIN="${TMP_DIR}/plain-repo"
git clone -q "$FIXTURE_REPO" "$PLAIN"
git -C "$PLAIN" remote remove origin
git -C "$PLAIN" checkout -q -B main
git -C "$PLAIN" config user.name "Harness Test"
git -C "$PLAIN" config user.email "harness-test@example.invalid"
git -C "$PLAIN" checkout -q -b feature/issue-07-plain-fixture

PLAIN_TRACE="${PLAIN}/.copilot-tracking/issues/issue-07/trace.jsonl"
(
  cd "$PLAIN"
  # shellcheck source=/dev/null
  source "./scripts/trace-lib.sh"
  trace_span lifecycle "harness.lifecycle_step=preflight" "harness.outcome=pass"
) || fail "trace_span in a plain repo returned non-zero"

[ -f "$PLAIN_TRACE" ] \
  || fail "plain-repo behavior regressed: trace_span must keep writing to the plain repo's own root (${PLAIN_TRACE} missing)"
[ "$(line_count "$PLAIN_TRACE")" = "1" ] \
  || fail "plain-repo call must append exactly one line, got $(line_count "$PLAIN_TRACE")"
jq -e '(.["harness.issue"] == 7) and ((.["harness.issue"] | type) == "number")' \
  "$PLAIN_TRACE" >/dev/null \
  || fail "plain-repo span must stamp harness.issue=7 from the feature/issue-07-* branch name"
validate_file "plain-repo trace" "$PLAIN_TRACE"

# --- 3. trace_now_ms: integer milliseconds, monotone-ish -------------------------
now_out="$(
  cd "$PLAIN"
  # shellcheck source=/dev/null
  source "./scripts/trace-lib.sh"
  declare -F trace_now_ms >/dev/null 2>&1 || exit 9
  t1="$(trace_now_ms)"
  t2="$(trace_now_ms)"
  printf '%s %s' "$t1" "$t2"
)" || fail "trace-lib.sh must define a trace_now_ms function (millisecond clock helper, plan Phase 1)"
read -r t1 t2 <<< "$now_out"
if ! [[ "$t1" =~ ^[0-9]+$ ]] || ! [[ "$t2" =~ ^[0-9]+$ ]]; then
  fail "trace_now_ms must print a bare integer, got '${t1}' / '${t2}'"
fi
# Epoch milliseconds are 13 digits in this era; 10 digits would mean seconds.
[ "${#t1}" -ge 13 ] \
  || fail "trace_now_ms must return MILLISECONDS since epoch (>= 13 digits), got '${t1}' — looks like seconds"
[ "$t2" -ge "$t1" ] \
  || fail "trace_now_ms must be monotone-ish: second call ${t2} < first call ${t1}"

# --- 4. Numeric typing extension (plan D4) ----------------------------------------
# harness.exit_status / harness.duration_ms / harness.incomplete_count must be
# JSON numbers; harness.stage free text must stay a JSON string.
lifecycle_line="$(nth_line "$MAIN_TRACE" 1)"
printf '%s\n' "$lifecycle_line" | jq -e '
    ((.["harness.exit_status"] | type) == "number")
    and (.["harness.exit_status"] == 0)
    and ((.["harness.duration_ms"] | type) == "number")
    and (.["harness.duration_ms"] == 123)
  ' >/dev/null \
  || fail "numeric typing (plan D4): harness.exit_status=0 and harness.duration_ms=123 must serialize as JSON numbers on the lifecycle span: ${lifecycle_line}"

tool_line="$(nth_line "$MAIN_TRACE" 2)"
printf '%s\n' "$tool_line" | jq -e '
    ((.["harness.exit_status"] | type) == "number")
    and (.["harness.exit_status"] == 0)
    and ((.["harness.duration_ms"] | type) == "number")
    and (.["harness.duration_ms"] == 123)
    and ((.["harness.incomplete_count"] | type) == "number")
    and (.["harness.incomplete_count"] == 2)
  ' >/dev/null \
  || fail "numeric typing (plan D4): harness.exit_status/harness.duration_ms/harness.incomplete_count must serialize as JSON numbers on the tool span: ${tool_line}"
printf '%s\n' "$tool_line" | jq -e '
    (.["harness.stage"] == "push") and ((.["harness.stage"] | type) == "string")
  ' >/dev/null \
  || fail "numeric typing (plan D4): non-integer harness.* free text like harness.stage=push must STAY a JSON string: ${tool_line}"

printf 'trace-lib main-root pinning, trace_now_ms and numeric typing contract honored\n'
)
