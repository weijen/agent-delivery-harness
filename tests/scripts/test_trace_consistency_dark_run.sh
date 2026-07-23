#!/usr/bin/env bash
# test_trace_consistency_dark_run.sh — regression sensor for issue #305,
# feature rescope-dark-run.
#
# Runtime capture is retired: "no runtime tool spans" is now the NORMAL state,
# so the old dark_run rule (fire when a complete window has zero runtime tool
# spans) is re-scoped. The rule now guards the SEMANTIC SPINE: on a complete
# issue window (worktree_create + finish lifecycle spans) at least one handback
# agent span (harness.lifecycle_step in red_handback|impl_handback|
# green_handback) or a conductor feature_start agent span must be present. An
# empty spine on a complete window is:
#
#   VIOLATION consistency: spine_incomplete <issue>
#
# Runtime tool spans NO LONGER affect the outcome — the SPINE suppresses the
# finding, not a runtime tool span (the old "runtime span suppresses dark_run"
# is inverted). TRACE_ALLOW_DARK_RUN=1 (env name kept for compatibility) skips
# the block with a NOTE; an incomplete window (missing worktree_create or
# finish) also NOTE-skips.
#
# Cases:
#   S1 spine_present_passes      complete window + handback spine, ZERO runtime
#                                tool spans -> exit 0, no spine_incomplete
#                                (the spine, not a runtime span, suppresses it).
#   S2 no_spine_fires            complete window, NO spine spans -> exit 1,
#                                spine_incomplete <issue>.
#   S3 runtime_does_not_suppress complete window, NO spine spans, WITH a runtime
#                                tool span -> exit 1, spine_incomplete <issue>
#                                (runtime tool spans no longer matter).
#   S4 incomplete_window_skips   worktree_create but no finish -> NOTE-skip,
#                                exit 0, no violation.
#   S5 override_skips            complete no-spine window + TRACE_ALLOW_DARK_RUN=1
#                                -> NOTE-skip and no spine_incomplete finding;
#                                consolidated completeness findings remain live.
#   S7 gate surfacing            review-gate.sh trace surfaces spine_incomplete
#                                warn-only (exit 0); REQUIRE_TRACE_CONSISTENCY=1
#                                makes the same finding blocking.

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

append_span() {
  local file="$1" json="$2"
  printf '%s\n' "$json" >> "$file"
}

# A fully consistent, spine-PRESENT artifact set: the Action Log carries the
# feature_start + handback + review_verdict bullets that match the spine trace,
# and the single feature passes (backed by feature_start + green_handback +
# review_verdict spans).
write_spine_artifacts() {
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

Conclusion: merged; review verdict: approved.

PR: https://github.com/acme/widgets/pull/123

## Action Log

- [conductor] feature_start feat-a pass — selected feat-a next
- [test-subagent] red_handback feat-a pass — feat-a sensor RED first
- [implementation-subagent] impl_handback feat-a pass — implemented feat-a
- [test-subagent] green_handback feat-a pass — verified feat-a GREEN
- [code-review-subagent] review_verdict feat-a pass — approved feat-a at end review
MD
}

# A fully consistent, spine-ABSENT artifact set: no Action Log bullets (so
# log_without_span never fires), and the single feature stays passes:false (so
# the state rules that key on passing features never fire). The ONLY finding a
# complete window here can produce is spine_incomplete.
write_nospine_artifacts() {
  local root="$1" issue="$2" pad dir
  pad="$(issue_pad "$issue")"
  dir="${root}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$dir" "${root}/.copilot-tracking/review-gate"
  printf '%s\n' "$APPROVED_SHA" > "${root}/.copilot-tracking/review-gate/approved-head"

  cat > "${dir}/feature_list.json" <<JSON
{"issue":${issue},"features":[{"id":"feat-a","title":"A","steps":[],"passes":false}]}
JSON

  cat > "${dir}/progress.md" <<MD
# Issue ${issue} progress

Conclusion: abandoned; review verdict: n-a.

## Action Log
MD
}

