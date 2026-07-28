#!/usr/bin/env bash
# verify-sensor-evidence.sh — validate script-recorded sensor evidence
# (issue #441 F2, companion to the run-sensors.sh recorder).
#
# Usage:
#   scripts/verify-sensor-evidence.sh <issue> [--head <sha>] [--mode <label>]
#
# Checks, over <main-root>/.copilot-tracking/issues/issue-NN/sensor-evidence.jsonl:
#   * every row is valid JSON with schema_version 1 and the recorder fields;
#   * every row's checksum recomputes from the canonical fields
#     "v1|head|mode|scope|ran|failed|timestamp" — tamper-EVIDENT, not
#     tamper-proof: it catches hand-edited bookkeeping, not a determined forger;
#   * with --head: at least one green (failed=0, ran>0) row is bound to that
#     sha (further restricted to --mode's label when given).
#
# Exit: 0 all checks pass · 1 verification failure / missing file · 2 usage.
set -euo pipefail

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }

ISSUE_RAW="${1:-}"
[ -n "$ISSUE_RAW" ] || { usage; exit 2; }
shift
[[ "$ISSUE_RAW" =~ ^[0-9]+$ ]] || { usage; exit 2; }

HEAD_WANT=""
MODE_WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) HEAD_WANT="${2:-}"; [ -n "$HEAD_WANT" ] || { usage; exit 2; }; shift 2 ;;
    --mode) MODE_WANT="${2:-}"; [ -n "$MODE_WANT" ] || { usage; exit 2; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 \
  || { printf 'verify-sensor-evidence: jq is required\n' >&2; exit 1; }

sha256_of() { # <canonical-string> → hex digest on stdout
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  else
    return 1
  fi
}

main_root() {
  local common=""
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *)  common="$(pwd)/$common" ;;
  esac
  (cd "$(dirname "$common")" 2>/dev/null && pwd -P) || return 1
}

ROOT="$(main_root)" \
  || { printf 'verify-sensor-evidence: cannot resolve the main checkout root\n' >&2; exit 1; }
PAD="$(printf '%02d' "$((10#$ISSUE_RAW))")"
EVIDENCE="${ROOT}/.copilot-tracking/issues/issue-${PAD}/sensor-evidence.jsonl"

[ -f "$EVIDENCE" ] \
  || { printf 'verify-sensor-evidence: FAIL no evidence file at %s\n' "$EVIDENCE" >&2; exit 1; }

line_no=0
bad=0
head_match=0
while IFS= read -r row; do
  line_no=$((line_no + 1))
  [ -n "$row" ] || continue
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$row"; then
    printf 'verify-sensor-evidence: FAIL line %d is not a JSON object\n' "$line_no" >&2
    bad=$((bad + 1)); continue
  fi
  fields="$(jq -r '[
      (.schema_version | tostring),
      (.head // ""), (.mode // ""), (.scope // ""),
      (.ran | tostring), (.failed | tostring),
      (.timestamp // ""), (.checksum // "")
    ] | @tsv' <<<"$row" 2>/dev/null)" || fields=""
  IFS=$'\t' read -r schema head mode scope ran failed ts checksum <<<"$fields"
  if [ "$schema" != "1" ] || [ -z "$head" ] || [ -z "$mode" ] || [ -z "$scope" ] \
    || [ -z "$ran" ] || [ -z "$failed" ] || [ -z "$ts" ] || [ -z "$checksum" ]; then
    printf 'verify-sensor-evidence: FAIL line %d missing recorder fields\n' "$line_no" >&2
    bad=$((bad + 1)); continue
  fi
  canonical="v1|${head}|${mode}|${scope}|${ran}|${failed}|${ts}"
  want="sha256:$(sha256_of "$canonical")" \
    || { printf 'verify-sensor-evidence: no sha256 tool available\n' >&2; exit 1; }
  if [ "$checksum" != "$want" ]; then
    printf 'verify-sensor-evidence: FAIL line %d checksum mismatch (hand-edited row?)\n' \
      "$line_no" >&2
    bad=$((bad + 1)); continue
  fi
  if [ -n "$HEAD_WANT" ] && [ "$head" = "$HEAD_WANT" ] && [ "$failed" = "0" ] \
    && [ "$ran" != "0" ]; then
    if [ -z "$MODE_WANT" ] || [ "$mode" = "$MODE_WANT" ]; then
      head_match=1
    fi
  fi
done < "$EVIDENCE"

if [ "$bad" -gt 0 ]; then
  printf 'verify-sensor-evidence: FAIL %d invalid row(s) in %s\n' "$bad" "$EVIDENCE" >&2
  exit 1
fi
if [ -n "$HEAD_WANT" ] && [ "$head_match" -ne 1 ]; then
  printf 'verify-sensor-evidence: FAIL no green row bound to head %s%s\n' \
    "$HEAD_WANT" "${MODE_WANT:+ (mode ${MODE_WANT})}" >&2
  exit 1
fi
printf 'verify-sensor-evidence: OK %d row(s) verified%s\n' \
  "$line_no" "${HEAD_WANT:+, green evidence present for ${HEAD_WANT}}"
exit 0
