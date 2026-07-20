#!/usr/bin/env bash
# Regression sensor for issue #318, feature finding-identity.
#
# Proves that:
#   E1–E3: log-handback.sh passthroughs for TRACE_REVIEW_EVENT_ID,
#          TRACE_FINDING_BASELINE_STATE (closed enum), and existing
#          TRACE_FINDING_FINGERPRINT work on review_verdict step
#   E4:    invalid TRACE_FINDING_BASELINE_STATE → omit + stderr warning
#   C1:    check-trace-consistency.sh rejects fail verdict missing fingerprint
#          when baseline_state is present (also finding_fingerprint_missing)
#   C2:    check-trace-consistency.sh rejects fail verdict with invalid
#          baseline_state enum value
#   C3:    check-trace-consistency.sh accepts fail verdict with valid
#          baseline_state + fingerprint
#   C4:    resolved PASS verdict with same fingerprint accepted (no violation)
#   C5:    fail verdict missing BOTH fingerprint AND baseline_state →
#          finding_fingerprint_missing + finding_baseline_state_missing
#   C6:    fail verdict with fingerprint only (no baseline_state) →
#          finding_baseline_state_missing
#   A1:    economics: N finding spans sharing one review_event_id = 1 round
#   A2:    economics: two explicit event IDs on same SHA/mode = 2 rounds
#   A3:    economics: explicit-ID-only spans without SHA/mode count
#   A4:    economics: historical fallback (no review_event_id, has SHA+mode)
#          stays correct
#   A5:    economics: mixed trace (some explicit ID, some legacy SHA/mode,
#          DIFFERENT coordinates) counts correctly without double-counting
#   A6:    economics: mixed same-event explicit+legacy SAME coordinates →
#          one round with complete coverage via unambiguous bridge
#   A7:    economics: ambiguous two explicit IDs + unkeyed legacy SAME
#          coordinates → review rounds n/a / numeric rounds omitted
#   M1:    mutation: revert economics to SHA/mode-only key → sensor kills it
#   M2:    mutation: count fingerprints instead of event IDs → sensor kills it

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="${ROOT}/.copilot-tracking/test-runs/test_finding_identity_decoupling.$$"
trap 'rm -rf "${SCRATCH}"' EXIT

fail() { printf 'FAIL [%s]: %s\n' "$1" "$*" >&2; exit 1; }
pass() { printf 'PASS [%s]: %s\n' "$1" "$2"; }

mkdir -p "${SCRATCH}"

# ---------- helpers -----------------------------------------------------------
# Minimal git repo for log-handback.sh (needs git rev-parse, branch, HEAD)
setup_git_env() {
  local dir="$1"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" checkout -q -b feature/issue-99-test 2>/dev/null || true
  git -C "$dir" commit -q --allow-empty -m "init" 2>/dev/null
  mkdir -p "$dir/.copilot-tracking/issues/issue-99"
  cat > "$dir/.copilot-tracking/issues/issue-99/progress.md" <<'MD'
# Issue 99 progress
## Action Log
MD
}

FAKE_REPO="${SCRATCH}/repo"
mkdir -p "$FAKE_REPO"
setup_git_env "$FAKE_REPO"

# Copy required scripts into the fake repo
cp -r "$ROOT/scripts" "$FAKE_REPO/scripts"
cp -r "$ROOT/docs" "$FAKE_REPO/docs" 2>/dev/null || true

run_log_handback() {
  # Run log-handback.sh inside the fake repo context
  (cd "$FAKE_REPO" && TRACE_ISSUE=99 bash scripts/log-handback.sh "$@")
}

