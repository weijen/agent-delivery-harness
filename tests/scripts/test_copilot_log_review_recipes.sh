#!/usr/bin/env bash
# test_copilot_log_review_recipes.sh — regression sensor for issue #306,
# feature log-review-recipes: the copilot-log-review SKILL.md ships executable
# jq Quantify recipes, and they compute correct (never negative) tool durations
# when run against a committed synthetic transcript fixture — and skip, rather
# than crash on, an orphaned tool call (a tool.execution_start with no matching
# tool.execution_complete, as a real transcript captured mid-call would carry).
#
# The sensor EXTRACTS the shipped jq programs from the SKILL.md fenced ```jq
# blocks (rather than hardcoding a copy) so it pins the recipes that actually
# ship, then runs them with `jq -s` on the fixture.
#
# Legs:
#   A (durations-recipe)  The ```jq block under "### Tool durations" exists,
#                         runs WITHOUT crashing on the fixture's orphaned call,
#                         and yields one duration per WELL-FORMED tool call,
#                         every duration >= 0 and non-null (the pair-by-
#                         toolCallId guarantee), with the summed duration
#                         matching the fixture's known good total (30s). The
#                         orphaned call (call_6_orphan) is SKIPPED, never counted
#                         as a duration. A naive sort_by(.type) pairing produces
#                         negatives, and an unguarded recipe crashes on the
#                         orphan, so this leg has teeth on both counts.
#   B (inventory-recipe)  The ```jq block under "### Session inventory" exists,
#                         runs, and reports the fixture's known good inventory
#                         (tool_count 6 — five complete pairs + one orphaned
#                         start, user_messages 1, assistant_turns 1, span_s 42).
#   C (decomposition)     The ```jq block under "### Workflow-time decomposition"
#                         exists, runs WITHOUT crashing on the orphaned call, and
#                         its category totals sum to the same well-formed 30s
#                         (the orphan is skipped from the roll-up too).
#
# Exit: 0 all legs pass · 1 any obligation missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for retired in scripts/audit-sweep.sh .copilot/prompts/audit-sweep.prompt.md; do
  [ ! -e "${ROOT}/${retired}" ] || {
    printf 'FAIL: retired audit entrypoint still exists: %s\n' "$retired" >&2
    exit 1
  }
done
if grep -Eq 'audit-sweep' \
  "${ROOT}/docs/HARNESS.md" \
  "${ROOT}/.copilot/instructions/harness.instructions.md" \
  "${ROOT}/.copilot/agents/code-review-subagent.agent.md"; then
  printf 'FAIL: current doctrine still advertises the retired audit entrypoint\n' >&2
  exit 1
fi
SKILL="${ROOT}/.copilot/skills/copilot-log-review/SKILL.md"
FIX="${ROOT}/tests/fixtures/copilot-log-review/sample-transcript.jsonl"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'FAIL: jq is required but not found on PATH\n' >&2
  exit 1
fi

if [ ! -f "${SKILL}" ]; then
  printf 'FAIL: SKILL.md not found (%s)\n' "${SKILL}" >&2
  exit 1
fi
if [ ! -f "${FIX}" ]; then
  printf 'FAIL: transcript fixture not found (%s)\n' "${FIX}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# extract_jq_block <heading-ERE> <file>
# Prints the first ```jq ... ``` fenced block appearing after a line matching
# the heading regex. Empty output means "no such recipe shipped".
extract_jq_block() {
  awk -v hre="$1" '
    state == 0 && $0 ~ hre { state = 1; next }
    state == 1 && /^```jq[[:space:]]*$/ { state = 2; next }
    state == 2 && /^```[[:space:]]*$/ { exit }
    state == 2 { print }
  ' "$2"
}

# --- Leg A: tool-durations recipe -------------------------------------------
dur_recipe="${TMP_DIR}/durations.jq"
extract_jq_block '^###[[:space:]].*[Tt]ool durations' "${SKILL}" > "${dur_recipe}"
if [ ! -s "${dur_recipe}" ]; then
  fail "A: no jq recipe found under a '### Tool durations' heading in SKILL.md"
