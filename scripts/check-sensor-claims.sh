#!/usr/bin/env bash
# Detect unsupported passed-file claims and the direct multi-glob bash footgun.
set -euo pipefail

usage() {
  printf 'usage: check-sensor-claims.sh <transcript-path> [head-sha]\n' >&2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
TRANSCRIPT="$1"
HEAD_SHA="${2:-}"
[ -r "$TRANSCRIPT" ] || {
  printf 'check-sensor-claims.sh: transcript is not readable: %s\n' "$TRANSCRIPT" >&2
  exit 2
}
if [ -z "$HEAD_SHA" ]; then
  HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)" || {
    printf 'check-sensor-claims.sh: cannot resolve current HEAD\n' >&2
    exit 2
  }
fi
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || {
  printf 'check-sensor-claims.sh: invalid HEAD: %s\n' "$HEAD_SHA" >&2
  exit 2
}

summary_re='^SENSORS (green|green-full-fallback|pre-review|pre-pr) head=([0-9a-f]{40}|[0-9a-f]{64}) scope=(scoped|full) ran=([0-9]+) failed=([0-9]+)$'
claim_re='([0-9]+)[[:space:]]+test[[:space:]]+files'
glob_re='bash([[:space:]]+-[^[:space:]]+)*[[:space:]]+(\./)?tests/(scripts|meta)/test_\*\.sh'
summaries=()
claims=()
violations=0

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ $summary_re ]] && [ "${BASH_REMATCH[5]}" = "0" ]; then
    summaries+=("${BASH_REMATCH[2]}:${BASH_REMATCH[4]}")
  fi
  shopt -s nocasematch
  if [[ "$line" =~ $claim_re ]]; then
    claim_count="${BASH_REMATCH[1]}"
    if [[ "$line" =~ pass ]]; then
      claims+=("$claim_count")
    fi
  fi
  if [[ "$line" =~ $glob_re ]]; then
    printf 'DEVIATION sensor_direct_multi_glob\n'
    violations=$((violations + 1))
  fi
  shopt -u nocasematch
done <"$TRANSCRIPT"

for claim_count in "${claims[@]}"; do
  supported=0
  for summary in "${summaries[@]}"; do
    if [ "$summary" = "${HEAD_SHA}:${claim_count}" ]; then
      supported=1
      break
    fi
  done
  if [ "$supported" -eq 0 ]; then
    printf 'VIOLATION sensor_claim_without_summary count=%s head=%s\n' \
      "$claim_count" "$HEAD_SHA"
    violations=$((violations + 1))
  fi
done

[ "$violations" -eq 0 ]
