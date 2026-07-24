#!/usr/bin/env bash
# test_trace_consistency_core.sh — regression sensor for the cross-artifact
# consistency checker core (issue #103, features trace-consistency-core and
# trace-consistency-state; issue #332 retires reconciliation).
#
# Executable spec for `scripts/check-trace-consistency.sh
# <issue-number|trace-path>` — the report-only cross-artifact checker in the
# same CLI family as check-trace-consistency.sh (findings to stdout, exit 0 no
# findings · 1 findings · 2 usage/environment error). Path mode, pinned
# here: the argument names trace.jsonl and the checker resolves progress.md
# as a SIBLING file in the same directory (hermetic L0 fixtures — the sensor
# never reads real .copilot-tracking state).
#
# Rules pinned by this sensor (finding formats frozen):
#
#   log_without_span / span_without_log — RETIRED (issue #332): trace.jsonl
#     is now the canonical record; progress.md Action Log is rendered from
#     spans by render-action-log.sh. Pre-renderer records (spans written
#     alongside bullets by the old dual-write log-handback.sh) are tolerated
#     as-is — the detector is removed and no reconciliation violation fires
#     for any mismatch between spans and progress.md bullets.
#
#   role_attribution_gap — every span=="agent" line must carry a
#     gen_ai.agent.name inside the schema's historical reader enum. The writer
#     itself accepts only the current conductor role. Pinned shape (line-numbered,
#     value-free — an out-of-enum role is an attribute VALUE and is not
#     echoed):
#         VIOLATION consistency: role_attribution_gap line <N>
#
# Legs:
#   1. Fixture pair produced by the REAL log-handback.sh -> exit 0, zero
#      VIOLATION findings.
#   2. Reconciliation retired (issue #332): extra Action Log bullet with no
#      span -> exit 0, NO log_without_span violation (detector removed).
#      Legacy carve-out proof: pre-renderer dual-write records are tolerated.
#   3. Reconciliation retired (issue #332): bullet removed for a real span
#      -> exit 0, NO span_without_log violation (detector removed).
#      Legacy carve-out proof: trace-only records are tolerated.
#   4a. Hand-written agent span with NO gen_ai.agent.name -> exit 1 +
#       role_attribution_gap naming the line.
#   4b. Hand-written agent span with an OUT-OF-ENUM role AND a matching
#       Action Log bullet -> role_attribution_gap still fires; proves the
#       gap rule is independent of span/bullet content.
#   5. CLI family: no args -> exit 2 + usage on stderr; nonexistent trace
#      path -> exit 2.
#   6. (#103 loop-2 review F6) Corrupt-line tolerance: ONE non-JSON line
#      inserted into an otherwise consistent trace -> the consolidated checker
#      reports invalid_json (schema family, folded from validate-trace.sh in
#      #335) while the cross-artifact pass still RUNS (no crash, no exit 2).
#      After reconciliation retirement (#332) no reconciliation finding fires
#      alongside the flagged corrupt line.
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not
# exist — every leg fails at the presence gate.
# Issue-332 note: legs 2 and 3 deliberately pin the RETIRED state — they
# fail RED against any checker that still has the old detector, and pass
# GREEN once the detector is removed.
#
# Exit codes: 0 consistency-core contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
HELPER="${ROOT}/scripts/log-handback.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The fixture must control tracing entirely: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  TRACE_FAILURE_MODE 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -f "$HELPER" ] \
  || hard_fail "scripts/log-handback.sh not found (${HELPER}) — fixtures are built with the real emitter"
