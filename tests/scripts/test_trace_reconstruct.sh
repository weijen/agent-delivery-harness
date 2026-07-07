#!/usr/bin/env bash
# test_trace_reconstruct.sh — regression sensor for scripts/trace-reconstruct.sh
# (issue #149, feature trace-reconstruct-core).
#
# Executable spec for `scripts/trace-reconstruct.sh <issue-number>`, the
# local-only CLI that reconstructs runtime `tool` spans from the GitHub Copilot
# on-disk transcript by TIME-WINDOW INTERSECTION — no session_id dependency for
# ATTRIBUTION (a session may span multiple issues; a tool pair is attributed to
# an issue purely by whether its start timestamp falls inside the issue's own
# lifecycle window). This sensor pins:
#
#   1. windowed_pairs_emitted — the issue TIME WINDOW is [earliest, latest]
#      timestamp among the harness spans ALREADY present in the issue's
#      trace.jsonl (this sensor seeds two lifecycle spans with known
#      timestamps to define it). Given a transcript with three start/complete
#      tool pairs — two whose start falls INSIDE the window, one AFTER it —
#      exactly the two in-window pairs become `tool` spans APPENDED to the
#      issue trace, each carrying:
#        gen_ai.tool.name      the start event's data.toolName
#        harness.duration_ms   integer ms between complete and start timestamps
#        harness.outcome       pass when data.success true, else fail
#        harness.session_id    the transcript filename's session id
#      and the out-of-window pair produces NO span.
#   2. no_arg_leak — a secret-shaped token planted in an in-window event's
#      data.arguments does NOT survive into any appended span (reconstruction
#      never re-emits raw tool arguments; trace-lib redaction is the backstop).
#   3. absent_transcripts_noop — COPILOT_TRANSCRIPTS_DIR pointing at a
#      non-existent/empty dir is best-effort: the script exits 0, warns, and
#      appends NOTHING (trace line count unchanged).
#   4. unpaired_ignored — an in-window start with no matching complete (and a
#      complete with no matching start) yields NO span: pairing by toolCallId
#      is required to compute duration/outcome.
#   5. validates — after reconstruction the whole issue trace still passes
#      scripts/validate-trace.sh (the appended spans are schema-v1 conformant).
#
# Hermetic: every case builds a throwaway git main-root (git init on a
# feature/issue-42-* branch — no commit, so no signing prompt) with the scripts
# and contract copied to their canonical relative paths, seeds the window via a
# hand-written trace.jsonl, and points COPILOT_TRANSCRIPTS_DIR at a fixture
# transcript dir. Nothing touches the developer's real checkout, network, or
# real workspaceStorage. Durations in the fixture are whole seconds so the
# assertions hold whether the script parses millisecond or second resolution.
#
# Exit codes: 0 reconstruction contract honored · 1 a contract obligation
# regressed (including the RED presence gate: the script does not exist yet).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECONSTRUCT="${ROOT}/scripts/trace-reconstruct.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SESSION_ID="sess-fixture-01"
SECRET_TOKEN="ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The fixture must control tracing and transcript discovery entirely: no
# ambient overrides may bleed in from the developer's environment.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID COPILOT_TRANSCRIPTS_DIR 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || fail "jq is required (the reconstructor and this sensor are jq-driven)"
command -v git >/dev/null 2>&1 \
  || fail "git is required to build the main-root fixture"
[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"
[ -f "$TRACE_LIB" ] \
  || fail "scripts/trace-lib.sh not found (${TRACE_LIB}) — trace_span/trace_redact back the reconstructor's span emission"
[ -f "$ISSUE_LIB" ] \
  || fail "scripts/issue-lib.sh not found (${ISSUE_LIB}) — issue-number → main-root path resolution depends on it"
[ -f "$VALIDATOR" ] \
  || fail "scripts/validate-trace.sh not found (${VALIDATOR}) — needed to prove the reconstructed trace still validates"

# --- RED presence gate ---------------------------------------------------------
# The script under test must exist (and be executable) before any behavior can
# be specified against it. With the production script absent this sensor is RED
# for exactly this reason.
[ -f "$RECONSTRUCT" ] \
  || fail "scripts/trace-reconstruct.sh not found (${RECONSTRUCT}) — the transcript reconstructor for feature trace-reconstruct-core (issue #149) is not implemented yet"
[ -x "$RECONSTRUCT" ] \
  || fail "scripts/trace-reconstruct.sh exists but is not executable (${RECONSTRUCT})"

# --- Fixture builder -----------------------------------------------------------
# Echoes a fresh main-root repo path with the scripts + contract copied to
# their canonical relative locations, on a feature/issue-42-* branch (so both
# the CLI arg and trace-lib's own issue resolution land on 42), with the issue
# trace pre-seeded with two lifecycle spans that DEFINE the window
# [2026-07-04T12:00:00Z, 2026-07-04T12:10:00Z].
build_fixture() {
  local fix
  fix="$(mktemp -d "${TMP_DIR}/fix.XXXXXX")"
  mkdir -p "${fix}/scripts" "${fix}/docs/evaluation" \
    "${fix}/.copilot-tracking/issues/issue-42"
  cp "$RECONSTRUCT" "${fix}/scripts/trace-reconstruct.sh"
  cp "$TRACE_LIB" "${fix}/scripts/trace-lib.sh"
  cp "$ISSUE_LIB" "${fix}/scripts/issue-lib.sh"
  cp "$VALIDATOR" "${fix}/scripts/validate-trace.sh"
  cp "$CONTRACT" "${fix}/docs/evaluation/trace-schema.v1.json"
  chmod +x "${fix}/scripts/trace-reconstruct.sh" "${fix}/scripts/validate-trace.sh"

  # Git main-root: an unborn feature branch is enough for --git-common-dir and
  # branch-based issue resolution; no commit is taken, so nothing can prompt
  # for a signing passphrase in a hermetic test.
  git -C "$fix" init -q -b feature/issue-42-recon
  git -C "$fix" config user.name "Harness Test"
  git -C "$fix" config user.email "harness-test@example.invalid"

  # Seed the window: two schema-v1 lifecycle spans with fixed timestamps. Their
  # min/max timestamp is the reconstruction window.
  {
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"lifecycle","harness.issue":42,"harness.version":"0.0.0-dev","harness.lifecycle_step":"worktree_create","span_id":"seed-early-01"}'
    printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-04T12:10:00Z","span":"lifecycle","harness.issue":42,"harness.version":"0.0.0-dev","harness.lifecycle_step":"feature_start","span_id":"seed-late-01"}'
  } > "${fix}/.copilot-tracking/issues/issue-42/trace.jsonl"

  printf '%s' "$fix"
}