# ---------- E1: TRACE_REVIEW_EVENT_ID passthrough ----------------------------
TRACE_FILE_E1="${FAKE_REPO}/.copilot-tracking/issues/issue-99/trace.jsonl"
: > "$TRACE_FILE_E1"
(cd "$FAKE_REPO" && \
  TRACE_ISSUE=99 \
  TRACE_REVIEW_MODE=full \
  TRACE_REVIEW_EVENT_ID="evt-abc-123" \
  TRACE_FAILURE_CLASS=regression \
  TRACE_FINDING_FINGERPRINT="sha256:deadbeef" \
  TRACE_FINDING_BASELINE_STATE=new \
  bash scripts/log-handback.sh code-review-subagent review_verdict f1 fail "finding one" \
) 2>"${SCRATCH}/e1_stderr"

if ! jq -e '.["harness.review_event_id"] == "evt-abc-123"' < "$TRACE_FILE_E1" >/dev/null 2>&1; then
  fail E1 "TRACE_REVIEW_EVENT_ID not passed through as harness.review_event_id"
fi
pass E1 "TRACE_REVIEW_EVENT_ID passthrough works"

# ---------- E2: TRACE_FINDING_BASELINE_STATE passthrough ---------------------
if ! jq -e '.["harness.finding_baseline_state"] == "new"' < "$TRACE_FILE_E1" >/dev/null 2>&1; then
  fail E2 "TRACE_FINDING_BASELINE_STATE not passed through as harness.finding_baseline_state"
fi
pass E2 "TRACE_FINDING_BASELINE_STATE passthrough works"

# ---------- E3: existing TRACE_FINDING_FINGERPRINT still works ---------------
if ! jq -e '.["harness.finding_fingerprint"] == "sha256:deadbeef"' < "$TRACE_FILE_E1" >/dev/null 2>&1; then
  fail E3 "TRACE_FINDING_FINGERPRINT not passed through"
fi
pass E3 "TRACE_FINDING_FINGERPRINT passthrough still works"

# ---------- E4: invalid TRACE_FINDING_BASELINE_STATE → omit + warn ----------
: > "$TRACE_FILE_E1"
(cd "$FAKE_REPO" && \
  TRACE_ISSUE=99 \
  TRACE_REVIEW_MODE=repair \
  TRACE_FAILURE_CLASS=regression \
  TRACE_FINDING_FINGERPRINT="sha256:bad" \
  TRACE_FINDING_BASELINE_STATE=bogus \
  bash scripts/log-handback.sh code-review-subagent review_verdict f1 fail "bad baseline" \
) 2>"${SCRATCH}/e4_stderr"

if jq -e 'has("harness.finding_baseline_state")' < "$TRACE_FILE_E1" >/dev/null 2>&1; then
  fail E4 "invalid baseline_state should be omitted, but was emitted"
fi
if ! grep -qi 'baseline' "${SCRATCH}/e4_stderr"; then
  fail E4 "invalid baseline_state should produce a stderr warning"
fi
pass E4 "invalid TRACE_FINDING_BASELINE_STATE omitted with warning"

# ---------- C1: fail verdict with baseline_state but no fingerprint → violation
TRACE_C_DIR="${SCRATCH}/consistency"
mkdir -p "$TRACE_C_DIR"
TRACE_C="${TRACE_C_DIR}/trace.jsonl"
# The checker requires a sibling progress.md with an Action Log section
cat > "${TRACE_C_DIR}/progress.md" <<'MD'
# progress
## Action Log
MD
cat > "$TRACE_C" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail","harness.feature_id":"f1","harness.review_mode":"full","harness.reviewed_sha":"sha-a","harness.failure_class":"regression","harness.finding_baseline_state":"new"}
JSONL
c1_out="$(bash "$ROOT/scripts/check-trace-consistency.sh" "$TRACE_C" 2>&1 || true)"
if ! grep -q 'finding_baseline_missing_fingerprint' <<< "$c1_out"; then
  fail C1 "fail verdict with baseline_state but no fingerprint should trigger finding_baseline_missing_fingerprint"
fi
if ! grep -q 'finding_fingerprint_missing' <<< "$c1_out"; then
  fail C1 "fail verdict missing fingerprint must also trigger finding_fingerprint_missing"
