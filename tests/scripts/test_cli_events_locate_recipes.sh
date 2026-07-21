#!/usr/bin/env bash
# test_cli_events_locate_recipes.sh — regression sensor for issue #319
# feature cli-events-locate-recipes.
#
# Contract under test:
#   1. SKILL.md (copilot-log-review) documents CLI native record paths
#      (~/.copilot/session-state/<sessionId>/events.jsonl, session-store.db)
#      as first-class Locate paths distinct from VS Code transcripts.
#   2. SKILL.md contains hardened jq recipes for CLI events.jsonl that handle:
#      - data.* nesting for checkpoints (CLI event payload shape)
#      - compaction nested path (.data.copilotUsage.tokenDetails.totalNanoAiu)
#      - fractional-second ISO timestamps with portable normalization
#      - missing-shutdown fallback to latest cumulative candidate
#      - deduplication of cumulative checkpoints (no naive summing)
#      - malformed/missing/non-number field rejection
#      - no rounding: full numeric precision preserved
#   3. Official AI Credits vocabulary and billing citation (separated from
#      adopter/community empirical nano-AIU mapping).
#   4. A commit-safe synthetic fixture exists at the expected path.
#   5. The jq cost recipe produces exact correct output against the fixture.
#   6. TEETH: mutations demonstrate load-bearing recipe logic.
#   7. Precision: recipe preserves sub-nano precision without rounding to zero.
#   8. Error path: recipe raises non-zero jq error on all-invalid input.
#
# Sensor legs (A-U):
#   A: SKILL.md contains CLI events.jsonl path documentation
#   B: SKILL.md contains session-store.db path documentation
#   C: SKILL.md distinguishes CLI records from VS Code transcripts
#   D: Fixture file exists at expected path (version-stamped CLI 1.0.72-1)
#   E: Fixture contains data.* nesting (CLI event shape)
#   F: Fixture contains fractional-second timestamps
#   G: Fixture contains >=2 cumulative candidate events (dedup test)
#   H: Fixture contains malformed/missing numeric field
#   I: Fixture has no session.shutdown event (fallback exercised)
#   J: SKILL.md recipe references compaction nested path
#   K: SKILL.md recipe includes timestamp normalization (sub fractional)
#   L: SKILL.md documents AI Credits with empirical nano-AIU conversion
#   M: SKILL.md cites official GitHub billing canonical URL with access date
#   N: jq cost recipe produces exact expected JSON (parsed with jq)
#   O: TEETH — naive sum of all valid candidates > correct latest value
#   P: TEETH — removing .data. nesting prefix causes error (no valid candidates)
#   Q: TEETH — removing compaction nested path yields wrong totalNanoAiu
#   R: TEETH — removing timestamp normalization causes error on fractional seconds
#   S: NEGATIVE — malformed record specifically excluded (exact field validation)
#   T: PRECISION — totalNanoAiu:1 yields exact ai_credits==1e-9, usd==1e-11 (no rounding)
#   U: ERROR PATH — all-invalid input raises non-zero exit with "no valid candidates"
#
# Exit codes: 0 all pass · 1 any obligation fails (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="${ROOT}/.copilot/skills/copilot-log-review/SKILL.md"
FIXTURE="${ROOT}/tests/fixtures/copilot-log-review/cli-events-1.0.72-1.jsonl"

fails=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  fails=$((fails + 1))
}
note() {
  printf 'ok   [%s]: %s\n' "$1" "$2"
}

# --- Pre-check: required files exist -----------------------------------------
if [ ! -f "$SKILL" ]; then
  fail "pre" "SKILL.md not found at ${SKILL}"
  printf 'RESULT: %d leg(s) failed (SKILL.md missing — cannot proceed)\n' "$fails" >&2
  exit 1
fi
if [ ! -f "$FIXTURE" ]; then
  fail "D" "CLI events fixture not found at ${FIXTURE}"
  printf 'RESULT: %d leg(s) failed (fixture missing — cannot proceed)\n' "$fails" >&2
  exit 1
fi

# --- Leg A: CLI events.jsonl path documented ----------------------------------
if grep -q 'events\.jsonl' "$SKILL" && grep -q 'session-state' "$SKILL"; then
  note "A" "SKILL.md documents CLI events.jsonl path"
