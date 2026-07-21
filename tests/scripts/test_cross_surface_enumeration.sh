#!/usr/bin/env bash
# test_cross_surface_enumeration.sh — regression sensor for issue #319
# feature cross-surface-enumeration.
#
# Contract under test: docs/runtime-adapters/github-copilot.md carries a
# dedicated "## Cross-surface record enumeration" section documenting portable
# enumeration of two independent Copilot record surfaces with event-timestamp
# interval overlap filtering and honest cross-surface association status.
#
# Sensor legs (28 total, 4 mutation-exec):
#   A: Heading "## Cross-surface record enumeration" exists
#   B: Section names VS Code workspaceStorage transcript path
#   C: Section names CLI session-state/events.jsonl path
#   D: Section names CLI session-store.db (as shortlist/index, not hardcoded join)
#   E: Section contains START_EPOCH and END_EPOCH numeric window variables
#   F: Section contains all three status labels (verified, unverified,
#      community-assumed)
#   G: Section carries explicit no-equivalence / no cross-surface join caveat
#   H: Section cites copilot-cli #2186 (cross-client session issue)
#   I: Section warns service.name is not a session join key
#   J: Section documents service.name disambiguation role (producer/surface)
#   K: Section mentions service.name observed value "github-copilot"
#   L: Section carries "community-assumed" for terminal UUID sharing claim
#   M: NEGATIVE — section must NOT assert cross-surface sessionId equality as
#      verified
#   N: Section must NOT use -newermt (GNU-only, not portable to macOS/BSD)
#   O: Section uses -print0 for safe path handling
#   P: Section performs timestamp extraction/interval overlap (jq + fromdateiso8601)
#   Q: Section provides overridable roots (COPILOT_CLI_STATE_ROOT /
#      COPILOT_VSCODE_STORAGE_ROOT)
#   R: Exact OTel citation to docs/monitoring/agent_monitoring.md
#   S: Temporal overlap row says "candidate association" not "identity proof"
#   T: TEETH (mutation exec) — injecting cross-surface join assertion fails child
#   U: TEETH (mutation exec) — removing all "unverified" labels fails child
#   V: TEETH (execution) — extracted recipe produces correct candidates
#      from synthetic fixture (inside-window CLI+VS Code appear; outside-window,
#      missing-timestamp, and malformed-timestamp files excluded; each absent
#      yields stderr WARNING naming the file)
#   W: TEETH (mutation exec) — re-injecting -newermt into recipe fails child
#   X: Prerequisites say bash ≥3.2 (not 4.0) and find with -print0 (not POSIX)
#   Y: Normalization anchored: sub("\\.[0-9]+Z$"; "Z") present
#   Z: Both find commands use -type f
#   AA: Recipe distinguishes malformed-timestamp (WARNING) from outside-window
#       (silent)
#
# Environment overrides (test-only):
#   DOC — path to the adapter doc; defaults to the production path.
#   SKIP_RECURSIVE_MUTATIONS — when set to "1", skip mutation/execution legs
#       (prevents infinite recursion when this sensor is invoked on a mutant).
#
# Exit codes: 0 all pass · 1 any obligation fails (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${DOC:-${ROOT}/docs/runtime-adapters/github-copilot.md}"

fails=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  fails=$((fails + 1))
}
note() {
  printf 'ok   [%s]: %s\n' "$1" "$2"
}

[ -f "$DOC" ] || { fail "pre" "adapter doc not found at ${DOC}"; exit 1; }

# --- Extract the cross-surface enumeration section ----------------------------
SECTION="$(sed -n '/^##[[:space:]]*Cross-surface record enumeration/,/^##[[:space:]]/{
  /^##[[:space:]]*Cross-surface record enumeration/p
  /^##[[:space:]]/!p
}' "$DOC")"

# --- Leg A: Heading exists ----------------------------------------------------
if [ -z "$SECTION" ]; then
  fail "A" "heading '## Cross-surface record enumeration' not found in doc"
  printf '\n%d obligation(s) failed.\n' "$fails" >&2
  exit 1
fi
note "A" "heading present"

# --- Leg B: VS Code workspaceStorage transcript path --------------------------
if printf '%s\n' "$SECTION" | grep -q 'workspaceStorage'; then
  note "B" "VS Code workspaceStorage path referenced"
else
  fail "B" "section must reference VS Code workspaceStorage transcript path"
fi

# --- Leg C: CLI session-state/events.jsonl path -------------------------------
if printf '%s\n' "$SECTION" | grep -q 'session-state' \
   && printf '%s\n' "$SECTION" | grep -q 'events\.jsonl'; then
  note "C" "CLI session-state/events.jsonl path referenced"
