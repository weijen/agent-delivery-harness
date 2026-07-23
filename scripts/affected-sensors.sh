#!/usr/bin/env bash
# affected-sensors.sh — resolve the scoped sensor set for a change (issue #343).
#
# Usage:
#   scripts/affected-sensors.sh [--declared <list>] [--diff <base-ref>] [<changed-path>...]
#   scripts/affected-sensors.sh --tests-root <dir> --repo-root <dir> ...   (fixture override)
#
# Given the set of changed repo-relative paths (explicit args, or derived from
# git when --diff <base-ref> is passed: committed vs base, staged, and unstaged
# changes are unioned), print the sensors that must run at a GREEN handback:
#
#   * every sensor named in --declared (comma- or space-separated; a declared
#     entry that does not exist on disk is warned about on stderr and skipped),
#   * every sensor under tests/scripts/ or tests/meta/ that mentions a changed
#     path (matched by repo-relative path or basename — over-inclusion is
#     acceptable, silent under-inclusion is not),
#   * a changed file that is itself a sensor is always in its own set.
#
# FULL fallback (conservative, single-line output `FULL`): a discovery error
# (reported as exit 2 for the runner to promote) or any changed path whose blast
# radius cannot be bounded by textual reference —
#   * shared sourced libraries: scripts/trace-lib.sh scripts/issue-lib.sh
#     scripts/finish-lib.sh scripts/reconcile-lib.sh scripts/ci-coverage-lib.sh
#   * schema/contract authorities: docs/evaluation/trace-schema.v1.json
#     docs/harness-contract.yml
#   * shared test scaffolding: anything under tests/scripts/lib/ or tests/lib/
# When FULL is printed the caller runs the whole suite; the reason is written
# to stderr.
#
# Output contract: either the single line `FULL`, or a sorted unique list of
# repo-relative sensor paths (possibly empty when only docs changed and no
# sensor references them). Exit 0 on success, 2 on usage errors. This script
# never runs sensors — it only resolves the set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTS_ROOT=""
DECLARED=""
DIFF_BASE=""
CHANGED=()

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --declared) DECLARED="${2:-}"; shift 2 ;;
    --diff) DIFF_BASE="${2:-}"; shift 2 ;;
    --repo-root) REPO_ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --tests-root) TESTS_ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do CHANGED+=("$1"); shift; done ;;
    -*) printf 'affected-sensors.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) CHANGED+=("$1"); shift ;;
  esac
done

[ -n "$TESTS_ROOT" ] || TESTS_ROOT="${REPO_ROOT}/tests"

if [ -n "$DIFF_BASE" ]; then
  discover_changed_paths() {
    local output=""
    output="$(git -C "$REPO_ROOT" diff --name-only "${DIFF_BASE}...HEAD" 2>/dev/null)" || return 1
    printf '%s\n' "$output"
    output="$(git -C "$REPO_ROOT" diff --name-only --cached 2>/dev/null)" || return 1
    printf '%s\n' "$output"
    output="$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null)" || return 1
    printf '%s\n' "$output"
    output="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null)" || return 1
    printf '%s\n' "$output"
  }
  if ! DISCOVERED="$(discover_changed_paths)"; then
    printf 'affected-sensors.sh: git discovery failed for diff base %s\n' "$DIFF_BASE" >&2
    exit 2
  fi
  while IFS= read -r p; do
    [ -n "$p" ] && CHANGED+=("$p")
  done < <(printf '%s\n' "$DISCOVERED" | sort -u)
fi

if [ ${#CHANGED[@]} -eq 0 ] && [ -z "$DECLARED" ]; then
  printf 'affected-sensors.sh: no changed paths and no --declared sensors given\n' >&2
  usage >&2
  exit 2
fi

# --- FULL fallback ------------------------------------------------------------
full_trigger() {
  case "$1" in
    scripts/trace-lib.sh|scripts/issue-lib.sh|scripts/finish-lib.sh|\
scripts/reconcile-lib.sh|scripts/ci-coverage-lib.sh) return 0 ;;
    docs/evaluation/trace-schema.v1.json|docs/harness-contract.yml) return 0 ;;
    tests/scripts/lib/*|tests/lib/*) return 0 ;;
  esac
  return 1
}

for p in ${CHANGED[@]+"${CHANGED[@]}"}; do
  if full_trigger "$p"; then
    printf 'affected-sensors.sh: %s has unbounded blast radius — falling back to the FULL suite\n' "$p" >&2
    printf 'FULL\n'
    exit 0
  fi
done

# --- Scoped resolution ----------------------------------------------------------
RESULT="$(mktemp)"
trap 'rm -f "${RESULT}"' EXIT

emit() { # emit <repo-relative-sensor-path>
  printf '%s\n' "$1" >> "$RESULT"
}

# Declared sensors first (warn + skip entries that do not exist).
if [ -n "$DECLARED" ]; then
  for d in $(printf '%s' "$DECLARED" | tr ',' ' '); do
    if [ -f "${REPO_ROOT}/${d}" ]; then
      emit "$d"
    else
      printf 'affected-sensors.sh: declared sensor %s not found — skipped\n' "$d" >&2
    fi
  done
fi

sensor_dirs=()
[ -d "${TESTS_ROOT}/scripts" ] && sensor_dirs+=("${TESTS_ROOT}/scripts")
[ -d "${TESTS_ROOT}/meta" ] && sensor_dirs+=("${TESTS_ROOT}/meta")

for p in ${CHANGED[@]+"${CHANGED[@]}"}; do
  base="$(basename "$p")"
  # A changed sensor always runs itself.
  case "$p" in
    tests/scripts/*.sh|tests/meta/*.sh)
      [ -f "${REPO_ROOT}/${p}" ] && emit "$p"
      ;;
  esac
  [ ${#sensor_dirs[@]} -gt 0 ] || continue
  # Sensors referencing the changed path (full relative path or basename).
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rel="${hit#"${TESTS_ROOT}"/}"
    case "$TESTS_ROOT" in
      "${REPO_ROOT}/tests") emit "tests/${rel}" ;;
      *) emit "tests/${rel}" ;;
    esac
  done < <(
    { grep -rlF -- "$p" "${sensor_dirs[@]}" 2>/dev/null || true
      grep -rlF -- "$base" "${sensor_dirs[@]}" 2>/dev/null || true
    } | grep -E '\.sh$' | sort -u
  )
done

sort -u "$RESULT"