else
  if ! dur_json="$(jq -s -f "${dur_recipe}" "${FIX}" 2>"${TMP_DIR}/dur.err")"; then
    fail "A: durations recipe failed to run (must skip the orphaned call, not crash): $(cat "${TMP_DIR}/dur.err")"
  elif [ -z "${dur_json}" ] || [ "${dur_json}" = "null" ]; then
    fail "A: durations recipe produced no output"
  else
    count="$(printf '%s' "${dur_json}" | jq '[.[].duration_s] | length')"
    min="$(printf '%s' "${dur_json}" | jq '[.[].duration_s] | min')"
    total="$(printf '%s' "${dur_json}" | jq '[.[].duration_s] | add')"
    nulls="$(printf '%s' "${dur_json}" | jq '[.[].duration_s | select(. == null)] | length')"
    orphan_counted="$(printf '%s' "${dur_json}" | jq '[.[].toolCallId] | any(. == "call_6_orphan")')"
    if [ "${count}" != "5" ]; then
      fail "A: expected 5 well-formed tool durations, got '${count}'"
    fi
    if [ "${nulls}" != "0" ]; then
      fail "A: a computed tool duration is null (${nulls}) — an orphaned call must be skipped, not emitted with a null duration"
    fi
    if [ "${orphan_counted}" != "false" ]; then
      fail "A: the orphaned tool call (call_6_orphan) was counted as a duration — it must be skipped"
    fi
    if [ -z "${min}" ] || [ "${min}" = "null" ] || jq -n --argjson m "${min}" '$m < 0' | grep -q true; then
      fail "A: a computed tool duration is negative (min='${min}') — pairing must be by toolCallId, not sort_by(.type)"
    fi
    if [ "${total}" != "30" ]; then
      fail "A: expected summed duration 30s for the fixture, got '${total}'"
    fi
  fi
fi

# --- Leg B: session-inventory recipe ----------------------------------------
inv_recipe="${TMP_DIR}/inventory.jq"
extract_jq_block '^###[[:space:]].*[Ss]ession inventory' "${SKILL}" > "${inv_recipe}"
if [ ! -s "${inv_recipe}" ]; then
  fail "B: no jq recipe found under a '### Session inventory' heading in SKILL.md"
else
  if ! inv_json="$(jq -s -f "${inv_recipe}" "${FIX}" 2>"${TMP_DIR}/inv.err")"; then
    fail "B: inventory recipe failed to run: $(cat "${TMP_DIR}/inv.err")"
  else
    tool_count="$(printf '%s' "${inv_json}" | jq -r '.tool_count')"
    users="$(printf '%s' "${inv_json}" | jq -r '.user_messages')"
    turns="$(printf '%s' "${inv_json}" | jq -r '.assistant_turns')"
    span="$(printf '%s' "${inv_json}" | jq -r '.span_s')"
    if [ "${tool_count}" != "6" ]; then
      fail "B: inventory tool_count expected 6 (5 complete pairs + 1 orphaned start), got '${tool_count}'"
    fi
    if [ "${users}" != "1" ]; then
      fail "B: inventory user_messages expected 1, got '${users}'"
    fi
    if [ "${turns}" != "1" ]; then
      fail "B: inventory assistant_turns expected 1, got '${turns}'"
    fi
    if [ "${span}" != "42" ]; then
      fail "B: inventory span_s expected 42, got '${span}'"
    fi
  fi
fi

# --- Leg C: workflow-time decomposition recipe ------------------------------
# Proves the same orphaned-call guard holds for the second roll-up: it must run
# WITHOUT crashing on call_6_orphan and its category totals must sum to the
# well-formed 30s (orphan skipped from the decomposition too).
wf_recipe="${TMP_DIR}/decomposition.jq"
extract_jq_block '^###[[:space:]].*[Ww]orkflow-time decomposition' "${SKILL}" > "${wf_recipe}"
if [ ! -s "${wf_recipe}" ]; then
  fail "C: no jq recipe found under a '### Workflow-time decomposition' heading in SKILL.md"
else
  if ! wf_json="$(jq -s -f "${wf_recipe}" "${FIX}" 2>"${TMP_DIR}/wf.err")"; then
    fail "C: decomposition recipe failed to run (must skip the orphaned call, not crash): $(cat "${TMP_DIR}/wf.err")"
  elif [ -z "${wf_json}" ] || [ "${wf_json}" = "null" ]; then
    fail "C: decomposition recipe produced no output"
  else
    wf_total="$(printf '%s' "${wf_json}" | jq '[.[].total_s] | add')"
    wf_nulls="$(printf '%s' "${wf_json}" | jq '[.[].total_s | select(. == null)] | length')"
    if [ "${wf_nulls}" != "0" ]; then
      fail "C: a category total is null (${wf_nulls}) — an orphaned call must be skipped, not roll up a null duration"
    fi
    if [ "${wf_total}" != "30" ]; then
      fail "C: expected decomposition category totals to sum to 30s, got '${wf_total}'"
    fi
  fi