fi
pass C1 "baseline_state without fingerprint → violation (both rules)"

# ---------- C2: fail verdict with invalid baseline_state → violation ---------
cat > "$TRACE_C" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail","harness.feature_id":"f1","harness.review_mode":"full","harness.reviewed_sha":"sha-a","harness.failure_class":"regression","harness.finding_fingerprint":"sha256:abc","harness.finding_baseline_state":"bogus"}
JSONL
c2_out="$(bash "$ROOT/scripts/check-trace-consistency.sh" "$TRACE_C" 2>&1 || true)"
if ! grep -q 'finding_baseline_state_invalid' <<< "$c2_out"; then
  fail C2 "invalid baseline_state on fail verdict should trigger finding_baseline_state_invalid"
fi
pass C2 "invalid baseline_state → violation"

# ---------- C3: valid fail verdict with fingerprint + baseline_state → clean --
cat > "$TRACE_C" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail","harness.feature_id":"f1","harness.review_mode":"full","harness.reviewed_sha":"sha-a","harness.failure_class":"regression","harness.finding_fingerprint":"sha256:abc","harness.finding_baseline_state":"new"}
JSONL
c3_out="$(bash "$ROOT/scripts/check-trace-consistency.sh" "$TRACE_C" 2>&1 || true)"
if grep -q 'finding_baseline' <<< "$c3_out"; then
  fail C3 "valid fail verdict with fingerprint + baseline_state should not trigger baseline violations"
fi
if grep -q 'finding_fingerprint_missing' <<< "$c3_out"; then
  fail C3 "valid fail verdict with fingerprint should not trigger finding_fingerprint_missing"
fi
pass C3 "valid fail verdict with fingerprint + baseline_state accepted"

# ---------- C4: resolved PASS verdict with fingerprint → accepted ------------
cat > "$TRACE_C" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.outcome":"pass","harness.feature_id":"f1","harness.review_mode":"repair","harness.reviewed_sha":"sha-b","harness.finding_fingerprint":"sha256:abc","harness.finding_baseline_state":"resolved","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent"}
JSONL
# Also add a matching Action Log line so span_without_log doesn't fire
cat > "${TRACE_C_DIR}/progress.md" <<'MD'
# progress
## Action Log
- [code-review-subagent] review_verdict f1 pass — resolved finding
MD
c4_out="$(bash "$ROOT/scripts/check-trace-consistency.sh" "$TRACE_C" 2>&1 || true)"
if grep -q 'finding_baseline' <<< "$c4_out"; then
  fail C4 "resolved PASS verdict with fingerprint should not trigger baseline violations"
fi
pass C4 "resolved PASS verdict with same fingerprint accepted"

# ---------- C5: fail missing BOTH fingerprint AND baseline_state → both violations
cat > "${TRACE_C_DIR}/progress.md" <<'MD'
# progress
## Action Log
MD
cat > "$TRACE_C" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail","harness.feature_id":"f1","harness.review_mode":"full","harness.reviewed_sha":"sha-a","harness.failure_class":"regression"}
JSONL
c5_out="$(bash "$ROOT/scripts/check-trace-consistency.sh" "$TRACE_C" 2>&1 || true)"
if ! grep -q 'finding_fingerprint_missing' <<< "$c5_out"; then
  fail C5 "fail verdict missing both fields must trigger finding_fingerprint_missing"
fi
if ! grep -q 'finding_baseline_state_missing' <<< "$c5_out"; then
  fail C5 "fail verdict missing both fields must trigger finding_baseline_state_missing"
fi
pass C5 "fail missing both → finding_fingerprint_missing + finding_baseline_state_missing"

