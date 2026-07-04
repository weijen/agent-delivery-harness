#!/usr/bin/env bash
# test_validate_trace_perf.sh — regression sensor for the validate-trace fork
# collapse + redaction-audit-error split (issue #103, feature
# validate-trace-single-pass, plan Phase 1).
#
# Executable spec, three legs:
#
#   LEG 1 (output parity): the single-pass rework must be a pure refactor of
#     the per-line findings. On a mixed fixture (2 valid spans, then one line
#     per violation class — invalid_json, schema_violation, type_violation,
#     failure_mode_violation, redaction_leak — plus a jq_skipped_pass warning
#     span, no `finish` step), the SET of findings (all VIOLATION/WARNING
#     lines, compared sorted so single-pass emission order is free to change),
#     the summary tail, the unfinished-run NOTE, and exit 1 must all match the
#     literal expectations pinned below. Those expectations were captured from
#     the pre-rework validator on this exact fixture — the old per-line-loop
#     binary is NOT diffed against at run time (it won't exist after the
#     rework); the pinned literals ARE the contract.
#
#   LEG 2 (fork budget): the validator's per-line loop forks ~6 jq processes
#     per trace line (check_line: jq empty + schema filter + type filter;
#     check_line_failure_mode: jq empty + enum filter; check_line_jq_skipped)
#     — ~300 forks for a 50-line trace, ~50k for a real gate-sized one. A
#     gate that forks 5xN processes is a gate people disable (plan, decision
#     4). Pinned budget: running the validator on a 50-LINE all-valid trace
#     makes AT MOST 10 jq invocations, counted by a PATH-shimmed jq wrapper
#     that appends one line to a counter file per call before exec'ing the
#     real jq.
#     Budget rationale: a single-pass design needs O(1) jq programs, not
#     O(N) — one classification pass over the whole file (jq -nR 'inputs'
#     style, like the existing completeness pass) covering invalid_json /
#     schema / type / failure_mode / jq_skipped, plus the finish-detection
#     and completeness whole-trace passes (2 today), plus small headroom for
#     a couple of auxiliary calls the implementation may keep. 3 + headroom
#     rounds to 10; the essential property is that the count is INDEPENDENT
#     of line count (10 << 300 at N=50; any per-line jq fork reintroduced
#     later blows the budget immediately).
#
#   LEG 3 (redaction_audit_error): a trace_redact RUNTIME FAILURE is not a
#     leak. Today check_line_redaction conflates the two: a broken auditor
#     yields `redaction_leak`, indistinguishable from a secret on disk.
#     Fail-closed stays (still a VIOLATION, still exit 1), but the rule name
#     must be distinct so operators can tell "the auditor broke" from "a
#     secret survived". Pinned: with a STUB trace-lib whose trace_redact
#     consumes stdin and exits 1, a clean 2-line trace reports
#         VIOLATION line 1: redaction_audit_error
#         VIOLATION line 2: redaction_audit_error
#     exit 1, and NO redaction_leak finding. Distinction is proven from both
#     sides: the leg-1 mixed fixture (REAL trace_redact, planted secret)
#     must report redaction_leak and NO redaction_audit_error.
#
# RED status at authoring time (issue #97 validator features GREEN):
#   RED: leg 2 (current loop makes ~301 jq calls on the 50-line fixture,
#     measured 2026-07-04; budget is <= 10) and leg 3 (broken auditor
#     currently reports redaction_leak, and redaction_audit_error does not
#     exist as a rule).
#   Already-passing guard: leg 1 parity — pinned NOW, from the current
#     implementation's output, so the single-pass rework cannot silently
#     change findings, ordering-per-line semantics (first failing rule wins),
#     the summary tail, or exit semantics while chasing the budget.
#
# Exit codes: 0 single-pass contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
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

# The fixtures must control tracing entirely: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the validator and this sensor are jq-driven)"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found (${CONTRACT})"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -x "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh not found or not executable (${VALIDATOR}) — the #97 validator must exist before the single-pass rework can be specified"

# --- Fixture repo A: real libraries at canonical relative locations ------------
# The validator resolves trace-lib.sh, issue-lib.sh, and the contract relative
# to its own location, so copying everything into a throwaway repo lets each
# leg substitute exactly one collaborator without touching the real checkout.
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
cp "$VALIDATOR" "${FIX}/scripts/validate-trace.sh"
cp "$TRACE_LIB" "${FIX}/scripts/trace-lib.sh"
cp "$ISSUE_LIB" "${FIX}/scripts/issue-lib.sh"
cp "$CONTRACT" "${FIX}/docs/evaluation/trace-schema.v1.json"
chmod +x "${FIX}/scripts/validate-trace.sh"
git -C "$FIX" init -q -b main

