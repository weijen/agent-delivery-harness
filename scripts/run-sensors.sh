#!/usr/bin/env bash
# run-sensors.sh — tiered sensor executor (issue #347, builds on #343).
#
# Usage:
#   scripts/run-sensors.sh green [--declared <list>] [--diff <base-ref>]
#   scripts/run-sensors.sh --gate pre-review
#   scripts/run-sensors.sh --gate pre-pr
#
# The only execution shapes are `green` and `--gate`.
# Enforcement by construction (the #343 doctrine's teeth): `green` CANNOT run
# the full suite by choice — it runs exactly the scoped set that
# scripts/affected-sensors.sh resolves (declared + affected), and escalates to
# the full suite ONLY when the resolver reports FULL (unbounded blast radius)
# or fails discovery with exit 2 (fail-closed fallback). The full suite otherwise requires an explicit `--gate pre-review`
# or `--gate pre-pr` invocation — the two per-issue points where it is owed.
# Cross-model evidence (2026-07-21/22 runs) shows agents over-comply with
# verification obligations regardless of prose doctrine; this runner removes
# the decision from the agent entirely.
#
# Output: one result line per sensor (PASS/FAIL <path>), then a summary line:
#   SENSORS <mode> head=<sha> scope=<scoped|full> ran=<n> failed=<m>
# The process exit is the authoritative gate result; scope/count are not copied
# into semantic trace spans.
# Exit: 0 all green · 1 failed/stale result · 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Guarded source: evidence recording (issue #441) reuses the trace-lib issue
# and main-root resolution; a missing trace-lib.sh only disables recording.
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi

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
  record_evidence "$label" "$scope" "$ran" "$failed"
  [ "$failed" -eq 0 ]
}

# --- Script-recorded evidence (issue #441) ------------------------------------
# A green summary (failed=0) is appended as one tamper-evident JSON row to
# <main-root>/.copilot-tracking/issues/issue-NN/sensor-evidence.jsonl, so the
# reviewer's gate_sensors evidence never depends on agent hand-copying.
# Every failure path warns and returns 0 — recording can never change the
# sensor result (the trace-lib guarantee, applied here).
evidence__warn() { printf 'run-sensors.sh: warning: %s\n' "$*" >&2; return 0; }

evidence__sha256() { # <canonical-string> → hex digest on stdout
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

record_evidence() { # <mode-label> <scope> <ran> <failed>
  local label="$1" scope="$2" ran="$3" failed="$4"
  [ "$failed" -eq 0 ] || return 0
  command -v jq >/dev/null 2>&1 \
    || { evidence__warn "jq unavailable — evidence row skipped"; return 0; }
  declare -F trace__resolve_issue >/dev/null 2>&1 \
    || { evidence__warn "trace-lib.sh unavailable — evidence row skipped"; return 0; }
  local issue="" main_root="" pad=""
  issue="$(trace__resolve_issue)" \
    || { evidence__warn "no issue context — evidence row skipped"; return 0; }
  main_root="$(trace__main_root)" \
    || { evidence__warn "cannot resolve the main checkout root — evidence row skipped"; return 0; }
  pad="$(printf '%02d' "$issue")"
  local ts="" row=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local canonical="v1|${HEAD_SHA}|${label}|${scope}|${ran}|${failed}|${ts}"
  local checksum=""
  checksum="$(evidence__sha256 "$canonical")" \
    || { evidence__warn "no sha256 tool — evidence row skipped"; return 0; }
  row="$(jq -cn \
    --arg ts "$ts" --arg mode "$label" --arg head "$HEAD_SHA" --arg scope "$scope" \
    --argjson ran "$ran" --argjson failed "$failed" --arg checksum "sha256:${checksum}" \
    '{schema_version: 1, timestamp: $ts, mode: $mode, head: $head,
      scope: $scope, ran: $ran, failed: $failed, checksum: $checksum}')" \
    || { evidence__warn "jq failed to serialize the evidence row — skipped"; return 0; }
  local dir="${main_root}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$dir" 2>/dev/null \
    || { evidence__warn "cannot create ${dir} — evidence row skipped"; return 0; }
  printf '%s\n' "$row" >> "${dir}/sensor-evidence.jsonl" 2>/dev/null \
    || evidence__warn "cannot append to ${dir}/sensor-evidence.jsonl — evidence row skipped"
  return 0
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

if [ "$MODE" = "gate" ]; then
  # The two owed full-suite points. Explicit, auditable, twice per issue.
  mapfile -t ALL < <(full_set)
  run_list full "$GATE" "${ALL[@]}"
  exit $?
fi

# green mode: resolver decides; the agent does not.
RESOLVER_ARGS=(--diff "$DIFF_BASE")
[ -n "$DECLARED" ] && RESOLVER_ARGS+=(--declared "$DECLARED")
set +e
RESOLVED="$("${SCRIPT_DIR}/affected-sensors.sh" "${RESOLVER_ARGS[@]}")"
resolver_rc=$?
set -e
if [ "$resolver_rc" -eq 2 ]; then
  printf 'run-sensors.sh: resolver failed — falling back to FULL with warning\n' >&2
  RESOLVED="FULL"
elif [ "$resolver_rc" -ne 0 ]; then
  exit "$resolver_rc"
fi

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