# ---------- C6: fail with fingerprint only (no baseline) → baseline missing ---
cat > "$TRACE_C" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail","harness.feature_id":"f1","harness.review_mode":"full","harness.reviewed_sha":"sha-a","harness.failure_class":"regression","harness.finding_fingerprint":"sha256:abc"}
JSONL
c6_out="$(bash "$ROOT/scripts/check-trace-consistency.sh" "$TRACE_C" 2>&1 || true)"
if ! grep -q 'finding_baseline_state_missing' <<< "$c6_out"; then
  fail C6 "fail verdict with fingerprint but no baseline must trigger finding_baseline_state_missing"
fi
if grep -q 'finding_fingerprint_missing' <<< "$c6_out"; then
  fail C6 "fail verdict with fingerprint present should not trigger finding_fingerprint_missing"
fi
pass C6 "fingerprint-only → finding_baseline_state_missing (no fingerprint violation)"

# ---------- Economics helpers -------------------------------------------------
run_markdown() {
  local library="$1" trace="$2"
  (
    # shellcheck source=scripts/finish-lib.sh
    source "$library"
    compute_delivery_economics "$trace" -
  )
}

run_numeric() {
  local library="$1" trace="$2"
  (
    # shellcheck source=scripts/finish-lib.sh
    source "$library"
    economics_numeric_aggregates "$trace" -
  )
}

# ---------- A1: N findings sharing one review_event_id = 1 round -------------
TRACE_A="${SCRATCH}/econ_trace.jsonl"
cat > "$TRACE_A" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.feature_id":"f3","harness.outcome":"pass"}
JSONL
a1_md="$(run_markdown "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
a1_num="$(run_numeric "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
if ! grep -Fx -- '- Review rounds: 1 (1 fail → 0 pass)' <<< "$a1_md" >/dev/null; then
  fail A1 "3 findings sharing one event ID must aggregate to 1 round (got: $(grep 'Review rounds' <<< "$a1_md"))"
fi
if ! grep -Fx -- 'harness.economics.review_rounds=1' <<< "$a1_num" >/dev/null; then
  fail A1 "numeric review_rounds must be 1"
fi
pass A1 "N findings same event_id = 1 round"

# ---------- A2: two explicit event IDs on same SHA/mode = 2 rounds -----------
cat > "$TRACE_A" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-2","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-2","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"pass"}
JSONL
a2_md="$(run_markdown "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
a2_num="$(run_numeric "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
if ! grep -Fx -- '- Review rounds: 2 (1 fail → 1 pass)' <<< "$a2_md" >/dev/null; then
  fail A2 "two explicit event IDs on same SHA/mode must = 2 rounds (got: $(grep 'Review rounds' <<< "$a2_md"))"
fi
if ! grep -Fx -- 'harness.economics.review_rounds=2' <<< "$a2_num" >/dev/null; then
  fail A2 "numeric review_rounds must be 2"
fi
pass A2 "two explicit event IDs same SHA/mode = 2 rounds"

# ---------- A3: explicit-ID-only spans without SHA/mode count ----------------
cat > "$TRACE_A" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-x","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-x","harness.feature_id":"f2","harness.outcome":"pass"}
JSONL
a3_md="$(run_markdown "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
a3_num="$(run_numeric "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
if ! grep -Fx -- '- Review rounds: 1 (0 fail → 1 pass)' <<< "$a3_md" >/dev/null; then
  fail A3 "explicit-ID-only spans without SHA/mode must count (got: $(grep 'Review rounds' <<< "$a3_md"))"
fi
grep -Fx -- 'harness.economics.review_rounds=1' <<< "$a3_num" >/dev/null \
  || fail A3 "numeric review_rounds must be 1"
grep -Fx -- 'harness.economics.review_identity_covered=2' <<< "$a3_num" >/dev/null \
  || fail A3 "identity coverage must be 2/2"
grep -Fx -- 'harness.economics.review_identity_total=2' <<< "$a3_num" >/dev/null \
  || fail A3 "identity total must be 2"
pass A3 "explicit-ID-only spans without SHA/mode count correctly"

