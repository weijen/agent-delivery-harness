#!/usr/bin/env bash
# test_trace_scorecard_core.sh — regression sensor for the cross-run trace
# scorecard aggregator (issue #104, feature scorecard-core, plan Phase 1).
#
# Executable spec for the future `scripts/trace-scorecard.sh` (this sensor IS
# the spec — plan D1/D2/D5 + conductor-resolved decisions). Pinned
# conventions:
#
#   1. CLI: no args → operates on the current repo's main root; optional
#      `--root <dir>` treats <dir> as the main root instead (fixture seam:
#      summaries are read from <root>/.copilot-tracking/issues/issue-*/ and
#      the scorecard is written to
#      <root>/tests/evals/scorecards/trace-scorecard.json). This sensor only
#      exercises --root — the no-arg path depends on machine-specific,
#      gitignored dogfood material and is pinned by its shared main-root
#      resolution (issue-lib), not here.
#   2. Output file: STABLE filename trace-scorecard.json (conductor-resolved
#      Open Question 1 = A): idempotent overwrite, never append, never
#      timestamped names. A second run over unchanged inputs produces a
#      BYTE-IDENTICAL file (cmp) — therefore no generation timestamp lives
#      inside the document (no top-level generated_at; input-derived
#      timestamps such as a summary's wall_clock are fine because they are
#      deterministic).
#   3. Scorecard shape (v1 draft, plan "Scorecard schema draft"):
#        * scorecard_schema_version == 1 and is a JSON NUMBER;
#        * inputs.summaries_found counts the v1 summaries aggregated;
#          each aggregated run row carries its summary_file provenance
#          (generated-from list);
#        * by_version: one bucket per attributed harness_version carrying
#          runs, issues[] rows, finished / passed counts,
#          red_reentry_free_rate {free, of}, deviations {count, feature_ids},
#          tool_calls {calls, fail_calls}, tokens (object of summed
#          input/output or null when NO run in the bucket carried token
#          data — absence is null, never 0), and
#          token_coverage {runs_with_tokens, of};
#        * inputs.missing_summaries: dirs with a trace.jsonl but NO
#          trace-summary.json, each entry naming the issue dir and a
#          regeneration hint that names trace-report.sh (report, never
#          repair — plan D4).
#   4. Version attribution (plan D1 — the heart of #104):
#        * single-element harness_versions → that version,
#          attribution "single" (fixture issue-10 → bucket vA);
#        * multi-element harness_versions + readable sibling trace.jsonl →
#          the LAST span in the trace carrying a "harness.version" key wins,
#          attribution "last_seen_in_trace" (fixture issue-11 → bucket vB).
#          The fixture is constructed so sort-order-last ≠ trace-last:
#          harness_versions is the sorted pair ["vB","vZ"] (sort-order-last
#          = vZ) while the last version-carrying trace span says vB, and a
#          trailing version-LESS span follows it — proving attribution is
#          the trace peek (last version-CARRYING span), never the summary's
#          sort order (meaningless for git SHAs) and never simply the last
#          line. No vZ bucket may exist.
#   5. Zero summaries found (conductor-resolved Open Question 2 = A):
#      exit 0 with an empty-but-valid scorecard (by_version [],
#      summaries_found 0) — reporting is not gating.
#   6. Exit codes: 0 scorecard produced · 2 usage/environment error
#      (e.g. --root pointing at a missing directory) · never 1.
#   7. Git hygiene: generated scorecards are local-only (l0-l1 spec:
#      "Generated scorecards are local artifacts and should not be
#      committed"). Pinned via git check-ignore against the REAL repo:
#      tests/evals/scorecards/trace-scorecard.json is ignored, while a
#      tracked keeper (tests/evals/scorecards/.gitkeep or the dir's own
#      .gitignore) exists and is itself NOT ignored, so the directory stays
#      present in checkouts. (Read-only git: check-ignore only.)
#
# Exit codes: 0 scorecard-core contract honored · 1 a contract obligation
# regressed (RED today: scripts/trace-scorecard.sh does not exist).

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

# --- 7. Git hygiene: scorecards are local-only, dir stays present -------------
# check-ignore works on paths that do not exist yet; read-only git only.
if git -C "$ROOT" check-ignore -q -- "$SCORECARD_REL"; then
  note "generated scorecard is gitignored (${SCORECARD_REL})"
else
  fail "git check-ignore says ${SCORECARD_REL} would be TRACKED — generated scorecards must never be committed (l0-l1 spec); add the ignore rule pair for tests/evals/scorecards/"
