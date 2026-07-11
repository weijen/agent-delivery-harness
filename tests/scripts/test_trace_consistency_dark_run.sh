#!/usr/bin/env bash
# test_trace_consistency_dark_run.sh — RED regression sensor for issue #243,
# feature trace-dark-run-liveness.
#
# A dark run is a completed issue window (worktree_create + finish) with zero
# runtime tool spans. Runtime tool spans are precisely span=="tool" with a
# string harness.session_id; harness-owned tool spans such as review-gate.trace
# do not count because they omit harness.session_id.
#
# Frozen finding:
#   VIOLATION consistency: dark_run <issue>
#
# Override / incomplete windows skip with a NOTE matching ^NOTE:.*dark_run.
#
# RED status at authoring time: scripts/check-trace-consistency.sh has no
# dark_run rule yet, so the dark fixtures are otherwise consistent but produce
# no dark_run finding/NOTE. This sensor must fail for that reason only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_PARENT="${ROOT}/.copilot-tracking/test-tmp"
mkdir -p "$TMP_PARENT"
TMP_DIR="$(mktemp -d "${TMP_PARENT}/dark-run.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
export TMPDIR="${TMP_DIR}/child-tmp"
mkdir -p "$TMPDIR"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_ALLOW_DARK_RUN \
  REQUIRE_TRACE_CONSISTENCY 2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh is missing or not executable"
[ -f "$SCHEMA" ] \
  || hard_fail "trace schema contract not found (${SCHEMA})"

APPROVED_SHA="1111111111111111111111111111111111111111"

issue_pad() {
  printf '%02d' "$1"
}

trace_path() {
  local name="$1" issue="$2" pad
  pad="$(issue_pad "$issue")"
  printf '%s' "${TMP_DIR}/${name}/.copilot-tracking/issues/issue-${pad}/trace.jsonl"
}

write_consistent_artifacts() {
  local root="$1" issue="$2" pad dir
  pad="$(issue_pad "$issue")"
  dir="${root}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$dir" "${root}/.copilot-tracking/review-gate"
  printf '%s\n' "$APPROVED_SHA" > "${root}/.copilot-tracking/review-gate/approved-head"

  cat > "${dir}/feature_list.json" <<JSON
{"issue":${issue},"features":[{"id":"feat-a","title":"A","steps":[],"passes":true}]}
JSON

  cat > "${dir}/progress.md" <<MD
# Issue ${issue} progress

Status: closing out.

PR: https://github.com/acme/widgets/pull/123

## Action Log

- [conductor] feature_start feat-a pass — selected feat-a next
- [test-subagent] red_handback feat-a pass — feat-a sensor RED first
- [implementation-subagent] impl_handback feat-a pass — implemented feat-a
- [test-subagent] green_handback feat-a pass — verified feat-a GREEN
MD
}

append_span() {
  local file="$1" json="$2"
  printf '%s\n' "$json" >> "$file"
}

write_trace() {
  local file="$1" issue="$2" include_finish="$3" tool_kind="$4"
  : > "$file"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:00Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"preflight\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:01Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"worktree_create\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:02Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"plan_handback\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:03Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"conductor\",\"harness.lifecycle_step\":\"feature_start\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:04Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"red_handback\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:05Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"implementation-subagent\",\"harness.lifecycle_step\":\"impl_handback\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:06Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"green_handback\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  case "$tool_kind" in
    none) ;;
    runtime)
      append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:07Z\",\"span\":\"tool\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.tool.name\":\"bash\",\"harness.session_id\":\"11111111-1111-4111-8111-111111111111\",\"harness.outcome\":\"pass\"}"
      ;;
    harness_only)
      append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:07Z\",\"span\":\"tool\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.tool.name\":\"review-gate.trace\",\"harness.outcome\":\"pass\",\"harness.violation_count\":0,\"harness.warning_count\":0}"
      ;;
    *) hard_fail "write_trace: unknown tool kind '${tool_kind}'" ;;
  esac
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:08Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"review_verdict\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:09Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"review_gate_approve\",\"harness.review_gate_sha\":\"${APPROVED_SHA}\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:10Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"pr_create\",\"harness.pr_number\":\"123\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:11Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.pr_number\":\"123\",\"harness.outcome\":\"pass\"}"
  if [ "$include_finish" = "yes" ]; then
    append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:12Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\"}"
  fi
}

mk_case() {
  local name="$1" issue="$2" include_finish="$3" tool_kind="$4" root dir trace
  root="${TMP_DIR}/${name}"
  dir="${root}/.copilot-tracking/issues/issue-$(issue_pad "$issue")"
  write_consistent_artifacts "$root" "$issue"
  trace="${dir}/trace.jsonl"
  write_trace "$trace" "$issue" "$include_finish" "$tool_kind"
  jq empty "$trace" >/dev/null 2>&1 \
    || hard_fail "fixture ${name}: trace.jsonl does not parse — sensor bug"
}

OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  env TMPDIR="$TMPDIR" "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}
run_checker_allow_dark() {
  local rc=0
  env TMPDIR="$TMPDIR" TRACE_ALLOW_DARK_RUN=1 "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

mk_case d1 243 yes none
mk_case d2 244 yes runtime
mk_case d3 245 yes harness_only
mk_case d4 246 no none

# D1: completed, otherwise consistent, zero runtime spans -> dark_run violation.
rc="$(run_checker "$(trace_path d1 243)")"
[ "$rc" = "1" ] \
  || fail "D1 dark_run: expected exit 1, got ${rc}; missing dark_run rule is the expected RED reason (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -Fq 'VIOLATION consistency: dark_run 243' "$OUT" \
  || fail "D1 dark_run: pinned finding 'VIOLATION consistency: dark_run 243' missing (stdout: $(tr '\n' '|' < "$OUT"))"

# D2: one runtime tool span (string harness.session_id) makes the run live.
rc="$(run_checker "$(trace_path d2 244)")"
[ "$rc" = "0" ] \
  || fail "D2 runtime span: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -q 'VIOLATION consistency: dark_run' "$OUT"; then
  fail "D2 runtime span: runtime tool span must suppress dark_run (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# D3: harness-owned tool span without harness.session_id must not mask darkness.
rc="$(run_checker "$(trace_path d3 245)")"
[ "$rc" = "1" ] \
  || fail "D3 harness-only tool span: expected exit 1, got ${rc}; missing dark_run rule is the expected RED reason (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: dark_run 245' "$OUT" \
  || fail "D3 harness-only tool span: pinned finding 'VIOLATION consistency: dark_run 245' missing (stdout: $(tr '\n' '|' < "$OUT"))"

# D4: incomplete window (worktree_create but no finish) note-skips dark_run.
rc="$(run_checker "$(trace_path d4 246)")"
[ "$rc" = "0" ] \
  || fail "D4 incomplete window: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Eq '^NOTE:.*dark_run' "$OUT" \
  || fail "D4 incomplete window: NOTE line naming dark_run is required (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION consistency: dark_run' "$OUT"; then
  fail "D4 incomplete window: dark_run must not fire before finish (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# D5: override note-skips dark_run on the completed dark fixture.
rc="$(run_checker_allow_dark "$(trace_path d1 243)")"
[ "$rc" = "0" ] \
  || fail "D5 override: expected exit 0 with TRACE_ALLOW_DARK_RUN=1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Eq '^NOTE:.*dark_run' "$OUT" \
  || fail "D5 override: NOTE line naming dark_run is required (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION consistency: dark_run' "$OUT"; then
  fail "D5 override: TRACE_ALLOW_DARK_RUN=1 must suppress dark_run violation (stdout: $(tr '\n' '|' < "$OUT"))"
fi

make_gate_fixture() {
  local dir="$1" issue="$2" pad wt tree commit
  pad="$(issue_pad "$issue")"
  wt="${dir}-worktrees/issue-${pad}"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/trace-schema.v1.json"
  local s
  for s in issue-lib.sh trace-lib.sh validate-trace.sh check-trace-consistency.sh review-gate.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/${s}"
  done
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md docs scripts
  tree="$(git -C "$dir" write-tree)"
  commit="$(printf 'initial\n' | git -C "$dir" commit-tree "$tree")"
  git -C "$dir" update-ref refs/heads/main "$commit"
  git -C "$dir" worktree add -q -b "feature/issue-${pad}-dark-run" "$wt"

  write_consistent_artifacts "$dir" "$issue"
  write_trace "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl" "$issue" yes none
}

GATE_ISSUE=247
GATE_MAIN="${TMP_DIR}/gate-main"
make_gate_fixture "$GATE_MAIN" "$GATE_ISSUE"
GATE_WT="${GATE_MAIN}-worktrees/issue-$(issue_pad "$GATE_ISSUE")"

run_gate() {
  local rc=0
  (cd "$GATE_WT" && env TMPDIR="$TMPDIR" "$@") >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# D7: review-gate.sh trace surfaces the finding but warns by default; the
# promotion flag makes the same finding blocking.
rc="$(run_gate ./scripts/review-gate.sh trace)"
[ "$rc" = "0" ] \
  || fail "D7 gate warn-only: expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -Fq "VIOLATION consistency: dark_run ${GATE_ISSUE}" "$OUT" \
  || fail "D7 gate warn-only: dark_run finding must be surfaced by review-gate.sh trace (output: $(tr '\n' '|' < "$OUT"))"

rc="$(run_gate REQUIRE_TRACE_CONSISTENCY=1 ./scripts/review-gate.sh trace)"
[ "$rc" != "0" ] \
  || fail "D7 gate blocking: REQUIRE_TRACE_CONSISTENCY=1 must make dark_run non-zero (output: $(tr '\n' '|' < "$OUT"))"
grep -Fq "VIOLATION consistency: dark_run ${GATE_ISSUE}" "$OUT" \
  || fail "D7 gate blocking: dark_run finding must still be printed when blocking (output: $(tr '\n' '|' < "$OUT"))"

if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-dark-run-liveness RED expectation failure(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-dark-run-liveness contract honored\n'