else
  fail "C" "section must reference CLI session-state and events.jsonl"
fi

# --- Leg D: CLI session-store.db (shortlist, not hardcoded join) --------------
if printf '%s\n' "$SECTION" | grep -q 'session-store\.db'; then
  if printf '%s\n' "$SECTION" | grep -qiE 'shortlist|index|inspect|undocumented|version-scoped'; then
    note "D" "CLI session-store.db referenced as shortlist/index (not hardcoded join)"
  else
    fail "D" "session-store.db must be described as shortlist/index after schema inspection, not hardcoded join"
  fi
else
  fail "D" "section must reference CLI session-store.db"
fi

# --- Leg E: START_EPOCH and END_EPOCH numeric window --------------------------
if printf '%s\n' "$SECTION" | grep -q 'START_EPOCH' \
   && printf '%s\n' "$SECTION" | grep -q 'END_EPOCH'; then
  note "E" "START_EPOCH and END_EPOCH numeric window variables present"
else
  fail "E" "section must use START_EPOCH and END_EPOCH (numeric UTC seconds)"
fi

# --- Leg F: All three status labels present -----------------------------------
has_verified=0; has_unverified=0; has_community=0
printf '%s\n' "$SECTION" | grep -qw 'verified' && has_verified=1
printf '%s\n' "$SECTION" | grep -qw 'unverified' && has_unverified=1
printf '%s\n' "$SECTION" | grep -q 'community-assumed' && has_community=1
if [ "$has_verified" -eq 1 ] && [ "$has_unverified" -eq 1 ] && [ "$has_community" -eq 1 ]; then
  note "F" "all three status labels present (verified, unverified, community-assumed)"
else
  fail "F" "section must contain all three status labels: verified, unverified, community-assumed (got: v=${has_verified} u=${has_unverified} c=${has_community})"
fi

# --- Leg G: Explicit no-equivalence caveat ------------------------------------
if printf '%s\n' "$SECTION" | grep -qiE 'no.*equivalence|not.*assume.*equal|no.*cross-surface.*(join|mapping|identity)|do not assume'; then
  note "G" "explicit no-equivalence caveat present"
else
  fail "G" "section must carry explicit no-equivalence / no cross-surface identity caveat"
fi

# --- Leg H: Citation of copilot-cli #2186 -------------------------------------
if printf '%s\n' "$SECTION" | grep -q '2186'; then
  note "H" "copilot-cli #2186 cited"
else
  fail "H" "section must cite copilot-cli #2186 (cross-client session sharing issue)"
fi

# --- Leg I: service.name is not a session join key ----------------------------
if printf '%s\n' "$SECTION" | grep -qiE 'service\.name' \
   && printf '%s\n' "$SECTION" | grep -qiE 'not.*(join key|session join|join.*key)'; then
  note "I" "service.name not-a-join-key warning present"
else
  fail "I" "section must warn that service.name is not a session join key"
fi

# --- Leg J: service.name disambiguation role ----------------------------------
if printf '%s\n' "$SECTION" | grep -qiE 'service\.name' \
   && printf '%s\n' "$SECTION" | grep -qiE 'disambiguat|producer|surface'; then
  note "J" "service.name disambiguation/producer role documented"
else
  fail "J" "section must document service.name disambiguation role (producer/surface)"
fi

# --- Leg K: service.name observed value "github-copilot" ----------------------
if printf '%s\n' "$SECTION" | grep -q 'github-copilot'; then
  note "K" "service.name observed value 'github-copilot' present"
else
  fail "K" "section must mention service.name observed value 'github-copilot'"
fi

# --- Leg L: community-assumed for terminal UUID sharing claim -----------------
if printf '%s\n' "$SECTION" | grep -qiE 'terminal|shared.*UUID|UUID.*shar' \
   && printf '%s\n' "$SECTION" | grep -q 'community-assumed'; then
  note "L" "terminal UUID sharing marked community-assumed"
else
  fail "L" "section must mark terminal-started UUID sharing claim as community-assumed"
fi

# --- Leg M: NEGATIVE — must NOT assert cross-surface sessionId equality -------
NORMALIZED_SECTION="$(printf '%s\n' "$SECTION" | tr '\n' ' ')"
if printf '%s' "$NORMALIZED_SECTION" | grep -qiE 'VS Code sessionId (equals|==|is identical to|is the same as) CLI sessionId.*(verified|proven|confirmed)'; then
  fail "M" "section must NOT assert cross-surface sessionId equality as verified"
else
  note "M" "no false cross-surface equality assertion"