else
  fail "A" "SKILL.md must document ~/.copilot/session-state/<sessionId>/events.jsonl"
fi

# --- Leg B: session-store.db path documented ----------------------------------
if grep -q 'session-store\.db' "$SKILL"; then
  note "B" "SKILL.md documents session-store.db"
else
  fail "B" "SKILL.md must document ~/.copilot/session-store.db"
fi

# --- Leg C: Distinguishes CLI from VS Code ------------------------------------
if grep -q 'VS Code' "$SKILL" && grep -qi 'CLI' "$SKILL" \
   && grep -qi 'distinct\|separate\|independent\|unlike\|in contrast\|not.*same' "$SKILL"; then
  note "C" "SKILL.md distinguishes CLI from VS Code records"
else
  fail "C" "SKILL.md must explicitly distinguish CLI records from VS Code transcripts"
fi

# --- Leg D: Fixture exists (already pre-checked, always passes here) ----------
note "D" "Fixture exists at expected path"

# --- Leg E: data.* nesting in fixture -----------------------------------------
if jq -e 'select(.type == "session.usage_checkpoint" and .data.totalNanoAiu != null)' "$FIXTURE" >/dev/null 2>&1; then
  note "E" "Fixture contains checkpoint data.totalNanoAiu nesting"
else
  fail "E" "Fixture must contain checkpoint events with .data.totalNanoAiu nesting"
fi

# --- Leg F: fractional-second timestamps --------------------------------------
if grep -qE '"timestamp":"[^"]+\.[0-9]+Z"' "$FIXTURE"; then
  note "F" "Fixture contains fractional-second timestamps"
else
  fail "F" "Fixture must contain fractional-second ISO timestamps"
fi

# --- Leg G: cumulative candidate events for dedup testing ---------------------
CANDIDATE_COUNT=$(jq -s '[.[] | select(
  (.type == "session.usage_checkpoint" or .type == "session.compaction_complete")
  and (
    ((.type == "session.compaction_complete") and ((.data.copilotUsage.tokenDetails.totalNanoAiu | type) == "number"))
    or ((.type != "session.compaction_complete") and ((.data.totalNanoAiu | type) == "number"))
  )
)] | length' "$FIXTURE" 2>/dev/null || echo 0)
if [ "$CANDIDATE_COUNT" -ge 2 ]; then
  note "G" "Fixture contains ${CANDIDATE_COUNT} valid cumulative candidate events"
else
  fail "G" "Fixture must contain >=2 valid cumulative candidate events for dedup testing"
fi

# --- Leg H: malformed/missing numeric field -----------------------------------
MALFORMED=$(jq -s '[.[] | select(
  (.type == "session.usage_checkpoint")
  and ((.data.totalNanoAiu | type) != "number")
)] | length' "$FIXTURE" 2>/dev/null || echo 0)
if [ "$MALFORMED" -ge 1 ]; then
  note "H" "Fixture contains ${MALFORMED} checkpoint(s) with malformed totalNanoAiu"
else
  fail "H" "Fixture must contain at least one checkpoint with malformed totalNanoAiu"
fi

# --- Leg I: no session.shutdown event -----------------------------------------
SHUTDOWN_COUNT=$(jq -s '[.[] | select(.type == "session.shutdown")] | length' "$FIXTURE" 2>/dev/null || echo 0)
if [ "$SHUTDOWN_COUNT" -eq 0 ]; then
  note "I" "Fixture has no session.shutdown (fallback path exercised)"
else
  fail "I" "Fixture must NOT contain session.shutdown to exercise fallback logic"
fi

# --- Leg J: Recipe references compaction nested path --------------------------
if grep -q 'copilotUsage\.tokenDetails\.totalNanoAiu\|copilotUsage.tokenDetails.totalNanoAiu' "$SKILL"; then
  note "J" "SKILL.md recipe references compaction nested path"
else
  fail "J" "SKILL.md recipe must reference .data.copilotUsage.tokenDetails.totalNanoAiu"
fi

# --- Leg K: Timestamp normalization in recipe ---------------------------------
if grep -q 'sub("\\\\.\[0-9\]' "$SKILL" || grep -qE 'sub\(.+\.\[0-9\]' "$SKILL"; then
  note "K" "SKILL.md includes timestamp normalization"
