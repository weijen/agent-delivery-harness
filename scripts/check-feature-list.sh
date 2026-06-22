#!/usr/bin/env bash
# check-feature-list.sh — minimal, reusable feature-list completion check.
#
# Validates a per-issue .copilot-tracking/issues/issue-NN/feature_list.json:
#   * the file exists, is valid JSON, and is a JSON object;
#   * each .features[] item has id, title, steps (array), and passes (boolean);
#   * any passes:true feature carries non-empty verification text.
#
# Completion reporting matches finish-issue.sh:
#   * default mode: incomplete (passes:false) features are a NON-BLOCKING warning;
#   * REQUIRE_FEATURES_COMPLETE=1: incomplete features are a hard failure.
#
# It is deliberately generic to the harness: it does not read project docs,
# devcontainer, CI, or sensor registries, and never executes anything from the
# feature list.
#
# Usage:
#   ./scripts/check-feature-list.sh 31
#   ./scripts/check-feature-list.sh ISSUE=31
#   ./scripts/check-feature-list.sh 31 SLUG=custom-slug   # slug is irrelevant to
#                                                          # resolution but accepted
#
# Exit codes: 0 ok (or warning-only) · 1 usage / invalid / hard-fail

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

# --- Parse args -------------------------------------------------------------
NUM_ARG="" SLUG_ARG=""
for arg in "$@"; do
  case "$arg" in
    SLUG=*) SLUG_ARG="${arg#SLUG=}" ;;
    *)      NUM_ARG="$arg" ;;
  esac
done
if [ -z "$NUM_ARG" ]; then
  red "usage: ./scripts/check-feature-list.sh <issue-number> [SLUG=custom-slug]"
  exit 1
fi
ISSUE_NUM="$(issue_parse_number "$NUM_ARG")"

if ! command -v jq >/dev/null 2>&1; then
  yellow "  ! jq not installed — skipping feature-list check"
  exit 0
fi

resolve_issue_env "$ISSUE_NUM" "$SLUG_ARG"
feature_list="${TRACKING_DIR}/feature_list.json"

if [ ! -f "$feature_list" ]; then
  red "✗ feature_list.json not found at ${feature_list}"
  exit 1
fi

# --- Structural validation --------------------------------------------------
if ! jq empty "$feature_list" >/dev/null 2>&1; then
  red "✗ ${feature_list} is not valid JSON"
  exit 1
fi

if [ "$(jq -r 'type' "$feature_list")" != "object" ]; then
  red "✗ ${feature_list} must be a JSON object"
  exit 1
fi

# .features must be an array when present; default to [] when absent.
features_type="$(jq -r 'if has("features") then (.features | type) else "array" end' "$feature_list")"
if [ "$features_type" != "array" ]; then
  red "✗ ${feature_list}: .features must be an array"
  exit 1
fi

# Per-feature field validation. jq emits one diagnostic line per problem; an
# empty result means every feature is well formed.
problems="$(jq -r '
  .features // []
  | to_entries[]
  | .key as $i | .value as $f
  | [
      (if ($f | has("id"))    and (($f.id    | type) == "string") and (($f.id | length) > 0) then empty else "feature[\($i)]: missing or empty string field: id" end),
      (if ($f | has("title")) and (($f.title | type) == "string") and (($f.title | length) > 0) then empty else "feature[\($i)]: missing or empty string field: title" end),
      (if ($f | has("steps")) and (($f.steps | type) == "array") then empty else "feature[\($i)]: missing field or non-array: steps" end),
      (if ($f | has("passes")) and (($f.passes | type) == "boolean") then empty else "feature[\($i)]: missing field or non-boolean: passes" end),
      (if (($f.passes // false) == true) and (((($f.verification // "") | type) != "string") or ((($f.verification // "") | gsub("\\s";"") | length) == 0)) then "feature[\($i)]: passes:true requires non-empty verification text" else empty end)
    ]
  | .[]
' "$feature_list")"

if [ -n "$problems" ]; then
  red "✗ ${feature_list} has invalid feature entries:"
  while IFS= read -r line; do
    [ -n "$line" ] && red "  - ${line}"
  done <<<"$problems"
  exit 1
fi

# --- Completion state -------------------------------------------------------
incomplete_count="$(jq '[.features[]? | select(.passes != true)] | length' "$feature_list")"
if [ "$incomplete_count" -gt 0 ]; then
  if [ "${REQUIRE_FEATURES_COMPLETE:-0}" = "1" ]; then
    red "✗ ${incomplete_count} incomplete feature_list items remain."
    echo "  Set each completed feature to passes:true before finishing, or unset REQUIRE_FEATURES_COMPLETE for warning mode."
    exit 1
  fi
  yellow "  ! ${incomplete_count} incomplete feature_list items remain (warning only)."
  echo "    → Set REQUIRE_FEATURES_COMPLETE=1 to make this a hard gate."
  exit 0
fi

green "✓ feature_list.json is valid and all features are complete (passes:true)."