fi

# --- Leg N: Must NOT use -newermt (GNU-only) ----------------------------------
if printf '%s\n' "$SECTION" | grep -q '\-newermt'; then
  fail "N" "section must NOT use -newermt (GNU-only; not portable to macOS/BSD)"
else
  note "N" "no -newermt usage (portable)"
fi

# --- Leg O: Uses -print0 for safe path handling -------------------------------
if printf '%s\n' "$SECTION" | grep -q '\-print0'; then
  note "O" "-print0 used for safe path handling"
else
  fail "O" "section must use -print0 for null-delimited safe path enumeration"
fi

# --- Leg P: Timestamp extraction/interval overlap (jq + fromdateiso8601) ------
if printf '%s\n' "$SECTION" | grep -q 'fromdateiso8601' \
   && printf '%s\n' "$SECTION" | grep -qiE 'overlap|first.*last|min.*max|last.*>=.*start'; then
  note "P" "timestamp extraction with interval overlap via jq/fromdateiso8601"
else
  fail "P" "section must perform timestamp extraction/interval overlap using jq fromdateiso8601"
fi

# --- Leg Q: Overridable roots -------------------------------------------------
if printf '%s\n' "$SECTION" | grep -q 'COPILOT_CLI_STATE_ROOT' \
   && printf '%s\n' "$SECTION" | grep -q 'COPILOT_VSCODE_STORAGE_ROOT'; then
  note "Q" "overridable roots COPILOT_CLI_STATE_ROOT and COPILOT_VSCODE_STORAGE_ROOT present"
else
  fail "Q" "section must provide COPILOT_CLI_STATE_ROOT and COPILOT_VSCODE_STORAGE_ROOT overrides"
fi

# --- Leg R: Exact OTel citation -----------------------------------------------
if printf '%s\n' "$SECTION" | grep -q 'https://github.com/microsoft/vscode-copilot-chat/blob/main/docs/monitoring/agent_monitoring.md'; then
  note "R" "exact OTel citation to docs/monitoring/agent_monitoring.md"
else
  fail "R" "section must cite exact URL: https://github.com/microsoft/vscode-copilot-chat/blob/main/docs/monitoring/agent_monitoring.md"
fi

# --- Leg S: Temporal overlap = candidate association, not identity proof -------
if printf '%s\n' "$SECTION" | grep -qiE 'candidate.*(association|only)|association.*only|not.*identity.*proof'; then
  note "S" "temporal overlap correctly labeled candidate association (not identity proof)"
else
  fail "S" "temporal overlap row must say 'candidate association' not 'identity proof'"
fi

# --- Leg X: Prerequisites say bash ≥3.2 and find with -print0 (not POSIX) ----
x_pass=true
if ! printf '%s\n' "$SECTION" | grep -qiE 'bash.*(3\.2|≥.*3\.2|>=.*3\.2)'; then
  fail "X" "prerequisites must state bash ≥3.2 (not 4.0) for macOS default compatibility"
  x_pass=false
fi
if printf '%s\n' "$SECTION" | grep -qiE 'POSIX.*find'; then
  fail "X" "prerequisites must NOT claim POSIX find (-print0 is not POSIX)"
  x_pass=false
fi
if ! printf '%s\n' "$SECTION" | grep -qiE 'find.*-print0.*(BSD|macOS|GNU)|BSD.*find|macOS.*find'; then
  fail "X" "prerequisites must note find -print0 available in macOS BSD find and GNU find"
  x_pass=false
fi
if [ "$x_pass" = true ]; then
  note "X" "prerequisites correctly state bash ≥3.2 and find with -print0 (BSD/GNU)"
fi

# --- Leg Y: Normalization anchored with \\.[0-9]+Z$ --------------------------
if printf '%s\n' "$SECTION" | grep -qF '\.[0-9]+Z$'; then
  note "Y" "normalization uses anchored sub(\"\\\\.[0-9]+Z\$\"; \"Z\")"
else
  fail "Y" "normalization must use anchored pattern \\.[0-9]+Z\$ (strip fractional only before trailing Z)"
fi

# --- Leg Z: Both find commands use -type f ------------------------------------
find_lines="$(printf '%s\n' "$SECTION" | grep -c '\-type f' || true)"
if [ "$find_lines" -ge 2 ]; then
  note "Z" "both find commands use -type f"
else
  fail "Z" "both find expressions must include -type f (found ${find_lines})"
fi

