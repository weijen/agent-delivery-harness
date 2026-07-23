#!/usr/bin/env bash
# run-sensors.sh — tiered sensor executor (issue #347, builds on #343).
#
# Usage:
#   scripts/run-sensors.sh green [--declared <list>] [--diff <base-ref>]
#   scripts/run-sensors.sh --gate pre-review
#   scripts/run-sensors.sh --gate pre-pr
#   scripts/run-sensors.sh --last
#
# The only execution shapes are `green` and `--gate`; `--last` is a read-only
# lookup of the most recent saved gate summary for the current HEAD.
# Enforcement by construction (the #343 doctrine's teeth): `green` CANNOT run
# the full suite by choice — it runs exactly the scoped set that
# scripts/affected-sensors.sh resolves (declared + affected), and escalates to
# the full suite ONLY when the resolver itself reports FULL (unbounded blast
# radius). The full suite otherwise requires an explicit `--gate pre-review`
# or `--gate pre-pr` invocation — the two per-issue points where it is owed.
# Cross-model evidence (2026-07-21/22 runs) shows agents over-comply with
# verification obligations regardless of prose doctrine; this runner removes
# the decision from the agent entirely.
#
# Output: one result line per sensor (PASS/FAIL <path>), then a summary line:
#   SENSORS <mode> head=<sha> scope=<scoped|full> ran=<n> failed=<m>
# The saved summary is the authoritative, HEAD-bound gate result consumed by
# review-gate.sh; scope/count are not copied into semantic trace spans.
# Gate summaries are saved under ignored .copilot-tracking state. `--last`
# refuses the record after HEAD changes and preserves the saved pass/fail exit.
# Exit: 0 all green · 1 failed/stale result · 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAST_SUMMARY_FILE="${REPO_ROOT}/.copilot-tracking/sensor-runs/last-gate"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }

MODE=""
GATE=""
DECLARED=""
DIFF_BASE="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    green)
      [ -z "$MODE" ] || { printf 'run-sensors.sh: choose one mode\n' >&2; exit 2; }
      MODE=green
      shift
      ;;
    --gate)
      [ -z "$MODE" ] || { printf 'run-sensors.sh: choose one mode\n' >&2; exit 2; }
      GATE="${2:-}"
      MODE=gate
      shift 2
      ;;
    --last)
      [ -z "$MODE" ] || { printf 'run-sensors.sh: choose one mode\n' >&2; exit 2; }
      MODE=last
      shift
      ;;
    --declared) DECLARED="${2:-}"; shift 2 ;;
    --diff) DIFF_BASE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'run-sensors.sh: unknown argument %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

if [ "$MODE" = "gate" ]; then
  case "$GATE" in
    pre-review|pre-pr) ;;
    *) printf 'run-sensors.sh: --gate must be pre-review or pre-pr (got "%s")\n' "$GATE" >&2; exit 2 ;;
  esac
elif [ "$MODE" != "green" ] && [ "$MODE" != "last" ]; then
  usage; exit 2
fi

save_gate_summary() {
  local summary="$1" tmp
  mkdir -p "$(dirname "$LAST_SUMMARY_FILE")"
  tmp="${LAST_SUMMARY_FILE}.tmp.$$"
  printf '%s\n' "$summary" >"$tmp"
  mv "$tmp" "$LAST_SUMMARY_FILE"
}

run_list() { # run_list <scope-label> <mode-label> <sensor-path>...
  local scope="$1" label="$2"; shift 2
  local failed=0 ran=0 summary t
  for t in "$@"; do
    [ -f "${REPO_ROOT}/${t}" ] || { printf 'SKIP %s (missing)\n' "$t"; continue; }
    ran=$((ran + 1))
    if bash "${REPO_ROOT}/${t}" >/dev/null 2>&1; then
      printf 'PASS %s\n' "$t"
    else
      printf 'FAIL %s\n' "$t"
      failed=$((failed + 1))
    fi
  done
  summary="SENSORS ${label} head=${HEAD_SHA} scope=${scope} ran=${ran} failed=${failed}"
  printf '%s\n' "$summary"
  [ "$MODE" != "gate" ] || save_gate_summary "$summary"
  [ "$failed" -eq 0 ]
}

full_set() {
  local t
  for t in tests/scripts/test_*.sh tests/meta/test_*.sh; do
    [ -e "${REPO_ROOT}/${t}" ] || continue
    printf '%s\n' "$t"
  done
}

cd "$REPO_ROOT"
HEAD_SHA="$(git rev-parse HEAD)"

if [ "$MODE" = "last" ]; then
  if [ ! -f "$LAST_SUMMARY_FILE" ]; then
    printf 'run-sensors.sh: no saved gate summary\n' >&2
    exit 1
  fi
  summary="$(cat "$LAST_SUMMARY_FILE")"
  if [[ ! "$summary" =~ ^SENSORS\ (pre-review|pre-pr)\ head=([0-9a-f]{40}|[0-9a-f]{64})\ scope=full\ ran=([0-9]+)\ failed=([0-9]+)$ ]]; then
    printf 'run-sensors.sh: saved gate summary is malformed\n' >&2
    exit 1
  fi
  saved_head="${BASH_REMATCH[2]}"
  saved_failed="${BASH_REMATCH[4]}"
  if [ "$saved_head" != "$HEAD_SHA" ]; then
    printf 'run-sensors.sh: saved summary is stale (saved HEAD %s, current HEAD %s)\n' \
      "$saved_head" "$HEAD_SHA" >&2
    exit 1
  fi
  printf '%s\n' "$summary"
  [ "$saved_failed" -eq 0 ]
  exit $?
fi

if [ "$MODE" = "gate" ]; then
  # The two owed full-suite points. Explicit, auditable, twice per issue.
  mapfile -t ALL < <(full_set)
  run_list full "$GATE" "${ALL[@]}"
  exit $?
fi

# green mode: resolver decides; the agent does not.
RESOLVER_ARGS=(--diff "$DIFF_BASE")
[ -n "$DECLARED" ] && RESOLVER_ARGS+=(--declared "$DECLARED")
RESOLVED="$("${SCRIPT_DIR}/affected-sensors.sh" "${RESOLVER_ARGS[@]}")"

if [ "$RESOLVED" = "FULL" ]; then
  # Unbounded blast radius (shared lib / schema authority changed): the ONLY
  # path to a full run at green, chosen by the resolver, not the agent.
  mapfile -t ALL < <(full_set)
  run_list full green-full-fallback "${ALL[@]}"
  exit $?
fi

if [ -z "$RESOLVED" ]; then
  printf 'SENSORS green head=%s scope=scoped ran=0 failed=0\n' "$HEAD_SHA"
  printf 'run-sensors.sh: nothing to run — no declared sensors and no referencing sensors for this diff\n' >&2
  exit 0
fi

mapfile -t SCOPED <<< "$RESOLVED"
run_list scoped green "${SCOPED[@]}"