# Spine-PRESENT trace: the full feature_start + red/impl/green handback +
# review_verdict agent spine, no runtime tool spans, complete lifecycle window.
write_spine_trace() {
  local file="$1" issue="$2"
  : > "$file"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:00Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"preflight\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:01Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"worktree_create\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:02Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"plan_handback\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:03Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"conductor\",\"harness.lifecycle_step\":\"feature_start\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:04Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"red_handback\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:05Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"implementation-subagent\",\"harness.lifecycle_step\":\"impl_handback\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:06Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"green_handback\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:08Z\",\"span\":\"agent\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"code-review-subagent\",\"harness.lifecycle_step\":\"review_verdict\",\"harness.feature_id\":\"feat-a\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:09Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"review_gate_approve\",\"harness.review_gate_sha\":\"${APPROVED_SHA}\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:10Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"pr_create\",\"harness.pr_number\":\"123\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:11Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.pr_number\":\"123\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:12Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\"}"
}

# Spine-ABSENT trace: only lifecycle spans (preflight, worktree_create,
# optional finish) and an optional runtime tool span — NO agent spans at all,
# so the semantic spine is empty.
write_nospine_trace() {
  local file="$1" issue="$2" include_finish="$3" include_runtime="$4"
  : > "$file"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:00Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"preflight\",\"harness.outcome\":\"pass\"}"
  append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:01Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"worktree_create\",\"harness.outcome\":\"pass\"}"
  if [ "$include_runtime" = "yes" ]; then
    append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:07Z\",\"span\":\"tool\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"gen_ai.tool.name\":\"bash\",\"harness.session_id\":\"11111111-1111-4111-8111-111111111111\",\"harness.outcome\":\"pass\"}"
  fi
  if [ "$include_finish" = "yes" ]; then
    append_span "$file" "{\"schema_version\":1,\"timestamp\":\"2026-07-09T12:00:12Z\",\"span\":\"lifecycle\",\"harness.issue\":${issue},\"harness.version\":\"abc1234\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\"}"
  fi
}

mk_spine_case() {
  local name="$1" issue="$2" root dir trace
  root="${TMP_DIR}/${name}"
  dir="${root}/.copilot-tracking/issues/issue-$(issue_pad "$issue")"
  write_spine_artifacts "$root" "$issue"
  trace="${dir}/trace.jsonl"
  write_spine_trace "$trace" "$issue"
  jq empty "$trace" >/dev/null 2>&1 \
    || hard_fail "fixture ${name}: trace.jsonl does not parse — sensor bug"
}