# --- Leg AA: Recipe distinguishes malformed (WARNING) from outside-window -----
if printf '%s\n' "$SECTION" | grep -qiE 'malformed|parse failure|no valid timestamps' \
   && printf '%s\n' "$SECTION" | grep -qiE 'WARNING|warn'; then
  note "AA" "recipe documents WARNING for malformed/missing timestamps (distinct from silent outside-window)"
else
  fail "AA" "recipe must distinguish malformed timestamps (WARNING + skip) from valid outside-window (silent)"
fi

# --- Legs T-W: TEETH via mutation & execution (skip in recursive child) -------
if [ "${SKIP_RECURSIVE_MUTATIONS:-0}" != "1" ]; then

  SELF="${BASH_SOURCE[0]}"
  MUTANT_DIR=""
  FIXTURE_DIR=""
  cleanup_all() { [ -n "$MUTANT_DIR" ] && rm -rf "$MUTANT_DIR"; [ -n "$FIXTURE_DIR" ] && rm -rf "$FIXTURE_DIR"; }
  trap cleanup_all EXIT

  MUTANT_DIR="$(mktemp -d)"
  FIXTURE_DIR="$(mktemp -d)"

  # --- Leg T: TEETH — inject unqualified cross-surface join assertion ----------
  MUTANT_T="${MUTANT_DIR}/mutant-t.md"
  sed '/^##[[:space:]]*Cross-surface record enumeration/a\
VS Code sessionId equals CLI sessionId and is a verified cross-surface join.' "$DOC" > "$MUTANT_T"

  if DOC="$MUTANT_T" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T" "TEETH: sensor passes on mutant with unqualified cross-surface join assertion"
  else
    note "T" "TEETH: mutant with cross-surface join assertion correctly rejected"
  fi

  # --- Leg U: TEETH — remove all "unverified" labels ---------------------------
  MUTANT_U="${MUTANT_DIR}/mutant-u.md"
  sed 's/unverified//g' "$DOC" > "$MUTANT_U"

  if DOC="$MUTANT_U" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "U" "TEETH: sensor passes on mutant with all 'unverified' labels removed"
  else
    note "U" "TEETH: mutant without 'unverified' labels correctly rejected"
  fi

  # --- Leg V: TEETH (execution) — extracted recipe produces correct output -----
  # Create synthetic fixture directories with spaces in paths.
  CLI_ROOT="${FIXTURE_DIR}/cli state root"
  VSCODE_ROOT="${FIXTURE_DIR}/vs code storage"
  mkdir -p "${CLI_ROOT}/session-inside/""" "${CLI_ROOT}/session-outside/"
  mkdir -p "${VSCODE_ROOT}/hash abc/GitHub.copilot-chat/transcripts"
  mkdir -p "${VSCODE_ROOT}/hash xyz/GitHub.copilot-chat/transcripts"

  # Window: 1000 .. 2000 (epoch seconds)
  TEST_START=1000
  TEST_END=2000

  # CLI inside-window: timestamps 1200..1500
  printf '{"timestamp":"1970-01-01T00:20:00.123Z","data":"a"}\n{"timestamp":"1970-01-01T00:25:00Z","data":"b"}\n' \
    > "${CLI_ROOT}/session-inside/events.jsonl"

  # CLI outside-window: timestamps 500..600
  printf '{"timestamp":"1970-01-01T00:08:20Z","data":"c"}\n{"timestamp":"1970-01-01T00:10:00Z","data":"d"}\n' \
    > "${CLI_ROOT}/session-outside/events.jsonl"

  # VS Code inside-window: timestamps 1800..1900
  printf '{"timestamp":"1970-01-01T00:30:00.456Z","data":"e"}\n{"timestamp":"1970-01-01T00:31:40Z","data":"f"}\n' \
    > "${VSCODE_ROOT}/hash abc/GitHub.copilot-chat/transcripts/vscode-sess-in.jsonl"

  # VS Code outside-window: timestamps 3000..3100
  printf '{"timestamp":"1970-01-01T00:50:00Z","data":"g"}\n{"timestamp":"1970-01-01T00:51:40Z","data":"h"}\n' \
    > "${VSCODE_ROOT}/hash xyz/GitHub.copilot-chat/transcripts/vscode-sess-out.jsonl"

  # Invalid-timestamp file (no parseable timestamp field)
  mkdir -p "${CLI_ROOT}/session-no-ts/"
  printf '{"message":"no timestamp here"}\n{"other":"still none"}\n' \
    > "${CLI_ROOT}/session-no-ts/events.jsonl"

  # Malformed-timestamp-string file (has .timestamp but value is not ISO 8601)
  mkdir -p "${CLI_ROOT}/session-malformed/"
  printf '{"timestamp":"not-a-date","data":"x"}\n{"timestamp":"also garbage","data":"y"}\n' \
    > "${CLI_ROOT}/session-malformed/events.jsonl"

  # Extract the recipe code block from the doc (deterministic: heading anchor)
  # shellcheck disable=SC2016 # sed address pattern is intentionally literal, not a shell expansion
  RECIPE_BLOCK="$(sed -n '/^#### Cross-surface enumeration recipe/,/^####\|^###\|^##/{
    /^```bash/,/^```/{
      /^```bash/d
      /^```/d
      p
    }
  }' "$DOC")"

  if [ -z "$RECIPE_BLOCK" ]; then
    fail "V" "could not extract recipe code block from doc (need '#### Cross-surface enumeration recipe' + bash fence)"
  else
    RECIPE_SCRIPT="${MUTANT_DIR}/recipe.sh"
    printf '%s\n' "$RECIPE_BLOCK" > "$RECIPE_SCRIPT"
    chmod +x "$RECIPE_SCRIPT"

    # Execute with overridden roots and window
    RECIPE_OUT="${MUTANT_DIR}/recipe-out.tsv"
    RECIPE_ERR="${MUTANT_DIR}/recipe-err.txt"
    if COPILOT_CLI_STATE_ROOT="$CLI_ROOT" \
       COPILOT_VSCODE_STORAGE_ROOT="$VSCODE_ROOT" \
       START_EPOCH="$TEST_START" END_EPOCH="$TEST_END" \
       bash "$RECIPE_SCRIPT" > "$RECIPE_OUT" 2> "$RECIPE_ERR"; then

      v_pass=true

      # Assert CLI inside-window candidate appears
      if ! grep -q $'cli\tsession-inside' "$RECIPE_OUT"; then
        fail "V" "recipe did not emit CLI inside-window candidate (session-inside)"
        v_pass=false
      fi

      # Assert VS Code inside-window candidate appears
      if ! grep -q $'vscode\tvscode-sess-in' "$RECIPE_OUT"; then
        fail "V" "recipe did not emit VS Code inside-window candidate (vscode-sess-in)"
        v_pass=false
      fi

      # Assert outside-window candidates do NOT appear
      if grep -q 'session-outside' "$RECIPE_OUT"; then
        fail "V" "recipe incorrectly emitted CLI outside-window candidate"
        v_pass=false
      fi
      if grep -q 'vscode-sess-out' "$RECIPE_OUT"; then
        fail "V" "recipe incorrectly emitted VS Code outside-window candidate"
        v_pass=false
      fi

      # Assert invalid-timestamp (no field) candidate does NOT appear
      if grep -q 'session-no-ts' "$RECIPE_OUT"; then
        fail "V" "recipe incorrectly emitted missing-timestamp candidate"
        v_pass=false
      fi

      # Assert malformed-timestamp candidate does NOT appear
      if grep -q 'session-malformed' "$RECIPE_OUT"; then
        fail "V" "recipe incorrectly emitted malformed-timestamp candidate"
        v_pass=false
      fi

      # Assert missing-timestamp yields stderr warning naming the file
      if ! grep -qi 'warning.*session-no-ts\|skip.*session-no-ts' "$RECIPE_ERR"; then
        fail "V" "recipe did not emit stderr warning for missing-timestamp file (session-no-ts)"
        v_pass=false
      fi

      # Assert malformed-timestamp yields stderr warning naming the file
      if ! grep -qi 'warning.*session-malformed\|skip.*session-malformed' "$RECIPE_ERR"; then
        fail "V" "recipe did not emit stderr warning for malformed-timestamp file (session-malformed)"
        v_pass=false
      fi

      if [ "$v_pass" = true ]; then
        note "V" "TEETH: extracted recipe produces correct candidates from synthetic fixture"
      fi
    else
      fail "V" "recipe execution failed (exit $?): $(cat "$RECIPE_ERR")"
    fi
  fi

  # --- Leg W: TEETH (mutation) — re-injecting -newermt into recipe fails child -
  MUTANT_W="${MUTANT_DIR}/mutant-w.md"
  sed 's/-print0/-newermt "2020-01-01" -print0/' "$DOC" > "$MUTANT_W"

  if DOC="$MUTANT_W" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "W" "TEETH: sensor passes on mutant with -newermt re-injected"
  else
    note "W" "TEETH: mutant with -newermt re-injected correctly rejected"
  fi

fi

# --- Summary ------------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  printf '\n%d obligation(s) failed.\n' "$fails" >&2
  exit 1
fi

printf 'OK: all cross-surface enumeration obligations pass (28 legs, 4 mutation/execution assertions).\n'