fi
keeper=""
if [ -f "${ROOT}/tests/evals/scorecards/.gitkeep" ]; then
  keeper="tests/evals/scorecards/.gitkeep"
elif [ -f "${ROOT}/tests/evals/scorecards/.gitignore" ]; then
  keeper="tests/evals/scorecards/.gitignore"
fi
if [ -z "$keeper" ]; then
  fail "no keeper file found — tests/evals/scorecards/ needs a .gitkeep (or its own .gitignore) so the directory stays present in checkouts"
else
  if git -C "$ROOT" check-ignore -q -- "$keeper"; then
    fail "keeper ${keeper} is itself gitignored — the un-ignore rule (e.g. !${keeper}) is missing, so the directory would vanish from checkouts"
  else
    note "keeper ${keeper} present and not ignored"
  fi
fi

# --- RED gate: the aggregator must exist -------------------------------------
[ -f "$SCORECARD_SH" ] \
  || hard_fail "scripts/trace-scorecard.sh not found (${SCORECARD_SH}) — feature scorecard-core (issue #104 Phase 1) must implement the cross-run aggregator (RED: failing for the right reason)"
[ -x "$SCORECARD_SH" ] \
  || hard_fail "scripts/trace-scorecard.sh exists but is not executable (${SCORECARD_SH})"

# --- Fixture main root ---------------------------------------------------------
# Three issue dirs under <root>/.copilot-tracking/issues/:
#   issue-10  summary only, single harness_version vA          → bucket vA
#   issue-11  summary ["vB","vZ"] + trace whose last version-  → bucket vB
#             carrying span is vB (sort-order-last is vZ)
#   issue-12  trace.jsonl only, NO summary                     → missing_summaries
FX_ROOT="${TMP_DIR}/fixture-root"
ISSUES_DIR="${FX_ROOT}/.copilot-tracking/issues"
mkdir -p "${ISSUES_DIR}/issue-10" "${ISSUES_DIR}/issue-11" "${ISSUES_DIR}/issue-12"

cat > "${ISSUES_DIR}/issue-10/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-10/trace.jsonl",
  "issue": 10,
  "harness_versions": ["vA"],
  "finished": true,
  "final_outcome": "pass",
  "span_counts": {"total": 8, "invalid_lines": 0, "by_type": {"lifecycle": 4, "tool": 4}},
  "wall_clock": {"first_timestamp": "2026-07-04T10:00:00Z", "last_timestamp": "2026-07-04T10:01:40Z", "elapsed_seconds": 100},
  "stages": [{"step": "preflight", "spans": 1, "duration_ms": 50}],
  "tools": [
    {"name": "git", "calls": 3, "fail_calls": 1, "duration_ms": 15},
    {"name": "jq", "calls": 2, "fail_calls": 0, "duration_ms": null}
  ],
  "tokens": null,
  "loop_indicators": [],
  "red_reentry": [],
  "deviations": {"count": 2, "feature_ids": ["feat-a", "feat-b"]}
}
EOF

cat > "${ISSUES_DIR}/issue-11/trace-summary.json" <<EOF
{
  "summary_schema_version": 1,
  "trace_file": "${ISSUES_DIR}/issue-11/trace.jsonl",
  "issue": 11,
  "harness_versions": ["vB", "vZ"],
  "finished": true,
  "final_outcome": "pass",
  "span_counts": {"total": 3, "invalid_lines": 0, "by_type": {"lifecycle": 2, "tool": 1}},
  "wall_clock": {"first_timestamp": "2026-07-04T09:00:00Z", "last_timestamp": "2026-07-04T09:20:00Z", "elapsed_seconds": 1200},
  "stages": [{"step": "preflight", "spans": 1, "duration_ms": null}],
  "tools": [
    {"name": "git", "calls": 4, "fail_calls": 0, "duration_ms": 20}
  ],
  "tokens": {"input": 1000, "output": 200},
  "loop_indicators": [],
  "red_reentry": ["feat-c"],
  "deviations": {"count": 0, "feature_ids": []}
}
EOF

