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
