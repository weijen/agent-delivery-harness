#!/usr/bin/env bash
# test_trace_consistency_reviewer_instruction_files.sh — regression sensor for
# the reviewer-instruction-files provenance detector (issue #299, feature
# reviewer-instruction-files-warn) of `scripts/check-trace-consistency.sh
# <issue-number|trace-path>` (report-only; CLI + core/state rules pinned by the
# sibling test_trace_consistency_*.sh sensors).
#
# Rule pinned (finding format frozen; WARN-only — the finding never flips the
# script exit code by itself, mirroring the existing duplicate_full_review and
# red_first_ordering_absent warnings): for a single harness.feature_id, when at
# least one HANDBACK span (harness.lifecycle_step in
# red_handback|impl_handback|green_handback) carries a non-empty string
# harness.instruction_files, but that feature's review_verdict span does NOT
# carry harness.instruction_files, the checker emits, once per such feature id:
#     WARNING consistency: reviewer_instruction_files_missing <feature_id>
# The intent is reviewer provenance: if the generator handbacks recorded the
# instruction files fed to the generator, the reviewer's verdict span should
# record the instruction files fed to the reviewer too. A feature whose
# review_verdict already carries instruction_files is silent; a feature where NO
# handback carried instruction_files is silent (nothing to mirror).
#
# Artifact resolution in path mode (pinned by the state sensor): progress.md is
# a SIBLING of the named trace.jsonl. All fixtures here are PLAIN directories
# (not git repos). Each fixture's progress.md carries an `## Action Log` section
# with a bullet paired to every agent span, so the ONLY finding that can fire is
# the reviewer_instruction_files_missing WARNING (the lifted #95 span/log
# multiset check stays clean) and each leg can assert an exact exit code.
#
# Legs:
#   W  impl_handback(instruction_files set) + review_verdict(no
#      instruction_files), same feature -> WARNING PRESENT, exit 0 (warn-only);
#      re-run under REQUIRE_TRACE_CONSISTENCY=1 STILL exits 0 (proves the
#      checker itself treats the finding as warn-only regardless of the gate
#      promotion flag).
#   N1 impl_handback(instruction_files set) + review_verdict(instruction_files
#      set), same feature -> NO warning (reviewer provenance present).
#   N2 impl_handback(no instruction_files) + review_verdict(no
#      instruction_files), same feature -> NO warning (nothing to mirror).
#   N3 feature_start(instruction_files set — NON-handback step) +
#      review_verdict(no instruction_files), same feature -> NO warning; proves
#      the handback lifecycle_step filter (red|impl|green_handback) has teeth: a
#      mutant that accepted any instruction_files-bearing span would fire here.
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not yet
# emit reviewer_instruction_files_missing, so W fails (WARNING absent).
#
# Exit codes: 0 reviewer-instruction-files contract honored · 1 a contract
# obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_TRACE_CONSISTENCY 2>/dev/null || true

IF_VALUE=".copilot/instructions/bash.instructions.md .copilot/instructions/tdd.instructions.md"

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -f "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the consistency checker for feature reviewer-instruction-files-warn (issue #299) is not implemented yet"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"

# --- Span + Action-Log bullet builders ----------------------------------------
# A generator handback span (impl_handback) WITH harness.instruction_files.
handback_if_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.feature_id":"%s","harness.instruction_files":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$fid" "$IF_VALUE"
}
# A generator handback span (impl_handback) WITHOUT harness.instruction_files.
handback_noif_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"impl_handback","harness.feature_id":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$fid"
}
# A reviewer verdict span WITH harness.instruction_files.
review_if_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.instruction_files":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$fid" "$IF_VALUE"
}
# A reviewer verdict span WITHOUT harness.instruction_files.
review_noif_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$fid"
}
# A NON-handback span (feature_start) carrying harness.instruction_files.
fstart_if_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"feature_start","harness.feature_id":"%s","harness.instruction_files":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$fid" "$IF_VALUE"
}

# The core span/log multiset check pairs `[role] step fid outcome` tuples; emit
# a matching Action Log bullet for every agent span so those findings stay
# silent and each leg can assert an exact exit code.
handback_bullet() {
  local fid="$1"
  printf -- '- [generator-subagent] impl_handback %s pass — impl handback\n' \
    "$fid"
}
review_bullet() {
  local fid="$1"
  printf -- '- [code-review-subagent] review_verdict %s pass — review verdict\n' \
    "$fid"
}
fstart_bullet() {
  local fid="$1"
  printf -- '- [conductor] feature_start %s pass — feature start\n' \
    "$fid"
}

