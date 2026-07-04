#!/usr/bin/env bash
# test_trace_scorecard_honesty.sh — regression sensor for the honest
# aggregation semantics of scripts/trace-scorecard.sh (issue #104, feature
# scorecard-honesty, plan Phase 2).
#
# Executable spec (this sensor IS the spec — plan D2/D4/D5 + conductor-resolved
# decisions). Pinned conventions:
#
#   1. Null-vs-zero tokens (absence is null, never a fabricated 0):
#        * a bucket where SOME runs carry tokens sums ONLY the data-carrying
#          runs — token_coverage {runs_with_tokens, of} carries the honest
#          denominator, and the totals equal exactly the data-carrying runs'
#          numbers (a tokens-null run must never be averaged in as 0);
#        * a bucket where NO run carries tokens emits tokens null (never
#          {input: 0, output: 0}) with token_coverage {runs_with_tokens: 0}.
#   2. Mixed bucket (plan D1 case 3, conductor-resolved Open Question 3 = A):
#      a multi-version summary with NO readable sibling trace.jsonl is never
#      guessed — it lands in a VISIBLE synthetic "mixed" bucket inside
#      by_version (attribution "unresolved_mixed", the full harness_versions
#      list preserved on the run row) and is counted in no other bucket.
#   3. Unknown schema major (open-world rule): a summary whose
#      summary_schema_version is not major 1 is never aggregated — it is
#      listed under inputs.skipped as {summary_file, reason} with the reason
#      naming summary_schema_version, no bucket carries its version, it does
#      not count into inputs.summaries_found, and the exit stays 0
#      (reporting is not gating).
#   4. Malformed summary JSON: skipped-with-note, never a crash — same
#      inputs.skipped listing ({summary_file, reason}), exit stays 0.
#   4b. REAL producer token shape (Loop-2 review finding): trace-report.sh
#      emits tokens as {input_tokens, output_tokens, by_role, by_feature}
#      (see tok_buckets in scripts/trace-report.sh), NOT the plan-draft
#      {input, output}. A run carrying the real shape must sum into its
#      bucket under the scorecard's canonical {input, output} keys with the
#      REAL numbers — dropping the input_tokens/output_tokens fallback
#      fabricates {0, 0} zeros (mutation-proven: deleting the fallback from
#      a scratch copy of the script makes exactly this leg fail).
#   5. Zero summaries (conductor-resolved Open Question 2 = A): exit 0 with
#      an empty-but-valid scorecard (by_version [], summaries_found 0,
#      skipped []). Pinned here as a REGRESSION leg — scorecard-core may
#      already satisfy it.
#
# inputs.summaries_found therefore counts AGGREGATED summaries only; skipped
# files are visible in inputs.skipped, missing ones in inputs.missing_summaries.
#
# Exit codes: 0 honesty contract honored · 1 an obligation regressed
# (RED today on the skipped-with-note legs: inputs.skipped is hardcoded []
# and an unknown major is still aggregated).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCORECARD_SH="${ROOT}/scripts/trace-scorecard.sh"
SCORECARD_REL="tests/evals/scorecards/trace-scorecard.json"

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
note() {
  printf 'note: %s\n' "$*"
}

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

# --- Prerequisites -----------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the scorecard contract and this sensor are jq-driven)"
[ -f "$SCORECARD_SH" ] \
  || hard_fail "scripts/trace-scorecard.sh not found (${SCORECARD_SH}) — feature scorecard-core must land before its honesty semantics can be specified"
[ -x "$SCORECARD_SH" ] \
  || hard_fail "scripts/trace-scorecard.sh exists but is not executable (${SCORECARD_SH})"

# --- Fixture main root ---------------------------------------------------------
#   issue-20  version wX, tokens null            } same bucket: proves partial
#   issue-21  version wX, tokens {500, 50}       } coverage sums ONLY run 21
#   issue-22  version wY, tokens null            → all-null bucket: tokens null
#   issue-23  versions [wX, wY], NO trace        → "mixed" bucket, no guessing
#   issue-24  summary_schema_version 2           → skipped-with-note
#   issue-25  malformed JSON                     → skipped-with-note, no crash
#   issue-26  version wZ, REAL producer tokens   → bucket sums the real
#             {input_tokens, output_tokens, ...}   numbers, never zeros
FX_ROOT="${TMP_DIR}/fixture-root"
ISSUES_DIR="${FX_ROOT}/.copilot-tracking/issues"
mkdir -p "${ISSUES_DIR}/issue-20" "${ISSUES_DIR}/issue-21" \
  "${ISSUES_DIR}/issue-22" "${ISSUES_DIR}/issue-23" \
  "${ISSUES_DIR}/issue-24" "${ISSUES_DIR}/issue-25" "${ISSUES_DIR}/issue-26"