trace_path() { printf '%s' "${1}/.copilot-tracking/issues/issue-42/trace.jsonl"; }

line_count() { wc -l < "$1" | tr -d '[:space:]'; }

OUT="${TMP_DIR}/out"
ERR="${TMP_DIR}/err"

# run_recon <fix> <transcripts-dir> — runs the reconstructor in issue-number
# mode from inside the fixture; prints the exit code, stdout→OUT, stderr→ERR.
run_recon() {
  local fix="$1" tdir="$2" rc=0
  ( cd "$fix" && COPILOT_TRANSCRIPTS_DIR="$tdir" ./scripts/trace-reconstruct.sh 42 ) \
    >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# assert_tool_span <trace> <toolName> <duration_ms> <outcome> — a `tool` span
# exists with the expected name, an INTEGER duration equal to the gap, the
# expected outcome, and the fixture session id.
assert_tool_span() {
  local trace="$1" tn="$2" dur="$3" oc="$4"
  jq -s -e --arg tn "$tn" --argjson dur "$dur" --arg oc "$oc" --arg sid "$SESSION_ID" '
    any(.[];
      .span == "tool"
      and (.["gen_ai.tool.name"] == $tn)
      and (.["harness.duration_ms"] == $dur)
      and ((.["harness.duration_ms"] | type) == "number")
      and (.["harness.outcome"] == $oc)
      and (.["harness.session_id"] == $sid))
  ' "$trace" >/dev/null 2>&1 \
    || fail "expected a tool span name=${tn} duration_ms=${dur} (integer) outcome=${oc} session_id=${SESSION_ID}; trace tool spans: $(jq -s -c '[.[] | select(.span=="tool")]' "$trace" 2>/dev/null)"
}

tool_span_count() {
  jq -s '[.[] | select(.span == "tool")] | length' "$1"
}

# =============================================================================
# Cases 1, 2, 5 share ONE windowed transcript (two in-window pairs + one
# out-of-window pair); the secret token rides pair 2's arguments.
# =============================================================================
FIX1="$(build_fixture)"
TRACE1="$(trace_path "$FIX1")"
TDIR1="${TMP_DIR}/transcripts-windowed"
mkdir -p "$TDIR1"
{
  # Pair 1 — in window (12:00:05 → 12:00:07 = 2000 ms), success → pass.
  printf '%s\n' '{"type":"tool.execution_start","timestamp":"2026-07-04T12:00:05.000Z","parentId":null,"id":"s1","data":{"toolName":"run_in_terminal","toolCallId":"call-1","arguments":{"command":"ls -la"}}}'
  printf '%s\n' '{"type":"tool.execution_complete","timestamp":"2026-07-04T12:00:07.000Z","parentId":null,"id":"c1","data":{"toolCallId":"call-1","success":true}}'
  # Pair 2 — in window (12:05:00 → 12:05:01 = 1000 ms), success false → fail;
  # arguments carry the secret-shaped token (no_arg_leak).
  printf '%s\n' "{\"type\":\"tool.execution_start\",\"timestamp\":\"2026-07-04T12:05:00.000Z\",\"parentId\":null,\"id\":\"s2\",\"data\":{\"toolName\":\"read_file\",\"toolCallId\":\"call-2\",\"arguments\":{\"token\":\"${SECRET_TOKEN}\"}}}"
  printf '%s\n' '{"type":"tool.execution_complete","timestamp":"2026-07-04T12:05:01.000Z","parentId":null,"id":"c2","data":{"toolCallId":"call-2","success":false}}'
  # Pair 3 — start AFTER the window (12:15:00): must NOT be emitted.
  printf '%s\n' '{"type":"tool.execution_start","timestamp":"2026-07-04T12:15:00.000Z","parentId":null,"id":"s3","data":{"toolName":"grep_search","toolCallId":"call-3","arguments":{"query":"x"}}}'
  printf '%s\n' '{"type":"tool.execution_complete","timestamp":"2026-07-04T12:15:02.000Z","parentId":null,"id":"c3","data":{"toolCallId":"call-3","success":true}}'
} > "${TDIR1}/${SESSION_ID}.jsonl"

seed1="$(line_count "$TRACE1")"
[ "$seed1" -eq 2 ] || fail "case windowed_pairs_emitted: expected 2 seeded window spans, got ${seed1}"

rc1="$(run_recon "$FIX1" "$TDIR1")"
[ "$rc1" = "0" ] \
  || fail "case windowed_pairs_emitted: expected exit 0, got ${rc1} (stderr: $(tr '\n' '|' < "$ERR"))"

# Case 1 — exactly the two in-window pairs became tool spans.
n1="$(tool_span_count "$TRACE1")"
[ "$n1" -eq 2 ] \
  || fail "case windowed_pairs_emitted: expected exactly 2 in-window tool spans appended, got ${n1} (out-of-window pair must NOT emit)"
assert_tool_span "$TRACE1" "run_in_terminal" 2000 "pass"
assert_tool_span "$TRACE1" "read_file" 1000 "fail"
jq -s -e 'any(.[]; .span == "tool" and (.["gen_ai.tool.name"] == "grep_search")) | not' \
  "$TRACE1" >/dev/null 2>&1 \
  || fail "case windowed_pairs_emitted: the out-of-window pair (grep_search) must NOT produce a tool span"

# Case 2 — the secret token must not survive into the appended spans.
if grep -qF -- "$SECRET_TOKEN" "$TRACE1"; then
  fail "case no_arg_leak: the secret token from data.arguments leaked into the reconstructed trace"
fi

# Case 5 — the whole issue trace still validates after reconstruction.
vrc=0
( cd "$FIX1" && ./scripts/validate-trace.sh 42 ) >"$OUT" 2>"$ERR" || vrc=$?
[ "$vrc" = "0" ] \
  || fail "case validates: validate-trace.sh must accept the reconstructed trace (exit 0), got ${vrc} (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'VIOLATION' "$OUT" "$ERR"; then
  fail "case validates: reconstructed trace produced VIOLATION findings — appended spans are not schema-v1 conformant"
fi

# =============================================================================
# Case 3 — absent_transcripts_noop: an empty/nonexistent transcripts dir is a
# best-effort no-op (exit 0, a warning, nothing appended).
# =============================================================================
FIX3="$(build_fixture)"
TRACE3="$(trace_path "$FIX3")"
before3="$(line_count "$TRACE3")"
rc3="$(run_recon "$FIX3" "${TMP_DIR}/does-not-exist-transcripts")"
[ "$rc3" = "0" ] \
  || fail "case absent_transcripts_noop: expected exit 0 for a missing transcripts dir, got ${rc3}"
grep -Eqi 'warn|transcript|empty|not found|missing|no-op' "$OUT" "$ERR" \
  || fail "case absent_transcripts_noop: expected a warning about the absent transcripts dir (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
after3="$(line_count "$TRACE3")"
[ "$before3" = "$after3" ] \
  || fail "case absent_transcripts_noop: trace line count changed (${before3} → ${after3}); nothing must be appended"

# =============================================================================
# Case 4 — unpaired_ignored: an in-window start with no matching complete, and
# an in-window complete with no matching start, yield NO span (pairing by
# toolCallId is required).
# =============================================================================
FIX4="$(build_fixture)"
TRACE4="$(trace_path "$FIX4")"
TDIR4="${TMP_DIR}/transcripts-unpaired"
mkdir -p "$TDIR4"
{
  printf '%s\n' '{"type":"tool.execution_start","timestamp":"2026-07-04T12:03:00.000Z","parentId":null,"id":"u1","data":{"toolName":"orphan_start","toolCallId":"call-orphan-start","arguments":{}}}'
  printf '%s\n' '{"type":"tool.execution_complete","timestamp":"2026-07-04T12:04:00.000Z","parentId":null,"id":"u2","data":{"toolCallId":"call-orphan-complete","success":true}}'
} > "${TDIR4}/${SESSION_ID}.jsonl"
before4="$(line_count "$TRACE4")"
rc4="$(run_recon "$FIX4" "$TDIR4")"
[ "$rc4" = "0" ] \
  || fail "case unpaired_ignored: expected exit 0, got ${rc4} (stderr: $(tr '\n' '|' < "$ERR"))"
n4="$(tool_span_count "$TRACE4")"
[ "$n4" -eq 0 ] \
  || fail "case unpaired_ignored: unpaired start/complete events must produce NO tool span, got ${n4}"
after4="$(line_count "$TRACE4")"
[ "$before4" = "$after4" ] \
  || fail "case unpaired_ignored: trace line count changed (${before4} → ${after4}); unpaired events must append nothing"

printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
