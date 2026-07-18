#!/usr/bin/env bash
# Regression sensor: trace <-> Action Log consistency detection (issue #95,
# feature trace-action-log-consistency, plan Phase 4 / D8).
#
# A run whose progress.md claims a handback with no matching agent span — or
# whose trace holds an agent span with no Action Log line — must be
# mechanically detectable. The detection logic lives IN this sensor (the
# deterministic reference implementation the issue #103 live validator will
# lift): compare the multiset of `[role] step feature_id outcome` tuples
# extracted from `span=="agent"` lines of trace.jsonl against the tuples
# parsed from the `## Action Log` payload bullets of progress.md
# (`- [<role>] <step> <feature_id> <outcome> — <summary>`, the exact shape
# scripts/log-handback.sh writes).
#
# Fixtures are built at runtime in a throwaway MAIN repo + linked issue
# worktree by running the REAL helper (single-source emitter), then mutated
# on copies — the sensor never reads real .copilot-tracking state (L0
# fixture isolation):
#   1. helper-produced pair            -> zero findings (consistent);
#   2. hand-authored Action Log bullet -> 'log-without-span' finding names
#      the exact tuple (and nothing is misreported as span-without-log);
#   3. bullet removed for a real span  -> 'span-without-log' finding names
#      the exact tuple (and nothing is misreported as log-without-span).
# Cases 2/3 are the teeth: they FAIL if the detector's comparison is
# weakened (mutation-tested by swapping the comm side-selection in a
# scratch copy and watching case 2 stop failing).
#
# Exit codes: 0 detection contract honored · 1 a detection obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${ROOT}/scripts/log-handback.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required for trace/Action Log consistency detection"
[ -f "$HELPER" ] || fail "scripts/log-handback.sh not found (${HELPER})"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found (${LIB})"

# ============================================================================
# CONSISTENCY DETECTOR (reference implementation; issue #103 lifts this)
# Usage: detect <trace.jsonl> <progress.md>
# Prints one finding per line:
#   log-without-span: [<role>] <step> <feature_id> <outcome>
#   span-without-log: [<role>] <step> <feature_id> <outcome>
# No output means the two views agree (multiset comparison, order-free).
# ============================================================================
detect() {
  local trace="$1" progress="$2"
  local spans="${TMP_DIR}/detect-spans" logs="${TMP_DIR}/detect-logs"
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
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS 2>/dev/null || true

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
  >/dev/null 2>&1 || fail "fixture: helper call 1 (feature_start) failed"
(cd "$WT" && ./scripts/log-handback.sh generator-subagent red_handback demo-feature pass "RED sensor authored") \
  >/dev/null 2>&1 || fail "fixture: helper call 2 (red_handback) failed"

TRACE="${MAIN}/.copilot-tracking/issues/issue-33/trace.jsonl"
PROG="${WT}/.copilot-tracking/issues/issue-33/progress.md"
[ "$(jq -s '[.[] | select(.span == "agent")] | length' "$TRACE")" = "2" ] \
  || fail "fixture: expected 2 helper-produced agent spans in ${TRACE}"
[ "$(grep -c '^- \[' "$PROG")" = "2" ] \
  || fail "fixture: expected 2 helper-produced Action Log bullets in ${PROG}"

# ============================================================================
# 1. Helper-produced pair -> consistent, zero findings.
# ============================================================================
findings="$(detect "$TRACE" "$PROG")"
[ -z "$findings" ] \
  || fail "helper-produced span/log pairs must yield ZERO findings, got: ${findings}"

# ============================================================================
# 2. Hand-authored Action Log claim with NO matching span -> detected.
#    (Same role as a real span, different step: a role-only comparison
#    would miss it — this is the mutation-tested tooth.)
# ============================================================================
CASE2="${TMP_DIR}/case2-progress.md"
cp "$PROG" "$CASE2"
printf -- '- [generator-subagent] green_handback demo-feature pass — hand-written claim, no span emitted\n' >> "$CASE2"
findings="$(detect "$TRACE" "$CASE2")"
printf '%s\n' "$findings" \
  | grep -qF 'log-without-span: [generator-subagent] green_handback demo-feature pass' \
  || fail "a hand-authored Action Log handback with no agent span must be flagged log-without-span (got: ${findings:-<none>})"
printf '%s\n' "$findings" | grep -q 'span-without-log' \
  && fail "case 2 must not misreport span-without-log findings: ${findings}"

# ============================================================================
# 3. Agent span whose progress.md bullet was removed -> detected.
# ============================================================================
CASE3="${TMP_DIR}/case3-progress.md"
grep -v 'red_handback' "$PROG" > "$CASE3"
findings="$(detect "$TRACE" "$CASE3")"
printf '%s\n' "$findings" \
  | grep -qF 'span-without-log: [generator-subagent] red_handback demo-feature pass' \
  || fail "an agent span with no matching Action Log line must be flagged span-without-log (got: ${findings:-<none>})"
printf '%s\n' "$findings" | grep -q 'log-without-span' \
  && fail "case 3 must not misreport log-without-span findings: ${findings}"

echo "trace/action-log consistency detection checks passed"
