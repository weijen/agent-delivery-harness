#!/usr/bin/env bash
# test_trace_report_loops.sh — regression sensor for the deterministic
# loop/retry indicators (issue #98, feature trace-report-loop-indicators,
# plan Phase 3).
#
# Executable spec for the retry/loop half of `scripts/trace-report.sh`.
# Deterministic-only doctrine (plan D4, cost-efficiency-evals.md): without
# purpose tags, only exact-identity counters are allowed. Pinned here:
#
#   1. REPEATED-IDENTICAL-SPAN identity (pinned precisely; loop-2 conductor
#      decision on the issue-96 review finding):
#      the full span object MINUS the volatile fields
#          span_id, parent_span_id, timestamp, harness.duration_ms,
#          harness.version
#      — harness.version is EXCLUDED from identity: loop detection is
#      within-run thrash, version comparison is #104's cross-run job, and a
#      harness upgrade mid-burst must neither split the burst nor produce
#      duplicate signatures. Everything else (including harness.feature_id)
#      participates, so a RED-re-entry feature's routine handbacks never
#      masquerade as a burst.
#      Groups with count >= 3 are reported (conductor-resolved threshold;
#      issue-96's legitimate double review-gate.check must stay quiet, and
#      a count of exactly 3 must flag — >= not >).
#      Display signature = "/"-joined:  span, (gen_ai.tool.name or
#      harness.lifecycle_step), harness.outcome (when present),
#      harness.stage (when present) — e.g.
#          lifecycle/pr_merge/fail/ci_checks     (the real issue-96 burst)
#          tool/check-feature-list/pass
#   2. Summary JSON (trace-summary.json beside the trace) carries, top-level:
#        * loop_indicators: array of {signature, count} for every >=3 group;
#        * red_reentry: array of harness.feature_id values that saw a
#          red_handback AFTER an earlier green_handback (file order),
#          counting harness.lifecycle_step across ALL span types;
#        * deviations: {count, feature_ids} counting
#          harness.lifecycle_step == "deviation" across ALL span types
#          (issue-97 precedent: deviations ride on agent spans too).
#   3. Markdown gets a "Loop indicators" section (header line contains
#      'loop indicators', any case) listing each signature with its count,
#      the red re-entry features, and the deviation count.
#   4. Quiet is empty, not null (plan D5): a clean trace reports
#      loop_indicators == [], red_reentry == [], deviations.count == 0 with
#      feature_ids == [] — the detectors RAN and found nothing — and the
#      markdown section says 'none'. Exit 0 both ways (reporting never
#      gates, plan D7).
#
# Exit codes: 0 loop-indicator contract honored · 1 a contract obligation
# regressed (RED today: the detectors do not exist).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_SH="${ROOT}/scripts/trace-report.sh"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the detectors and this sensor are jq-driven)"
[ -f "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh not found (${REPORT_SH}) — feature trace-report-core must land before its loop indicators can be specified"
[ -x "$REPORT_SH" ] \
  || hard_fail "scripts/trace-report.sh exists but is not executable (${REPORT_SH})"

OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_report() {
  local rc=0
  (
    cd "$TMP_DIR" || exit 9
    exec "$@"
  ) >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# common-fields shorthand for fixture lines
C='"schema_version":1,"harness.issue":98,"harness.version":"fix1234"'

# --- Loopy fixture: modeled on the real issue-96 pr_merge fail burst -------------
# Expected detections (and ONLY these):
#   loop_indicators (sorted by signature):
#     lifecycle/pr_merge/fail/ci_checks  count 5   (burst; spans differ ONLY
#                                                   in span_id/timestamp/
#                                                   duration_ms — volatile
#                                                   fields excluded from
#                                                   identity)
#     tool/check-feature-list/pass       count 3   (exactly the threshold —
#                                                   >= 3 flags)
#   NOT flagged:
#     review-gate.check pass x2                    (below threshold — the
#                                                   issue-96 legitimate double)
#     pr_merge PASS ci_checks x1                   (outcome differs → not in
#                                                   the fail group; count
#                                                   stays 5, not 6)
#     red_handback agent spans                     (feature_id participates in
#                                                   identity: loopy-feat x2 +
#                                                   steady-feat x1 never merge
#                                                   into a >=3 group)
#   red_reentry == ["loopy-feat"]  (red AFTER green; steady-feat's plain
#                                   red→green must NOT appear)
#   deviations.count == 2, feature_ids ["dev-feat-a","dev-feat-b"]
#                                  (one lifecycle span, one AGENT span)
LOOPY_DIR="${TMP_DIR}/loopy"
mkdir -p "$LOOPY_DIR"
LOOPY="${LOOPY_DIR}/trace.jsonl"
{
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:00:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"preflight\",\"harness.duration_ms\":100}"
  # the burst: 5 identical pr_merge fails, volatile fields varying
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:01:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"fail\",\"harness.stage\":\"ci_checks\",\"span_id\":\"s1\",\"harness.duration_ms\":901}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:02:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"fail\",\"harness.stage\":\"ci_checks\",\"span_id\":\"s2\",\"harness.duration_ms\":902}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:03:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"fail\",\"harness.stage\":\"ci_checks\",\"span_id\":\"s3\",\"harness.duration_ms\":903}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:04:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"fail\",\"harness.stage\":\"ci_checks\",\"span_id\":\"s4\",\"harness.duration_ms\":904}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:05:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"fail\",\"harness.stage\":\"ci_checks\",\"span_id\":\"s5\",\"harness.duration_ms\":905}"
  # outcome differs → its own group of 1, never merged into the burst
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:06:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"pass\",\"harness.stage\":\"ci_checks\",\"harness.duration_ms\":800}"
  # exactly-at-threshold tool group (3 identical check-feature-list passes)
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:07:00Z\",\"span\":\"tool\",\"gen_ai.tool.name\":\"check-feature-list\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":10}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:08:00Z\",\"span\":\"tool\",\"gen_ai.tool.name\":\"check-feature-list\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":11}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:09:00Z\",\"span\":\"tool\",\"gen_ai.tool.name\":\"check-feature-list\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":12}"
  # below-threshold legitimate double (issue-96 review-gate.check precedent)
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:10:00Z\",\"span\":\"tool\",\"gen_ai.tool.name\":\"review-gate.check\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":20}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:11:00Z\",\"span\":\"tool\",\"gen_ai.tool.name\":\"review-gate.check\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":21}"
  # loopy-feat: red → green → RED AGAIN → green (re-entry)
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:12:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"red_handback\",\"harness.feature_id\":\"loopy-feat\",\"harness.outcome\":\"pass\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:13:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"green_handback\",\"harness.feature_id\":\"loopy-feat\",\"harness.outcome\":\"pass\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:14:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"red_handback\",\"harness.feature_id\":\"loopy-feat\",\"harness.outcome\":\"pass\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:15:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"green_handback\",\"harness.feature_id\":\"loopy-feat\",\"harness.outcome\":\"pass\"}"
  # steady-feat: plain red → green (must NOT be re-entry)
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:16:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"red_handback\",\"harness.feature_id\":\"steady-feat\",\"harness.outcome\":\"pass\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:17:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"green_handback\",\"harness.feature_id\":\"steady-feat\",\"harness.outcome\":\"pass\"}"
  # deviations across span types: one lifecycle, one agent
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:18:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"deviation\",\"harness.feature_id\":\"dev-feat-a\",\"harness.duration_ms\":5}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:19:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"conductor\",\"harness.lifecycle_step\":\"deviation\",\"harness.feature_id\":\"dev-feat-b\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T12:20:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":50}"
} > "$LOOPY"
LOOPY_SUMMARY="${LOOPY_DIR}/trace-summary.json"

