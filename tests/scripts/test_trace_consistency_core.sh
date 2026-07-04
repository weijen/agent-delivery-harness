#!/usr/bin/env bash
# test_trace_consistency_core.sh — regression sensor for the cross-artifact
# consistency checker core (issue #103, feature trace-consistency-core,
# plan Phase 2).
#
# Executable spec for `scripts/check-trace-consistency.sh
# <issue-number|trace-path>` — the report-only cross-artifact checker in the
# same CLI family as validate-trace.sh (findings to stdout, exit 0 no
# findings · 1 findings · 2 usage/environment error). Path mode, pinned
# here: the argument names trace.jsonl and the checker resolves progress.md
# as a SIBLING file in the same directory (hermetic L0 fixtures — the sensor
# never reads real .copilot-tracking state).
#
# Rules pinned by this sensor (finding formats frozen):
#
#   log_without_span / span_without_log — the lifted #95 multiset detector:
#     compare `[role] step feature_id outcome` tuples from span=="agent"
#     trace lines against the `## Action Log` payload bullets of progress.md
#     (`- [<role>] <step> <feature_id> <outcome> — <summary>`, exactly what
#     log-handback.sh writes). Pinned finding shapes:
#         VIOLATION consistency: log_without_span [<role>] <step> <feature_id> <outcome>
#         VIOLATION consistency: span_without_log [<role>] <step> <feature_id> <outcome>
#     Echoing the tuple is deliberate and safe: the tuple is enum-valued
#     fields already public in progress.md (plan decision 6) — free-text
#     summaries are never echoed.
#
#   role_attribution_gap — every span=="agent" line must carry a
#     gen_ai.agent.name inside the closed log-handback role enum
#     (conductor | planning-subagent | implementation-subagent |
#     test-subagent | code-review-subagent). Pinned shape (line-numbered,
#     value-free — an out-of-enum role is an attribute VALUE and is not
#     echoed):
#         VIOLATION consistency: role_attribution_gap line <N>
#
# Legs:
#   1. Fixture pair produced by the REAL log-handback.sh (single-source
#      emitter, same MAIN-repo + linked-worktree pattern as the meta oracle)
#      -> exit 0, zero VIOLATION findings.
#   2. Hand-appended Action Log bullet with no span -> exit 1 + the pinned
#      log_without_span finding naming the exact tuple; nothing misreported
#      as span_without_log.
#   3. Bullet removed for a real span -> exit 1 + the pinned span_without_log
#      finding; nothing misreported as log_without_span.
#   4a. Hand-written agent span with NO gen_ai.agent.name (log-handback
#       always sets it; only a hand-written span can lack it) -> exit 1 +
#       role_attribution_gap naming the line.
#   4b. Hand-written agent span with an OUT-OF-ENUM role AND a matching
#       Action Log bullet (multisets agree!) -> role_attribution_gap still
#       fires, and neither log_without_span nor span_without_log does —
#       proves the gap rule is independent of the multiset comparison.
#   5. Parity leg: on the case-1/2/3 fixtures, this sensor re-runs the meta
#      oracle's detector pipeline (tests/meta/test_trace_action_log_consistency.sh
#      detect(): jq tuple extraction + awk section slice + sed bullet parse +
#      comm side-selection, copied VERBATIM below) and asserts the live
#      checker reports exactly the same tuple multisets under the underscore
#      rule names. Honesty mechanism (plan decision 5): the meta test keeps
#      its own inlined mutation-tested copy; THIS leg holds the live script
#      to tuple-for-tuple parity with that logic, so weakening the live
#      comparison breaks this sensor even if the meta test still passes.
#   6. CLI family: no args -> exit 2 + usage on stderr; nonexistent trace
#      path -> exit 2.
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not
# exist — every leg fails at the presence gate.
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

# ============================================================================
# META ORACLE DETECTOR (copied VERBATIM from
# tests/meta/test_trace_action_log_consistency.sh detect() — the #95
# mutation-tested reference; only the temp-file names differ). Used by the
# parity leg to hold the live checker to tuple-for-tuple agreement.
# ============================================================================
oracle_detect() {
  local trace="$1" progress="$2"
  local spans="${TMP_DIR}/oracle-spans" logs="${TMP_DIR}/oracle-logs"
  if [ -f "$trace" ]; then
    jq -r 'select(.span == "agent")
           | "[\(.["gen_ai.agent.name"])] \(.["harness.lifecycle_step"] // "-") \(.["harness.feature_id"] // "-") \(.["harness.outcome"] // "-")"' \
      "$trace" | sort > "$spans"
  else
    : > "$spans"
  fi
  awk '/^## Action Log/{inlog=1; next} /^## /{inlog=0} inlog' "$progress" \
    | sed -En 's/^- (\[[^]]+\] [^ ]+ [^ ]+ [^ ]+) — .*/\1/p' \
    | sort > "$logs"
  comm -23 "$logs" "$spans" | sed 's/^/log-without-span: /'
  comm -13 "$logs" "$spans" | sed 's/^/span-without-log: /'
}

