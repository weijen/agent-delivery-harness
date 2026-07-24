#!/usr/bin/env bash
# Regression sensor for issue #267, feature f3 `economics-span`.
#
# The f2 closeout helper already computes and stamps the operator-facing
# economics markdown block. This sensor pins the next machine-readable contract:
# the same finish helper must append exactly one finish-issue.economics tool span
# to the MAIN-root issue trace, with numeric aggregate fields and omit-never-fake
# token usage semantics.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
SCRATCH_ROOT="${ROOT}/.copilot-tracking/test-economics-span.$$"
TMP_DIR="${SCRATCH_ROOT}/tmp"
BIN="${SCRATCH_ROOT}/bin"
trap 'rm -rf "${SCRATCH_ROOT}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required for the economics span sensor"
[ -f "$SCHEMA" ] || hard_fail "trace schema contract not found (${SCHEMA})"

mkdir -p "$TMP_DIR" "$BIN"

link_tools() {
  local dir="$1"; shift
  local t p
  mkdir -p "$dir"
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat grep printf jq date \
  od tr head cp mv awk sort comm sed touch chmod pwd

copy_fixture_scripts() {
  local dir="$1"
  local s
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  for s in finish-lib.sh economics-report-lib.sh trace-lib.sh log-handback.sh check-trace-consistency.sh trace-report.sh issue-lib.sh; do
    [ -f "${ROOT}/scripts/${s}" ] \
      || hard_fail "scripts/${s} not found — required by economics span fixture"
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "$SCHEMA" "${dir}/docs/evaluation/trace-schema.v1.json"
  if [ -f "${ROOT}/VERSION" ]; then
    cp "${ROOT}/VERSION" "${dir}/VERSION"
  fi
}

make_economics_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "$dir"
  copy_fixture_scripts "$dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md docs scripts
  git -C "$dir" commit -q -m initial

  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  cat > "${dir}/.copilot-tracking/issues/issue-${pad}/feature_list.json" <<JSON
{
  "issue": ${issue},
  "features": [
    {"id":"f1","passes":true,"teeth_proof":{"kind":"red_first","evidence":"sensor-a"}},
    {"id":"f2","passes":true},
    {"id":"f3","passes":false,"teeth_proof":{"kind":"negative_fixture","evidence":"sensor-b"}},
    {"id":"f4","passes":false}
  ]
}
JSON
}

plant_with_tokens_trace() {
  local trace_file="$1" issue="$2"
  cat > "$trace_file" <<JSONL
{"schema_version":1,"timestamp":"2026-07-10T10:00:00Z","span":"model","harness.issue":${issue},"harness.version":"0.0.0-test","span_id":"model-a","gen_ai.request.model":"fixture-model","gen_ai.usage.input_tokens":10,"gen_ai.usage.output_tokens":20}
{"schema_version":1,"timestamp":"2026-07-10T10:00:02Z","span":"model","harness.issue":${issue},"harness.version":"0.0.0-test","span_id":"model-b","gen_ai.request.model":"fixture-model","gen_ai.usage.input_tokens":5,"gen_ai.usage.output_tokens":7}
{"schema_version":1,"timestamp":"2026-07-10T10:00:03Z","span":"model","harness.issue":${issue},"harness.version":"0.0.0-test","span_id":"model-c","gen_ai.request.model":"fixture-model"}
{"schema_version":1,"timestamp":"2026-07-10T10:00:04Z","span":"lifecycle","harness.issue":${issue},"harness.version":"0.0.0-test","span_id":"review-a","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-10T10:00:05Z","span":"lifecycle","harness.issue":${issue},"harness.version":"0.0.0-test","span_id":"deviation-a","harness.lifecycle_step":"deviation","harness.failure_mode":"weak-sensor"}
JSONL
}