rc="$(run_report "$REPORT_SH" "$LOOPY")"
[ "$rc" = "0" ] \
  || fail "loopy fixture: expected exit 0 (loops never gate — plan D7), got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"

# Markdown pins (section + contents)
grep -Eiq '^#+ .*loop indicators' "$OUT" \
  || fail "loopy markdown: report must carry a 'Loop indicators' section header"
grep -Eq 'lifecycle/pr_merge/fail/ci_checks' "$OUT" \
  || fail "loopy markdown: the burst signature lifecycle/pr_merge/fail/ci_checks must be listed"
grep -E 'lifecycle/pr_merge/fail/ci_checks' "$OUT" | grep -Eq '(^|[^0-9])5([^0-9]|$)' \
  || fail "loopy markdown: the burst line must carry its count 5"
grep -Eiq 're.?entry' "$OUT" \
  || fail "loopy markdown: RED re-entry must be reported"
grep -Ei 're.?entry' "$OUT" | grep -Fq 'loopy-feat' \
  || fail "loopy markdown: loopy-feat must be listed as the re-entering feature"
if grep -Ei 're.?entry' "$OUT" | grep -Fq 'steady-feat'; then
  fail "loopy markdown: steady-feat went red->green once and must NOT be flagged as re-entry"
fi
# The stage table already shows a 'deviation' row; the ROLLUP is only proven
# by the feature ids, which no stage/tool table ever prints.
if ! { grep -Fq 'dev-feat-a' "$OUT" && grep -Fq 'dev-feat-b' "$OUT"; }; then
  fail "loopy markdown: the deviation rollup must list the deviating feature ids (dev-feat-a, dev-feat-b) across span types"