# --- Fixture: MAIN repo + linked worktree, pairs produced by the REAL helper ---
MAIN="${TMP_DIR}/main-repo"
mkdir -p "${MAIN}/scripts"
cp "$HELPER" "${MAIN}/scripts/log-handback.sh"
cp "$LIB" "${MAIN}/scripts/trace-lib.sh"
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

(cd "$WT" && ./scripts/log-handback.sh conductor feature_start demo-feature pass "selected demo-feature") \
  >/dev/null 2>&1 || hard_fail "fixture: helper call 1 (feature_start) failed"
(cd "$WT" && ./scripts/log-handback.sh test-subagent red_handback demo-feature pass "RED sensor authored") \
  >/dev/null 2>&1 || hard_fail "fixture: helper call 2 (red_handback) failed"

HELPER_TRACE="${MAIN}/.copilot-tracking/issues/issue-33/trace.jsonl"
HELPER_PROG="${WT}/.copilot-tracking/issues/issue-33/progress.md"
[ "$(jq -s '[.[] | select(.span == "agent")] | length' "$HELPER_TRACE")" = "2" ] \
  || hard_fail "fixture: expected 2 helper-produced agent spans in ${HELPER_TRACE}"
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
grep -v 'red_handback' "$HELPER_PROG" > "${TMP_DIR}/case3/progress.md"
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

# --- 2. Hand-authored bullet with no span -> log_without_span ---------------------
rc="$(run_checker "${TMP_DIR}/case2/trace.jsonl")"
[ "$rc" = "1" ] \
  || fail "log_without_span: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: log_without_span [test-subagent] green_handback demo-feature pass' "$OUT" \
  || fail "log_without_span: pinned finding format 'VIOLATION consistency: log_without_span [test-subagent] green_handback demo-feature pass' missing (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'span_without_log' "$OUT"; then
  fail "log_without_span case must not misreport span_without_log (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 3. Bullet removed for a real span -> span_without_log ------------------------
rc="$(run_checker "${TMP_DIR}/case3/trace.jsonl")"
[ "$rc" = "1" ] \
  || fail "span_without_log: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION consistency: span_without_log [test-subagent] red_handback demo-feature pass' "$OUT" \
  || fail "span_without_log: pinned finding format 'VIOLATION consistency: span_without_log [test-subagent] red_handback demo-feature pass' missing (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'log_without_span' "$OUT"; then
  fail "span_without_log case must not misreport log_without_span (stdout: $(tr '\n' '|' < "$OUT"))"
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
  fail "role gap (out-of-enum): multisets agree, so no log/span finding may fire — the gap rule must be independent (stdout: $(tr '\n' '|' < "$OUT"))"
fi
if grep -q 'janitor' "$OUT"; then
  # No multiset finding fires here (asserted above), so the offending role
  # VALUE has no legitimate carrier line — the gap finding is value-free
  # (plan decision 6: rule names, tuples of enum-valued fields, line
  # numbers, SHAs only).
  fail "role gap (out-of-enum): the report echoed the offending role value (stdout: $(tr '\n' '|' < "$OUT"))"
fi

# --- 5. Parity with the meta oracle detector on cases 1-3 -------------------------
# Same verdict AND same tuple multiset: oracle 'log-without-span: T' /
# 'span-without-log: T' lines map 1:1 to the live checker's
# 'VIOLATION consistency: log_without_span T' / 'span_without_log T' lines.
parity_case() {
  local name="$1"
  local trace="${TMP_DIR}/${name}/trace.jsonl" progress="${TMP_DIR}/${name}/progress.md"
  local oracle_norm="${TMP_DIR}/${name}-oracle.norm" live_norm="${TMP_DIR}/${name}-live.norm"
  oracle_detect "$trace" "$progress" \
    | sed -e 's/^log-without-span: /log_without_span /' \
          -e 's/^span-without-log: /span_without_log /' \
    | sort > "$oracle_norm"
  "$CHECKER" "$trace" > "${TMP_DIR}/${name}-live.out" 2>/dev/null || true
  sed -En 's/^VIOLATION consistency: (log_without_span|span_without_log) (.*)$/\1 \2/p' \
    "${TMP_DIR}/${name}-live.out" | sort > "$live_norm"
  if ! diff -u "$oracle_norm" "$live_norm" > "${TMP_DIR}/${name}-parity.diff" 2>&1; then
    fail "parity (${name}): live checker and meta oracle disagree on the tuple multiset (diff: $(tr '\n' '|' < "${TMP_DIR}/${name}-parity.diff"))"
  fi
}
parity_case case1
parity_case case2
parity_case case3

# --- 6. CLI family: usage/environment errors exit 2 -------------------------------
rc="$(run_checker)"
[ "$rc" = "2" ] \
  || fail "no args: expected exit 2 (usage error), got ${rc}"
[ -s "$ERR" ] \
  || fail "no args: a usage message on stderr is required"
rc="$(run_checker "${TMP_DIR}/does-not-exist/trace.jsonl")"
[ "$rc" = "2" ] \
  || fail "missing trace file: expected exit 2 (environment error), got ${rc}"

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-consistency-core contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-consistency-core contract honored\n'