else
  fail "K" "SKILL.md must include sub(...) fractional-second timestamp normalization"
fi

# --- Leg L: AI Credits vocabulary with nano-AIU conversion --------------------
if grep -q 'AI Credits' "$SKILL" && grep -q 'totalNanoAiu / 1e9' "$SKILL" \
   && grep -qi 'empirical\|community\|adopter' "$SKILL"; then
  note "L" "SKILL.md documents AI Credits with empirical nano-AIU conversion"
else
  fail "L" "SKILL.md must document empirical totalNanoAiu / 1e9 = AI Credits conversion"
fi

# --- Leg M: Official GitHub billing citation with access date -----------------
if grep -q 'docs.github.com/en/copilot' "$SKILL" \
   && grep -q 'accessed 2026' "$SKILL"; then
  note "M" "SKILL.md cites official GitHub Docs canonical URL with access date"
else
  fail "M" "SKILL.md must cite canonical docs.github.com/en/copilot URL with access date"
fi

# --- Helper: extract jq recipe from SKILL.md CLI session cost section ---------
extract_cli_recipe() {
  awk '
    /^### CLI session cost/{found=1; next}
    found && /^##[[:space:]]/{exit}
    found && /^```jq$/{in_jq=1; next}
    found && in_jq && /^```$/{in_jq=0; found=0; next}
    in_jq{print}
  ' "$SKILL"
}

# --- Leg N: jq cost recipe produces exact expected JSON -----------------------
RECIPE=$(extract_cli_recipe)
if [ -z "$RECIPE" ]; then
  fail "N" "Cannot extract CLI cost recipe from SKILL.md (### CLI session cost section)"
else
  ACTUAL=$(printf '%s\n' "$RECIPE" | jq -s -f /dev/stdin "$FIXTURE" 2>&1) || {
    fail "N" "jq recipe execution failed: ${ACTUAL}"
    ACTUAL=""
  }
  if [ -n "$ACTUAL" ]; then
    # Parse exact fields with jq — no grep substrings
    GOT_NANO=$(printf '%s' "$ACTUAL" | jq -r '.totalNanoAiu')
    GOT_CREDITS=$(printf '%s' "$ACTUAL" | jq -r '.ai_credits')
    GOT_USD=$(printf '%s' "$ACTUAL" | jq -r '.usd')
    GOT_SOURCE=$(printf '%s' "$ACTUAL" | jq -r '.source_event')
    GOT_TS=$(printf '%s' "$ACTUAL" | jq -r '.timestamp')

    PASS_N=true
    if [ "$GOT_NANO" != "4200000000" ]; then
      fail "N" "totalNanoAiu: expected 4200000000, got ${GOT_NANO}"
      PASS_N=false
    fi
    if [ "$GOT_CREDITS" != "4.2" ]; then
      fail "N" "ai_credits: expected 4.2, got ${GOT_CREDITS}"
      PASS_N=false
    fi
    if [ "$GOT_USD" != "0.042" ]; then
      fail "N" "usd: expected 0.042, got ${GOT_USD}"
      PASS_N=false
    fi
    if [ "$GOT_SOURCE" != "session.compaction_complete" ]; then
      fail "N" "source_event: expected session.compaction_complete, got ${GOT_SOURCE}"
      PASS_N=false
    fi
    if [ "$GOT_TS" != "2026-03-15T14:05:00.700Z" ]; then
      fail "N" "timestamp: expected 2026-03-15T14:05:00.700Z, got ${GOT_TS}"
      PASS_N=false
    fi
    if [ "$PASS_N" = "true" ]; then
      note "N" "Recipe produces exact expected JSON output"
    fi
  fi
fi

# --- Leg O: TEETH — naive sum yields wrong (larger) number --------------------
NAIVE_RECIPE='
def norm_ts: sub("\\.[0-9]+Z$"; "Z");
[.[] | select(.type == "session.shutdown" or .type == "session.usage_checkpoint" or .type == "session.compaction_complete")
 | {type, timestamp} + (
     if .type == "session.compaction_complete" then
       {totalNanoAiu: .data.copilotUsage.tokenDetails.totalNanoAiu}
     else
       {totalNanoAiu: .data.totalNanoAiu}
     end
   )
 | select((.totalNanoAiu | type) == "number")
 | .totalNanoAiu
] | add
'
NAIVE_SUM=$(printf '%s\n' "$NAIVE_RECIPE" | jq -s -f /dev/stdin "$FIXTURE" 2>/dev/null || echo "0")
if [ "$NAIVE_SUM" -gt 4200000000 ] 2>/dev/null; then
  note "O" "TEETH: naive sum (${NAIVE_SUM}) > correct latest (4200000000)"
