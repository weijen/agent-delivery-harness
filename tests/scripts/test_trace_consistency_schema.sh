#!/usr/bin/env bash
# Consolidated schema, completeness, redaction, sanity, and constant-pass
# sensor for scripts/check-trace-consistency.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
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

command -v jq >/dev/null 2>&1 || hard_fail "jq is required"
[ -x "$CHECKER" ] || hard_fail "consistency checker is missing"
[ -f "$TRACE_LIB" ] || hard_fail "trace-lib.sh is missing"
[ -f "$ISSUE_LIB" ] || hard_fail "issue-lib.sh is missing"
[ -f "$CONTRACT" ] || hard_fail "trace schema is missing"

OUT="${TMP_DIR}/out"
ERR="${TMP_DIR}/err"
run_checker() {
  local rc=0
  "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

make_case() {
  local name="$1"
  local dir="${TMP_DIR}/${name}/.copilot-tracking/issues/issue-42"
  mkdir -p "$dir"
  printf '# Progress\n\n## Action Log\n' > "${dir}/progress.md"
  printf '%s' "$dir"
}

expect_finding() {
  local name="$1" expected="$2"
  shift 2
  local dir rc
  dir="$(make_case "$name")"
  printf '%s\n' "$@" > "${dir}/trace.jsonl"
  rc="$(run_checker "$CHECKER" "${dir}/trace.jsonl")"
  [ "$rc" = "1" ] \
    || fail "${name}: expected exit 1, got ${rc} ($(tr '\n' '|' < "$OUT"))"
  grep -Fq "$expected" "$OUT" \
    || fail "${name}: missing '${expected}' ($(tr '\n' '|' < "$OUT"))"
}

VALID='{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}'

# Clean schema-valid trace.
clean_dir="$(make_case clean)"
printf '%s\n' "$VALID" > "${clean_dir}/trace.jsonl"
rc="$(run_checker "$CHECKER" "${clean_dir}/trace.jsonl")"
[ "$rc" = "0" ] \
  || fail "valid trace must pass, got ${rc} ($(tr '\n' '|' < "$OUT"))"
grep -Eq '[0-9]+ span\(s\), 0 violation\(s\), 0 warning\(s\)' "$OUT" \
  || fail "valid trace must report the consolidated span/finding count"

# JSON, schema, known-key type, and failure-mode checks.
expect_finding invalid-json 'VIOLATION line 2: invalid_json' \
  "$VALID" 'not json {'
expect_finding schema 'VIOLATION line 2: schema_violation' \
  "$VALID" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"banana","harness.issue":42,"harness.version":"abc1234"}'
expect_finding type 'VIOLATION line 2: type_violation' \
  "$VALID" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"preflight","harness.duration_ms":"42"}'
expect_finding failure-mode 'VIOLATION line 2: failure_mode_violation' \
  "$VALID" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git","harness.failure_mode":"gremlins"}'

# Sanity warnings remain non-blocking.
warning_dir="$(make_case warnings)"
printf '%s\n%s\n' "$VALID" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"check-feature-list","harness.outcome":"pass","harness.warning":"jq_skipped"}' \
  > "${warning_dir}/trace.jsonl"
rc="$(run_checker "$CHECKER" "${warning_dir}/trace.jsonl")"
[ "$rc" = "0" ] || fail "jq-skipped warning must not change exit status"
grep -Fq 'WARNING line 2: jq_skipped_pass' "$OUT" \
  || fail "jq-skipped warning is missing"

elsewhere="${TMP_DIR}/elsewhere"
mkdir -p "$elsewhere"
printf '# Progress\n\n## Action Log\n' > "${elsewhere}/progress.md"
printf '%s\n' "$VALID" > "${elsewhere}/trace.jsonl"
rc="$(run_checker "$CHECKER" "${elsewhere}/trace.jsonl")"
[ "$rc" = "0" ] || fail "unexpected location warning must not change exit status"
grep -Fq 'WARNING: unexpected trace location' "$OUT" \
  || fail "unexpected-location warning is missing"

# Redaction audit reports no value and distinguishes a failed auditor.
GHP_SECRET="ghp_SyntheticFixtureToken0123456789abcd"
leak_dir="$(make_case leak)"
printf '%s\n' \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git","harness.summary":"'"${GHP_SECRET}"'"}' \
  > "${leak_dir}/trace.jsonl"
rc="$(run_checker "$CHECKER" "${leak_dir}/trace.jsonl")"
[ "$rc" = "1" ] || fail "redaction leak must fail"
grep -Fq 'VIOLATION line 1: redaction_leak' "$OUT" \
  || fail "redaction leak finding is missing"
if grep -Fq "$GHP_SECRET" "$OUT" "$ERR"; then
  fail "redaction finding echoed the planted secret"
fi

broken="${TMP_DIR}/broken"
mkdir -p "${broken}/scripts" "${broken}/docs/evaluation" \
  "${broken}/.copilot-tracking/issues/issue-42"