# write_summary <issue> <versions-json> <tokens-json> <schema-version>
write_summary() {
  local issue="$1" versions="$2" tokens="$3" schema="$4"
  cat > "${ISSUES_DIR}/issue-${issue}/trace-summary.json" <<EOF
{
  "summary_schema_version": ${schema},
  "trace_file": "${ISSUES_DIR}/issue-${issue}/trace.jsonl",
  "issue": ${issue},
  "harness_versions": ${versions},
  "finished": true,
  "final_outcome": "pass",
  "span_counts": {"total": 2, "invalid_lines": 0, "by_type": {"lifecycle": 2}},
  "wall_clock": {"first_timestamp": "2026-07-04T10:00:00Z", "last_timestamp": "2026-07-04T10:00:30Z", "elapsed_seconds": 30},
  "stages": [{"step": "preflight", "spans": 1, "duration_ms": null}],
  "tools": [{"name": "git", "calls": 1, "fail_calls": 0, "duration_ms": null}],
  "tokens": ${tokens},
  "loop_indicators": [],
  "red_reentry": [],
  "deviations": {"count": 0, "feature_ids": []}
}
EOF
}

write_summary 20 '["wX"]' 'null' 1
write_summary 21 '["wX"]' '{"input": 500, "output": 50}' 1
write_summary 22 '["wY"]' 'null' 1
write_summary 23 '["wX", "wY"]' 'null' 1   # multi-version, NO sibling trace
write_summary 24 '["vTWO"]' 'null' 2       # unknown major — must be skipped
printf '{ this is not JSON at all\n' > "${ISSUES_DIR}/issue-25/trace-summary.json"
# The REAL shape trace-report.sh emits (input_tokens/output_tokens + buckets),
# verbatim structure from its tok_buckets emission — not the plan draft.
write_summary 26 '["wZ"]' '{
    "input_tokens": 700,
    "output_tokens": 70,
    "by_role": {
      "conductor": {"input_tokens": 400, "output_tokens": 40},
      "unattributed": {"input_tokens": 300, "output_tokens": 30}
    },
    "by_feature": {
      "feat-z": {"input_tokens": 700, "output_tokens": 70}
    }
  }' 1

# --- Run: exit 0 despite skip-worthy inputs (reporting is not gating) ----------
rc=0
"$SCORECARD_SH" --root "$FX_ROOT" > "${TMP_DIR}/stdout.txt" 2> "${TMP_DIR}/stderr.txt" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "trace-scorecard.sh must exit 0 even with skipped/malformed inputs (never a crash), got exit ${rc}; stderr: $(cat "${TMP_DIR}/stderr.txt")"
fi
SCORECARD="${FX_ROOT}/${SCORECARD_REL}"
[ -f "$SCORECARD" ] \
  || hard_fail "scorecard not written to <root>/${SCORECARD_REL}"
jq empty "$SCORECARD" >/dev/null 2>&1 \
  || hard_fail "scorecard is not valid JSON (${SCORECARD})"

# --- 1a. Partial token coverage: sum ONLY the data-carrying runs ----------------
jq -e '
  (.by_version[] | select(.harness_version == "wX")) as $b
  | $b.runs == 2
  and ($b.token_coverage == {"runs_with_tokens": 1, "of": 2})
  and ($b.tokens.input == 500)
  and ($b.tokens.output == 50)
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "wX bucket wrong — 2 runs, token_coverage {runs_with_tokens 1, of 2}, totals exactly {500, 50} from the ONE data-carrying run (a tokens-null run must never dilute or zero the sums): $(jq -c '.by_version[] | select(.harness_version == "wX") | {runs, tokens, token_coverage}' "$SCORECARD" 2>/dev/null)"

# --- 1b. All-null bucket: tokens null, never fabricated zeros -------------------
jq -e '
  (.by_version[] | select(.harness_version == "wY")) as $b
  | $b.runs == 1
  and ($b.tokens == null)
  and ($b.token_coverage == {"runs_with_tokens": 0, "of": 1})
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "wY bucket wrong — no run carried tokens so tokens must be null (never {input 0, output 0}) with token_coverage {0, of 1}: $(jq -c '.by_version[] | select(.harness_version == "wY") | {runs, tokens, token_coverage}' "$SCORECARD" 2>/dev/null)"

# --- 1c. REAL producer token shape: real sums, never fabricated zeros -----------
# trace-report.sh emits {input_tokens, output_tokens, by_role, by_feature};
# the scorecard must normalize to canonical {input, output} with the REAL
# numbers. {input: 0, output: 0} here means the producer-key fallback was
# dropped and zeros were fabricated from present-but-differently-keyed data.
jq -e '
  (.by_version[] | select(.harness_version == "wZ")) as $b
  | $b.runs == 1
  and ($b.tokens.input == 700)
  and ($b.tokens.output == 70)
  and ($b.token_coverage == {"runs_with_tokens": 1, "of": 1})
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "wZ bucket wrong — a summary carrying the REAL trace-report.sh token shape {input_tokens 700, output_tokens 70, by_role, by_feature} must sum to tokens {input 700, output 70} with coverage {1, of 1}; zeros here are fabricated from data that exists under the producer's keys: $(jq -c '.by_version[] | select(.harness_version == "wZ") | {runs, tokens, token_coverage}' "$SCORECARD" 2>/dev/null)"

