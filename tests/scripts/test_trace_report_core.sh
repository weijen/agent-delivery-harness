#!/usr/bin/env bash
# test_trace_report_core.sh — regression sensor for the per-issue trace report
# core (issue #98, feature trace-report-core, plan Phase 1).
#
# Executable spec for `scripts/trace-report.sh <issue-number|trace-path>`, the
# deterministic, report-only CLI that turns a per-issue trace.jsonl into a
# markdown run report on STDOUT and a machine-readable trace-summary.json.
# The consolidated scope includes core aggregation, bounded/open semantics,
# summary JSON, robustness, and token honesty.
#
# Pinned report conventions (this sensor IS the spec — plan D1/D3/D7):
#
#   1. Markdown on stdout (at least one '#' heading). Per-lifecycle-stage
#      section reports BOTH clocks, separately and distinctly labeled
#      (plan D3 — never blended):
#        * clock A label contains the literal text  `summed duration_ms`
#          (per-stage sum of harness.duration_ms — script-measured work);
#        * clock B label contains the literal text
#          `first-to-last timestamp elapsed`  (whole-run wall clock,
#          reported in SECONDS, includes agent thinking time between spans).
#   2. Stage table rows are markdown pipe rows, column order
#          | <step> | <spans> | <summed duration_ms> |
#      A stage whose spans carry no harness.duration_ms reports  n/a  —
#      never a fabricated 0 (absence semantics, plan D5). Stages count
#      harness.lifecycle_step across ALL span types (log-handback rides
#      steps on agent spans), so a red_handback agent span makes a
#      red_handback stage row.
#   3. Tool table keyed on gen_ai.tool.name; pipe rows with column order
#          | <tool name> | <calls> | ...
#      header row carries the word `calls`. Exact counts.
#   4. Final outcome line: label contains `final outcome` (any case) and
#      carries the harness.outcome of the finish lifecycle span.
#   5. Invalid lines (unparseable JSON, or parseable-but-not-an-object) are
#      skipped and counted, reported as  `invalid lines: <N>`  plus a pointer
#      containing  `check-trace-consistency.sh`  (pinned loosely — plan D1: the report
#      never re-implements validation).
#   6. No validation duplication (plan D1): a TYPE-violating but parseable
#      span (check-trace-consistency.sh would flag type_violation) still aggregates —
#      the report is not a validator.
#   7. CLI parity with check-trace-consistency.sh (plan D7): plain issue-number arg
#      resolves <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl;
#      an explicit path arg reads that file directly; no args → exit 2 with
#      a usage message on stderr; missing trace file → exit 2. Exit 0
#      whenever a report is produced — invalid lines in the trace do NOT
#      change the exit code (reporting is not gating; gate wiring is #103).
#
# Exit codes: 0 report contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
SUMMARY_CONTRACT="${ROOT}/docs/evaluation/trace-summary.v1.json"
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

# The fixture must control everything: no ambient trace overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the report and this sensor are jq-driven)"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB}) — trace-report.sh issue-number mode depends on it"