[ -f "$LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${LIB})"

# RED gate: the script under test must exist before behavior can be specified.
[ -f "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the cross-artifact consistency checker for feature trace-consistency-core (issue #103 Phase 2) is not implemented yet"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"
[ ! -e "${ROOT}/scripts/check-sensor-claims.sh" ] \
  || fail "retired advisory sensor-claim checker still exists"
if grep -qE 'SENSOR_CLAIM_(TRANSCRIPT|HEAD)|check-sensor-claims' "$CHECKER"; then
  fail "trace consistency checker still carries the retired sensor-claim hook"
fi

# (Issue #332: the META ORACLE DETECTOR block was removed along with the parity
# leg. The reconciliation oracle meta-test is deleted; reconciliation is retired.)

# --- Fixture: MAIN repo + linked worktree, pairs produced by the REAL helper ---
MAIN="${TMP_DIR}/main-repo"
mkdir -p "${MAIN}/scripts"
cp "$HELPER" "${MAIN}/scripts/log-handback.sh"
cp "$LIB" "${MAIN}/scripts/trace-lib.sh"
cp "${ROOT}/scripts/render-action-log.sh" "${MAIN}/scripts/render-action-log.sh"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.name "Harness Test"
git -C "$MAIN" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > "${MAIN}/.gitignore"
git -C "$MAIN" add .gitignore scripts
git -C "$MAIN" commit -q -m initial

WT="${TMP_DIR}/wt-issue-33"
git -C "$MAIN" worktree add -q -b feature/issue-33-fixture "$WT"
mkdir -p "${WT}/.copilot-tracking/issues/issue-33"
cat > "${WT}/.copilot-tracking/issues/issue-33/progress.md" <<'MD'
# Issue 33 progress

Status: in progress.

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
MD

if (cd "$WT" && ./scripts/log-handback.sh test-subagent red_handback demo-feature pass "legacy writer probe") \
    >/dev/null 2>&1; then
  hard_fail "writer must reject retired subagent/handback shapes"
fi
(cd "$WT" && ./scripts/log-handback.sh conductor feature_start demo-feature pass "selected demo-feature") \
  >/dev/null 2>&1 || hard_fail "fixture: helper call 1 (feature_start) failed"
(cd "$WT" && TRACE_FAILURE_MODE=weak-sensor \
  TRACE_FAILURE_CLASS=regression TRACE_FAILURE_DISPOSITION=point-fix \
  ./scripts/log-handback.sh conductor deviation demo-feature blocked "sensor gap found") \
  >/dev/null 2>&1 || hard_fail "fixture: helper call 2 (deviation) failed"

HELPER_TRACE="${MAIN}/.copilot-tracking/issues/issue-33/trace.jsonl"
HELPER_PROG="${WT}/.copilot-tracking/issues/issue-33/progress.md"
# Historical reader compatibility: the narrowed writer cannot create this
# shape, but the checker must continue to accept existing traces that contain it.
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T12:00:02Z","span":"agent","harness.issue":33,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"demo-feature","harness.outcome":"pass"}' \
  >> "$HELPER_TRACE"
[ "$(jq -s '[.[] | select(.span == "agent")] | length' "$HELPER_TRACE")" = "3" ] \
  || hard_fail "fixture: expected 2 current writer spans plus one legacy reader span"
[ "$(grep -c '^- \[' "$HELPER_PROG")" = "2" ] \
  || hard_fail "fixture: expected 2 helper-produced Action Log bullets in ${HELPER_PROG}"

# Case dirs: trace.jsonl + progress.md side by side (the pinned path-mode
# artifact resolution); mutations happen on copies only.
mk_case() {
  local name="$1"
  mkdir -p "${TMP_DIR}/${name}"
  cp "$HELPER_TRACE" "${TMP_DIR}/${name}/trace.jsonl"
  cp "$HELPER_PROG" "${TMP_DIR}/${name}/progress.md"
}
mk_case case1
mk_case case2
printf -- '- [test-subagent] green_handback demo-feature pass — hand-written claim, no span emitted\n' \
  >> "${TMP_DIR}/case2/progress.md"
mk_case case3
grep -v 'deviation' "$HELPER_PROG" > "${TMP_DIR}/case3/progress.md"
mk_case case4a
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T12:00:09Z","span":"agent","harness.issue":33,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","harness.lifecycle_step":"impl_handback","harness.feature_id":"demo-feature","harness.outcome":"pass"}' \
  >> "${TMP_DIR}/case4a/trace.jsonl"
GAP_LINE_4A="$(wc -l < "${TMP_DIR}/case4a/trace.jsonl" | tr -d '[:space:]')"
mk_case case4b
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T12:00:09Z","span":"agent","harness.issue":33,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"janitor","harness.lifecycle_step":"impl_handback","harness.feature_id":"demo-feature","harness.outcome":"pass"}' \
  >> "${TMP_DIR}/case4b/trace.jsonl"
GAP_LINE_4B="$(wc -l < "${TMP_DIR}/case4b/trace.jsonl" | tr -d '[:space:]')"
printf -- '- [janitor] impl_handback demo-feature pass — rogue-role handback, tuple matches its span\n' \
  >> "${TMP_DIR}/case4b/progress.md"

# --- Checker run helper ----------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- 1. Consistent helper-produced pair -> exit 0, zero findings ------------------
rc="$(run_checker "${TMP_DIR}/case1/trace.jsonl")"
[ "$rc" = "0" ] \
  || fail "consistent pair: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -q '^VIOLATION ' "$OUT"; then
  fail "consistent pair: zero VIOLATION findings expected (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 2. Reconciliation retired: extra bullet with no span -> NO log_without_span (issue #332) ---
# Legacy carve-out: pre-renderer dual-write records (or any mismatch) are
# tolerated as-is once reconciliation is retired.
rc="$(run_checker "${TMP_DIR}/case2/trace.jsonl")"
[ "$rc" = "0" ] \
  || fail "reconciliation-retired (log_without_span): extra bullet must not fire — expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -q 'log_without_span' "$OUT"; then
  fail "reconciliation-retired: log_without_span detection is retired — no violation may fire for an extra bullet (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 3. Reconciliation retired: missing bullet for real span -> NO span_without_log (issue #332) ---
# Legacy carve-out: a trace-only record (no bullet) is also tolerated.
rc="$(run_checker "${TMP_DIR}/case3/trace.jsonl")"
[ "$rc" = "0" ] \
  || fail "reconciliation-retired (span_without_log): missing bullet must not fire — expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
if grep -q 'span_without_log' "$OUT"; then
  fail "reconciliation-retired: span_without_log detection is retired — no violation may fire for a missing bullet (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 4a. Agent span with NO gen_ai.agent.name -> role_attribution_gap -------------
rc="$(run_checker "${TMP_DIR}/case4a/trace.jsonl")"
[ "$rc" = "1" ] \
  || fail "role gap (missing name): expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq "VIOLATION consistency: role_attribution_gap line ${GAP_LINE_4A}" "$OUT" \
  || fail "role gap (missing name): pinned finding 'VIOLATION consistency: role_attribution_gap line ${GAP_LINE_4A}' missing (stdout: $(tr '\n' '|' < "$OUT"))"

# --- 4b. Out-of-enum role, tuple-matched bullet -> gap fires alone ----------------
rc="$(run_checker "${TMP_DIR}/case4b/trace.jsonl")"
[ "$rc" = "1" ] \
  || fail "role gap (out-of-enum): expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq "VIOLATION consistency: role_attribution_gap line ${GAP_LINE_4B}" "$OUT" \
  || fail "role gap (out-of-enum): pinned finding 'VIOLATION consistency: role_attribution_gap line ${GAP_LINE_4B}' missing (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -Eq 'log_without_span|span_without_log' "$OUT"; then
  fail "role gap (out-of-enum): reconciliation is retired, no log/span finding may fire (stdout: $(tr '\n' '|' < "$OUT"))"
fi
if grep -q 'janitor' "$OUT"; then
  # No multiset finding fires here (asserted above), so the offending role
  # VALUE has no legitimate carrier line — the gap finding is value-free
  # (plan decision 6: rule names, tuples of enum-valued fields, line
  # numbers, SHAs only).
  fail "role gap (out-of-enum): the report echoed the offending role value (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 5. CLI family: usage/environment errors exit 2 -------------------------------
rc="$(run_checker)"
[ "$rc" = "2" ] \
  || fail "no args: expected exit 2 (usage error), got ${rc}"
[ -s "$ERR" ] \
  || fail "no args: a usage message on stderr is required"
rc="$(run_checker "${TMP_DIR}/does-not-exist/trace.jsonl")"
[ "$rc" = "2" ] \
  || fail "missing trace file: expected exit 2 (environment error), got ${rc}"

# --- 7. Corrupt-line tolerance (loop-2 review F6) ----------------------------------
# One non-JSON line spliced into the middle of the consistent case-1 trace.
mkdir -p "${TMP_DIR}/case7"
{
  head -n 1 "${TMP_DIR}/case1/trace.jsonl"
  printf 'CORRUPT_FIXTURE_LINE not json {\n'
  tail -n +2 "${TMP_DIR}/case1/trace.jsonl"
} > "${TMP_DIR}/case7/trace.jsonl"
cp "${TMP_DIR}/case1/progress.md" "${TMP_DIR}/case7/progress.md"
[ "$(wc -l < "${TMP_DIR}/case7/trace.jsonl" | tr -d '[:space:]')" = "4" ] \
  || hard_fail "case7 fixture: expected 4 lines (3 spans + 1 corrupt) — sensor bug"

rc="$(run_checker "${TMP_DIR}/case7/trace.jsonl")"
[ "$rc" = "1" ] \
  || fail "corrupt handling: invalid_json must fail without crashing the cross-artifact pass — expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -Fq 'VIOLATION line 2: invalid_json' "$OUT" \
  || fail "corrupt handling: consolidated checker must report invalid_json"
if grep -q '^VIOLATION consistency:' "$OUT"; then
  fail "corrupt handling: the consistent pair must produce no cross-artifact finding (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# Same corrupt trace + the case-2 progress.md (extra bullet): after
# reconciliation retirement, the extra bullet fires no violation, so the
# corrupt trace + extra bullet still exits 0.
cp "${TMP_DIR}/case2/progress.md" "${TMP_DIR}/case7/progress.md"
rc="$(run_checker "${TMP_DIR}/case7/trace.jsonl")"
[ "$rc" = "1" ] \
  || fail "corrupt tolerance: consolidated checker must report the corrupt line as invalid_json (findings exit 1, never 2/crash), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -q 'invalid_json' "$OUT" \
  || fail "corrupt tolerance: folded schema pass (#335) must flag the corrupt line as invalid_json (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -Eq 'log_without_span|span_without_log' "$OUT"; then
  fail "corrupt tolerance: retired reconciliation findings must not fire (#332) (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 8. Folded schema/redaction judgments ------------------------------------
expect_finding() {
  local name="$1" expected="$2"
  shift 2
  local dir="${TMP_DIR}/${name}" finding_rc
  mkdir -p "$dir"
  printf '# Progress\n\n## Action Log\n' > "${dir}/progress.md"
  printf '%s\n' "$@" > "${dir}/trace.jsonl"
  finding_rc="$(run_checker "${dir}/trace.jsonl")"
  [ "$finding_rc" = "1" ] \
    || fail "${name}: expected findings exit 1, got ${finding_rc}"
  grep -Fq "$expected" "$OUT" \
    || fail "${name}: missing ${expected} (stdout: $(tr '\n' '|' < "$OUT"))"
}

VALID_TOOL='{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":33,"harness.version":"abc1234","gen_ai.tool.name":"git"}'
expect_finding folded-invalid-json 'VIOLATION line 2: invalid_json' \
  "$VALID_TOOL" 'not json {'
expect_finding folded-schema 'VIOLATION line 2: schema_violation' \
  "$VALID_TOOL" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"banana","harness.issue":33,"harness.version":"abc1234"}'
expect_finding folded-type 'VIOLATION line 2: type_violation' \
  "$VALID_TOOL" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"lifecycle","harness.issue":33,"harness.version":"abc1234","harness.lifecycle_step":"preflight","harness.duration_ms":"42"}'

GHP_SECRET="ghp_SyntheticFixtureToken0123456789abcd"
expect_finding folded-redaction 'VIOLATION line 1: redaction_leak' \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":33,"harness.version":"abc1234","gen_ai.tool.name":"git","harness.summary":"'"${GHP_SECRET}"'"}'
if grep -Fq "$GHP_SECRET" "$OUT" "$ERR"; then
  fail "redaction finding echoed the planted secret"
fi

# --- 9. Finished completeness follows the current lifecycle, not retired
# handback steps that remain schema-readable.
complete_dir="${TMP_DIR}/current-complete"
mkdir -p "$complete_dir"
printf '# Progress\n\n## Action Log\n' > "${complete_dir}/progress.md"
for step in preflight worktree_create review_gate_approve pr_create pr_merge finish; do
  printf '{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"lifecycle","harness.issue":33,"harness.version":"abc1234","harness.lifecycle_step":"%s"}\n' \
    "$step"
done > "${complete_dir}/trace.jsonl"
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"agent","harness.issue":33,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"f1","harness.outcome":"pass"}' \
  >> "${complete_dir}/trace.jsonl"