# --- 2. Mixed bucket: visible, honest, counted nowhere else ---------------------
jq -e '
  (.by_version[] | select(.harness_version == "mixed")) as $b
  | $b.runs == 1
  and ([$b.issues[].issue] == [23])
  and ($b.issues[0].attribution == "unresolved_mixed")
  and ($b.issues[0].harness_versions == ["wX", "wY"])
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "issue-23 (multi-version, no trace) must land in a visible 'mixed' bucket inside by_version with attribution unresolved_mixed and the full version list preserved on the row: $(jq -c '[.by_version[].harness_version]' "$SCORECARD" 2>/dev/null)"
jq -e '
  [.by_version[] | select(.harness_version != "mixed") | .issues[].issue]
  | index(23) == null
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "issue-23 leaked into a real version bucket — an unresolved-mixed run must be counted ONLY in the mixed bucket (no guessing, plan D1 case 3)"

# --- 3. Unknown schema major: skipped-with-note, never aggregated ---------------
jq -e '
  [.inputs.skipped[] | select(.summary_file | contains("issue-24"))] as $s
  | ($s | length) == 1
  and ($s[0].reason | contains("summary_schema_version"))
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "issue-24 (summary_schema_version 2) must appear in inputs.skipped as {summary_file, reason} with the reason naming summary_schema_version (open-world rule: consumers reject unknown majors): $(jq -c '.inputs.skipped' "$SCORECARD" 2>/dev/null)"
jq -e '[.by_version[].harness_version] | index("vTWO") == null' "$SCORECARD" >/dev/null 2>&1 \
  || fail "the unknown-major summary was AGGREGATED (a vTWO bucket exists) — a major-2 summary must be skipped untouched, never interpreted under the v1 contract"
jq -e '
  [.by_version[].issues[].issue] | index(24) == null
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "issue-24 appears in a by_version bucket — skipped summaries must contribute to no aggregate"

# --- 4. Malformed summary JSON: skipped-with-note, not a crash ------------------
jq -e '
  [.inputs.skipped[] | select(.summary_file | contains("issue-25"))] as $s
  | ($s | length) == 1
  and ($s[0].reason | type == "string")
  and (($s[0].reason | length) > 0)
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "issue-25 (malformed JSON) must appear in inputs.skipped as {summary_file, reason} with a non-empty reason — unreadable input is reported, never silently dropped: $(jq -c '.inputs.skipped' "$SCORECARD" 2>/dev/null)"

# --- summaries_found counts AGGREGATED summaries only ---------------------------
jq -e '.inputs.summaries_found == 5' "$SCORECARD" >/dev/null 2>&1 \
  || fail "inputs.summaries_found must be 5 (issues 20-23 and 26 aggregated; 24 and 25 are skipped, not found-and-counted): $(jq -c '.inputs.summaries_found' "$SCORECARD" 2>/dev/null)"
jq -e '([.by_version[].runs] | add) == 5' "$SCORECARD" >/dev/null 2>&1 \
  || fail "bucket runs must sum to 5 — every aggregated run in exactly one bucket, skipped files in none: $(jq -c '[.by_version[] | {harness_version, runs}]' "$SCORECARD" 2>/dev/null)"

# --- 5. Regression pin: zero summaries → empty-but-valid, exit 0 ----------------
EMPTY_ROOT="${TMP_DIR}/empty-root"
mkdir -p "${EMPTY_ROOT}/.copilot-tracking/issues"
rc=0
"$SCORECARD_SH" --root "$EMPTY_ROOT" > /dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "zero summaries must exit 0 with an empty-but-valid scorecard (conductor-resolved), got exit ${rc}"
else
  jq -e '
    .scorecard_schema_version == 1
    and (.by_version == [])
    and (.inputs.summaries_found == 0)
    and (.inputs.skipped == [])
  ' "${EMPTY_ROOT}/${SCORECARD_REL}" >/dev/null 2>&1 \
    || fail "empty scorecard must be valid v1 with by_version [], summaries_found 0, skipped []: $(jq -c '{scorecard_schema_version, by_version, inputs}' "${EMPTY_ROOT}/${SCORECARD_REL}" 2>/dev/null)"
  note "zero-summaries leg green (regression pin)"
fi

# --- Verdict --------------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  printf 'test_trace_scorecard_honesty: %d failure(s)\n' "$fails" >&2
  exit 1
fi
echo "test_trace_scorecard_honesty: PASS"
