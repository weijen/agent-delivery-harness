#!/usr/bin/env bash
# run-sensors.sh — tiered sensor executor (issue #347, builds on #343).
#
# Usage:
#   scripts/run-sensors.sh green --diff <fixed-feature-base> [--declared <list>]
#   scripts/run-sensors.sh --gate pre-pr
#   scripts/run-sensors.sh --gate ci --diff <pull-request-base>
#   scripts/run-sensors.sh --gate release|maintenance
#
# The only execution shapes are `green` and `--gate`.
# Enforcement by construction: `green` runs declared + feature-affected sensors,
# never a FULL fallback. Capture the feature base before its first edit and keep
# it fixed across commits and repairs. Invalid selection fails, rather than
# silently widening coverage. Publication verifies evidence without execution.
# Real whole-suite wrappers are boundary-only; they remain in canonical full
# discovery and run at applicable final/CI boundaries, never feature greens.
# Cross-model evidence (2026-07-21/22 runs) shows agents over-comply with
# verification obligations regardless of prose doctrine; this runner removes
# the decision from the agent entirely.
#
# Output: one result line per sensor (PASS/FAIL <path>), then a summary line:
#   SENSORS <mode> head=<sha> scope=<scoped|applicable> ran=<n> failed=<m>
# The process exit is the authoritative gate result; scope/count are not copied
# into semantic trace spans.
# Exit: 0 all green · 1 failed/stale result · 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Guarded source: evidence recording (issue #441) reuses the trace-lib issue
# and main-root resolution; a missing trace-lib.sh only disables recording.
if [ -f "${SCRIPT_DIR}/lib/trace-lib.sh" ]; then
  # shellcheck source=scripts/lib/trace-lib.sh
  source "${SCRIPT_DIR}/lib/trace-lib.sh"
fi

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }

MODE=""
GATE=""
DECLARED=""
DIFF_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    green)
      [ -z "$MODE" ] || { printf 'run-sensors.sh: choose one mode\n' >&2; exit 2; }
      MODE=green
      shift
      ;;
    --gate)
      [ -z "$MODE" ] || { printf 'run-sensors.sh: choose one mode\n' >&2; exit 2; }
      [ "$#" -ge 2 ] || { usage; exit 2; }
      GATE="${2:-}"
      MODE=gate
      shift 2
      ;;
    --declared|--diff)
      [ "$#" -ge 2 ] && [ -n "$2" ] \
        || { printf 'run-sensors.sh: %s requires a value\n' "$1" >&2; exit 2; }
      if [ "$1" = --declared ]; then DECLARED="$2"; else DIFF_BASE="$2"; fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'run-sensors.sh: unknown argument %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

if [ "$MODE" = "gate" ]; then
  case "$GATE" in
    pre-pr|release|maintenance)
      [ -z "$DIFF_BASE$DECLARED" ] \
        || { printf 'run-sensors.sh: %s does not accept narrower diff/declarations\n' "$GATE" >&2; exit 2; } ;;
    ci)
      [ -n "$DIFF_BASE" ] && [ -z "$DECLARED" ] \
        || { printf 'run-sensors.sh: ci requires --diff and forbids --declared\n' >&2; exit 2; } ;;
    pre-review)
      printf 'run-sensors.sh: pre-review execution is retired; use scoped feature checks, then --gate pre-pr after review approval\n' >&2
      exit 2 ;;
    *) printf 'run-sensors.sh: --gate must be pre-pr, ci, release or maintenance (got "%s")\n' "$GATE" >&2; exit 2 ;;
  esac
elif [ "$MODE" != "green" ]; then
  usage; exit 2
elif [ -z "$DIFF_BASE" ]; then
  printf 'run-sensors.sh: green requires --diff with the fixed feature base\n' >&2
  exit 2
fi