# --- Mixed fixture trace (leg 1 input, leg 3 counter-fixture) -------------------
# Line-by-line design (first failing rule wins per line; exactly one finding
# expected per bad line):
#   1  valid tool span                                  -> no finding
#   2  valid tool span, LEGAL failure_mode weak-sensor  -> no finding (guards
#      the enum check against false positives)
#   3  not JSON                                         -> invalid_json
#   4  unknown span type                                -> schema_violation
#   5  harness.duration_ms as a STRING                  -> type_violation
#   6  harness.failure_mode outside the closed enum     -> failure_mode_violation
#   7  planted synthetic ghp_ token in harness.summary  -> redaction_leak
#   8  check-feature-list pass span with jq_skipped     -> WARNING jq_skipped_pass
# No `finish` step anywhere -> unfinished-run NOTE, completeness skipped.
# The trace sits at a contract-shaped path so NO location warning muddies the
# expected set.
GHP_SECRET="ghp_SyntheticFixtureToken0123456789abcd"
mkdir -p "${FIX}/.copilot-tracking/issues/issue-42"
MIXED_TRACE="${FIX}/.copilot-tracking/issues/issue-42/trace.jsonl"
cat > "$MIXED_TRACE" <<EOF
{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"pytest","harness.failure_mode":"weak-sensor"}
this is not json {
{"schema_version":1,"timestamp":"2026-07-04T12:00:03Z","span":"banana","harness.issue":42,"harness.version":"abc1234"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:04Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"preflight","harness.duration_ms":"42"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:05Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git","harness.failure_mode":"gremlins"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:06Z","span":"agent","harness.issue":42,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"red_handback","harness.summary":"pushed with ${GHP_SECRET} by mistake"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:07Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"check-feature-list","harness.outcome":"pass","harness.warning":"jq_skipped"}
EOF

# Fixture self-checks (anti-vacuity): the planted secret must be something
# the REAL trace_redact alters, and every JSON-intended line must parse —
# otherwise the pinned expectations drift silently.
redacted_line="$(
  # shellcheck source=/dev/null
  source "$TRACE_LIB"
  sed -n '7p' "$MIXED_TRACE" | trace_redact
)"
if [ "$redacted_line" = "$(sed -n '7p' "$MIXED_TRACE")" ]; then
  hard_fail "trace_redact no longer alters the planted ghp_ line — redaction_leak fixture vacuous"
fi
for lineno in 1 2 4 5 6 7 8; do
  sed -n "${lineno}p" "$MIXED_TRACE" | jq empty >/dev/null 2>&1 \
    || hard_fail "mixed fixture line ${lineno} is not valid JSON — sensor bug"
done

# --- Validator run helper --------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_validator() {
  local rc=0
  "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# ==============================================================================
# LEG 1 — output parity on the mixed fixture (pinned from pre-rework behavior)
# ==============================================================================
EXPECTED_FINDINGS="${TMP_DIR}/expected-findings.txt"
cat > "$EXPECTED_FINDINGS" <<'EOF'
VIOLATION line 3: invalid_json
VIOLATION line 4: schema_violation
VIOLATION line 5: type_violation
VIOLATION line 6: failure_mode_violation
VIOLATION line 7: redaction_leak
WARNING line 8: jq_skipped_pass
EOF

rc="$(run_validator "${FIX}/scripts/validate-trace.sh" "$MIXED_TRACE")"
[ "$rc" = "1" ] \
  || fail "parity: mixed fixture must exit 1 (violations present), got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"

ACTUAL_FINDINGS="${TMP_DIR}/actual-findings.txt"
grep -E '^(VIOLATION|WARNING) ' "$OUT" | sort > "$ACTUAL_FINDINGS" || true
if ! diff -u <(sort "$EXPECTED_FINDINGS") "$ACTUAL_FINDINGS" >"${TMP_DIR}/findings.diff" 2>&1; then
  fail "parity: finding set changed on the mixed fixture (diff: $(tr '\n' '|' < "${TMP_DIR}/findings.diff"))"