fi

if [ "${fails}" -ne 0 ]; then
  printf '\n%d copilot-log-review Quantify recipe obligation(s) failed.\n' "${fails}" >&2
  exit 1
fi
printf 'copilot-log-review Quantify recipes: durations non-negative (sum 30s, orphaned call skipped), decomposition totals 30s, and inventory verified against the fixture\n'

(
cd "$ROOT"

SKILL="${ROOT}/.copilot/skills/copilot-log-review/SKILL.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${SKILL}" ]; then
  printf 'FAIL: SKILL.md not found (%s)\n' "${SKILL}" >&2
  exit 1
fi

# section <heading-ERE> <file>
# Prints from the first line matching <heading-ERE> down to (but excluding) the
# next top-level `## ` heading. Scoping each stage's assertions to its own
# section is what gives this sensor teeth: reverting the feature deletes the
# section, and the pre-existing frontmatter / Quantify text cannot mask it.
section() {
  awk -v hre="$1" '
    /^## / { if (inb) exit }
    $0 ~ hre { inb = 1 }
    inb { print }
  ' "$2"
}

# flatten <text> — join to one spaced line so phrase assertions tolerate the
# markdown hard line-wraps in prose.
flatten() {
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

# --- Locate stage -----------------------------------------------------------
if ! grep -qE '^## Locate[[:space:]]*$' "${SKILL}"; then
  fail "Locate: missing a '## Locate' stage heading"
fi
loc="$(flatten "$(section '^## Locate[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${loc}" | grep -qiF 'workspace.json' \
  || fail "Locate: must resolve the workspace hash via workspaceStorage/*/workspace.json"
printf '%s\n' "${loc}" | grep -qF 'workspaceStorage' \
  || fail "Locate: must name the workspaceStorage directory"
printf '%s\n' "${loc}" | grep -qiF 'review window' \
  || fail "Locate: must enumerate sessions overlapping the review window"
printf '%s\n' "${loc}" | grep -qiF 'lifecycle-span' \
  || fail "Locate: must support an issue lifecycle-span enumeration window"
printf '%s\n' "${loc}" | grep -qF 'trace.jsonl' \
  || fail "Locate: lifecycle-span window must come from .copilot-tracking/issues/issue-NN/trace.jsonl"
printf '%s\n' "${loc}" | grep -qiF 'offline join' \
  || fail "Locate: must describe the offline (time-window) session-to-issue join"

# Verified macOS transcript path fragments.
printf '%s\n' "${loc}" | grep -qF 'Library/Application Support/Code/User/workspaceStorage' \
  || fail "Locate: must give the verified macOS workspaceStorage path"
printf '%s\n' "${loc}" | grep -qF 'GitHub.copilot-chat/transcripts' \
  || fail "Locate: must give the verified macOS transcript path (GitHub.copilot-chat/transcripts)"

# Per-OS: macOS verified, Windows + Linux variants unverified.
printf '%s\n' "${loc}" | grep -qiF 'only macOS paths are verified' \
  || fail "Locate: must state only macOS paths are verified"
printf '%s\n' "${loc}" | grep -qF '%APPDATA%' \
  || fail "Locate: must give the Windows (%APPDATA%) workspaceStorage variant"
printf '%s\n' "${loc}" | grep -qF '.config/Code/User/workspaceStorage' \
  || fail "Locate: must give the Linux (~/.config) workspaceStorage variant"
printf '%s\n' "${loc}" | grep -qiF 'unverified' \
  || fail "Locate: must mark the Windows/Linux variants as unverified"

# --- Qualify stage ----------------------------------------------------------
if ! grep -qE '^## Qualify[[:space:]]*$' "${SKILL}"; then
  fail "Qualify: missing a '## Qualify' stage heading"
fi
qual="$(flatten "$(section '^## Qualify[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${qual}" | grep -qF 'reasoningText' \
  || fail "Qualify: must sample reasoningText around key decisions"

# --- Report stage -----------------------------------------------------------
if ! grep -qE '^## Report[[:space:]]*$' "${SKILL}"; then
  fail "Report: missing a '## Report' stage heading"
fi
rep="$(flatten "$(section '^## Report[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${rep}" | grep -qF '_audit-conventions.md' \
  || fail "Report: must follow the shared _audit-conventions.md report shape"
printf '%s\n' "${rep}" | grep -qF 'logs/audit/' \
  || fail "Report: must name the logs/audit/<UTC-timestamp>/ output directory"
printf '%s\n' "${rep}" | grep -qF 'copilot-log-review.md' \
  || fail "Report: must write to logs/audit/<UTC-timestamp>/copilot-log-review.md"
printf '%s\n' "${rep}" | grep -qiF 'previous report' \
  || fail "Report: must compare against the previous report when one exists"
printf '%s\n' "${rep}" | grep -qiF 'trend' \
  || fail "Report: must produce a trend, not a snapshot"

# --- Report-only + privacy --------------------------------------------------
if ! grep -qE '^## Report-only and privacy[[:space:]]*$' "${SKILL}"; then
  fail "Privacy: missing a '## Report-only and privacy' section"
fi
priv="$(flatten "$(section '^## Report-only and privacy[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${priv}" | grep -qiF 'report-only' \
  || fail "Privacy: must restate the skill is report-only"
printf '%s\n' "${priv}" | grep -qiF 'never edit' \
  || fail "Privacy: must state the skill never edits the repo"
printf '%s\n' "${priv}" | grep -qiF 'never commit' \
  || fail "Privacy: must forbid committing raw transcript excerpts (never commit)"
printf '%s\n' "${priv}" | grep -qiF 'transcript' \
  || fail "Privacy: must scope the never-commit rule to transcript content"
printf '%s\n' "${priv}" | grep -qiF 'redact' \
  || fail "Privacy: must route quotes through the redaction patterns"

if [ "${fails}" -ne 0 ]; then
  printf '\n%d copilot-log-review structure obligation(s) failed.\n' "${fails}" >&2
  exit 1
fi

printf 'PASS: copilot-log-review SKILL.md ships Locate/Qualify/Report stages, report-only + privacy, and per-OS paths.\n'
)

(
cd "$ROOT"

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
)

(
cd "$ROOT"

MANIFEST="${MANIFEST:-${ROOT}/tests/fixtures/copilot-log-review/cli-record-contract.json}"
SKILL_PATH="${SKILL_PATH:-${ROOT}/.copilot/skills/copilot-log-review/SKILL.md}"
FIXTURE_ROOT="${FIXTURE_ROOT:-${ROOT}}"

fails=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  fails=$((fails + 1))
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'FAIL: jq is required but not found on PATH\n' >&2
  exit 1
fi

# --- Bash-3.2-portable linear-lookup helpers for parallel indexed arrays ------
# _lookup_disc_jqfile <key> — print jq filepath for a discovered source-tuple key
_lookup_disc_jqfile() {
  local needle="$1" idx=0
  while [ "$idx" -lt "${#discovered_keys[@]}" ]; do
    if [ "${discovered_keys[idx]}" = "$needle" ]; then
      printf '%s' "${_disc_jqfiles[idx]}"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# _lookup_mani_id <key> — print manifest recipe id for a manifest source-tuple key
_lookup_mani_id() {
  local needle="$1" idx=0
  while [ "$idx" -lt "${#manifest_recipe_keys[@]}" ]; do
    if [ "${manifest_recipe_keys[idx]}" = "$needle" ]; then
      printf '%s' "${_mani_ids[idx]}"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# ==============================================================================
# Leg A: Manifest exists, valid JSON, schema_version=="1.0.0", structural checks
# ==============================================================================
if [ ! -f "$MANIFEST" ]; then
  fail "A" "contract manifest not found at ${MANIFEST}"
  printf '\n%d obligation(s) failed.\n' "$fails" >&2
  exit 1
fi
if ! jq empty "$MANIFEST" 2>/dev/null; then
  fail "A" "manifest is not valid JSON"
  printf '\n%d obligation(s) failed.\n' "$fails" >&2
  exit 1
fi

SUPPORTED_SCHEMA="1.0.0"
schema_version="$(jq -r '.schema_version // empty' "$MANIFEST")"
if [ "$schema_version" != "$SUPPORTED_SCHEMA" ]; then
  fail "A" "manifest schema_version must be exactly '${SUPPORTED_SCHEMA}', got '${schema_version}'"
fi

# Structural array type check — exit cleanly on failure (unsafe to loop non-arrays)
struct_ok=true
for arr in fixtures recipes; do
  arr_type="$(jq -r --arg a "$arr" '.[$a] | type' "$MANIFEST")"
  if [ "$arr_type" != "array" ]; then
    fail "A" "manifest .${arr} must be an array (got type '${arr_type}')"
    struct_ok=false
  else
    arr_len="$(jq --arg a "$arr" '.[$a] | length' "$MANIFEST")"
    if [ "$arr_len" -lt 1 ]; then
      fail "A" "manifest .${arr} must be non-empty (got length ${arr_len})"
      struct_ok=false
    fi
  fi
done
if [ "$struct_ok" != "true" ]; then
  printf '\n%d obligation(s) failed (structural array type check).\n' "$fails" >&2
  exit 1
fi

fixture_count="$(jq '.fixtures | length' "$MANIFEST")"
recipe_count="$(jq '.recipes | length' "$MANIFEST")"

# Validate fixtures: id, relative_path, surface must be nonempty strings;
# observed_cli_version must be null or nonempty string
for i in $(seq 0 $((fixture_count - 1))); do
  for fld in id relative_path surface; do
    fld_ok="$(jq ".fixtures[$i].${fld} | type == \"string\" and length > 0" "$MANIFEST")"
    if [ "$fld_ok" != "true" ]; then
      fail "A" "fixture[$i].${fld} must be a non-empty string"
    fi
  done
  ocv_ok="$(jq ".fixtures[$i].observed_cli_version | . == null or (type == \"string\" and length > 0)" "$MANIFEST")"
  if [ "$ocv_ok" != "true" ]; then
    fail "A" "fixture[$i].observed_cli_version must be null or a non-empty string"
  fi
done

# Validate recipes: required strings, source_context_level only ## or ###,
# ordinal must be a numeric integer >= 1
for i in $(seq 0 $((recipe_count - 1))); do
  for fld in id source_heading source_context_level fixture_id expectation; do
    fld_ok="$(jq ".recipes[$i].${fld} | type == \"string\" and length > 0" "$MANIFEST")"
    if [ "$fld_ok" != "true" ]; then
      fail "A" "recipe[$i].${fld} must be a non-empty string"
    fi
  done
  # source_context_level constraint
  scl="$(jq -r ".recipes[$i].source_context_level" "$MANIFEST")"
  if [ "$scl" != "##" ] && [ "$scl" != "###" ]; then
    fail "A" "recipe[$i].source_context_level must be '##' or '###', got '${scl}'"
  fi
  # ordinal: numeric integer >= 1 (jq type check, not shell -lt on text)
  ord_ok="$(jq ".recipes[$i].ordinal | type == \"number\" and floor == . and . >= 1" "$MANIFEST")"
  if [ "$ord_ok" != "true" ]; then
    ord_raw="$(jq ".recipes[$i].ordinal" "$MANIFEST")"
    fail "A" "recipe[$i].ordinal must be a positive integer (number, floor==self, >=1), got '${ord_raw}'"
  fi
  # Verify referenced fixture ID exists
  ref_fid="$(jq -r ".recipes[$i].fixture_id" "$MANIFEST")"
  ref_exists="$(jq --arg fid "$ref_fid" '[.fixtures[].id] | any(. == $fid)' "$MANIFEST")"
  if [ "$ref_exists" != "true" ]; then
    fail "A" "recipe[$i].fixture_id '${ref_fid}' references a fixture not declared in manifest"
  fi
done

# ==============================================================================
# Leg B: Manifest uniqueness — IDs, paths, source tuples, fixture-backed count
# ==============================================================================

# Fixture IDs unique
fixture_id_dups="$(jq -r '[.fixtures[].id] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$fixture_id_dups" ]; then
  fail "B" "duplicate fixture id: '${fixture_id_dups}'"
fi
# Fixture paths unique
fixture_path_dups="$(jq -r '[.fixtures[].relative_path] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$fixture_path_dups" ]; then
  fail "B" "duplicate fixture relative_path: '${fixture_path_dups}'"
fi
# Recipe IDs unique
recipe_id_dups="$(jq -r '[.recipes[].id] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$recipe_id_dups" ]; then
  fail "B" "duplicate recipe id: '${recipe_id_dups}'"
fi
# Recipe source tuples unique
recipe_tuple_dups="$(jq -r '[.recipes[] | "\(.source_context_level)|\(.source_heading)|\(.ordinal)"] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$recipe_tuple_dups" ]; then
  fail "B" "duplicate recipe source tuple: '${recipe_tuple_dups}'"