mk_nospine_case() {
  local name="$1" issue="$2" include_finish="$3" include_runtime="$4" root dir trace
  root="${TMP_DIR}/${name}"
  dir="${root}/.copilot-tracking/issues/issue-$(issue_pad "$issue")"
  write_nospine_artifacts "$root" "$issue"
  trace="${dir}/trace.jsonl"
  write_nospine_trace "$trace" "$issue" "$include_finish" "$include_runtime"
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

mk_spine_case s1 243
mk_nospine_case s2 244 yes no
mk_nospine_case s3 245 yes yes
mk_nospine_case s4 246 no no
mk_nospine_case s5 247 yes no

# S1: complete window WITH a handback spine and ZERO runtime tool spans passes —
# the spine, not a runtime span, suppresses the finding.
rc="$(run_checker "$(trace_path s1 243)")"
[ "$rc" = "0" ] \
  || fail "S1 spine present: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -q 'VIOLATION consistency: spine_incomplete' "$OUT"; then
  fail "S1 spine present: a present spine must suppress spine_incomplete even with zero runtime tool spans (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# S2: complete window with NO spine spans -> spine_incomplete violation.
rc="$(run_checker "$(trace_path s2 244)")"
[ "$rc" = "1" ] \
  || fail "S2 no spine: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -Fq 'VIOLATION consistency: spine_incomplete 244' "$OUT" \
  || fail "S2 no spine: pinned finding 'VIOLATION consistency: spine_incomplete 244' missing (stdout: $(tr '\n' '|' < "$OUT"))"

# S3: runtime tool spans no longer matter — a complete window with a runtime
# tool span but NO spine still fires spine_incomplete.
rc="$(run_checker "$(trace_path s3 245)")"
[ "$rc" = "1" ] \
  || fail "S3 runtime does not suppress: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -Fq 'VIOLATION consistency: spine_incomplete 245' "$OUT" \
  || fail "S3 runtime does not suppress: a runtime tool span must NOT suppress spine_incomplete (stdout: $(tr '\n' '|' < "$OUT"))"

# S4: incomplete window (worktree_create but no finish) NOTE-skips.
rc="$(run_checker "$(trace_path s4 246)")"
[ "$rc" = "0" ] \
  || fail "S4 incomplete window: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Eq '^NOTE:.*spine_incomplete' "$OUT" \
  || fail "S4 incomplete window: NOTE line naming spine_incomplete is required (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION consistency: spine_incomplete' "$OUT"; then
  fail "S4 incomplete window: spine_incomplete must not fire before finish (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# S5: override NOTE-skips spine_incomplete on the complete no-spine fixture.
rc="$(run_checker_allow_dark "$(trace_path s5 247)")"
[ "$rc" != "2" ] \
  || fail "S5 override: checker must run with TRACE_ALLOW_DARK_RUN=1 (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Eq '^NOTE:.*spine_incomplete' "$OUT" \
  || fail "S5 override: NOTE line naming spine_incomplete is required (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION consistency: spine_incomplete' "$OUT"; then
  fail "S5 override: TRACE_ALLOW_DARK_RUN=1 must suppress spine_incomplete violation (stdout: $(tr '\n' '|' < "$OUT"))"
fi

make_gate_fixture() {
  local dir="$1" issue="$2" pad wt tree commit
  pad="$(issue_pad "$issue")"
  wt="${dir}/.worktrees/issue-${pad}"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/trace-schema.v1.json"
  local s
  for s in issue-lib.sh trace-lib.sh check-trace-consistency.sh review-gate.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/${s}"
  done
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md docs scripts
  tree="$(git -C "$dir" write-tree)"
  commit="$(printf 'initial\n' | git -C "$dir" commit-tree "$tree")"
  git -C "$dir" update-ref refs/heads/main "$commit"
  git -C "$dir" worktree add -q -b "feature/issue-${pad}-dark-run" "$wt"

  write_nospine_artifacts "$dir" "$issue"
  write_nospine_trace "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl" "$issue" yes no
}

GATE_ISSUE=248
GATE_MAIN="${TMP_DIR}/gate-main"
make_gate_fixture "$GATE_MAIN" "$GATE_ISSUE"
GATE_WT="${GATE_MAIN}/.worktrees/issue-$(issue_pad "$GATE_ISSUE")"

run_gate() {
  local rc=0
  (cd "$GATE_WT" && env TMPDIR="$TMPDIR" "$@") >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# S7: review-gate.sh trace surfaces the finding but warns by default; the
# promotion flag makes the same finding blocking.
rc="$(run_gate ./scripts/review-gate.sh trace)"
[ "$rc" = "0" ] \
  || fail "S7 gate warn-only: expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -Fq "VIOLATION consistency: spine_incomplete ${GATE_ISSUE}" "$OUT" \
  || fail "S7 gate warn-only: spine_incomplete finding must be surfaced by review-gate.sh trace (output: $(tr '\n' '|' < "$OUT"))"

rc="$(run_gate REQUIRE_TRACE_CONSISTENCY=1 ./scripts/review-gate.sh trace)"
[ "$rc" != "0" ] \
  || fail "S7 gate blocking: REQUIRE_TRACE_CONSISTENCY=1 must make spine_incomplete non-zero (output: $(tr '\n' '|' < "$OUT"))"
grep -Fq "VIOLATION consistency: spine_incomplete ${GATE_ISSUE}" "$OUT" \
  || fail "S7 gate blocking: spine_incomplete finding must still be printed when blocking (output: $(tr '\n' '|' < "$OUT"))"

if [ "$fails" -ne 0 ]; then
  printf '\n%d rescope-dark-run RED expectation failure(s).\n' "$fails" >&2
  exit 1
fi
printf 'rescope-dark-run spine_incomplete contract honored\n'