diagnostics_init() { # <scope> <mode>
  DIAGNOSTICS_DIR=""
  local root issue="" parent
  if ! declare -F trace_redact >/dev/null || ! declare -F trace_now_ms >/dev/null \
    || ! declare -F trace__main_root >/dev/null; then
    printf 'run-sensors.sh: diagnostics unavailable: trace helpers missing; output discarded, timing uses whole seconds\n' >&2
    return 0
  fi
  if ! root="$(trace__main_root)"; then
    printf 'run-sensors.sh: diagnostics unavailable: cannot resolve main checkout\n' >&2
    return 0
  fi
  parent="${root}/.copilot-tracking"
  if issue="$(trace__resolve_issue)"; then
    parent="${parent}/issues/issue-$(printf '%02d' "$issue")"
  fi
  parent="${parent}/sensor-runs"
  if ! DIAGNOSTICS_DIR="$(umask 077; mkdir -p "$parent" && mktemp -d "${parent}/run.XXXXXX")"; then
    printf 'run-sensors.sh: diagnostics unavailable: cannot create run directory under %s\n' "$parent" >&2
    DIAGNOSTICS_DIR=""
    return 0
  fi
  if ! {
    printf 'head\tmode\tscope\n%s\t%s\t%s\n' "$HEAD_SHA" "$2" "$1" >"${DIAGNOSTICS_DIR}/run.tsv" &&
    printf 'sensor\telapsed_ms\texit_status\tlog\n' >"${DIAGNOSTICS_DIR}/sensors.tsv"
  }; then
    printf 'run-sensors.sh: diagnostics unavailable: cannot write run metadata in %s\n' "$DIAGNOSTICS_DIR" >&2
    DIAGNOSTICS_DIR=""
    return 0
  fi
  printf 'DIAGNOSTICS %s/sensors.tsv\n' "$DIAGNOSTICS_DIR"
}