else
  fail "O" "TEETH: naive sum (${NAIVE_SUM}) must exceed correct value (4200000000)"
fi

# --- Leg P: TEETH — removing .data. nesting causes error ----------------------
if [ -n "$RECIPE" ]; then
  # Strip .data. prefix from all paths: .data.totalNanoAiu → .totalNanoAiu,
  # .data.copilotUsage → .copilotUsage
  BROKEN_NO_DATA=$(printf '%s\n' "$RECIPE" | sed 's/\.data\./\./g')
  BROKEN_EXIT=0
  printf '%s\n' "$BROKEN_NO_DATA" | jq -s -f /dev/stdin "$FIXTURE" >/dev/null 2>&1 || BROKEN_EXIT=$?

  if [ "$BROKEN_EXIT" -ne 0 ]; then
    note "P" "TEETH: removing .data. nesting causes jq error (exit ${BROKEN_EXIT})"
  else
    fail "P" "TEETH: recipe without .data. nesting must error (got exit 0)"
  fi
else
  fail "P" "Cannot extract recipe for data-nesting mutation"
fi

# --- Leg Q: TEETH — removing compaction nested path yields wrong output -------
if [ -n "$RECIPE" ]; then
  # Replace the compaction-specific path with flat .data.totalNanoAiu
  BROKEN_COMPACT=$(printf '%s\n' "$RECIPE" | sed 's/\.data\.copilotUsage\.tokenDetails\.totalNanoAiu/.data.totalNanoAiu/g')
  COMPACT_RESULT=""
  COMPACT_EXIT=0
  COMPACT_RESULT=$(printf '%s\n' "$BROKEN_COMPACT" | jq -s -f /dev/stdin "$FIXTURE" 2>&1) || COMPACT_EXIT=$?

  if [ "$COMPACT_EXIT" -ne 0 ]; then
    note "Q" "TEETH: removing compaction nested path causes error"
  else
    COMPACT_NANO=$(printf '%s' "$COMPACT_RESULT" | jq -r '.totalNanoAiu' 2>/dev/null)
    if [ "$COMPACT_NANO" != "4200000000" ]; then
      note "Q" "TEETH: removing compaction nested path yields wrong value (${COMPACT_NANO} != 4200000000)"
    else
      fail "Q" "TEETH: removing compaction nested path must yield wrong output or error"
    fi
  fi
else
  fail "Q" "Cannot extract recipe for compaction-path mutation"
fi

# --- Leg R: TEETH — removing timestamp normalization causes error -------------
if [ -n "$RECIPE" ]; then
  # Remove norm_ts definition usage: replace "| norm_ts |" with "|"
  BROKEN_TS=$(printf '%s\n' "$RECIPE" | sed 's/| norm_ts |/|/g')
  TS_EXIT=0
  printf '%s\n' "$BROKEN_TS" | jq -s -f /dev/stdin "$FIXTURE" >/dev/null 2>&1 || TS_EXIT=$?

  if [ "$TS_EXIT" -ne 0 ]; then
    note "R" "TEETH: removing timestamp normalization causes jq error (exit ${TS_EXIT})"
  else
    fail "R" "TEETH: recipe without timestamp normalization must error on fractional seconds"
  fi
else
  fail "R" "Cannot extract recipe for timestamp mutation"
fi