# Trace order proves the peek: vZ first, vB on the LAST version-carrying span,
# then a trailing span with NO harness.version at all.
write_issue11_trace() {
  local f="${ISSUES_DIR}/issue-11/trace.jsonl"
  : > "$f"
  local ln
  for ln in \
    '{"schema_version":1,"timestamp":"2026-07-04T09:00:00Z","span":"lifecycle","harness.issue":11,"harness.version":"vZ","harness.lifecycle_step":"preflight"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T09:10:00Z","span":"tool","harness.issue":11,"harness.version":"vB","gen_ai.tool.name":"git","harness.outcome":"pass"}' \
    '{"schema_version":1,"timestamp":"2026-07-04T09:20:00Z","span":"lifecycle","harness.issue":11,"harness.lifecycle_step":"finish","harness.outcome":"pass"}'; do
    printf '%s\n' "$ln" >> "$f"
  done
}
write_issue11_trace

printf '%s\n' \
  '{"schema_version":1,"timestamp":"2026-07-04T08:00:00Z","span":"lifecycle","harness.issue":12,"harness.version":"vA","harness.lifecycle_step":"preflight"}' \
  > "${ISSUES_DIR}/issue-12/trace.jsonl"

# --- Run 1: exit 0, scorecard produced at the stable path ----------------------
rc=0
"$SCORECARD_SH" --root "$FX_ROOT" > "${TMP_DIR}/stdout1.txt" 2> "${TMP_DIR}/stderr1.txt" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "trace-scorecard.sh --root <fixture> exited ${rc}, want 0 (reporting is not gating); stderr: $(cat "${TMP_DIR}/stderr1.txt")"
fi

SCORECARD="${FX_ROOT}/${SCORECARD_REL}"
if [ ! -f "$SCORECARD" ]; then
  hard_fail "scorecard not written to the stable path <root>/${SCORECARD_REL} (conductor-resolved: single stable filename, idempotent overwrite)"
fi
jq empty "$SCORECARD" >/dev/null 2>&1 \
  || hard_fail "scorecard is not valid JSON (${SCORECARD})"

# --- 3a. Versioned envelope + generated-from inputs ----------------------------
jq -e '.scorecard_schema_version == 1 and (.scorecard_schema_version | type == "number")' \
  "$SCORECARD" >/dev/null 2>&1 \
  || fail "scorecard must declare scorecard_schema_version 1 as a JSON number"
jq -e '.inputs.summaries_found == 2' "$SCORECARD" >/dev/null 2>&1 \
  || fail "inputs.summaries_found must be 2 (issue-10 + issue-11 summaries aggregated)"
jq -e 'has("generated_at") | not' "$SCORECARD" >/dev/null 2>&1 \
  || fail "scorecard must NOT carry a top-level generated_at — no timestamps inside (byte-identical idempotency doctrine)"

# --- 3b/4. by_version buckets + attribution ------------------------------------
jq -e '([.by_version[].harness_version] | sort) == ["vA", "vB"]' "$SCORECARD" >/dev/null 2>&1 \
  || fail "by_version buckets must be exactly [vA, vB]: issue-10 → vA (single), issue-11 → vB (trace peek); a vZ bucket would mean sort-order attribution ($(jq -c '[.by_version[].harness_version]' "$SCORECARD" 2>/dev/null))"

# vA bucket (issue-10, attribution "single")
jq -e '
  (.by_version[] | select(.harness_version == "vA")) as $b
  | $b.runs == 1
  and ([$b.issues[].issue] == [10])
  and ($b.issues[0].summary_file | endswith("issue-10/trace-summary.json"))
  and ($b.issues[0].attribution == "single")
  and ($b.finished == 1)
  and ($b.passed == 1)
  and ($b.red_reentry_free_rate == {"free": 1, "of": 1})
  and ($b.deviations.count == 2)
  and (($b.deviations.feature_ids | sort) == ["feat-a", "feat-b"])
  and ($b.tool_calls == {"calls": 5, "fail_calls": 1})
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "vA bucket wrong — want runs 1, issues [10] (attribution single, summary_file provenance), finished 1, passed 1, red_reentry_free_rate 1/1, deviations {2, [feat-a feat-b]}, tool_calls {5, 1}: $(jq -c '.by_version[] | select(.harness_version == "vA")' "$SCORECARD" 2>/dev/null)"

# vA token honesty: no run carried tokens → null, never 0 (coverage says why)
jq -e '
  (.by_version[] | select(.harness_version == "vA")) as $b
  | ($b.tokens == null)
  and ($b.token_coverage == {"runs_with_tokens": 0, "of": 1})
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "vA bucket tokens must be null with token_coverage {runs_with_tokens 0, of 1} — absence is null, never a fabricated 0"