fi
grep -Fq 'NOTE: unfinished run' "$OUT" \
  || fail "parity: unfinished-run NOTE missing (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq '8 span(s), 5 violation(s), 1 warning(s)' "$OUT" \
  || fail "parity: summary tail must stay '8 span(s), 5 violation(s), 1 warning(s)' (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -qF -- "$GHP_SECRET" "$OUT" "$ERR"; then
  fail "parity: the report ECHOED the planted secret — findings must stay value-free"
fi
# Distinction, real-oracle side (leg 3 counterpart): a genuine leak is a
# redaction_leak, never an audit error.
if grep -q 'redaction_audit_error' "$OUT"; then
  fail "parity: healthy trace_redact + planted secret must report redaction_leak, NOT redaction_audit_error"
fi

# ==============================================================================
# LEG 2 — fork budget: <= 10 jq invocations for a 50-line all-valid trace
# ==============================================================================
# 50 valid tool spans at a contract-shaped path (all-valid isolates the
# budget from finding-path forks; exit must stay 0 so a shim-induced
# malfunction cannot masquerade as a passing budget).
mkdir -p "${FIX}/.copilot-tracking/issues/issue-50"
BUDGET_TRACE="${FIX}/.copilot-tracking/issues/issue-50/trace.jsonl"
: > "$BUDGET_TRACE"
i=1
while [ "$i" -le 50 ]; do
  printf '{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":50,"harness.version":"abc1234","gen_ai.tool.name":"git"}\n' \
    >> "$BUDGET_TRACE"
  i=$((i + 1))
done
[ "$(wc -l < "$BUDGET_TRACE" | tr -d '[:space:]')" = "50" ] \
  || hard_fail "budget fixture is not 50 lines — sensor bug"

# PATH-shimmed jq: append one line to the counter file per invocation, then
# exec the real jq so the validator behaves identically. Invocations are
# sequential (the validator never backgrounds jq), so line-append counting
# is exact.
REAL_JQ="$(command -v jq)"
SHIM_DIR="${TMP_DIR}/shim-bin"
mkdir -p "$SHIM_DIR"
JQ_COUNT_FILE="${TMP_DIR}/jq-invocations"
: > "$JQ_COUNT_FILE"
cat > "${SHIM_DIR}/jq" <<SHIM
#!/usr/bin/env bash
printf 'x\n' >> "${JQ_COUNT_FILE}"
exec "${REAL_JQ}" "\$@"
SHIM
chmod +x "${SHIM_DIR}/jq"

# Shim self-check: one probe call must count exactly once and still work.
probe="$(PATH="${SHIM_DIR}:${PATH}" jq -n '1+1')"
if [ "$probe" != "2" ]; then
  hard_fail "jq counting shim broke jq itself (probe output: ${probe}) — sensor bug"
fi
[ "$(wc -l < "$JQ_COUNT_FILE" | tr -d '[:space:]')" = "1" ] \
  || hard_fail "jq counting shim did not count the probe call — sensor bug"
: > "$JQ_COUNT_FILE"

rc="$(run_validator env PATH="${SHIM_DIR}:${PATH}" "${FIX}/scripts/validate-trace.sh" "$BUDGET_TRACE")"
[ "$rc" = "0" ] \
  || fail "budget: 50-line all-valid trace must still exit 0 under the shim, got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"
jq_calls="$(wc -l < "$JQ_COUNT_FILE" | tr -d '[:space:]')"
if [ "$jq_calls" -gt 10 ]; then
  fail "budget: ${jq_calls} jq invocations for a 50-line trace — budget is <= 10 (single-pass classification + whole-trace passes + headroom, independent of line count; the per-line loop measures ~301 here)"
fi

# ==============================================================================
# LEG 3 — broken trace_redact => redaction_audit_error, distinct from a leak
# ==============================================================================
# Fixture repo B: identical layout, but trace-lib.sh is a STUB whose
# trace_redact consumes stdin and exits 1 — the auditor itself is broken.
# The trace is CLEAN (self-checked against the real oracle above via line 1's
# shape), so any redaction finding here is attributable to the runtime
# failure alone.
BROKEN="${TMP_DIR}/broken-repo"
mkdir -p "${BROKEN}/scripts" "${BROKEN}/docs/evaluation"
cp "$VALIDATOR" "${BROKEN}/scripts/validate-trace.sh"
cp "$ISSUE_LIB" "${BROKEN}/scripts/issue-lib.sh"
cp "$CONTRACT" "${BROKEN}/docs/evaluation/trace-schema.v1.json"
chmod +x "${BROKEN}/scripts/validate-trace.sh"
cat > "${BROKEN}/scripts/trace-lib.sh" <<'EOF'
#!/usr/bin/env bash
# STUB trace-lib for the redaction_audit_error leg: the auditor is broken.
trace_redact() {
  cat > /dev/null
  return 1
}
EOF
git -C "$BROKEN" init -q -b main

mkdir -p "${BROKEN}/.copilot-tracking/issues/issue-42"
CLEAN_TRACE="${BROKEN}/.copilot-tracking/issues/issue-42/trace.jsonl"
cat > "$CLEAN_TRACE" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}
{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"preflight"}
EOF
# Anti-vacuity: the REAL oracle must leave these lines untouched, so a
# correct implementation reports NOTHING redaction-shaped on a healthy lib.
clean_roundtrip="$(
  # shellcheck source=/dev/null
  source "$TRACE_LIB"
  trace_redact < "$CLEAN_TRACE"
)"
if [ "$clean_roundtrip" != "$(cat "$CLEAN_TRACE")" ]; then
  hard_fail "clean leg-3 trace is altered by the real trace_redact — fixture would conflate leak and audit error, sensor bug"
fi

rc="$(run_validator "${BROKEN}/scripts/validate-trace.sh" "$CLEAN_TRACE")"
[ "$rc" = "1" ] \
  || fail "audit error: broken trace_redact must fail closed with exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION line 1: redaction_audit_error' "$OUT" \
  || fail "audit error: report must carry 'VIOLATION line 1: redaction_audit_error' (stdout: $(tr '\n' '|' < "$OUT"))"
grep -Fq 'VIOLATION line 2: redaction_audit_error' "$OUT" \
  || fail "audit error: EVERY line audited under a broken trace_redact must be flagged (line 2 missing; stdout: $(tr '\n' '|' < "$OUT"))"
if grep -q 'redaction_leak' "$OUT" "$ERR"; then
  fail "audit error: broken auditor reported redaction_leak — the two rules must be distinct (a broken auditor is not a secret on disk)"
fi

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d validate-trace-single-pass contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'validate-trace single-pass contract honored\n'