# ---------- A4: historical fallback (no review_event_id) stays correct -------
cat > "$TRACE_A" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"repair","harness.feature_id":"f1","harness.outcome":"pass"}
JSONL
a4_md="$(run_markdown "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
a4_num="$(run_numeric "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
if ! grep -Fx -- '- Review rounds: 2 (1 fail → 1 pass)' <<< "$a4_md" >/dev/null; then
  fail A4 "historical fallback must still count 2 rounds (got: $(grep 'Review rounds' <<< "$a4_md"))"
fi
grep -Fx -- 'harness.economics.review_rounds=2' <<< "$a4_num" >/dev/null \
  || fail A4 "numeric review_rounds must be 2 for historical spans"
pass A4 "historical fallback (no review_event_id) stays correct"

# ---------- A5: mixed trace — explicit IDs + legacy SHA/mode -----------------
cat > "$TRACE_A" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"repair","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-b","harness.review_mode":"repair","harness.feature_id":"f2","harness.outcome":"pass"}
JSONL
a5_md="$(run_markdown "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
a5_num="$(run_numeric "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
# evt-1 groups the first two spans; the last two share (sha-b, repair) fallback = 1 more
if ! grep -Fx -- '- Review rounds: 2 (1 fail → 1 pass)' <<< "$a5_md" >/dev/null; then
  fail A5 "mixed trace must count 2 rounds: 1 explicit + 1 historical (got: $(grep 'Review rounds' <<< "$a5_md"))"
fi
grep -Fx -- 'harness.economics.review_rounds=2' <<< "$a5_num" >/dev/null \
  || fail A5 "numeric review_rounds must be 2 for mixed traces"
grep -Fx -- 'harness.economics.review_identity_covered=4' <<< "$a5_num" >/dev/null \
  || fail A5 "mixed trace coverage must be 4/4"
pass A5 "mixed trace counts correctly without double-counting"

# ---------- A6: mixed same-event explicit+legacy SAME coordinates → bridge ---
# One explicit-ID span and one legacy span share the SAME (sha-a, full)
# coordinates; the legacy span unambiguously bridges to evt-1.
cat > "$TRACE_A" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
JSONL
a6_md="$(run_markdown "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
a6_num="$(run_numeric "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
if ! grep -Fx -- '- Review rounds: 1 (1 fail → 0 pass)' <<< "$a6_md" >/dev/null; then
  fail A6 "unambiguous bridge must aggregate to 1 round (got: $(grep 'Review rounds' <<< "$a6_md"))"
fi
grep -Fx -- 'harness.economics.review_rounds=1' <<< "$a6_num" >/dev/null \
  || fail A6 "numeric review_rounds must be 1 via bridge"
grep -Fx -- 'harness.economics.review_identity_covered=2' <<< "$a6_num" >/dev/null \
  || fail A6 "bridge coverage must be 2/2"
grep -Fx -- 'harness.economics.review_identity_total=2' <<< "$a6_num" >/dev/null \
  || fail A6 "bridge total must be 2"
pass A6 "mixed same-event explicit+legacy same coordinates → 1 round via bridge"

# ---------- A7: ambiguous two explicit IDs + legacy same coordinates → n/a ---
# Two explicit-ID spans share (sha-a, full); a third legacy span at the same
# coordinates cannot be attributed → uncovered → coverage incomplete → n/a.
cat > "$TRACE_A" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-2","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f3","harness.outcome":"pass"}
JSONL
a7_md="$(run_markdown "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
a7_num="$(run_numeric "$ROOT/scripts/finish-lib.sh" "$TRACE_A")"
if ! grep -q 'Review rounds: n/a' <<< "$a7_md"; then
  fail A7 "ambiguous coordinates must produce n/a (got: $(grep 'Review rounds' <<< "$a7_md"))"
fi
if grep -Fq 'harness.economics.review_rounds=' <<< "$a7_num"; then
  fail A7 "numeric review_rounds must be omitted when coverage is ambiguous"