fi

# Summary JSON pins (top-level loop_indicators / red_reentry / deviations)
if [ ! -f "$LOOPY_SUMMARY" ]; then
  fail "loopy fixture: trace-summary.json not written beside the trace (${LOOPY_SUMMARY}) — the detectors have nowhere to land yet"
else
  jq -e '
    (.loop_indicators | sort_by(.signature)) ==
      [ {signature: "lifecycle/pr_merge/fail/ci_checks", count: 5},
        {signature: "tool/check-feature-list/pass",      count: 3} ]
  ' "$LOOPY_SUMMARY" >/dev/null 2>&1 \
    || fail "loopy JSON: loop_indicators must be EXACTLY the >=3 groups [{lifecycle/pr_merge/fail/ci_checks,5},{tool/check-feature-list/pass,3}] — no review-gate.check double, no pass-outcome merge, no handback groups (got: $(jq -c '.loop_indicators' "$LOOPY_SUMMARY" 2>/dev/null))"
  jq -e '.red_reentry == ["loopy-feat"]' "$LOOPY_SUMMARY" >/dev/null 2>&1 \
    || fail "loopy JSON: red_reentry must be exactly [\"loopy-feat\"] (got: $(jq -c '.red_reentry' "$LOOPY_SUMMARY" 2>/dev/null))"
  jq -e '.deviations.count == 2 and (.deviations.feature_ids | sort) == ["dev-feat-a","dev-feat-b"]' \
    "$LOOPY_SUMMARY" >/dev/null 2>&1 \
    || fail "loopy JSON: deviations must roll up across span types — count 2, feature_ids [dev-feat-a, dev-feat-b] (got: $(jq -c '.deviations' "$LOOPY_SUMMARY" 2>/dev/null))"
fi

# --- Version-split fixture: the reviewer's issue-96 reproduction -------------------
# 6 spans identical except the volatile fields, split 3+3 across TWO
# harness.version values (a harness upgrade mid-burst — the real issue-96
# dogfood shape). With harness.version excluded from identity this is ONE
# group of 6: the burst is not fragmented by the upgrade and no duplicate
# signature rows appear.
VSPLIT_DIR="${TMP_DIR}/version-split"
mkdir -p "$VSPLIT_DIR"
VSPLIT="${VSPLIT_DIR}/trace.jsonl"
{
  n=0
  for ver in verOLD verOLD verOLD verNEW verNEW verNEW; do
    n=$((n + 1))
    printf '%s\n' "{\"schema_version\":1,\"harness.issue\":98,\"harness.version\":\"${ver}\",\"timestamp\":\"2026-07-04T14:0${n}:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"pr_merge\",\"harness.outcome\":\"fail\",\"harness.stage\":\"ci_checks\",\"span_id\":\"v${n}\",\"harness.duration_ms\":$((900 + n))}"
  done
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T14:10:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":50}"
} > "$VSPLIT"
VSPLIT_SUMMARY="${VSPLIT_DIR}/trace-summary.json"

# Fixture self-check: both versions really are on disk (guards the pin
# against a copy-paste collapse to one version, which would pass vacuously).
jq -s '[.[]["harness.version"]] | unique == ["fix1234","verNEW","verOLD"]' "$VSPLIT" \
  | grep -q true \
  || hard_fail "version-split fixture must carry two burst versions (verOLD/verNEW) plus the finish span's fix1234"