cp "$CHECKER" "${broken}/scripts/check-trace-consistency.sh"
cp "$ISSUE_LIB" "${broken}/scripts/issue-lib.sh"
cp "$CONTRACT" "${broken}/docs/evaluation/trace-schema.v1.json"
cat > "${broken}/scripts/trace-lib.sh" <<'EOF'
#!/usr/bin/env bash
trace_redact() {
  cat >/dev/null
  return 1
}
EOF
printf '# Progress\n\n## Action Log\n' \
  > "${broken}/.copilot-tracking/issues/issue-42/progress.md"
printf '%s\n%s\n' "$VALID" "$VALID" \
  > "${broken}/.copilot-tracking/issues/issue-42/trace.jsonl"
rc="$(run_checker "${broken}/scripts/check-trace-consistency.sh" \
  "${broken}/.copilot-tracking/issues/issue-42/trace.jsonl")"
[ "$rc" = "1" ] || fail "broken redaction auditor must fail closed"
grep -Fq 'VIOLATION line 1: redaction_audit_error' "$OUT" \
  || fail "redaction audit error line 1 is missing"
grep -Fq 'VIOLATION line 2: redaction_audit_error' "$OUT" \
  || fail "redaction audit error line 2 is missing"
if grep -q 'redaction_leak' "$OUT"; then
  fail "broken auditor must not be reported as a leak"
fi

# Finished-run completeness counts steps across span types and permits repeats.
complete_dir="$(make_case complete)"
for step in preflight worktree_create plan_handback feature_start red_handback \
  impl_handback green_handback review_verdict review_gate_approve pr_create \
  pr_merge pr_merge finish; do
  printf '{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"%s"}\n' \
    "$step"
done > "${complete_dir}/trace.jsonl"
printf '%s\n' \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"agent","harness.issue":42,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"feature_start","harness.feature_id":"f1","harness.outcome":"pass"}' \
  >> "${complete_dir}/trace.jsonl"
printf -- '- [conductor] feature_start f1 pass — fixture\n' \
  >> "${complete_dir}/progress.md"
rc="$(run_checker "$CHECKER" "${complete_dir}/trace.jsonl")"
[ "$rc" = "0" ] \
  || fail "finished trace with all lifecycle steps must pass ($(tr '\n' '|' < "$OUT"))"

missing_dir="$(make_case incomplete)"
grep -v '"harness.lifecycle_step":"red_handback"' \
  "${complete_dir}/trace.jsonl" > "${missing_dir}/trace.jsonl"
cp "${complete_dir}/progress.md" "${missing_dir}/progress.md"
rc="$(run_checker "$CHECKER" "${missing_dir}/trace.jsonl")"
[ "$rc" = "1" ] || fail "finished trace missing a lifecycle step must fail"
grep -Fq 'VIOLATION completeness: missing lifecycle step red_handback' "$OUT" \
  || fail "finished-run completeness finding is missing"

# The consolidated classification remains constant-pass, not per-line jq.
budget_dir="$(make_case budget)"
: > "${budget_dir}/trace.jsonl"
for _ in $(seq 1 50); do
  printf '%s\n' "$VALID" >> "${budget_dir}/trace.jsonl"
done
REAL_JQ="$(command -v jq)"
SHIM="${TMP_DIR}/shim"
COUNT="${TMP_DIR}/jq-count"
mkdir -p "$SHIM"
: > "$COUNT"
cat > "${SHIM}/jq" <<EOF
#!/usr/bin/env bash
printf 'x\n' >> "${COUNT}"
exec "${REAL_JQ}" "\$@"
EOF
chmod +x "${SHIM}/jq"
rc="$(run_checker env PATH="${SHIM}:${PATH}" "$CHECKER" \
  "${budget_dir}/trace.jsonl")"
[ "$rc" = "0" ] || fail "50-line valid trace must pass"
jq_calls="$(wc -l < "$COUNT" | tr -d '[:space:]')"
[ "$jq_calls" -le 10 ] \
  || fail "constant-pass budget exceeded: ${jq_calls} jq calls for 50 lines"

# CLI/environment failures remain distinct.
rc="$(run_checker "$CHECKER")"
[ "$rc" = "2" ] || fail "no arguments must exit 2"
rc="$(run_checker "$CHECKER" "${TMP_DIR}/missing/trace.jsonl")"
[ "$rc" = "2" ] || fail "missing trace must exit 2"

missing_lib="${TMP_DIR}/missing-lib"
mkdir -p "${missing_lib}/scripts" "${missing_lib}/docs/evaluation"
cp "$CHECKER" "${missing_lib}/scripts/check-trace-consistency.sh"
cp "$ISSUE_LIB" "${missing_lib}/scripts/issue-lib.sh"
cp "$CONTRACT" "${missing_lib}/docs/evaluation/trace-schema.v1.json"
rc="$(run_checker "${missing_lib}/scripts/check-trace-consistency.sh" \
  "${clean_dir}/trace.jsonl")"
[ "$rc" = "2" ] \
  || fail "missing trace-lib.sh must be an environment error (exit 2), got ${rc}"
grep -Fq 'error: cannot load scripts/trace-lib.sh' "$ERR" \
  || fail "missing trace-lib.sh must report an explicit environment error"

if [ "$fails" -ne 0 ]; then
  printf '\n%d consolidated trace-schema contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-consistency schema/completeness/redaction/sanity contract honored\n'