fi
grep -Fx -- 'harness.economics.review_identity_covered=2' <<< "$a7_num" >/dev/null \
  || fail A7 "ambiguous coverage must report 2 covered (explicit-ID spans only)"
grep -Fx -- 'harness.economics.review_identity_total=3' <<< "$a7_num" >/dev/null \
  || fail A7 "ambiguous total must be 3"
pass A7 "ambiguous two explicit IDs + legacy same coordinates → n/a, coverage honest"

# ---------- M1: mutation — revert to SHA/mode-only key kills sensor ----------
MUTATED_LIB="${SCRATCH}/finish-lib-mutated-m1.sh"
# shellcheck disable=SC2016 # $eid is the literal jq variable name being mutated.
sed 's/\$eid/null/g' "$ROOT/scripts/finish-lib.sh" > "$MUTATED_LIB"
# If the mutation didn't alter anything meaningful, try alternate approach
if cmp -s "$ROOT/scripts/finish-lib.sh" "$MUTATED_LIB"; then
  # The variable name may differ; strip the review_event_id key lookup entirely
  sed 's/"harness.review_event_id"/"__disabled__"/g' "$ROOT/scripts/finish-lib.sh" > "$MUTATED_LIB"
fi
if cmp -s "$ROOT/scripts/finish-lib.sh" "$MUTATED_LIB"; then
  fail M1 "mutation setup did not alter the review-event key"
fi
# A2 must fail: two explicit event IDs on same SHA/mode would collapse to 1
cat > "${SCRATCH}/m1_trace.jsonl" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-2","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-2","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.feature_id":"f2","harness.outcome":"pass"}
JSONL
m1_md="$(run_markdown "$MUTATED_LIB" "${SCRATCH}/m1_trace.jsonl")"
m1_rounds="$(sed -n 's/^- Review rounds: \([0-9][0-9]*\).*/\1/p' <<< "$m1_md")"
if [ "${m1_rounds:-}" = "2" ]; then
  fail M1 "mutation that disables review_event_id should not produce 2 rounds"
fi
pass M1 "mutation reverting to SHA/mode-only key killed by sensor"

# ---------- M2: mutation — count fingerprints instead of event IDs -----------
MUTATED_LIB2="${SCRATCH}/finish-lib-mutated-m2.sh"
sed 's/"harness.review_event_id"/"harness.finding_fingerprint"/g' "$ROOT/scripts/finish-lib.sh" > "$MUTATED_LIB2"
if cmp -s "$ROOT/scripts/finish-lib.sh" "$MUTATED_LIB2"; then
  fail M2 "mutation setup did not alter the identity key"
fi
# With fingerprint as key, A1 trace (3 findings, 1 event) would show 3 rounds if fingerprints differ
cat > "${SCRATCH}/m2_trace.jsonl" <<'JSONL'
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.finding_fingerprint":"fp-1","harness.feature_id":"f1","harness.outcome":"pass"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.finding_fingerprint":"fp-2","harness.feature_id":"f2","harness.outcome":"fail"}
{"span":"agent","harness.lifecycle_step":"review_verdict","harness.review_event_id":"evt-1","harness.finding_fingerprint":"fp-3","harness.feature_id":"f3","harness.outcome":"pass"}
JSONL
m2_md="$(run_markdown "$MUTATED_LIB2" "${SCRATCH}/m2_trace.jsonl")"
m2_rounds="$(sed -n 's/^- Review rounds: \([0-9][0-9]*\).*/\1/p' <<< "$m2_md")"
if [ "${m2_rounds:-}" = "1" ]; then
  fail M2 "mutation counting fingerprints should not produce 1 round (it groups by fingerprint, not event ID)"
fi
pass M2 "mutation counting fingerprints instead of event IDs killed by sensor"

printf '\nfinding identity decoupling contract honored (%d legs passed)\n' 19