rc="$(run_report "$REPORT_SH" "$VSPLIT")"
[ "$rc" = "0" ] \
  || fail "version-split fixture: expected exit 0, got ${rc} (stderr: $(tr '\n' '|' < "$ERR"))"
if [ ! -f "$VSPLIT_SUMMARY" ]; then
  fail "version-split fixture: trace-summary.json not written beside the trace (${VSPLIT_SUMMARY})"
else
  jq -e '
    .loop_indicators ==
      [ {signature: "lifecycle/pr_merge/fail/ci_checks", count: 6} ]
  ' "$VSPLIT_SUMMARY" >/dev/null 2>&1 \
    || fail "version-split JSON: a mid-burst harness upgrade must NOT split the group — expected exactly [{lifecycle/pr_merge/fail/ci_checks, 6}], one entry, no duplicate signatures (harness.version is excluded from identity; got: $(jq -c '.loop_indicators' "$VSPLIT_SUMMARY" 2>/dev/null))"
fi
grep -E 'lifecycle/pr_merge/fail/ci_checks' "$OUT" | grep -Eq '(^|[^0-9])6([^0-9]|$)' \
  || fail "version-split markdown: the merged burst must be listed with count 6"
[ "$(grep -cE 'lifecycle/pr_merge/fail/ci_checks' "$OUT")" = "1" ] \
  || fail "version-split markdown: the signature must appear exactly once (no duplicate-signature rows)"

# --- Clean fixture: detectors ran and found NOTHING (empty, not null) -------------
CLEAN_DIR="${TMP_DIR}/clean"
mkdir -p "$CLEAN_DIR"
CLEAN="${CLEAN_DIR}/trace.jsonl"
{
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T13:00:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"preflight\",\"harness.duration_ms\":90}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T13:01:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"red_handback\",\"harness.feature_id\":\"only-feat\",\"harness.outcome\":\"pass\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T13:02:00Z\",\"span\":\"agent\",\"gen_ai.operation.name\":\"invoke_agent\",\"gen_ai.agent.name\":\"test-subagent\",\"harness.lifecycle_step\":\"green_handback\",\"harness.feature_id\":\"only-feat\",\"harness.outcome\":\"pass\"}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T13:03:00Z\",\"span\":\"tool\",\"gen_ai.tool.name\":\"review-gate.check\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":15}"
  printf '%s\n' "{${C},\"timestamp\":\"2026-07-04T13:04:00Z\",\"span\":\"lifecycle\",\"harness.lifecycle_step\":\"finish\",\"harness.outcome\":\"pass\",\"harness.duration_ms\":40}"
} > "$CLEAN"
CLEAN_SUMMARY="${CLEAN_DIR}/trace-summary.json"

rc="$(run_report "$REPORT_SH" "$CLEAN")"
[ "$rc" = "0" ] \
  || fail "clean fixture: expected exit 0, got ${rc}"
grep -Eiq '^#+ .*loop indicators' "$OUT" \
  || fail "clean markdown: the Loop indicators section must still render (quiet, not absent)"
grep -Eiq 'none' "$OUT" \
  || fail "clean markdown: a quiet run must say 'none' in the loop indicators section"
if [ ! -f "$CLEAN_SUMMARY" ]; then
  fail "clean fixture: trace-summary.json not written beside the trace (${CLEAN_SUMMARY})"
else
  jq -e '.loop_indicators == []' "$CLEAN_SUMMARY" >/dev/null 2>&1 \
    || fail "clean JSON: loop_indicators must be [] — empty means the detector ran and found nothing; null would mean it never ran (plan D5)"
  jq -e '.red_reentry == []' "$CLEAN_SUMMARY" >/dev/null 2>&1 \
    || fail "clean JSON: red_reentry must be []"
  jq -e '.deviations.count == 0 and .deviations.feature_ids == []' \
    "$CLEAN_SUMMARY" >/dev/null 2>&1 \
    || fail "clean JSON: deviations must be a measured zero — count 0, feature_ids []"
fi

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d loop-indicator contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-report loop-indicator contract honored\n'
