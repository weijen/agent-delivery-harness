#!/usr/bin/env bash
# test_log_handback_sensor_scope.sh — regression sensor for the #343
# sensor-scope passthrough in scripts/log-handback.sh.
#
# Contract under test (pinned here, mirrors the token/failure-mode shapes):
#   TRACE_SENSOR_SCOPE → harness.sensor_scope, forwarded ONLY when the value
#     is a member of the closed enum {scoped, full}; out-of-enum → key
#     OMITTED, stderr warning naming sensor_scope, call still exits 0.
#   TRACE_SENSOR_COUNT → harness.sensor_count, forwarded ONLY when the value
#     is a pure decimal integer; non-integer → key OMITTED, stderr warning,
#     call still exits 0.
#   Each is forwarded independently; unset → keys ABSENT (omit, never fake).
#
# Fixture style: minimal MAIN repo + linked issue worktree, helper invoked
# from the worktree (conductor context), as in test_log_handback.sh.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
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

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$HELPER" ] || fail "scripts/log-handback.sh not found"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_SENSOR_SCOPE TRACE_SENSOR_COUNT 2>/dev/null || true

MAIN="${TMP_DIR}/main-repo"
mkdir -p "${MAIN}/scripts"
cp "$HELPER" "${MAIN}/scripts/log-handback.sh"
cp "$LIB" "${MAIN}/scripts/trace-lib.sh"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.name "Harness Test"
git -C "$MAIN" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > "${MAIN}/.gitignore"
printf 'fixture\n' > "${MAIN}/README.md"
git -C "$MAIN" add .gitignore README.md scripts
git -C "$MAIN" commit -q -m initial

WT="${TMP_DIR}/wt-issue-21"
git -C "$MAIN" worktree add -q -b feature/issue-21-fixture "$WT"
mkdir -p "${WT}/.copilot-tracking/issues/issue-21"
cat > "${WT}/.copilot-tracking/issues/issue-21/progress.md" <<'MD'
# Issue 21 progress

## Action Log

- _seed_
MD
TRACE="${MAIN}/.copilot-tracking/issues/issue-21/trace.jsonl"

run_hb() { # run_hb <out-file> [ENV=val ...] -- <helper args...>
  local out="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  (cd "$WT" && env "${envs[@]}" ./scripts/log-handback.sh "$@") > "$out" 2>&1
}

last_span() { tail -1 "$TRACE"; }

# 1. Happy path: scoped + count land as harness.sensor_scope / sensor_count.
run_hb "${TMP_DIR}/o1" TRACE_SENSOR_SCOPE=scoped TRACE_SENSOR_COUNT=12 -- \
  generator-subagent green_handback f1 pass "scoped sensor tier ran" \
  || fail "happy path exited non-zero: $(cat "${TMP_DIR}/o1")"
last_span | jq -e '
    (.["harness.sensor_scope"] == "scoped")
    and ((.["harness.sensor_count"] | tostring) == "12")
  ' >/dev/null \
  || fail "green_handback span must carry harness.sensor_scope=scoped and harness.sensor_count=12: $(last_span)"

# 2. full is the other enum member.
run_hb "${TMP_DIR}/o2" TRACE_SENSOR_SCOPE=full -- \
  generator-subagent green_handback f2 pass "full suite ran" \
  || fail "full-scope call exited non-zero"
last_span | jq -e '.["harness.sensor_scope"] == "full"' >/dev/null \
  || fail "harness.sensor_scope=full must be forwarded: $(last_span)"
last_span | jq -e 'has("harness.sensor_count") | not' >/dev/null \
  || fail "sensor_count unset must leave harness.sensor_count absent (independent forwarding)"

# 3. Out-of-enum scope → key omitted, warn, still exit 0, span still written.
before="$(wc -l < "$TRACE" | tr -d '[:space:]')"
run_hb "${TMP_DIR}/o3" TRACE_SENSOR_SCOPE=partial TRACE_SENSOR_COUNT=5 -- \
  generator-subagent green_handback f3 pass "bad scope value" \
  || fail "out-of-enum scope must not fail the call: $(cat "${TMP_DIR}/o3")"
after="$(wc -l < "$TRACE" | tr -d '[:space:]')"
[ "$after" -gt "$before" ] || fail "span must still be written on out-of-enum scope"
last_span | jq -e 'has("harness.sensor_scope") | not' >/dev/null \
  || fail "out-of-enum scope must omit harness.sensor_scope (omit, never fake): $(last_span)"
last_span | jq -e '(.["harness.sensor_count"] | tostring) == "5"' >/dev/null \
  || fail "valid count must still be forwarded when scope is invalid (independent forwarding)"
grep -qi 'sensor_scope' "${TMP_DIR}/o3" \
  || fail "out-of-enum scope must warn naming sensor_scope"

# 4. Non-integer count → key omitted, warn, exit 0.
run_hb "${TMP_DIR}/o4" TRACE_SENSOR_SCOPE=scoped TRACE_SENSOR_COUNT=dozen -- \
  generator-subagent green_handback f4 pass "bad count value" \
  || fail "non-integer count must not fail the call"
last_span | jq -e 'has("harness.sensor_count") | not' >/dev/null \
  || fail "non-integer count must omit harness.sensor_count: $(last_span)"
grep -qi 'sensor_count\|SENSOR_COUNT' "${TMP_DIR}/o4" \
  || fail "non-integer count must warn on stderr"

# 5. Both unset → both keys absent.
run_hb "${TMP_DIR}/o5" HOME="$HOME" -- \
  generator-subagent green_handback f5 pass "no sensor scope env" \
  || fail "unset env call exited non-zero"
last_span | jq -e '(has("harness.sensor_scope") or has("harness.sensor_count")) | not' >/dev/null \
  || fail "unset env must leave both keys absent: $(last_span)"

printf 'PASS: log-handback sensor-scope passthrough honors the #343 contract\n'