# vB bucket (issue-11, attribution "last_seen_in_trace" — the trace-peek proof)
jq -e '
  (.by_version[] | select(.harness_version == "vB")) as $b
  | $b.runs == 1
  and ([$b.issues[].issue] == [11])
  and ($b.issues[0].summary_file | endswith("issue-11/trace-summary.json"))
  and ($b.issues[0].attribution == "last_seen_in_trace")
  and ($b.finished == 1)
  and ($b.passed == 1)
  and ($b.red_reentry_free_rate == {"free": 0, "of": 1})
  and ($b.deviations.count == 0)
  and ($b.tool_calls == {"calls": 4, "fail_calls": 0})
  and ($b.tokens.input == 1000)
  and ($b.tokens.output == 200)
  and ($b.token_coverage == {"runs_with_tokens": 1, "of": 1})
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "vB bucket wrong — issue-11 must be attributed to vB via the LAST version-carrying trace span (attribution last_seen_in_trace), with red_reentry_free_rate 0/1 (feat-c re-entered red), tool_calls {4, 0}, tokens {1000, 200}, coverage 1/1: $(jq -c '.by_version[] | select(.harness_version == "vB")' "$SCORECARD" 2>/dev/null)"

# --- 3c. missing_summaries: reported, never repaired ---------------------------
jq -e '
  (.inputs.missing_summaries | length) == 1
  and (.inputs.missing_summaries[0] | tostring | contains("issue-12"))
  and (.inputs.missing_summaries[0].hint | contains("trace-report.sh"))
' "$SCORECARD" >/dev/null 2>&1 \
  || fail "inputs.missing_summaries must list exactly issue-12 (trace without summary) with a regeneration hint naming trace-report.sh: $(jq -c '.inputs.missing_summaries' "$SCORECARD" 2>/dev/null)"
if [ -f "${ISSUES_DIR}/issue-12/trace-summary.json" ]; then
  fail "the aggregator regenerated issue-12/trace-summary.json — reporting must never repair (plan D4, single responsibility with trace-report.sh)"
fi

# --- 2. Idempotent overwrite: second run is byte-identical ----------------------
cp "$SCORECARD" "${TMP_DIR}/scorecard-run1.json"
rc=0
"$SCORECARD_SH" --root "$FX_ROOT" > /dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "second run exited ${rc}, want 0"
fi
if cmp -s "${TMP_DIR}/scorecard-run1.json" "$SCORECARD"; then
  note "second run byte-identical (idempotent overwrite, no timestamps)"
else
  fail "second run over unchanged inputs did not produce a byte-identical scorecard — overwrite must be idempotent and the document must carry no generation timestamp"
fi
doc_count="$(jq -s 'length' "$SCORECARD" 2>/dev/null)"
if [ "$doc_count" != "1" ]; then
  fail "scorecard file holds ${doc_count:-0} JSON documents after two runs, want exactly 1 (overwrite, never append)"
fi

# --- 5. Zero summaries: exit 0, empty-but-valid scorecard -----------------------
EMPTY_ROOT="${TMP_DIR}/empty-root"
mkdir -p "${EMPTY_ROOT}/.copilot-tracking/issues"
rc=0
"$SCORECARD_SH" --root "$EMPTY_ROOT" > /dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "zero summaries found must still exit 0 with an empty-but-valid scorecard (conductor-resolved: reporting is not gating), got exit ${rc}"
fi
EMPTY_SCORECARD="${EMPTY_ROOT}/${SCORECARD_REL}"
if [ ! -f "$EMPTY_SCORECARD" ]; then
  fail "zero-summaries run must still write ${SCORECARD_REL} (empty-but-valid)"
else
  jq -e '
    .scorecard_schema_version == 1
    and (.by_version == [])
    and (.inputs.summaries_found == 0)
  ' "$EMPTY_SCORECARD" >/dev/null 2>&1 \
    || fail "empty scorecard must still be valid v1 with by_version [] and summaries_found 0: $(jq -c '{scorecard_schema_version, by_version, inputs}' "$EMPTY_SCORECARD" 2>/dev/null)"
fi

# --- 6. Missing --root dir is an environment error: exit 2, never 1 ------------
rc=0
"$SCORECARD_SH" --root "${TMP_DIR}/no-such-root" > /dev/null 2>&1 || rc=$?
if [ "$rc" -ne 2 ]; then
  fail "--root pointing at a missing directory must exit 2 (usage/environment error, never 1), got exit ${rc}"
fi

# --- Verdict --------------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  printf 'test_trace_scorecard_core: %d failure(s)\n' "$fails" >&2
  exit 1
fi
echo "test_trace_scorecard_core: PASS"