plant_no_tokens_trace() {
  local trace_file="$1" issue="$2"
  cat > "$trace_file" <<JSONL
{"schema_version":1,"timestamp":"2026-07-10T11:00:00Z","span":"lifecycle","harness.issue":${issue},"harness.version":"0.0.0-test","span_id":"review-b","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"full","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-10T11:00:01Z","span":"lifecycle","harness.issue":${issue},"harness.version":"0.0.0-test","span_id":"deviation-b","harness.lifecycle_step":"deviation","harness.failure_mode":"weak-sensor"}
JSONL
}

run_economics_stamp() {
  local dir="$1" issue="$2"
  # Hermeticity (issue #329): pin the native-record root to an isolated empty
  # dir and unset the ambient COPILOT_AGENT_SESSION_ID so the real developer
  # ~/.copilot/session-state can never leak native economics into this fixture.
  (
    cd "$dir"
    env -u COPILOT_AGENT_SESSION_ID PATH="$BIN" ISSUE_NUM="$issue" WORKTREE_DIR="" SCRIPT_DIR="${dir}/scripts" TRACE_ISSUE="$issue" \
      COPILOT_CLI_STATE_ROOT="${TMP_DIR}/native-empty" \
      bash -c 'source scripts/trace-lib.sh; source scripts/finish-lib.sh; source scripts/economics-report-lib.sh; trace_report_economics_stamp >/dev/null'
  )
}

economics_span_count() {
  jq -nRr '[inputs|fromjson?|objects|select(.["gen_ai.tool.name"]=="finish-issue.economics")]|length' < "$1"
}

last_economics_span() {
  jq -nRr '[inputs|fromjson?|objects|select(.["gen_ai.tool.name"]=="finish-issue.economics")]|last // empty' < "$1"
}

jq_span() {
  local span="$1" filter="$2"
  jq -e "$filter" >/dev/null <<< "$span"
}

assert_single_economics_span() {
  local trace_file="$1" label="$2" count
  count="$(economics_span_count "$trace_file")"
  if [ "$count" != "1" ]; then
    fail "${label}: expected exactly one finish-issue.economics span, got ${count}"
    return 1
  fi
  return 0
}

# CASE WITH-TOKENS: token aggregation, feature aggregation, wall clock, and
# validator self-clean once the economics numeric keys are registered.
F_WITH="${TMP_DIR}/with-tokens"
ISSUE_WITH=94
PAD_WITH="$(printf '%02d' "$ISSUE_WITH")"
make_economics_fixture "$F_WITH" "$ISSUE_WITH"
TRACE_WITH="${F_WITH}/.copilot-tracking/issues/issue-${PAD_WITH}/trace.jsonl"
plant_with_tokens_trace "$TRACE_WITH" "$ISSUE_WITH"
run_economics_stamp "$F_WITH" "$ISSUE_WITH"

if assert_single_economics_span "$TRACE_WITH" "with-tokens"; then
  span="$(last_economics_span "$TRACE_WITH")"
  jq_span "$span" '.span == "tool"' \
    || fail "with-tokens: economics span must be a tool span"
  jq_span "$span" '."gen_ai.tool.name" == "finish-issue.economics"' \
    || fail "with-tokens: economics span has wrong tool name"
  jq_span "$span" '."harness.outcome" == "pass"' \
    || fail "with-tokens: economics span must report pass outcome"
  jq_span "$span" '."gen_ai.usage.input_tokens" == 15 and (."gen_ai.usage.input_tokens"|type) == "number"' \
    || fail "with-tokens: input token total must be numeric 15"
  jq_span "$span" '."gen_ai.usage.output_tokens" == 27 and (."gen_ai.usage.output_tokens"|type) == "number"' \
    || fail "with-tokens: output token total must be numeric 27"
  jq_span "$span" '."harness.economics.token_runs" == 2 and (."harness.economics.token_runs"|type) == "number"' \
    || fail "with-tokens: token_runs must be numeric 2"
  jq_span "$span" '."harness.economics.token_runs_total" == 3 and (."harness.economics.token_runs_total"|type) == "number"' \
    || fail "with-tokens: token_runs_total must be numeric 3"
  jq_span "$span" '."harness.economics.review_rounds" == 1 and (."harness.economics.review_rounds"|type) == "number"' \
    || fail "with-tokens: review_rounds must be numeric 1"
  jq_span "$span" '."harness.economics.review_identity_covered" == 1 and ."harness.economics.review_identity_total" == 1' \
    || fail "with-tokens: review identity coverage must be numeric 1/1"
  jq_span "$span" '."harness.economics.deviations" == 1 and (."harness.economics.deviations"|type) == "number"' \
    || fail "with-tokens: deviations must be numeric 1"
  jq_span "$span" '."harness.economics.features_total" == 4 and (."harness.economics.features_total"|type) == "number"' \
    || fail "with-tokens: features_total must be numeric 4"
  jq_span "$span" '."harness.economics.features_passing" == 2 and (."harness.economics.features_passing"|type) == "number"' \
    || fail "with-tokens: features_passing must be numeric 2"
  jq_span "$span" 'has("harness.economics.teeth_proof") | not' \
    || fail "with-tokens: retired teeth_proof counter (#334) must not be stamped"
  jq_span "$span" '."harness.economics.wall_clock_ms" > 0 and (."harness.economics.wall_clock_ms"|type) == "number"' \
    || fail "with-tokens: wall_clock_ms must be a positive number"
  jq_span "$span" '."harness.economics.active_ms" == 5000 and (."harness.economics.active_ms"|type) == "number"' \
    || fail "with-tokens: active_ms must be the numeric sum of adjacent qualifying gaps"

  (cd "$F_WITH" && env PATH="$BIN" ./scripts/check-trace-consistency.sh "$ISSUE_WITH") \
    > "${TMP_DIR}/validate-with.out" 2>&1 || true
  if grep -Eq 'schema_violation|type_violation|invalid_json|failure_mode_violation' \
      "${TMP_DIR}/validate-with.out"; then
    fail "with-tokens: consolidated checker rejected the economics span schema/types (output: $(tr '\n' '|' < "${TMP_DIR}/validate-with.out"))"
  fi
fi

# CASE NO-TOKENS: omit-never-fake. With no model usage available, token usage
# totals must be absent, not fabricated as zero.
F_NO="${TMP_DIR}/no-tokens"
ISSUE_NO=96
PAD_NO="$(printf '%02d' "$ISSUE_NO")"
make_economics_fixture "$F_NO" "$ISSUE_NO"
TRACE_NO="${F_NO}/.copilot-tracking/issues/issue-${PAD_NO}/trace.jsonl"
plant_no_tokens_trace "$TRACE_NO" "$ISSUE_NO"
run_economics_stamp "$F_NO" "$ISSUE_NO"

if assert_single_economics_span "$TRACE_NO" "no-tokens"; then
  span="$(last_economics_span "$TRACE_NO")"
  jq_span "$span" 'has("gen_ai.usage.input_tokens") == false' \
    || fail "no-tokens: input token total must be absent when no model span carried usage"
  jq_span "$span" 'has("gen_ai.usage.output_tokens") == false' \
    || fail "no-tokens: output token total must be absent when no model span carried usage"
  jq_span "$span" '."harness.economics.review_rounds" == 1 and (."harness.economics.review_rounds"|type) == "number"' \
    || fail "no-tokens: review_rounds must still be numeric 1"
  jq_span "$span" '."harness.economics.review_identity_covered" == 1 and ."harness.economics.review_identity_total" == 1' \
    || fail "no-tokens: review identity coverage must still be numeric 1/1"
  jq_span "$span" '."harness.economics.deviations" == 1 and (."harness.economics.deviations"|type) == "number"' \
    || fail "no-tokens: deviations must still be numeric 1"
  jq_span "$span" '."harness.economics.features_total" == 4 and (."harness.economics.features_total"|type) == "number"' \
    || fail "no-tokens: features_total must still be numeric 4"
  jq_span "$span" '."harness.outcome" == "pass"' \
    || fail "no-tokens: economics span must report pass outcome"
fi

if [ "$fails" -ne 0 ]; then
  printf '%s failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'economics span contract honored\n'

(
cd "$ROOT"

TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_delivery_economics_compute.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE \
  REQUIRE_TRACE_CONSISTENCY REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true

run_compute() {
  local trace_file="$1" feature_list_file="$2"
  source "${ROOT}/scripts/economics-report-lib.sh"
  compute_delivery_economics "$trace_file" "$feature_list_file"
}

assert_line() {
  local label="$1" output="$2" expected="$3"
  printf '%s\n' "$output" | grep -Fx -- "$expected" >/dev/null \
    || fail "${label}: missing exact line: ${expected}; output was: $(printf '%s' "$output" | tr '\n' '|')"
}

assert_not_contains() {
  local label="$1" output="$2" needle="$3"
  if printf '%s\n' "$output" | grep -F -- "$needle" >/dev/null; then
    fail "${label}: output must not contain: ${needle}; output was: $(printf '%s' "$output" | tr '\n' '|')"
  fi
}

TRACE_FULL="${TMP_DIR}/trace-full.jsonl"
cat > "$TRACE_FULL" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T09:14:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":40}
{"schema_version":1,"timestamp":"2026-07-08T10:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"-","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.outcome":"fail"}
{"schema_version":1,"timestamp":"2026-07-08T11:00:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x","gen_ai.usage.input_tokens":250,"gen_ai.usage.output_tokens":70}
{"schema_version":1,"timestamp":"2026-07-08T12:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"implementation-subagent","harness.lifecycle_step":"deviation","harness.feature_id":"f1","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-08T13:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"deviation","harness.feature_id":"f1","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-08T14:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"-","harness.reviewed_sha":"sha-b","harness.review_mode":"full","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-09T16:02:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x"}
JSONL

FEATURE_LIST="${TMP_DIR}/feature_list.json"
cat > "$FEATURE_LIST" <<'JSON'
{"features":[{"id":"f1","passes":true,"teeth_proof":{"kind":"red_first","evidence":"sensor failed before implementation"}},{"id":"f2","passes":true,"teeth_proof":{"kind":"negative_fixture","evidence":"fixture proves omit-never-fake"}},{"id":"f3","passes":true,"teeth_proof":null},{"id":"f4","passes":false}]}
JSON

# CASE A — full trace, partial token coverage, review/deviation counts, and features.
out="$(run_compute "$TRACE_FULL" "$FEATURE_LIST")"
assert_line "CASE A heading" "$out" "## Delivery economics (auto-stamped, trace-derived)"
assert_line "CASE A wall-clock" "$out" "- Wall-clock span: 2026-07-08T09:14:00Z → 2026-07-09T16:02:00Z (elapsed 30.8h / active 0.0h; gaps >30min excluded)"
assert_line "CASE A tokens" "$out" "- Tokens: in 350 / out 110 (coverage: 2/3 runs)"
assert_line "CASE A review rounds" "$out" "- Review rounds: 2 (1 fail → 1 pass)"
assert_line "CASE A deviations" "$out" "- Deviations logged: 2"
assert_line "CASE A features" "$out" "- Features: 3/4 passes:true"

TRACE_NO_TOKENS="${TMP_DIR}/trace-no-tokens.jsonl"
cat > "$TRACE_NO_TOKENS" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T09:14:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x"}
{"schema_version":1,"timestamp":"2026-07-08T10:00:00Z","span":"agent","harness.issue":267,"harness.version":"0.7.0","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"-","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-08T11:00:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x"}
JSONL

# CASE B — no model usage: the token row is OMITTED entirely (issue #329), not a
# half-present "- Tokens: n/a" placeholder, and never a faked zero total. The
# honest subagent-only native token surface (joined at closeout) is the token
# source when the runtime carries no gen_ai.usage.* on model spans.
out="$(run_compute "$TRACE_NO_TOKENS" "$FEATURE_LIST")"
assert_not_contains "CASE B tokens omitted" "$out" "- Tokens:"
assert_not_contains "CASE B tokens omit-never-fake" "$out" "in 0 / out 0"

# CASE C — no feature list available.
out="$(run_compute "$TRACE_FULL" -)"
assert_line "CASE C features absent" "$out" "- Features: n/a"

TRACE_SINGLE_TIMESTAMP="${TMP_DIR}/trace-single-timestamp.jsonl"
cat > "$TRACE_SINGLE_TIMESTAMP" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T09:14:00Z","span":"model","harness.issue":267,"harness.version":"0.7.0","gen_ai.request.model":"x","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":40}
{"schema_version":1,"span":"agent","harness.issue":267,"harness.version":"0.7.0","harness.lifecycle_step":"deviation"}
JSONL

# CASE D — fewer than two timestamps cannot claim a wall-clock span.
out="$(run_compute "$TRACE_SINGLE_TIMESTAMP" "$FEATURE_LIST")"
assert_line "CASE D wall-clock n/a" "$out" "- Wall-clock span: n/a"

printf 'test_delivery_economics_compute: ok\n'
)

(
cd "$ROOT"

SCRATCH="${ROOT}/.copilot-tracking/test-delivery-economics-active-time.$$"
trap 'rm -rf "${SCRATCH}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SCRATCH"

run_human() {
  local library="$1" trace_file="$2"
  (
    # shellcheck source=scripts/economics-report-lib.sh
    source "$library"
    compute_delivery_economics "$trace_file" -
  )
}

run_numeric() {
  local library="$1" trace_file="$2"
  (
    # shellcheck source=scripts/economics-report-lib.sh
    source "$library"
    economics_numeric_aggregates "$trace_file" -
  )
}

assert_line() {
  local label="$1" output="$2" expected="$3"
  printf '%s\n' "$output" | grep -Fx -- "$expected" >/dev/null \
    || fail "${label}: missing exact line '${expected}'"
}

assert_numeric() {
  local label="$1" output="$2" expected="$3"
  printf '%s\n' "$output" | grep -Fx -- "$expected" >/dev/null \
    || fail "${label}: missing numeric aggregate '${expected}'"
}

assert_omits() {
  local label="$1" output="$2" needle="$3"
  if printf '%s\n' "$output" | grep -F -- "$needle" >/dev/null; then
    fail "${label}: unexpectedly contained '${needle}'"
  fi
}

LIB="${ROOT}/scripts/economics-report-lib.sh"
TRACE_MIXED="${SCRATCH}/mixed.jsonl"
cat > "$TRACE_MIXED" <<'JSONL'
{"timestamp":"2026-07-20T02:00:00.750Z","span":"tool"}
{"timestamp":"2026-07-20T00:30:00.250Z","span":"tool"}
{"timestamp":"2026-07-20T01:00:00.500Z","span":"tool"}
{"timestamp":"2026-07-20T00:00:00.250Z","span":"tool"}
{"timestamp":"2026-07-20T01:10:00.750Z","span":"tool"}
JSONL

# Unsorted fractional timestamps: exactly 30 minutes is active; both gaps over
# 30 minutes are excluded in full. Markdown and machine aggregates must agree.
human="$(run_human "$LIB" "$TRACE_MIXED")"
numeric="$(run_numeric "$LIB" "$TRACE_MIXED")"
assert_line "mixed human" "$human" \
  "- Wall-clock span: 2026-07-20T00:00:00.250Z → 2026-07-20T02:00:00.750Z (elapsed 2.0h / active 0.7h; gaps >30min excluded)"
assert_numeric "mixed elapsed" "$numeric" "harness.economics.wall_clock_ms=7200500"
assert_numeric "mixed active" "$numeric" "harness.economics.active_ms=2400250"

TRACE_ZERO="${SCRATCH}/zero.jsonl"
cat > "$TRACE_ZERO" <<'JSONL'
{"timestamp":"2026-07-20T03:00:00.125Z","span":"tool"}
{"timestamp":"2026-07-20T03:00:00.125Z","span":"tool"}
JSONL
human="$(run_human "$LIB" "$TRACE_ZERO")"
numeric="$(run_numeric "$LIB" "$TRACE_ZERO")"
assert_line "measured zero human" "$human" \
  "- Wall-clock span: 2026-07-20T03:00:00.125Z → 2026-07-20T03:00:00.125Z (elapsed 0.0h / active 0.0h; gaps >30min excluded)"
assert_numeric "measured zero active" "$numeric" "harness.economics.active_ms=0"

TRACE_INVALID="${SCRATCH}/invalid.jsonl"
cat > "$TRACE_INVALID" <<'JSONL'
{"timestamp":"2026-07-20T03:00:00Z","span":"tool"}
{"timestamp":"not-a-timestamp","span":"tool"}
JSONL
human="$(run_human "$LIB" "$TRACE_INVALID")"
numeric="$(run_numeric "$LIB" "$TRACE_INVALID")"
assert_line "invalid human" "$human" "- Wall-clock span: n/a"
assert_omits "invalid elapsed" "$numeric" "harness.economics.wall_clock_ms="
assert_omits "invalid active" "$numeric" "harness.economics.active_ms="

TRACE_SINGLE="${SCRATCH}/single.jsonl"
printf '%s\n' '{"timestamp":"2026-07-20T03:00:00.500Z","span":"tool"}' > "$TRACE_SINGLE"
human="$(run_human "$LIB" "$TRACE_SINGLE")"
numeric="$(run_numeric "$LIB" "$TRACE_SINGLE")"
assert_line "single human" "$human" "- Wall-clock span: n/a"
assert_omits "single active" "$numeric" "harness.economics.active_ms="

# Mutation proof: excluding the exactly-30-minute gap must make this sensor's
# mixed fixture disagree with the required active aggregate.
MUTATED_LIB="${SCRATCH}/economics-report-lib-mutated.sh"
awk '
  !mutated && sub(/<= 1800/, "< 1800") { mutated = 1 }
  { print }
' "$LIB" > "$MUTATED_LIB"
cmp -s "$LIB" "$MUTATED_LIB" \
  && fail "mutation setup did not find the inclusive 30-minute boundary"
mutated_numeric="$(run_numeric "$MUTATED_LIB" "$TRACE_MIXED")"
if printf '%s\n' "$mutated_numeric" | grep -Fx \
    "harness.economics.active_ms=2400250" >/dev/null; then
  fail "sensor did not kill the exclusive 30-minute-boundary mutation"
fi

printf 'delivery economics active-time contract honored\n'
)

(
cd "$ROOT"

SCRATCH="${ROOT}/.copilot-tracking/test-runs/test_delivery_economics_review_events.$$"
trap 'rm -rf "${SCRATCH}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SCRATCH"

write_complete_trace() {
  cat > "$1" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f3","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"repair","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"repair","harness.feature_id":"f2","harness.outcome":"pass"}
JSONL
}

run_markdown() {
  local library="$1" trace="$2"
  (
    # shellcheck source=scripts/economics-report-lib.sh
    source "$library"
    compute_delivery_economics "$trace" -
  )
}

run_numeric() {
  local library="$1" trace="$2"
  (
    # shellcheck source=scripts/economics-report-lib.sh
    source "$library"
    economics_numeric_aggregates "$trace" -
  )
}

assert_complete_contract() {
  local library="$1" trace="$2" markdown numeric markdown_rounds numeric_rounds
  markdown="$(run_markdown "$library" "$trace")"
  numeric="$(run_numeric "$library" "$trace")"

  grep -Fx -- '- Review rounds: 3 (1 fail → 2 pass)' <<< "$markdown" >/dev/null \
    || fail "7 per-feature verdict spans must aggregate to 3 events with mixed outcomes"
  grep -Fx -- 'harness.economics.review_rounds=3' <<< "$numeric" >/dev/null \
    || fail "numeric economics must count the same 3 review events"
  grep -Fx -- 'harness.economics.review_identity_covered=7' <<< "$numeric" >/dev/null \
    || fail "numeric economics must report seven identified verdict spans"
  grep -Fx -- 'harness.economics.review_identity_total=7' <<< "$numeric" >/dev/null \
    || fail "numeric economics must report seven total verdict spans"

  markdown_rounds="$(sed -n 's/^- Review rounds: \([0-9][0-9]*\).*/\1/p' <<< "$markdown")"
  numeric_rounds="$(sed -n 's/^harness\.economics\.review_rounds=//p' <<< "$numeric")"
  [ "$markdown_rounds" = "$numeric_rounds" ] \
    || fail "Markdown and machine-readable review-round counts must match"
}

COMPLETE="${SCRATCH}/complete.jsonl"
write_complete_trace "$COMPLETE"
assert_complete_contract "${ROOT}/scripts/economics-report-lib.sh" "$COMPLETE"

MISSING="${SCRATCH}/missing.jsonl"
cat > "$MISSING" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"quick","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_mode":"repair","harness.outcome":"pass"}
JSONL
markdown="$(run_markdown "${ROOT}/scripts/economics-report-lib.sh" "$MISSING")"
numeric="$(run_numeric "${ROOT}/scripts/economics-report-lib.sh" "$MISSING")"
grep -Fx -- '- Review rounds: n/a (event identity coverage: 1/3 verdict spans; some spans lack unambiguous event identity)' <<< "$markdown" >/dev/null \
  || fail "incomplete review identity must render n/a with coverage"
if grep -Fq -- 'harness.economics.review_rounds=' <<< "$numeric"; then
  fail "numeric review_rounds must be omitted when any event identity is missing"
fi
grep -Fx -- 'harness.economics.review_identity_covered=1' <<< "$numeric" >/dev/null \
  || fail "numeric economics must explain incomplete identity coverage"
grep -Fx -- 'harness.economics.review_identity_total=3' <<< "$numeric" >/dev/null \
  || fail "numeric economics must expose the review identity denominator"

NONE="${SCRATCH}/none.jsonl"
printf '{"span":"agent","harness.lifecycle_step":"deviation"}\n' > "$NONE"
grep -Fx -- '- Review rounds: 0' <<< "$(run_markdown "${ROOT}/scripts/economics-report-lib.sh" "$NONE")" >/dev/null \
  || fail "no review verdict spans must remain a measured zero"
grep -Fx -- 'harness.economics.review_rounds=0' <<< "$(run_numeric "${ROOT}/scripts/economics-report-lib.sh" "$NONE")" >/dev/null \
  || fail "numeric economics must report zero when there are no review verdict spans"

# Mutation proof: dropping review_mode from the legacy coordinate must collapse
# the full and repair reviews at sha-b, and this sensor must reject that result.
# The legacy key now uses a coord string "\($sha)\t\($mode)"; stripping the mode
# portion collapses distinct modes to the same key.
MUTATED="${SCRATCH}/economics-report-lib-mutated.sh"
# shellcheck disable=SC2016 # $mode is the literal jq variable name being mutated.
sed 's/\\t\\($mode)//' "${ROOT}/scripts/economics-report-lib.sh" > "$MUTATED"
if cmp -s "${ROOT}/scripts/economics-report-lib.sh" "$MUTATED"; then
  fail "mutation setup did not alter the review-event key"
fi
if (
  assert_complete_contract "$MUTATED" "$COMPLETE"
) >/dev/null 2>&1; then
  fail "sensor survived a mutation that removed review_mode from the event key"
fi

printf 'delivery economics review-event aggregation contract honored\n'
)

(
cd "$ROOT"

TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_finish_issue_economics_stamp.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR"

count_marker() {
  local file="$1" marker="$2" count
  count="$(grep -F -c "$marker" "$file" || true)"
  printf '%s' "$count"
}

assert_marker_count() {
  local file="$1" marker="$2" expected="$3" actual
  actual="$(count_marker "$file" "$marker")"
  [ "$actual" -eq "$expected" ] \
    || fail "expected ${expected} copies of ${marker}, found ${actual}"
}

assert_file_contains() {
  local file="$1" needle="$2"
  grep -F -q -- "$needle" "$file" \
    || fail "expected ${file} to contain: ${needle}"
}

assert_file_not_contains() {
  local file="$1" needle="$2"
  if grep -F -q -- "$needle" "$file"; then
    fail "expected ${file} not to contain: ${needle}"
  fi
}

call_economics_stamp_into() {
  local progress_file="$1" block_text="$2"
  (
    set -euo pipefail
    # shellcheck source=scripts/economics-report-lib.sh
    source "${ROOT}/scripts/economics-report-lib.sh"
    economics_stamp_into "$progress_file" "$block_text"
  )
}

link_tools() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  local tool path
  for tool in "$@"; do
    path="$(command -v "$tool" || true)"
    [ -n "$path" ] && ln -sf "$path" "${dir}/${tool}"
  done
}

write_fake_gh() {
  cat > "$1" <<'FAKEGH'
#!/usr/bin/env bash
exit 1
FAKEGH
  chmod +x "$1"
}

copy_finish_fixture_scripts() {
  local dir="$1" script
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  for script in \
    issue-lib.sh lifecycle-runtime-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh review-gate.sh \
    economics-report-lib.sh trace-lib.sh log-handback.sh check-trace-consistency.sh trace-report.sh; do
    cp "${ROOT}/scripts/${script}" "${dir}/scripts/"
  done
  chmod +x "${dir}/scripts/"*.sh
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/trace-schema.v1.json"
}

make_finish_fixture() {
  local dir="$1" issue="$2" pad start_out
  pad="$(printf '%02d' "$issue")"
  copy_finish_fixture_scripts "$dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial

  if ! start_out="$(cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture 2>&1)"; then
    printf '%s\n' "$start_out"
    fail "setup: start-issue for issue ${issue} failed"
  fi
  [ -d "${dir}/.worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"

  cat > "${dir}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json" <<JSON
{
  "features": [
    {
      "id": "economics-stamp",
      "title": "Delivery economics stamp",
      "steps": [],
      "passes": true,
      "verification": "done",
      "teeth_proof": {"kind": "red_first", "evidence": "fixture complete"}
    }
  ]
}
JSON
}

write_trace_fixture() {
  local main="$1" issue="$2" pad trace_dir
  pad="$(printf '%02d' "$issue")"
  trace_dir="${main}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$trace_dir"
  cat > "${trace_dir}/trace.jsonl" <<'JSONL'
{"timestamp":"2026-07-10T10:00:00Z","span":"model","gen_ai.usage.input_tokens":120,"gen_ai.usage.output_tokens":30}
{"timestamp":"2026-07-10T10:30:00Z","span":"model","gen_ai.usage.input_tokens":80,"gen_ai.usage.output_tokens":20}
{"timestamp":"2026-07-10T10:40:00Z","span":"lifecycle","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.outcome":"fail"}
{"timestamp":"2026-07-10T10:50:00Z","span":"lifecycle","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"full","harness.outcome":"pass"}
{"timestamp":"2026-07-10T11:00:00Z","span":"lifecycle","harness.lifecycle_step":"deviation","harness.outcome":"warn"}
JSONL
}

assert_behavioral_finish_reports_economics_post_teardown() {
  local main="$1" issue="$2" out rc
  make_finish_fixture "$main" "$issue"
  write_trace_fixture "$main" "$issue"

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "finish-issue.sh must exit 0"; }
  if printf '%s\n' "$out" | grep -F -q '## Delivery economics (auto-stamped, trace-derived)'; then
    printf '%s\n' "$out"
    fail "finish output must not compute economics in the destructive path"
  fi

  local pad main_progress
  pad="$(printf '%02d' "$issue")"
  main_progress="${main}/.copilot-tracking/issues/issue-${pad}/progress.md"
  [ ! -d "${main}/.worktrees/issue-${pad}" ] \
    || fail "worktree for issue ${issue} must be removed after finish"
  [ -f "$main_progress" ] || fail "migrated MAIN-checkout progress.md is missing"
  grep -F -q '## Delivery economics (auto-stamped, trace-derived)' "$main_progress" \
    || fail "post-teardown trace reporting must stamp economics into surviving progress"
  grep -F -q -- '- Tokens: in 200 / out 50 (coverage: 2/2 runs)' "$main_progress" \
    || fail "post-teardown economics must use the surviving MAIN-root trace"
}

# UNIT U1: append the economics region into progress.md.
PROGRESS="${TMP_DIR}/unit-progress.md"
cat > "$PROGRESS" <<'MD'
# Issue 267 progress

## Action Log

- Existing handback.
MD

OLD_BLOCK=$'## Delivery economics (auto-stamped, trace-derived)\n- x'
call_economics_stamp_into "$PROGRESS" "$OLD_BLOCK"
assert_marker_count "$PROGRESS" '<!-- delivery-economics:start -->' 1
assert_marker_count "$PROGRESS" '<!-- delivery-economics:end -->' 1
assert_file_contains "$PROGRESS" '## Delivery economics (auto-stamped, trace-derived)'
assert_file_contains "$PROGRESS" '- x'

# UNIT U2: replace the existing region without duplicating markers.
NEW_BLOCK=$'## Delivery economics (auto-stamped, trace-derived)\n- y'
call_economics_stamp_into "$PROGRESS" "$NEW_BLOCK"
assert_marker_count "$PROGRESS" '<!-- delivery-economics:start -->' 1
assert_marker_count "$PROGRESS" '<!-- delivery-economics:end -->' 1
assert_file_contains "$PROGRESS" '- y'
assert_file_not_contains "$PROGRESS" '- x'

# UNIT U3: missing path warns to stderr only, writes no stdout, and returns 0.
rc=0
warn_out="$(call_economics_stamp_into "${TMP_DIR}/does-not-exist/progress.md" "block" 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "missing progress.md path must return 0"
[ -z "$warn_out" ] || fail "missing progress.md path must write nothing to stdout"

# BEHAVIOR: finish-issue does not compute economics before teardown.
BIN="${TMP_DIR}/bin"
# mktemp/mv are included (issue #290) so best_effort_progress_migrate takes
# its atomic temp-copy-then-rename path rather than the rejected direct
# `cp -f` fallback — this fixture asserts the migrated progress.md survives
# teardown, so it must exercise the real (non-fallback) migration path.
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc chmod cp head \
  mktemp mv
write_fake_gh "${BIN}/gh"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
# Hermeticity (issue #329): the finish-issue.sh closeout now joins native
# Copilot economics from ${COPILOT_CLI_STATE_ROOT}/<session>/events.jsonl. Pin
# the root to an isolated empty dir and unset the ambient session id so this
# fixture's token assertions read only its planted MAIN-root trace, never the
# real developer session state.
unset COPILOT_AGENT_SESSION_ID 2>/dev/null || true
export COPILOT_CLI_STATE_ROOT="${TMP_DIR}/native-empty"
export ABANDONED=1
assert_behavioral_finish_reports_economics_post_teardown "${TMP_DIR}/r86" 86

printf 'finish-issue delivery economics stamp contract honored\n'
)

(
cd "$ROOT"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts finish-lib.sh,economics-report-lib.sh,trace-lib.sh,log-handback.sh,check-trace-consistency.sh,trace-report.sh,issue-lib.sh,start-issue.sh,finish-issue.sh,check-feature-list.sh
# shellcheck source=tests/scripts/lib/native-economics-fixture.sh
source "${ROOT}/tests/scripts/lib/native-economics-fixture.sh"
# ===========================================================================
# CASE BRACKET — direct stamp: in-window aggregation, out-of-window exclusion,
# model names in markdown, bracketing AIU delta, and exact numeric span keys.
# ===========================================================================
F_BR="${TMP_DIR}/bracket"
I_BR=41
make_git_fixture "$F_BR" "$I_BR"
plant_window_trace "$(trace_of "$F_BR" "$I_BR")" "$I_BR"
STATE_BR="${TMP_DIR}/state-bracket"
plant_events "$STATE_BR" "$SID" bracket

OUT_BR="$(run_stamp "$F_BR" "$I_BR" "$SID" "$STATE_BR" 2>/dev/null)"

# Markdown block: a clearly-labelled subagent-only native section.
block_has "$OUT_BR" '## Delivery economics (auto-stamped, trace-derived)' \
  || fail "BRACKET: the base trace-derived economics block must still be present"
if ! printf '%s\n' "$OUT_BR" | grep -Eqi 'native|subagent-only'; then
  fail "BRACKET: a native/subagent-only economics section must be rendered"
fi
# Subagent-only token total = 1000+2000+500 = 3500 (out-of-window 8888/9999 excluded).
block_has "$OUT_BR" '3500' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: subagent-only token total must be 3500 (in-window only)"; }
# Out-of-window tokens MUST NOT leak into the block.
if block_has "$OUT_BR" '8888' || block_has "$OUT_BR" '9999'; then
  printf '%s\n' "$OUT_BR"; fail "BRACKET: out-of-window subagent tokens (8888/9999) must be excluded"
fi
# Model NAMES appear in the markdown (operator-facing).
block_has "$OUT_BR" 'claude-sonnet-5' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: markdown must name model claude-sonnet-5"; }
block_has "$OUT_BR" 'claude-opus-4.8' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: markdown must name model claude-opus-4.8"; }
# Never an n/a tokens placeholder when real data exists.
if block_has "$OUT_BR" '- Tokens: n/a'; then
  printf '%s\n' "$OUT_BR"; fail "BRACKET: must never print a '- Tokens: n/a' placeholder"
fi
# Bracketing AIU delta = 180e9 - 100e9 = 80000000000 present in the block.
block_has "$OUT_BR" '80000000000' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: bracketing AIU delta 80000000000 must render"; }

TR_BR="$(trace_of "$F_BR" "$I_BR")"
[ "$(economics_span_count "$TR_BR")" = "1" ] \
  || fail "BRACKET: expected exactly one finish-issue.economics span"
SP_BR="$(last_economics_span "$TR_BR")"
jq_span "$SP_BR" '."harness.economics.native_subagent_tokens" == 3500 and (."harness.economics.native_subagent_tokens"|type=="number")' \
  || fail "BRACKET: native_subagent_tokens must be numeric 3500"
jq_span "$SP_BR" '."harness.economics.native_subagent_count" == 3 and (."harness.economics.native_subagent_count"|type=="number")' \
  || fail "BRACKET: native_subagent_count must be numeric 3"
jq_span "$SP_BR" '."harness.economics.native_tool_calls" == 10 and (."harness.economics.native_tool_calls"|type=="number")' \
  || fail "BRACKET: native_tool_calls must be numeric 10"
jq_span "$SP_BR" '."harness.economics.native_duration_ms" == 35000 and (."harness.economics.native_duration_ms"|type=="number")' \
  || fail "BRACKET: native_duration_ms must be numeric 35000"
jq_span "$SP_BR" '."harness.economics.native_models_distinct" == 2 and (."harness.economics.native_models_distinct"|type=="number")' \
  || fail "BRACKET: native_models_distinct must be numeric 2"
jq_span "$SP_BR" '."harness.economics.native_aiu_nano_delta" == 80000000000 and (."harness.economics.native_aiu_nano_delta"|type=="number")' \
  || fail "BRACKET: native_aiu_nano_delta must be numeric 80000000000"
# The span carries NO raw model-name string (numeric prefix stays numeric-only).
jq_span "$SP_BR" '[to_entries[] | select(.key|startswith("harness.economics.native_")) | .value | type] | all(. == "number")' \
  || fail "BRACKET: every harness.economics.native_* span value must be numeric"
# The consolidated checker must accept the resulting span's schema and types;
# unrelated feature-state findings in this focused fixture are ignored.
(cd "$F_BR" && env PATH="$BIN" ./scripts/check-trace-consistency.sh "$I_BR") \
  >"${TMP_DIR}/vt-br.out" 2>&1 || true
if grep -Eq 'schema_violation|type_violation|invalid_json|failure_mode_violation' \
    "${TMP_DIR}/vt-br.out"; then
  fail "BRACKET: consolidated checker rejected the native economics schema/types (out: $(tr '\n' '|' < "${TMP_DIR}/vt-br.out"))"
fi

# ===========================================================================
# CASE UNBRACKET — AIU omitted when no checkpoint moves inside the window,
# even though a baseline exists; subagent economics still present.
# ===========================================================================
F_UN="${TMP_DIR}/unbracket"
I_UN=42
make_git_fixture "$F_UN" "$I_UN"
plant_window_trace "$(trace_of "$F_UN" "$I_UN")" "$I_UN"
STATE_UN="${TMP_DIR}/state-unbracket"
plant_events "$STATE_UN" "$SID" unbracket

OUT_UN="$(run_stamp "$F_UN" "$I_UN" "$SID" "$STATE_UN" 2>/dev/null)"

block_has "$OUT_UN" '3500' \
  || { printf '%s\n' "$OUT_UN"; fail "UNBRACKET: subagent-only token total 3500 must still render"; }
# No AIU delta anywhere (no value, no 0, no n/a).
if block_has "$OUT_UN" '80000000000' || block_has "$OUT_UN" '50000000000'; then
  printf '%s\n' "$OUT_UN"; fail "UNBRACKET: no AIU delta may be printed when unbracketed"
fi
if printf '%s\n' "$OUT_UN" | grep -Eqi 'aiu'; then
  # An AIU LABEL with no bracket is the exact half-present field #329 forbids.
  printf '%s\n' "$OUT_UN"; fail "UNBRACKET: no AIU line may be rendered when the window is not bracketed"
fi
TR_UN="$(trace_of "$F_UN" "$I_UN")"
SP_UN="$(last_economics_span "$TR_UN")"
jq_span "$SP_UN" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "UNBRACKET: native_subagent_tokens must still be 3500"
jq_span "$SP_UN" 'has("harness.economics.native_aiu_nano_delta") == false' \
  || fail "UNBRACKET: native_aiu_nano_delta must be ABSENT (omit-never-zero) when unbracketed"

# ===========================================================================
# CASE INCOMPLETE — honesty of the field-presence policy: three good in-window
# subagents PLUS four in-window subagent.completed events each missing or
# wrong-typing a REQUIRED economics field (absent/empty model, string tokens,
# absent tool calls, null duration) but carrying huge otherwise-valid values.
# The honest policy aggregates a record ONLY when all four required fields are
# genuinely present with correct types, so every malformed record is EXCLUDED
# rather than mapped to an "unknown" model or a fabricated 0 — totals stay
# exactly the three good events' 3500 / 3 / 10 / 35000 / 2.
# ===========================================================================
F_IN="${TMP_DIR}/incomplete"
I_IN=45
make_git_fixture "$F_IN" "$I_IN"
plant_window_trace "$(trace_of "$F_IN" "$I_IN")" "$I_IN"
STATE_IN="${TMP_DIR}/state-incomplete"
plant_events "$STATE_IN" "$SID" incomplete

OUT_IN="$(run_stamp "$F_IN" "$I_IN" "$SID" "$STATE_IN" 2>/dev/null)"

block_has "$OUT_IN" '3500' \
  || { printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: subagent-only token total must stay 3500 (malformed records excluded)"; }
# No malformed record's corrupting value may leak into the block.
for corrupt in 777777 666666 555555 444444; do
  if block_has "$OUT_IN" "$corrupt"; then
    printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: malformed record value ${corrupt} must be excluded, not aggregated"
  fi
done
# A fabricated "unknown" model name must never appear (the old default).
if printf '%s\n' "$OUT_IN" | grep -Fq -- 'unknown'; then
  printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: absent/invalid model must be EXCLUDED, never mapped to 'unknown'"
fi
# A malformed record's partially-valid model name must not sneak into the models.
if block_has "$OUT_IN" 'claude-ghost-9'; then
  printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: a record with one malformed required field must be excluded whole"
fi
TR_IN="$(trace_of "$F_IN" "$I_IN")"
SP_IN="$(last_economics_span "$TR_IN")"
jq_span "$SP_IN" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "INCOMPLETE: native_subagent_tokens must stay 3500 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_subagent_count" == 3' \
  || fail "INCOMPLETE: native_subagent_count must stay 3 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_tool_calls" == 10' \
  || fail "INCOMPLETE: native_tool_calls must stay 10 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_duration_ms" == 35000' \
  || fail "INCOMPLETE: native_duration_ms must stay 35000 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_models_distinct" == 2' \
  || fail "INCOMPLETE: native_models_distinct must stay 2 (malformed excluded)"

# ===========================================================================
# CASE ROLLBACK — AIU is cumulative: when the in-window checkpoint value has
# DECREASED below the baseline (a session reset/rollback), the delta is omitted
# entirely rather than emitting a negative or masked-zero value. The subagent
# economics still render.
# ===========================================================================
F_RB="${TMP_DIR}/rollback"
I_RB=46
make_git_fixture "$F_RB" "$I_RB"
plant_window_trace "$(trace_of "$F_RB" "$I_RB")" "$I_RB"
STATE_RB="${TMP_DIR}/state-rollback"
plant_events "$STATE_RB" "$SID" rollback

OUT_RB="$(run_stamp "$F_RB" "$I_RB" "$SID" "$STATE_RB" 2>/dev/null)"

block_has "$OUT_RB" '3500' \
  || { printf '%s\n' "$OUT_RB"; fail "ROLLBACK: subagent-only token total 3500 must still render"; }
# No AIU line and no delta value (positive, negative, or masked zero).
if printf '%s\n' "$OUT_RB" | grep -Eqi 'aiu'; then
  printf '%s\n' "$OUT_RB"; fail "ROLLBACK: no AIU line may render when the cumulative counter decreased"
fi
if block_has "$OUT_RB" '-80000000000' || block_has "$OUT_RB" '80000000000'; then
  printf '%s\n' "$OUT_RB"; fail "ROLLBACK: no AIU delta may be printed on a decreasing counter"
fi
TR_RB="$(trace_of "$F_RB" "$I_RB")"
SP_RB="$(last_economics_span "$TR_RB")"
jq_span "$SP_RB" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "ROLLBACK: native_subagent_tokens must still be 3500"
jq_span "$SP_RB" 'has("harness.economics.native_aiu_nano_delta") == false' \
  || fail "ROLLBACK: native_aiu_nano_delta must be ABSENT (omit-never-fake) on a decreasing counter"

# ===========================================================================
# CASE INJECT — security repair, fingerprint native-model-markdown-injection
# (failure_class validation-bypass). compute_native_economics honestly accepts
# any non-empty string model (field-presence honesty is about type/presence,
# not content sanity), so a hostile in-window subagent.completed record can
# carry a `model` containing CR, bare LF, and the literal
# <!-- delivery-economics:start/end --> marker text, or an adversarially long
# label. render_native_economics must still render a BOUNDED, SINGLE-LINE,
# marker-safe models line — never reproducing raw CR/LF/marker bytes verbatim —
# while compute_native_economics's numeric aggregates (which are grouped on the
# RAW model string, unaffected by rendering-time sanitization) stay honest: no
# fabricated totals, no dropped in-window subagent. Two full stamps are run to
# prove economics_stamp_into's line-based marker matching stays a single
# well-formed region even when the FIRST stamp's own rendered block is the
# hostile input under test.
# ===========================================================================
F_IJ="${TMP_DIR}/inject"
I_IJ=48
make_git_fixture "$F_IJ" "$I_IJ"
plant_window_trace "$(trace_of "$F_IJ" "$I_IJ")" "$I_IJ"
STATE_IJ="${TMP_DIR}/state-inject"
plant_events "$STATE_IJ" "$SID" inject

# --- Unit-level proof directly on the two pure helpers: the rendered native
# block must stay exactly 5 lines (the fixed template — no AIU line in this
# fixture) no matter how many raw newlines the hostile model label embeds.
WIN_IJ="$(run_fn "$F_IJ" native_economics_window "$(trace_of "$F_IJ" "$I_IJ")")"
NATIVE_JSON_IJ="$(run_fn "$F_IJ" compute_native_economics "${STATE_IJ}/${SID}/events.jsonl" "${WIN_IJ%% *}" "${WIN_IJ##* }")"
[ -n "$NATIVE_JSON_IJ" ] || fail "INJECT: compute_native_economics must still aggregate a well-typed-but-hostile record"
jq -e '.subagent_tokens == 7600 and .subagent_count == 5 and .tool_calls == 15 and .duration_ms == 76000 and (.models|length) == 4' \
  >/dev/null <<<"$NATIVE_JSON_IJ" \
  || { printf '%s\n' "$NATIVE_JSON_IJ"; fail "INJECT: hostile-but-well-typed records must still be honestly aggregated (7600/5/15/76000/4 models)"; }
NATIVE_BLOCK_IJ="$(run_fn "$F_IJ" render_native_economics "$NATIVE_JSON_IJ")"
NATIVE_LINES_IJ="$(printf '%s\n' "$NATIVE_BLOCK_IJ" | wc -l | tr -d ' ')"
[ "$NATIVE_LINES_IJ" = "5" ] \
  || { printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: render_native_economics must stay exactly 5 fixed lines (got ${NATIVE_LINES_IJ}); a hostile model label must never inject extra lines"; }
if printf '%s\n' "$NATIVE_BLOCK_IJ" | grep -Fxq -- '<!-- delivery-economics:end -->' \
  || printf '%s\n' "$NATIVE_BLOCK_IJ" | grep -Fxq -- '<!-- delivery-economics:start -->'; then
  printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: no rendered line may be byte-identical to a delivery-economics marker"
fi
if printf '%s\n' "$NATIVE_BLOCK_IJ" | grep -q $'\r'; then
  printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: rendered native block must never contain a raw CR byte"
fi
if block_has "$NATIVE_BLOCK_IJ" "$MODEL_LONG"; then
  printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: the full 300-char adversarial model label must never render verbatim (unbounded)"
fi
# An ordinary model label mixed into the same fixture must render unchanged.
block_has "$NATIVE_BLOCK_IJ" 'claude-sonnet-5' \
  || { printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: an ordinary model label must still render unchanged alongside hostile ones"; }

# --- Full end-to-end proof: run trace_report_economics_stamp TWICE against the
# same hostile fixture (the first stamp's own output is what could corrupt the
# marker region on the second, marker-replace-path stamp).
OUT_IJ1="$(run_stamp "$F_IJ" "$I_IJ" "$SID" "$STATE_IJ" 2>/dev/null)"
OUT_IJ2="$(run_stamp "$F_IJ" "$I_IJ" "$SID" "$STATE_IJ" 2>/dev/null)"
if printf '%s\n' "$OUT_IJ1$OUT_IJ2" | grep -q $'\r'; then
  fail "INJECT: neither stamp's stdout block may contain a raw CR byte"
fi
PROG_IJ="$(progress_of "$F_IJ" "$I_IJ")"
[ -f "$PROG_IJ" ] || fail "INJECT: progress.md must exist after two stamps"
START_CT_IJ="$(grep -Fxc -- '<!-- delivery-economics:start -->' "$PROG_IJ" || true)"
END_CT_IJ="$(grep -Fxc -- '<!-- delivery-economics:end -->' "$PROG_IJ" || true)"
[ "$START_CT_IJ" = "1" ] \
  || { cat -n "$PROG_IJ"; fail "INJECT: progress.md must carry exactly one start marker after two stamps (got ${START_CT_IJ})"; }
[ "$END_CT_IJ" = "1" ] \
  || { cat -n "$PROG_IJ"; fail "INJECT: progress.md must carry exactly one end marker after two stamps (got ${END_CT_IJ})"; }
# The single end marker must be the LAST line of the file — any corrupted
# leftover body content from a mis-matched marker replacement would land
# AFTER it, which the bare count check above cannot distinguish on its own.
END_LINE_IJ="$(grep -Fxn -- '<!-- delivery-economics:end -->' "$PROG_IJ" | tail -1 | cut -d: -f1)" || true
TOTAL_LINES_IJ="$(wc -l < "$PROG_IJ" | tr -d ' ')"
{ [ -n "$END_LINE_IJ" ] && [ "$END_LINE_IJ" = "$TOTAL_LINES_IJ" ]; } \
  || { cat -n "$PROG_IJ"; fail "INJECT: no content may trail the end marker (end marker at line ${END_LINE_IJ:-<none>} of ${TOTAL_LINES_IJ} total) — marker replacement must produce exactly one well-formed region"; }
grep -F -q '7600' "$PROG_IJ" \
  || { cat -n "$PROG_IJ"; fail "INJECT: the surviving progress.md must still carry the honest 7600 subagent token total"; }
if grep -F -q -- "$MODEL_LONG" "$PROG_IJ"; then
  fail "INJECT: the surviving progress.md must never carry the full unbounded adversarial model label"
fi
TR_IJ="$(trace_of "$F_IJ" "$I_IJ")"
[ "$(economics_span_count "$TR_IJ")" = "2" ] \
  || fail "INJECT: two stamps must emit exactly two finish-issue.economics spans"
SP_IJ="$(last_economics_span "$TR_IJ")"
jq_span "$SP_IJ" '."harness.economics.native_subagent_tokens" == 7600 and (."harness.economics.native_subagent_tokens"|type=="number")' \
  || fail "INJECT: native_subagent_tokens must stay honestly numeric 7600 (hostile records aggregated, never dropped)"
jq_span "$SP_IJ" '."harness.economics.native_models_distinct" == 4 and (."harness.economics.native_models_distinct"|type=="number")' \
  || fail "INJECT: native_models_distinct must stay honestly numeric 4 (raw cardinality unaffected by rendering-time sanitization)"

# ===========================================================================
# CASE ABSENT — fail-open: no session id -> no native block, no native_* keys,
# still exactly one economics span, and no n/a token placeholder.
# ===========================================================================
F_AB="${TMP_DIR}/absent"
I_AB=43
make_git_fixture "$F_AB" "$I_AB"
plant_window_trace "$(trace_of "$F_AB" "$I_AB")" "$I_AB"

OUT_AB="$(run_stamp "$F_AB" "$I_AB" 2>/dev/null)"

if printf '%s\n' "$OUT_AB" | grep -Eqi 'native|subagent-only'; then
  printf '%s\n' "$OUT_AB"; fail "ABSENT: no native economics section may render without a session"
fi
if block_has "$OUT_AB" '- Tokens: n/a'; then
  printf '%s\n' "$OUT_AB"; fail "ABSENT: must not emit a '- Tokens: n/a' placeholder"
fi
TR_AB="$(trace_of "$F_AB" "$I_AB")"
[ "$(economics_span_count "$TR_AB")" = "1" ] \
  || fail "ABSENT: exactly one finish-issue.economics span must still be emitted"
SP_AB="$(last_economics_span "$TR_AB")"
jq_span "$SP_AB" '[to_entries[] | select(.key|startswith("harness.economics.native_"))] | length == 0' \
  || fail "ABSENT: no harness.economics.native_* keys may be emitted when records are absent"

)