rc="$(run_checker "${complete_dir}/trace.jsonl")"
[ "$rc" = "0" ] \
  || fail "current six-step finished lifecycle must be complete ($(tr '\n' '|' < "$OUT"))"
grep -v '"harness.lifecycle_step":"pr_merge"' "${complete_dir}/trace.jsonl" \
  > "${complete_dir}/missing.jsonl"
cp "${complete_dir}/progress.md" "${complete_dir}/progress.md.tmp"
mv "${complete_dir}/progress.md.tmp" "${complete_dir}/progress.md"
rc="$(run_checker "${complete_dir}/missing.jsonl")"
[ "$rc" = "1" ] || fail "finished lifecycle missing pr_merge must fail"
grep -Fq 'VIOLATION completeness: missing lifecycle step pr_merge' "$OUT" \
  || fail "current lifecycle completeness did not report missing pr_merge"
if grep -Eq 'missing lifecycle step (red_handback|impl_handback|green_handback|plan_handback)' "$OUT"; then
  fail "retired handback steps still participate in completeness"
fi

# --- 10. Folded state judgments remain marker-only and scan the final PR ref.
state_root="${TMP_DIR}/state/.copilot-tracking"
state_dir="${state_root}/issues/issue-77"
mkdir -p "$state_dir" "${state_root}/review-gate"
printf '# Progress\n\nPR: https://github.com/example/repo/pull/123\n\n## Action Log\n' \
  > "${state_dir}/progress.md"
