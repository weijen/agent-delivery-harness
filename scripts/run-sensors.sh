#!/usr/bin/env bash
# run-sensors.sh — tiered sensor executor (issue #347, builds on #343).
#
# Usage:
#   scripts/run-sensors.sh green [--declared <list>] [--diff <base-ref>]
#   scripts/run-sensors.sh --gate pre-review
#   scripts/run-sensors.sh --gate pre-pr
#
# Enforcement by construction (the #343 doctrine's teeth): the `green` mode
# CANNOT run the full suite by choice — it runs exactly the scoped set that
# scripts/affected-sensors.sh resolves (declared + affected), and escalates to
# the full suite ONLY when the resolver itself reports FULL (unbounded blast
# radius). The full suite otherwise requires an explicit `--gate pre-review`
# or `--gate pre-pr` invocation — the two per-issue points where it is owed.
# Cross-model evidence (2026-07-21/22 runs) shows agents over-comply with
# verification obligations regardless of prose doctrine; this runner removes
# the decision from the agent entirely.
#
# Output: one result line per sensor (PASS/FAIL <path>), then a summary line:
#   SENSORS <mode> scope=<scoped|full> ran=<n> failed=<m>
# The summary line's scope/count feed TRACE_SENSOR_SCOPE / TRACE_SENSOR_COUNT
# on the corresponding handback (see log-handback.sh #343 passthrough).
# Exit: 0 all green · 1 at least one sensor failed · 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }

MODE=""
GATE=""
DECLARED=""
DIFF_BASE="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    green) MODE=green; shift ;;
    --gate) GATE="${2:-}"; MODE=gate; shift 2 ;;
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
elif [ "$MODE" != "green" ]; then
  usage; exit 2
fi

run_list() { # run_list <scope-label> <mode-label> <sensor-path>...
  local scope="$1" label="$2"; shift 2
  local failed=0 ran=0 t
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
  printf 'SENSORS %s scope=%s ran=%d failed=%d\n' "$label" "$scope" "$ran" "$failed"
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
  printf 'SENSORS green scope=scoped ran=0 failed=0\n'
  printf 'run-sensors.sh: nothing to run — no declared sensors and no referencing sensors for this diff\n' >&2
  exit 0
fi

mapfile -t SCOPED <<< "$RESOLVED"
run_list scoped green "${SCOPED[@]}"
