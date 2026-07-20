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
  od tr head cp mv awk sort sed touch chmod pwd

copy_fixture_scripts() {
  local dir="$1"
  local s
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  for s in finish-lib.sh trace-lib.sh log-handback.sh validate-trace.sh trace-report.sh issue-lib.sh; do
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
  (
    cd "$dir"
    env PATH="$BIN" ISSUE_NUM="$issue" WORKTREE_DIR="" SCRIPT_DIR="${dir}/scripts" TRACE_ISSUE="$issue" \
      bash -c 'source scripts/trace-lib.sh; source scripts/finish-lib.sh; best_effort_economics_stamp >/dev/null'
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
  jq_span "$span" '."harness.economics.teeth_proof" == 2 and (."harness.economics.teeth_proof"|type) == "number"' \
    || fail "with-tokens: teeth_proof must be numeric 2"
  jq_span "$span" '."harness.economics.wall_clock_ms" > 0 and (."harness.economics.wall_clock_ms"|type) == "number"' \
    || fail "with-tokens: wall_clock_ms must be a positive number"
  jq_span "$span" '."harness.economics.active_ms" == 5000 and (."harness.economics.active_ms"|type) == "number"' \
    || fail "with-tokens: active_ms must be the numeric sum of adjacent qualifying gaps"

  if ! (cd "$F_WITH" && env PATH="$BIN" ./scripts/validate-trace.sh "$ISSUE_WITH") \
      > "${TMP_DIR}/validate-with.out" 2>&1; then
    fail "with-tokens: validate-trace.sh ${ISSUE_WITH} must accept the resulting trace (output: $(tr '\n' '|' < "${TMP_DIR}/validate-with.out"))"
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