printf '{"features":[]}\n' > "${state_dir}/feature_list.json"
printf '%s\n' 1111111111111111111111111111111111111111 \
  > "${state_root}/review-gate/approved-head"
cat > "${state_dir}/trace.jsonl" <<'TRACE'
{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"lifecycle","harness.issue":77,"harness.version":"abc1234","harness.lifecycle_step":"review_gate_approve","harness.review_gate_sha":"1111111111111111111111111111111111111111"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"lifecycle","harness.issue":77,"harness.version":"abc1234","harness.lifecycle_step":"pr_create","harness.pr_number":"123"}
TRACE
rc="$(run_checker "${state_dir}/trace.jsonl")"
[ "$rc" = "0" ] || fail "matching review marker and PR reference must pass"

# Issue-scoped approval state wins over a stale legacy marker (#398).
mkdir -p "${state_root}/review-gate/issue-77"
printf '%s\n' 2222222222222222222222222222222222222222 \
  > "${state_root}/review-gate/approved-head"
printf '%s\n' 1111111111111111111111111111111111111111 \
  > "${state_root}/review-gate/issue-77/approved-head"
rc="$(run_checker "${state_dir}/trace.jsonl")"
[ "$rc" = "0" ] || fail "issue-scoped review marker must override stale legacy state"