diagnostics_capture() { # <log> -- consume all input even when storage/redaction fails
  local log="$1"
  if [ -n "$log" ] && {
    # Frame raw quoted values and PEM blocks before the shared line redactor.
    awk '
      BEGIN {
        credential = "(secret|token|password|passwd|api_?key|credential|access_key)[[:alnum:]_.]*[\"\047]?[[:space:]]*[:=][[:space:]]*[\"\047]"
      }
      function quote_end(text, delimiter, i, escaped, character) {
        for (i = 1; i <= length(text); i++) {
          character = substr(text, i, 1)
          if (escaped) escaped = 0
          else if (character == "\\") escaped = 1
          else if (character == delimiter) return i
        }
        return 0
      }
      function open_quote(text, delimiter, ending) {
        while (match(tolower(text), credential)) {
          delimiter = substr(text, RSTART + RLENGTH - 1, 1)
          text = substr(text, RSTART + RLENGTH)
          ending = quote_end(text, delimiter)
          if (!ending) return delimiter
          text = substr(text, ending + 1)
        }
        return ""
      }
      { gsub(/\033\[[0-9;]*[A-Za-z]/, ""); gsub(/[[:cntrl:]]/, "") }
      quoted != "" {
        ending = quote_end($0, quoted)
        if (ending) quoted = open_quote(substr($0, ending + 1))
        next
      }
      /-----BEGIN .*PRIVATE KEY-----/ { private_key=1; print "[REDACTED private key]" }
      private_key { if (/-----END .*PRIVATE KEY-----/) private_key=0; next }
      match(tolower($0), credential) {
        quoted = open_quote($0)
        print "[REDACTED quoted credential]"; next
      }
      { print }
    ' | trace_redact >"$log"
  }; then
    return 0
  fi
  # Keep the producer alive to preserve its own exit code, including on disk full.
  cat >/dev/null
  return 1
}

diagnostics_now_ms() {
  if declare -F trace_now_ms >/dev/null; then trace_now_ms
  else printf '%s\n' "$((SECONDS * 1000))"
  fi
}

diagnostics_excerpt() { # <sensor> <sanitized-log>
  printf 'Failure output for %s (bounded; complete sanitized output: %s):\n' "$1" "$2" >&2
  LC_ALL=C awk '
    NR <= 10 { print "  | " substr($0, 1, 200); next }
    { last[NR % 10] = substr($0, 1, 200) }
    END {
      if (NR > 20) print "  | ... middle output omitted ..."
      start = NR > 20 ? NR - 9 : 11
      for (i = start; i <= NR; i++) print "  | " last[i % 10]
    }
  ' "$2" >&2 || printf 'run-sensors.sh: diagnostic excerpt unavailable for %s\n' "$1" >&2
}

run_list() { # run_list <scope-label> <mode-label> <sensor-path>...
  local scope="$1" label="$2"; shift 2
  local failed=0 ran=0 summary t log start elapsed status
  local -a pipeline_status
  diagnostics_init "$scope" "$label"
  for t in "$@"; do
    ran=$((ran + 1))
    log=""
    [ -z "$DIAGNOSTICS_DIR" ] || log="${DIAGNOSTICS_DIR}/${ran}.log"
    start="$(diagnostics_now_ms)"
    if bash "${REPO_ROOT}/${t}" 2>&1 | diagnostics_capture "$log"; then
      pipeline_status=("${PIPESTATUS[@]}")
    else
      pipeline_status=("${PIPESTATUS[@]}")
    fi
    status="${pipeline_status[0]}"
    elapsed="$(( $(diagnostics_now_ms) - start ))"
    if [ "$elapsed" -lt 0 ]; then
      printf 'run-sensors.sh: diagnostic clock moved backwards for %s; elapsed_ms clamped to zero\n' "$t" >&2
      elapsed=0
    fi
    if [ "${pipeline_status[1]}" -ne 0 ]; then
      printf 'run-sensors.sh: diagnostics unavailable for %s: capture/redaction/write failed; sensor exit=%s\n' "$t" "$status" >&2
      if [ -n "$log" ]; then
        rm -f "$log" || printf 'run-sensors.sh: cannot remove incomplete sanitized log %s\n' "$log" >&2
      fi
      log="unavailable"
    fi
    if [ "$status" -eq 0 ]; then
      printf 'PASS %s\n' "$t"
    else
      printf 'FAIL %s\n' "$t"
      failed=$((failed + 1))
    fi
    printf 'SENSOR %s elapsed_ms=%s exit_status=%s log=%s\n' "$t" "$elapsed" "$status" "$log"
    if [ "$status" -ne 0 ] && [ -f "$log" ]; then
      diagnostics_excerpt "$t" "$log"
    fi
    if [ -n "$DIAGNOSTICS_DIR" ]; then
      printf '%s\t%s\t%s\t%s\n' "$t" "$elapsed" "$status" "$log" \
        >>"${DIAGNOSTICS_DIR}/sensors.tsv" \
        || printf 'run-sensors.sh: diagnostic index write failed for %s (sensor exit=%s)\n' "$t" "$status" >&2
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

cd "$REPO_ROOT"
HEAD_SHA="$(git rev-parse HEAD)"

if [ "$MODE" = "gate" ]; then
  case "$GATE" in
    pre-pr)
      if ! DIFF_BASE="$(git merge-base origin/main HEAD)"; then
        printf 'run-sensors.sh: final applicability base discovery failed; prepare origin/main before final validation\n' >&2
        exit 2
      fi
      RESOLVER_ARGS=(--gate pre-pr --diff "$DIFF_BASE") ;;
    ci) RESOLVER_ARGS=(--gate pre-pr --diff "$DIFF_BASE") ;;
    *) RESOLVER_ARGS=(--gate "$GATE") ;;
  esac
  if ! selected="$("${SCRIPT_DIR}/validation/affected-sensors.sh" "${RESOLVER_ARGS[@]}")"; then
    printf 'run-sensors.sh: applicable resolver failed; no sensors executed\n' >&2
    exit 2
  fi
  if [ -z "$selected" ]; then
    printf 'run-sensors.sh: no applicable sensors found for %s\n' "$GATE" >&2
    exit 1
  fi
  mapfile -t ALL <<<"$selected"
  run_list applicable "$GATE" "${ALL[@]}"
  exit $?
fi

# green mode: resolver decides; the agent does not.
RESOLVER_ARGS=(--diff "$DIFF_BASE")
[ -n "$DECLARED" ] && RESOLVER_ARGS+=(--declared "$DECLARED")
set +e
RESOLVED="$("${SCRIPT_DIR}/validation/affected-sensors.sh" "${RESOLVER_ARGS[@]}")"
resolver_rc=$?
set -e
if [ "$resolver_rc" -ne 0 ]; then
  printf 'run-sensors.sh: resolver failed — feature verification stopped; no FULL fallback\n' >&2
  exit "$resolver_rc"
fi

if [ "$RESOLVED" = "FULL" ]; then
  printf 'run-sensors.sh: incompatible resolver requested FULL during green; update the resolver\n' >&2
  exit 2
fi

if [ -z "$RESOLVED" ]; then
  printf 'SENSORS green head=%s scope=scoped ran=0 failed=0\n' "$HEAD_SHA"
  printf 'run-sensors.sh: nothing to run — no declared sensors and no referencing sensors for this diff\n' >&2
  exit 0
fi

mapfile -t SCOPED <<< "$RESOLVED"
run_list scoped green "${SCOPED[@]}"