fi
# Exactly one fixture with observed_cli_version (v1 simplicity)
cli_version_fixture_count="$(jq '[.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "")] | length' "$MANIFEST")"
if [ "$cli_version_fixture_count" -ne 1 ]; then
  fail "B" "expected exactly 1 fixture with observed_cli_version, got ${cli_version_fixture_count}"
fi

# ==============================================================================
# Leg C: Fixture records — paths exist and JSONL lines parse
# ==============================================================================
for i in $(seq 0 $((fixture_count - 1))); do
  fid="$(jq -r ".fixtures[$i].id" "$MANIFEST")"
  fpath="$(jq -r ".fixtures[$i].relative_path" "$MANIFEST")"
  full_path="${FIXTURE_ROOT}/${fpath}"
  if [ ! -f "$full_path" ]; then
    fail "C" "fixture '${fid}' path does not exist: ${full_path}"
    continue
  fi
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [ -n "$line" ] && ! printf '%s' "$line" | jq empty 2>/dev/null; then
      fail "C" "fixture '${fid}' line ${line_num} is not valid JSON"
      break
    fi
  done < "$full_path"
done

# ==============================================================================
# Leg D: Recipe discovery — awk state machine to extract jq blocks
# ==============================================================================
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

awk -v tmpdir="$TMP_DIR" '
  /^(##|###)[[:space:]]+/ {
    heading = $0
    level = heading
    sub(/[[:space:]]+.*/, "", level)
    sub(/^##+[[:space:]]+/, "", heading)
    fence_in_heading = 0
  }
  /^```jq[[:space:]]*$/ {
    fence_in_heading++
    in_fence = 1
    outfile = tmpdir "/recipe_" NR ".jq"
    printf "" > outfile
    printf "%s\t%s\t%d\t%s\n", level, heading, fence_in_heading, outfile >> (tmpdir "/index.tsv")
    next
  }
  in_fence && /^```[[:space:]]*$/ {
    in_fence = 0
    close(outfile)
    next
  }
  in_fence {
    print >> outfile
  }
' "$SKILL_PATH"

discovered_count=0
if [ -f "$TMP_DIR/index.tsv" ]; then
  discovered_count="$(wc -l < "$TMP_DIR/index.tsv" | tr -d ' ')"
fi
if [ "$discovered_count" -lt 1 ]; then
  fail "D" "no jq fenced blocks discovered in SKILL.md (expected >=1)"
fi

# ==============================================================================
# Leg E: Recipe↔manifest set equality (bidirectional, equal counts, unique)
# ==============================================================================
# Parallel indexed arrays (Bash-3.2-portable map emulation):
#   discovered_keys[i]  → source tuple key
#   _disc_jqfiles[i]    → corresponding discovered jq file path
discovered_keys=()
_disc_jqfiles=()
if [ -f "$TMP_DIR/index.tsv" ]; then
  while IFS=$'\t' read -r dlevel dheading dordinal djqfile; do
    dkey="${dlevel}|${dheading}|${dordinal}"
    discovered_keys+=("$dkey")
    _disc_jqfiles+=("$djqfile")
  done < "$TMP_DIR/index.tsv"
fi

# Build manifest source-tuple set (parallel indexed arrays):
#   manifest_recipe_keys[i] → source tuple key
#   _mani_ids[i]            → corresponding manifest recipe id
manifest_recipe_keys=()
_mani_ids=()
for i in $(seq 0 $((recipe_count - 1))); do
  mheading="$(jq -r ".recipes[$i].source_heading" "$MANIFEST")"
  mlevel="$(jq -r ".recipes[$i].source_context_level" "$MANIFEST")"
  mordinal="$(jq -r ".recipes[$i].ordinal" "$MANIFEST")"
  mkey="${mlevel}|${mheading}|${mordinal}"
  mid="$(jq -r ".recipes[$i].id" "$MANIFEST")"
  manifest_recipe_keys+=("$mkey")
  _mani_ids+=("$mid")
done

# Equal counts
if [ "$discovered_count" -ne "$recipe_count" ]; then
  fail "E" "discovered ${discovered_count} jq blocks but manifest declares ${recipe_count} recipes (count mismatch)"
fi

# Discovered → manifest (no orphan discovered)
for dkey in "${discovered_keys[@]}"; do
  if ! _lookup_mani_id "$dkey" >/dev/null 2>&1; then
    fail "E" "discovered jq block '${dkey}' not registered in manifest (orphan discovered recipe)"
  fi
done

# Manifest → discovered (no orphan manifest recipe)
for mkey in "${manifest_recipe_keys[@]}"; do
  if ! _lookup_disc_jqfile "$mkey" >/dev/null 2>&1; then
    mid="$(_lookup_mani_id "$mkey")"
    fail "E" "manifest recipe '${mid}' (${mkey}) not found in SKILL.md (orphan manifest recipe)"
  fi
done

# ==============================================================================
# Leg F: Recipe execution — each jq recipe runs against its declared fixture
# ==============================================================================
for i in $(seq 0 $((recipe_count - 1))); do
  rid="$(jq -r ".recipes[$i].id" "$MANIFEST")"
  fixture_id="$(jq -r ".recipes[$i].fixture_id" "$MANIFEST")"
  mheading="$(jq -r ".recipes[$i].source_heading" "$MANIFEST")"
  mlevel="$(jq -r ".recipes[$i].source_context_level" "$MANIFEST")"
  mordinal="$(jq -r ".recipes[$i].ordinal" "$MANIFEST")"
  mkey="${mlevel}|${mheading}|${mordinal}"

  fixture_path="$(jq -r --arg fid "$fixture_id" '.fixtures[] | select(.id == $fid) | .relative_path' "$MANIFEST")"
  if [ -z "$fixture_path" ]; then
    fail "F" "recipe '${rid}' references fixture_id '${fixture_id}' not found in manifest fixtures"
    continue
  fi
  full_fixture="${FIXTURE_ROOT}/${fixture_path}"

  jq_file="$(_lookup_disc_jqfile "$mkey" || true)"
  if [ -z "$jq_file" ] || [ ! -s "$jq_file" ]; then
    fail "F" "recipe '${rid}' has no extracted jq file (key '${mkey}')"
    continue
  fi

  recipe_output_file="${TMP_DIR}/output_${rid}.json"
  if ! jq -s -f "$jq_file" "$full_fixture" > "$recipe_output_file" 2>"${TMP_DIR}/err_${rid}.txt"; then
    fail "F" "recipe '${rid}' failed: $(cat "${TMP_DIR}/err_${rid}.txt")"
    continue
  fi
done

# ==============================================================================
# Leg G: Recipe expectations — validate each manifest expectation
# ==============================================================================
for i in $(seq 0 $((recipe_count - 1))); do
  rid="$(jq -r ".recipes[$i].id" "$MANIFEST")"
  recipe_output_file="${TMP_DIR}/output_${rid}.json"
  [ -f "$recipe_output_file" ] || continue

  expectation="$(jq -r ".recipes[$i].expectation // empty" "$MANIFEST")"
  if [ -z "$expectation" ]; then
    fail "G" "recipe '${rid}' has no expectation in manifest"
    continue
  fi

  result="$(jq -r "$expectation" "$recipe_output_file" 2>"${TMP_DIR}/expect_err_${rid}.txt")" || true
  if [ "$result" != "true" ]; then
    fail "G" "recipe '${rid}' expectation failed (got '${result}'): ${expectation}"
  fi
done

# ==============================================================================
# Leg H: CLI native-record version link
# ==============================================================================
manifest_cli_version="$(jq -r '.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "") | .observed_cli_version' "$MANIFEST" | head -1)"
if [ -n "$manifest_cli_version" ]; then
  cli_fixture_path="$(jq -r '.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "") | .relative_path' "$MANIFEST" | head -1)"
  actual_version="$(head -1 "${FIXTURE_ROOT}/${cli_fixture_path}" | jq -r '.data.cliVersion // empty')"
  if [ "$actual_version" != "$manifest_cli_version" ]; then
    fail "H" "manifest CLI version '${manifest_cli_version}' != fixture first-event .data.cliVersion '${actual_version}'"
  fi
fi

# ==============================================================================
# Teeth: Mutation legs (skipped under recursion guard)
# ==============================================================================
if [ "${SKIP_RECURSIVE_MUTATIONS:-0}" != "1" ]; then

  SELF="${BASH_SOURCE[0]}"
  MUTANT_DIR="${TMP_DIR}/mutants"
  mkdir -p "$MUTANT_DIR"

  # --- T1: Append new jq fence → source-tuple set mismatch -------------------
  MUTANT_SKILL="${MUTANT_DIR}/skill-t1.md"
  cp "$SKILL_PATH" "$MUTANT_SKILL"
  cat >> "$MUTANT_SKILL" <<'EOF'

### Phantom recipe

```jq
{ phantom: true }
```
EOF
  if SKILL_PATH="$MUTANT_SKILL" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T1" "TEETH: sensor passes with an unregistered jq fence appended (set mismatch not detected)"
  fi

  # --- T2: Remove a recipe entry → orphan discovered recipe -------------------
  MUTANT_MANIFEST="${MUTANT_DIR}/manifest-t2.json"
  jq 'del(.recipes[0])' "$MANIFEST" > "$MUTANT_MANIFEST"
  if MANIFEST="$MUTANT_MANIFEST" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T2" "TEETH: sensor passes with a recipe entry removed from manifest"
  fi

  # --- T4: Change CLI fixture version → version cross-check -------------------
  MUTANT_FIXTURE_DIR="${MUTANT_DIR}/fixtures-t4"
  mkdir -p "$MUTANT_FIXTURE_DIR/tests/fixtures/copilot-log-review"
  cli_fixture_relpath="$(jq -r '.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "") | .relative_path' "$MANIFEST" | head -1)"
  if [ -n "$cli_fixture_relpath" ]; then
    while IFS= read -r fpath; do
      fdir="$(dirname "$fpath")"
      mkdir -p "${MUTANT_FIXTURE_DIR}/${fdir}"
      cp "${FIXTURE_ROOT}/${fpath}" "${MUTANT_FIXTURE_DIR}/${fpath}"
    done < <(jq -r '.fixtures[].relative_path' "$MANIFEST")
    # Mutate the CLI fixture version
    sed 's/"cliVersion":"1.0.72-1"/"cliVersion":"9.9.99"/' "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}" \
      > "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}.tmp" \
      && mv "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}.tmp" "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}"
    if FIXTURE_ROOT="$MUTANT_FIXTURE_DIR" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
      fail "T4" "TEETH: sensor passes with CLI fixture version changed"
    fi
  fi

  # --- T5: Add orphan manifest recipe (no SKILL.md block) → set mismatch -----
  MUTANT_MANIFEST5="${MUTANT_DIR}/manifest-t5.json"
  jq '.recipes += [{"id":"phantom-orphan","source_heading":"Nonexistent","source_context_level":"###","ordinal":1,"fixture_id":"sample-transcript","expectation":"true"}]' "$MANIFEST" > "$MUTANT_MANIFEST5"
  if MANIFEST="$MUTANT_MANIFEST5" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T5" "TEETH: sensor passes with an orphan recipe entry in manifest"
  fi

  # --- T7: Duplicate a recipe ID and source tuple → uniqueness failure --------
  MUTANT_MANIFEST7="${MUTANT_DIR}/manifest-t7.json"
  jq '.recipes += [.recipes[0]]' "$MANIFEST" > "$MUTANT_MANIFEST7"
  if MANIFEST="$MUTANT_MANIFEST7" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T7" "TEETH: sensor passes with duplicate recipe ID/source tuple"
  fi

  # --- T9: Set ordinal to 1.5 — structural validation must catch non-integer --
  MUTANT_MANIFEST9="${MUTANT_DIR}/manifest-t9.json"
  jq '.recipes[0].ordinal = 1.5' "$MANIFEST" > "$MUTANT_MANIFEST9"
  if MANIFEST="$MUTANT_MANIFEST9" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T9" "TEETH: sensor passes with ordinal=1.5 (integer validation not enforced)"
  fi

  # --- T10: Remove fixture surface field — structural validation must catch ---
  MUTANT_MANIFEST10="${MUTANT_DIR}/manifest-t10.json"
  jq '.fixtures[0].surface = null' "$MANIFEST" > "$MUTANT_MANIFEST10"
  if MANIFEST="$MUTANT_MANIFEST10" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T10" "TEETH: sensor passes with fixture surface removed (structural type check not enforced)"
  fi
fi

# ==============================================================================
# Final verdict
# ==============================================================================
if [ "${fails}" -ne 0 ]; then
  printf '\n%d fixture-recipe-smoke-doc-consistency obligation(s) failed.\n' "$fails" >&2
  exit 1
fi

printf 'PASS: fixture-recipe-smoke-doc-consistency — all native-record recipes, fixtures, and versions are consistent.\n'
)
