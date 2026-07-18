#!/usr/bin/env bash
# test_copilot_log_review_recipes.sh — regression sensor for issue #306,
# feature log-review-recipes: the copilot-log-review SKILL.md ships executable
# jq Quantify recipes, and they compute correct (never negative) tool durations
# when run against a committed synthetic transcript fixture.
#
# The sensor EXTRACTS the shipped jq programs from the SKILL.md fenced ```jq
# blocks (rather than hardcoding a copy) so it pins the recipes that actually
# ship, then runs them with `jq -s` on the fixture.
#
# Legs:
#   A (durations-recipe)  The ```jq block under "### Tool durations" exists,
#                         runs, and yields one duration per tool call, every
#                         duration >= 0 (the pair-by-toolCallId guarantee), with
#                         the summed duration matching the fixture's known good
#                         total (30s). A naive sort_by(.type) pairing on the same
#                         fixture produces negatives, so this leg has teeth.
#   B (inventory-recipe)  The ```jq block under "### Session inventory" exists,
#                         runs, and reports the fixture's known good inventory
#                         (tool_count 5, user_messages 1, assistant_turns 1,
#                         span_s 42).
#
# Exit: 0 both legs pass · 1 any obligation missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
    fail "A: durations recipe failed to run: $(cat "${TMP_DIR}/dur.err")"
  elif [ -z "${dur_json}" ] || [ "${dur_json}" = "null" ]; then
    fail "A: durations recipe produced no output"
  else
    count="$(printf '%s' "${dur_json}" | jq '[.[].duration_s] | length')"
    min="$(printf '%s' "${dur_json}" | jq '[.[].duration_s] | min')"
    total="$(printf '%s' "${dur_json}" | jq '[.[].duration_s] | add')"
    if [ "${count}" != "5" ]; then
      fail "A: expected 5 tool durations, got '${count}'"
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
    if [ "${tool_count}" != "5" ]; then
      fail "B: inventory tool_count expected 5, got '${tool_count}'"
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

if [ "${fails}" -ne 0 ]; then
  printf '\n%d copilot-log-review Quantify recipe obligation(s) failed.\n' "${fails}" >&2
  exit 1
fi
printf 'copilot-log-review Quantify recipes: durations non-negative (sum 30s) and inventory verified against the fixture\n'