trace_path() {
  printf '%s' "${TMP_DIR}/$1/trace.jsonl"
}

# --- W: handback carries instruction_files, review_verdict does not -> WARN ----
mkdir -p "${TMP_DIR}/w"
{
  handback_if_span "2026-07-18T12:00:00Z" foo
  review_noif_span "2026-07-18T12:01:00Z" foo
} > "$(trace_path w)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  handback_bullet foo
  review_bullet foo
} > "${TMP_DIR}/w/progress.md"

# --- N1: review_verdict ALSO carries instruction_files -> no warning ----------
mkdir -p "${TMP_DIR}/n1"
{
  handback_if_span "2026-07-18T12:00:00Z" foo
  review_if_span "2026-07-18T12:01:00Z" foo
} > "$(trace_path n1)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  handback_bullet foo
  review_bullet foo
} > "${TMP_DIR}/n1/progress.md"

# --- N2: no handback carries instruction_files -> no warning ------------------
mkdir -p "${TMP_DIR}/n2"
{
  handback_noif_span "2026-07-18T12:00:00Z" foo
  review_noif_span "2026-07-18T12:01:00Z" foo
} > "$(trace_path n2)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  handback_bullet foo
  review_bullet foo
} > "${TMP_DIR}/n2/progress.md"

# --- N3: instruction_files on a NON-handback (feature_start) span -> no warn ---
mkdir -p "${TMP_DIR}/n3"
{
  fstart_if_span "2026-07-18T12:00:00Z" foo
  review_noif_span "2026-07-18T12:01:00Z" foo
} > "$(trace_path n3)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  fstart_bullet foo
  review_bullet foo
} > "${TMP_DIR}/n3/progress.md"

# Fixture self-check: every trace line parses.
for c in w n1 n2 n3; do
  jq empty "$(trace_path "$c")" >/dev/null 2>&1 \
    || hard_fail "fixture ${c}: trace.jsonl does not parse — sensor bug"
done

# --- Checker run helper -------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- W. missing reviewer provenance -> WARNING present, exit 0 (warn-only) ----
rc="$(run_checker "$(trace_path w)")"
grep -Fq 'WARNING consistency: reviewer_instruction_files_missing foo' "$OUT" \
  || fail "W missing reviewer provenance: pinned finding 'WARNING consistency: reviewer_instruction_files_missing foo' missing (stdout: $(tr '\n' '|' < "$OUT"))"
[ "$rc" = "0" ] \
  || fail "W missing reviewer provenance: warn-only must NOT flip the exit code, expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- W under REQUIRE_TRACE_CONSISTENCY=1 -> STILL exit 0, warning present ------
rc=0
REQUIRE_TRACE_CONSISTENCY=1 "$CHECKER" "$(trace_path w)" >"$OUT" 2>"$ERR" || rc=$?
grep -Fq 'WARNING consistency: reviewer_instruction_files_missing foo' "$OUT" \
  || fail "W (promoted): warning must still be printed under REQUIRE_TRACE_CONSISTENCY=1 (stdout: $(tr '\n' '|' < "$OUT"))"
[ "$rc" = "0" ] \
  || fail "W (promoted): the checker itself treats reviewer_instruction_files_missing as warn-only, so even REQUIRE_TRACE_CONSISTENCY=1 must exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- N1. reviewer provenance present -> no warning ----------------------------
rc="$(run_checker "$(trace_path n1)")"
if grep -Fq 'reviewer_instruction_files_missing' "$OUT"; then
  fail "N1 provenance present: review_verdict already carries harness.instruction_files, no warning expected (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "N1 provenance present: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- N2. nothing to mirror -> no warning --------------------------------------
rc="$(run_checker "$(trace_path n2)")"
if grep -Fq 'reviewer_instruction_files_missing' "$OUT"; then
  fail "N2 nothing to mirror: no handback carried harness.instruction_files, so there is no provenance to mirror; no warning expected (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "N2 nothing to mirror: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- N3. instruction_files on a non-handback span -> no warning ---------------
rc="$(run_checker "$(trace_path n3)")"
if grep -Fq 'reviewer_instruction_files_missing' "$OUT"; then
  fail "N3 handback-step filter: harness.instruction_files sits on a feature_start (non-handback) span; only red|impl|green_handback spans arm the mirror check (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "N3 handback-step filter: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- Verdict ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'ok: reviewer_instruction_files_missing contract honored (W warns, N1/N2/N3 silent, all warn-only)\n'