# RED gate: the script under test must exist (and be executable) before any
# behavior can be specified against it.
[ -f "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh not found (${REPORT_SH}) — the per-issue trace report for feature trace-report-core (issue #98 Phase 1) is not implemented yet"
[ -x "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh exists but is not executable (${REPORT_SH})"

# --- Fixture trace: hand-built, KNOWN numbers -----------------------------------
# 15 aggregatable lines + 2 planted invalid lines = 17 lines total.
#
# Expected numbers (the whole spec hangs off these):
#   wall clock:  first ts 10:00:00Z (preflight) → last ts 10:10:30Z (finish)
#                = 630 seconds first-to-last elapsed
#   stages (harness.lifecycle_step across ALL span types):
#     preflight      1 span   summed duration_ms 1200
#     feature_start  1 span   summed duration_ms 300
#     red_handback   1 span   n/a  (agent span, no harness.duration_ms)
#     pr_create      1 span   summed duration_ms 2500
#     pr_merge       2 spans  summed duration_ms 1000  (400 + 600)
#     finish         1 span   summed duration_ms 150   (harness.outcome pass)
#   tools (gen_ai.tool.name):
#     check-feature-list 2 · git 3 · review-gate.check 1 · typedrift-tool 1
#     (typedrift-tool is the type-violating-but-parseable span: string
#      schema_version and string harness.issue — check-trace-consistency.sh territory,
#      NOT the report's; it must still aggregate)
#   invalid lines: exactly 2 (one non-JSON, one JSON-scalar non-object)
write_fixture_trace() {
  local f="$1"
  : > "$f"
  local ln
  for ln in \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"preflight","harness.exit_status":0,"harness.duration_ms":1200}' \
    'GARBAGE_LINE_a17c this is not JSON {{{' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:05Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"feature_start","harness.feature_id":"trace-report-core","harness.duration_ms":300}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:00:10Z","span":"agent","harness.issue":98,"harness.version":"fix1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"test-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"trace-report-core","harness.outcome":"pass"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:01:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"check-feature-list","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":10}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:02:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"check-feature-list","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":20}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:03:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":5}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:03:10Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":5}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:03:20Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"git","harness.outcome":"pass","harness.duration_ms":5}' \
    '"SCALAR_LINE_b42e — valid JSON, not an object"' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:04:00Z","span":"tool","harness.issue":98,"harness.version":"fix1234","gen_ai.tool.name":"review-gate.check","harness.outcome":"pass","harness.duration_ms":40}' \
    '{"schema_version":"1","timestamp":"2026-07-04T10:05:00Z","span":"tool","harness.issue":"98","harness.version":"fix1234","gen_ai.tool.name":"typedrift-tool","harness.duration_ms":7}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:06:00Z","span":"agent","harness.issue":98,"harness.version":"fix1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:07:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"pr_create","harness.duration_ms":2500}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:08:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"pr_merge","harness.duration_ms":400}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:09:00Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"pr_merge","harness.duration_ms":600}' \
    '{"schema_version":1,"timestamp":"2026-07-04T10:10:30Z","span":"lifecycle","harness.issue":98,"harness.version":"fix1234","harness.lifecycle_step":"finish","harness.outcome":"pass","harness.duration_ms":150}' \
    ; do
    printf '%s\n' "$ln" >> "$f"
  done
}

TRACE="${TMP_DIR}/trace.jsonl"
write_fixture_trace "$TRACE"

# Fixture self-checks: the planted shapes must actually be on disk.
[ "$(wc -l < "$TRACE" | tr -d '[:space:]')" = "17" ] \
  || hard_fail "fixture trace must have exactly 17 lines"
if printf '%s\n' "$(sed -n '2p' "$TRACE")" | jq empty >/dev/null 2>&1; then
  hard_fail "fixture line 2 was supposed to be non-JSON garbage"
fi
jq -e 'type != "object"' <<< "$(sed -n '10p' "$TRACE")" >/dev/null 2>&1 \
  || hard_fail "fixture line 10 was supposed to be a JSON scalar (non-object)"
jq -e '.["gen_ai.tool.name"] == "typedrift-tool" and (.schema_version | type) == "string"' \
  <<< "$(sed -n '12p' "$TRACE")" >/dev/null 2>&1 \
  || hard_fail "fixture line 12 was supposed to be the type-violating-but-parseable tool span"

# --- Run helpers ------------------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
# run_report [--cwd <dir>] <cmd...> → prints the exit code; stdout/stderr land
# in $OUT/$ERR.
run_report() {
  local dir="$TMP_DIR"
  if [ "$1" = "--cwd" ]; then
    dir="$2"
    shift 2
  fi
  local rc=0
  (
    cd "$dir" || exit 9
    exec "$@"
  ) >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

expect_out() {
  local label="$1" ere="$2"
  grep -Eq "$ere" "$OUT" \
    || fail "${label}: stdout must match /${ere}/ (stdout was: $(tr '\n' '|' < "$OUT"))"
}

# Pipe-row regex: | <c1> | <c2> | <c3-or-more> ...
row3_re() {
  printf '[|][[:space:]]*%s[[:space:]]*[|][[:space:]]*%s[[:space:]]*[|][[:space:]]*%s[[:space:]]*[|]' \
    "$1" "$2" "$3"
}
row2_re() {
  printf '[|][[:space:]]*%s[[:space:]]*[|][[:space:]]*%s[[:space:]]*[|]' "$1" "$2"
}

# --- 1. Path mode: full report, exit 0 despite planted invalid lines ---------------
rc="$(run_report "$REPORT_SH" "$TRACE")"
[ "$rc" = "0" ] \
  || fail "path mode: expected exit 0 (a report was producible — invalid lines never gate, plan D7), got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"
expect_out "markdown shape" '^#'

# --- 2. Two clocks, labeled distinctly (plan D3) ------------------------------------
expect_out "clock A label (per-stage summed harness.duration_ms)" \
  'summed duration_ms'
expect_out "clock B label (whole-run wall clock)" \
  'first-to-last timestamp elapsed'
elapsed_line="$(grep -Ei 'first-to-last' "$OUT" | head -n 1)"
printf '%s\n' "$elapsed_line" | grep -Eq '(^|[^0-9])630([^0-9]|$)' \
  || fail "clock B value: the first-to-last line must carry 630 (seconds, 10:00:00Z → 10:10:30Z), got: ${elapsed_line}"

# --- 3. Per-lifecycle-stage table: exact fixture numbers ----------------------------
expect_out "stage row preflight (1 span, 1200 ms)"       "$(row3_re preflight 1 1200)"
expect_out "stage row feature_start (1 span, 300 ms)"    "$(row3_re feature_start 1 300)"
expect_out "stage row pr_create (1 span, 2500 ms)"       "$(row3_re pr_create 1 2500)"
expect_out "stage row pr_merge (2 spans, 400+600=1000)"  "$(row3_re pr_merge 2 1000)"
expect_out "stage row finish (1 span, 150 ms)"           "$(row3_re finish 1 150)"
# Steps ride on agent spans too (log-handback); no duration → n/a, never 0.
expect_out "stage row red_handback from an AGENT span, duration n/a (absent data is absent, not 0)" \
  "$(row3_re red_handback 1 'n/a')"

# --- 4. Tool-call counts by gen_ai.tool.name: exact counts --------------------------
expect_out "tool table header carries 'calls'" '[|].*calls'
expect_out "tool row check-feature-list (2 calls)" "$(row2_re 'check-feature-list' 2)"
expect_out "tool row git (3 calls)"                "$(row2_re 'git' 3)"
expect_out "tool row review-gate.check (1 call)"   "$(row2_re 'review-gate\.check' 1)"

# --- 5. No validation duplication (plan D1): type-violating span still aggregates ---
expect_out "type-violating-but-parseable span aggregates (report is not a validator)" \
  "$(row2_re 'typedrift-tool' 1)"

# --- 6. Final outcome line (finish span's harness.outcome) --------------------------
grep -Eiq 'final outcome.*pass' "$OUT" \
  || fail "final outcome: report must carry a 'final outcome' line with the finish span's harness.outcome 'pass' (stdout was: $(tr '\n' '|' < "$OUT"))"

# --- 7. Invalid lines: skipped, counted, pointed at the validator -------------------
grep -Eiq 'invalid lines: 2' "$OUT" \
  || fail "invalid lines: report must count exactly the 2 planted bad lines as 'invalid lines: 2' (the type-violating span is NOT invalid here)"
grep -Fq 'check-trace-consistency.sh' "$OUT" \
  || fail "invalid lines: report must point at check-trace-consistency.sh for details (plan D1 — no validation duplication)"

# --- 8. Issue-number mode (CLI parity with check-trace-consistency.sh, plan D7) --------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
cp "$REPORT_SH" "${FIX}/scripts/trace-report.sh"
cp "$ISSUE_LIB" "${FIX}/scripts/issue-lib.sh"
if [ -f "$TRACE_LIB" ]; then
  cp "$TRACE_LIB" "${FIX}/scripts/trace-lib.sh"
fi
if [ -f "$CONTRACT" ]; then
  cp "$CONTRACT" "${FIX}/docs/evaluation/trace-schema.v1.json"
fi
chmod +x "${FIX}/scripts/trace-report.sh"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name "Harness Test"
git -C "$FIX" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${FIX}/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m initial
mkdir -p "${FIX}/.copilot-tracking/issues/issue-98"
write_fixture_trace "${FIX}/.copilot-tracking/issues/issue-98/trace.jsonl"

rc="$(run_report --cwd "$FIX" "./scripts/trace-report.sh" 98)"
[ "$rc" = "0" ] \
  || fail "issue-number mode: expected exit 0 for issue 98 resolved from the main root, got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"
expect_out "issue-number mode: same numbers — tool row git (3 calls)" "$(row2_re 'git' 3)"
expect_out "issue-number mode: same numbers — stage row pr_merge"     "$(row3_re pr_merge 2 1000)"
grep -Eiq 'invalid lines: 2' "$OUT" \
  || fail "issue-number mode: invalid-line count must match path mode (2)"

# --- 9. Usage/environment errors: exit 2 --------------------------------------------
rc="$(run_report "$REPORT_SH")"
[ "$rc" = "2" ] \
  || fail "no arguments: expected exit 2 (usage error), got ${rc}"
grep -qi 'usage' "$ERR" \
  || fail "no arguments: expected a usage message on stderr, got: $(tr '\n' '|' < "$ERR")"

rc="$(run_report "$REPORT_SH" "${TMP_DIR}/does-not-exist/trace.jsonl")"
[ "$rc" = "2" ] \
  || fail "missing trace file (path mode): expected exit 2 (environment error), got ${rc}"
grep -Eqi 'usage|not found|no such|missing' "$ERR" \
  || fail "missing trace file: expected a usage-ish message on stderr, got: $(tr '\n' '|' < "$ERR")"

# --- 10. Machine-readable summary and markdown agreement ---------------------------
SUMMARY="${TMP_DIR}/trace-summary.json"
[ -f "$SUMMARY_CONTRACT" ] \
  || hard_fail "trace summary contract is missing: ${SUMMARY_CONTRACT}"
jq -e '
  .summary_schema_version == 1
  and (["summary_schema_version","trace_file","issue","harness_versions",
        "finished","final_outcome","span_counts","wall_clock","stages",
        "tools","tokens"]
       | all(.[]; . as $key | $required | index($key) != null))
' --argjson required "$(jq '.required_top_level' "$SUMMARY_CONTRACT")" \
  "$SUMMARY_CONTRACT" >/dev/null \
  || fail "trace-summary.v1 contract does not retain its required vocabulary"

# Re-run the canonical fixture so later CLI error legs cannot obscure the
# summary emitted beside it.
rc="$(run_report "$REPORT_SH" "$TRACE")"
[ "$rc" = "0" ] || fail "summary fixture re-run failed with ${rc}"
if [ ! -f "$SUMMARY" ]; then
  fail "trace-summary.json was not emitted beside the trace"
else
  jq -e '
    .summary_schema_version == 1
    and .issue == 98
    and .finished == true
    and .bounded == true
    and .closed_by == "finish"
    and .final_outcome == "pass"
    and .span_counts.total == 15
    and .span_counts.invalid_lines == 2
    and .wall_clock.elapsed_seconds == 630
    and ((.stages[] | select(.step == "pr_merge"))
         | .spans == 2 and .duration_ms == 1000)
    and ((.tools[] | select(.name == "git")) | .calls == 3)
    and .tokens == null
  ' "$SUMMARY" >/dev/null \
    || fail "canonical trace summary lost exact core measurements"
  before_summary="$(shasum -a 256 "$SUMMARY")"
  rc="$(run_report "$REPORT_SH" "$TRACE")"
  [ "$rc" = "0" ] || fail "idempotent summary re-run failed with ${rc}"
  [ "$(shasum -a 256 "$SUMMARY")" = "$before_summary" ] \
    || fail "identical report input did not produce identical summary JSON"
  jq -es 'length == 1' "$SUMMARY" >/dev/null \
    || fail "summary writer appended instead of atomically replacing"
fi

# --- 11. Terminal bounds are distinct from finished outcome ----------------------
BOUND_DIR="${TMP_DIR}/bounds"
mkdir -p "$BOUND_DIR"
cat > "${BOUND_DIR}/trace.jsonl" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T11:00:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"preflight","harness.duration_ms":100}
{"schema_version":1,"timestamp":"2026-07-08T11:01:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"pr_merge","harness.duration_ms":200}
JSONL
rc="$(run_report "$REPORT_SH" "${BOUND_DIR}/trace.jsonl")"
[ "$rc" = "0" ] || fail "pr_merge-bounded report failed with ${rc}"
jq -e '.finished == false and .bounded == true
  and .closed_by == "pr_merge" and .final_outcome == null' \
  "${BOUND_DIR}/trace-summary.json" >/dev/null \
  || fail "pr_merge-only trace was not represented as bounded but unfinished"
grep -Eiq 'bounded by.*pr_merge|pr_merge.*bounded by' "$OUT" \
  || fail "pr_merge bound was not explained in markdown"

OPEN_DIR="${TMP_DIR}/open"
mkdir -p "$OPEN_DIR"
cat > "${OPEN_DIR}/trace.jsonl" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-08T12:00:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"preflight","harness.duration_ms":100}
{"schema_version":1,"timestamp":"2026-07-08T12:01:00Z","span":"lifecycle","harness.issue":170,"harness.version":"bounded1","harness.lifecycle_step":"feature_start","harness.feature_id":"open-run","harness.duration_ms":200}
JSONL
rc="$(run_report "$REPORT_SH" "${OPEN_DIR}/trace.jsonl")"
[ "$rc" = "0" ] || fail "open report failed with ${rc}"
jq -e '.finished == false and .bounded == false
  and .closed_by == null and .final_outcome == null' \
  "${OPEN_DIR}/trace-summary.json" >/dev/null \
  || fail "open trace fabricated a terminal bound or outcome"

# --- 12. Robust absence semantics and large-line handling ------------------------
EMPTY_DIR="${TMP_DIR}/empty"
mkdir -p "$EMPTY_DIR"
: > "${EMPTY_DIR}/trace.jsonl"
rc="$(run_report "$REPORT_SH" "${EMPTY_DIR}/trace.jsonl")"
[ "$rc" = "0" ] || fail "empty trace crashed with ${rc}"
jq -e '
  .span_counts == {"total":0,"by_type":{},"invalid_lines":0}
  and .stages == [] and .tools == [] and .tokens == null
  and .wall_clock == null and .final_outcome == null
' "${EMPTY_DIR}/trace-summary.json" >/dev/null \
  || fail "empty trace fabricated measurements"

GARBAGE_DIR="${TMP_DIR}/garbage"
mkdir -p "$GARBAGE_DIR"
printf '%s\n' 'not json' '"valid scalar"' > "${GARBAGE_DIR}/trace.jsonl"
rc="$(run_report "$REPORT_SH" "${GARBAGE_DIR}/trace.jsonl")"
[ "$rc" = "0" ] || fail "garbage-only trace crashed with ${rc}"
jq -e '.span_counts.total == 0 and .span_counts.invalid_lines == 2
  and .wall_clock == null and .tokens == null' \
  "${GARBAGE_DIR}/trace-summary.json" >/dev/null \
  || fail "garbage-only trace was not skipped and counted honestly"

BIG_DIR="${TMP_DIR}/big-line"
mkdir -p "$BIG_DIR"
jq -nc '{schema_version:1,timestamp:"2026-07-04T14:00:00Z",span:"tool",
  "harness.issue":98,"harness.version":"fix1234",
  "gen_ai.tool.name":"big-tool","harness.duration_ms":1,
  "harness.note":("x" * 1048576)}' > "${BIG_DIR}/trace.jsonl"
rc="$(run_report "$REPORT_SH" "${BIG_DIR}/trace.jsonl")"
[ "$rc" = "0" ] || fail "one-megabyte span line crashed with ${rc}"
jq -e '(.tools[] | select(.name == "big-tool")) | .calls == 1' \
  "${BIG_DIR}/trace-summary.json" >/dev/null \
  || fail "large valid span did not aggregate"

# --- 13. Tokens come only from measured model spans ------------------------------
TOKEN_DIR="${TMP_DIR}/tokens"
mkdir -p "$TOKEN_DIR"
cat > "${TOKEN_DIR}/trace.jsonl" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-04T15:00:00Z","span":"model","harness.issue":98,"harness.version":"fix1234","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":10,"gen_ai.agent.name":"planner","harness.feature_id":"feat-x"}
{"schema_version":1,"timestamp":"2026-07-04T15:01:00Z","span":"model","harness.issue":98,"harness.version":"fix1234","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":200,"gen_ai.usage.output_tokens":20,"gen_ai.agent.name":"planner","harness.feature_id":"feat-y"}
{"schema_version":1,"timestamp":"2026-07-04T15:02:00Z","span":"agent","harness.issue":98,"harness.version":"fix1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"deviation","harness.feature_id":"feat-x","harness.outcome":"blocked","gen_ai.usage.input_tokens":9999,"gen_ai.usage.output_tokens":9999}
JSONL
rc="$(run_report "$REPORT_SH" "${TOKEN_DIR}/trace.jsonl")"
[ "$rc" = "0" ] || fail "measured-token trace failed with ${rc}"
jq -e '
  .tokens.input_tokens == 300
  and .tokens.output_tokens == 30
  and .tokens.by_role.planner == {"input_tokens":300,"output_tokens":30}
  and .tokens.by_feature["feat-x"] == {"input_tokens":100,"output_tokens":10}
  and .tokens.by_feature["feat-y"] == {"input_tokens":200,"output_tokens":20}
' "${TOKEN_DIR}/trace-summary.json" >/dev/null \
  || fail "token totals included non-model passthrough or lost attribution"

# --- Result ---------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-report core contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-report core contract honored\n'