# --- Leg S: NEGATIVE — malformed record specifically excluded -----------------
if [ -n "$RECIPE" ]; then
  # Verify the malformed event is excluded: recipe selects latest valid candidate,
  # not the corrupted checkpoint at 14:04
  S_RESULT=$(printf '%s\n' "$RECIPE" | jq -s -f /dev/stdin "$FIXTURE" 2>/dev/null)
  S_EXIT=$?
  if [ "$S_EXIT" -eq 0 ]; then
    S_NANO=$(printf '%s' "$S_RESULT" | jq -r '.totalNanoAiu')
    S_SOURCE=$(printf '%s' "$S_RESULT" | jq -r '.source_event')
    S_TS=$(printf '%s' "$S_RESULT" | jq -r '.timestamp')
    # The malformed checkpoint is at 14:04:00.600Z — it must NOT be the source
    if [ "$S_TS" != "2026-03-15T14:04:00.600Z" ] && [ "$S_SOURCE" != "null" ] \
       && [ "$S_NANO" = "4200000000" ]; then
      note "S" "NEGATIVE: malformed record at 14:04 excluded; latest valid selected"
    else
      fail "S" "Malformed record must be excluded (got source=${S_SOURCE} ts=${S_TS})"
    fi
  else
    fail "S" "Recipe errored when malformed record should be excluded gracefully"
  fi
else
  fail "S" "Cannot extract recipe for malformed-record test"
fi

# --- Leg T: PRECISION — totalNanoAiu:1 yields exact nonzero results -----------
if [ -n "$RECIPE" ]; then
  # Synthetic single-event input with totalNanoAiu: 1 (smallest valid value)
  PRECISION_INPUT='{"type":"session.usage_checkpoint","timestamp":"2026-01-01T00:00:00.100Z","data":{"totalNanoAiu":1}}'
  T_RESULT=$(printf '%s\n' "$RECIPE" | jq -s -f /dev/stdin <(printf '%s\n' "$PRECISION_INPUT") 2>&1)
  T_EXIT=$?
  if [ "$T_EXIT" -ne 0 ]; then
    fail "T" "PRECISION: recipe failed on totalNanoAiu:1 input: ${T_RESULT}"
  else
    # Assert exact numeric equality via jq (not string comparison — handles scientific notation)
    T_CREDITS_OK=$(printf '%s' "$T_RESULT" | jq '.ai_credits == 1e-9')
    T_USD_OK=$(printf '%s' "$T_RESULT" | jq '.usd == 1e-11')
    if [ "$T_CREDITS_OK" = "true" ] && [ "$T_USD_OK" = "true" ]; then
      note "T" "PRECISION: totalNanoAiu:1 → ai_credits==1e-9, usd==1e-11 (no rounding)"
    else
      T_C=$(printf '%s' "$T_RESULT" | jq '.ai_credits')
      T_U=$(printf '%s' "$T_RESULT" | jq '.usd')
      fail "T" "PRECISION: expected ai_credits==1e-9 usd==1e-11, got credits=${T_C} usd=${T_U}"
    fi
  fi
else
  fail "T" "Cannot extract recipe for precision test"
fi

# --- Leg U: ERROR PATH — all-invalid input raises non-zero with message -------
if [ -n "$RECIPE" ]; then
  # Input with only malformed/string totalNanoAiu values — no valid candidates
  INVALID_INPUT='{"type":"session.usage_checkpoint","timestamp":"2026-01-01T00:00:01.000Z","data":{"totalNanoAiu":"NOT_A_NUMBER"}}
{"type":"session.usage_checkpoint","timestamp":"2026-01-01T00:00:02.000Z","data":{"totalNanoAiu":null}}'
  U_STDERR=""
  U_EXIT=0
  U_STDERR=$(printf '%s\n' "$RECIPE" | jq -s -f /dev/stdin <(printf '%s\n' "$INVALID_INPUT") 2>&1 >/dev/null) || U_EXIT=$?
  if [ "$U_EXIT" -ne 0 ]; then
    if printf '%s' "$U_STDERR" | grep -q 'no valid candidates'; then
      note "U" "ERROR PATH: all-invalid input → exit ${U_EXIT} with 'no valid candidates'"
    else
      fail "U" "ERROR PATH: expected 'no valid candidates' in stderr, got: ${U_STDERR}"
    fi
  else
    fail "U" "ERROR PATH: recipe must exit non-zero on all-invalid input (got exit 0)"
  fi
else
  fail "U" "Cannot extract recipe for error-path test"
fi

# --- Summary ------------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  printf '\nRESULT: %d leg(s) failed\n' "$fails" >&2
  exit 1
else
  printf '\nRESULT: all 21 legs passed (A-U)\n'
  exit 0
fi