printf '%s\n' 2222222222222222222222222222222222222222 \
  > "${state_root}/review-gate/issue-77/approved-head"
rc="$(run_checker "${state_dir}/trace.jsonl")"
[ "$rc" = "1" ] || fail "mismatched review marker must fail"
grep -Fq 'VIOLATION consistency: review_sha_mismatch' "$OUT" \
  || fail "review marker mismatch finding is missing"
rm -rf "${state_root}/review-gate/issue-77"
printf '%s\n' 1111111111111111111111111111111111111111 \
  > "${state_root}/review-gate/approved-head"
printf '# Progress\n\nSplit from https://github.com/example/repo/pull/55\nPR: https://github.com/example/repo/pull/124\n\n## Action Log\n' \
  > "${state_dir}/progress.md"
rc="$(run_checker "${state_dir}/trace.jsonl")"
[ "$rc" = "1" ] || fail "mismatched final PR reference must fail"
grep -Fq 'VIOLATION consistency: pr_mismatch' "$OUT" \
  || fail "PR mismatch finding is missing"

# --- 11. Secure scratch creation is mandatory; no predictable fallback.
no_mktemp_bin="${TMP_DIR}/no-mktemp-bin"
mkdir -p "$no_mktemp_bin"
for tool in bash dirname basename git jq mkdir rm; do
  tool_path="$(command -v "$tool")"
  ln -s "$tool_path" "${no_mktemp_bin}/${tool}"
done
set +e
PATH="$no_mktemp_bin" "$CHECKER" "${state_dir}/trace.jsonl" >"$OUT" 2>"$ERR"
no_mktemp_rc=$?
set -e
[ "$no_mktemp_rc" = "2" ] \
  || fail "checker without mktemp must exit 2 (got ${no_mktemp_rc})"
grep -qi 'mktemp is required' "$ERR" \
  || fail "checker without mktemp must explain the hard requirement"

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-consistency-core contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-consistency-core contract honored\n'
