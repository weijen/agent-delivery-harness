#!/usr/bin/env bash
# affected-sensors.sh — resolve the scoped sensor set for a change (issue #343).
#
# Usage:
#   scripts/validation/affected-sensors.sh [--declared <list>] [--diff <base-ref>] [<changed-path>...]
#   scripts/validation/affected-sensors.sh --tests-root <dir> --repo-root <dir> ...   (fixture override)
#   scripts/validation/affected-sensors.sh --list   (canonical full-suite discovery, no execution)
#
# Given the set of changed repo-relative paths (explicit args, or derived from
# git when --diff <base-ref> is passed: committed vs base, staged, and unstaged
# changes are unioned), print the sensors that must run at a GREEN handback:
#
#   * every feature-eligible sensor named in --declared (comma/space-separated;
#     missing, non-sensor and boundary-only declarations are errors),
#   * every sensor under tests/scripts/ or tests/meta/ that mentions a changed
#     path (matched by repo-relative path or basename — over-inclusion is
#     acceptable, silent under-inclusion is not),
#   * a changed file that is itself a sensor is always in its own set.
#
# Shared changes use the same scoped mapping, never an automatic FULL fallback.
# Sensors with a header `# harness-sensor-stage: boundary` wrap real whole suites;
# they stay in --list for issue gates/CI, but are deferred from feature selection.
# Miniature hermetic suites testing runner behavior remain feature-eligible.
# Use a fixed feature-start commit for --diff; earlier completed features then
# stop polluting the active feature's scope, including after partial commits.
#
# Output contract: a sorted unique list of repo-relative sensor paths (possibly
# empty when only docs changed and no sensor references them).
# Exit 0 on success, 2 on invalid scope/declarations or discovery errors. This script
# never runs sensors — it only resolves the set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTS_ROOT=""
DECLARED=""
DIFF_BASE=""
LIST=0
CHANGED=()

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --declared) DECLARED="${2:-}"; shift 2 ;;
    --diff) DIFF_BASE="${2:-}"; shift 2 ;;
    --list) LIST=1; shift ;;
    --repo-root) REPO_ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --tests-root) TESTS_ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do CHANGED+=("$1"); shift; done ;;
    -*) printf 'affected-sensors.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) CHANGED+=("$1"); shift ;;
  esac
done

[ -n "$TESTS_ROOT" ] || TESTS_ROOT="${REPO_ROOT}/tests"

discover_sensors() (
  local paths=() found directory
  for directory in scripts meta; do
    [ ! -d "${TESTS_ROOT}/${directory}" ] || paths+=("$directory")
  done
  [ "${#paths[@]}" -gt 0 ] || return 0
  cd "$TESTS_ROOT" || return 2
  if ! found="$(find "${paths[@]}" \
    -type d \( -name lib -o -name helpers -o -name fixtures \) -prune -o \
    -type f -name 'test_*.sh' -print)"; then
    printf 'affected-sensors.sh: sensor discovery failed\n' >&2
    return 2
  fi
  [ -n "$found" ] || return 0
  printf '%s\n' "$found" | LC_ALL=C sort -u | sed 's|^|tests/|'
)

if [ "$LIST" -eq 1 ]; then
  discover_sensors
  exit $?
fi

if [ -n "$DIFF_BASE" ]; then
  if ! BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "${DIFF_BASE}^{commit}" 2>/dev/null)" \
    || ! git -C "$REPO_ROOT" merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null; then
    printf 'affected-sensors.sh: git discovery failed — diff base %s must name an ancestor of HEAD\n' "$DIFF_BASE" >&2
    exit 2
  fi
  discover_changed_paths() {
    local output=""
    output="$(git -C "$REPO_ROOT" diff --name-only "${BASE_SHA}..HEAD" 2>/dev/null)" || return 1
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

sensor_stage() {
  local line stage=feature seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '# harness-sensor-stage:'*)
        [ "$seen" -eq 0 ] || return 2
        seen=1
        case "$line" in
          '# harness-sensor-stage: feature') stage=feature ;;
          '# harness-sensor-stage: boundary') stage=boundary ;;
          *) return 2 ;;
        esac
        ;;
      '#'*|'') ;;
      *) [[ "$line" =~ ^[[:space:]]*$ ]] || break ;;
    esac
  done <"$1" || return 2
  printf '%s\n' "$stage"
}

# --- Scoped resolution ----------------------------------------------------------
if ! SENSOR_LIST="$(discover_sensors)"; then
  exit 2
fi
SENSORS=()
[ -z "$SENSOR_LIST" ] || mapfile -t SENSORS <<< "$SENSOR_LIST"
SENSOR_FILES=()
BOUNDARY_LIST=""
for sensor in "${SENSORS[@]}"; do
  file="${TESTS_ROOT}/${sensor#tests/}"
  if ! stage="$(sensor_stage "$file")"; then
    printf 'affected-sensors.sh: invalid or unreadable sensor stage header: %s\n' "$sensor" >&2
    exit 2
  fi
  if [ "$stage" = boundary ]; then
    BOUNDARY_LIST+="${sensor}"$'\n'
  else
    SENSOR_FILES+=("$file")
  fi
done

RESULT="$(mktemp)"
trap 'rm -f "${RESULT}"' EXIT

emit() { # emit <repo-relative-sensor-path>
  printf '%s\n' "$1" >> "$RESULT"
}

# Declared entries must also belong to the canonical sensor set.
if [ -n "$DECLARED" ]; then
  for d in $(printf '%s' "$DECLARED" | tr ',' ' '); do
    if grep -Fxq -- "$d" <<< "$BOUNDARY_LIST"; then
      printf 'affected-sensors.sh: declared sensor %s is boundary-only; declare a targeted feature sensor instead\n' "$d" >&2
      exit 2
    elif grep -Fxq -- "$d" <<< "$SENSOR_LIST"; then
      emit "$d"
    elif [ -f "${REPO_ROOT}/${d}" ]; then
      printf 'affected-sensors.sh: declared path %s is not a sensor\n' "$d" >&2
      exit 2
    else
      printf 'affected-sensors.sh: declared sensor %s not found\n' "$d" >&2
      exit 2
    fi
  done
fi

for p in ${CHANGED[@]+"${CHANGED[@]}"}; do
  base="$(basename "$p")"
  [ "${#SENSOR_FILES[@]}" -gt 0 ] || continue
  if grep -Fxq -- "$p" <<< "$BOUNDARY_LIST"; then
    printf 'affected-sensors.sh: %s deferred to full issue gates (boundary-only)\n' "$p" >&2
  elif grep -Fxq -- "$p" <<< "$SENSOR_LIST"; then
    emit "$p"
  fi
  hits=""
  if hits="$(grep -lF -e "$p" -e "$base" -- "${SENSOR_FILES[@]}")"; then
    while IFS= read -r hit; do
      emit "tests/${hit#"${TESTS_ROOT}/"}"
    done <<< "$hits"
  else
    grep_rc=$?
    if [ "$grep_rc" -ne 1 ]; then
      printf 'affected-sensors.sh: reference discovery failed for %s\n' "$p" >&2
      exit 2
    fi
  fi
done

sort -u "$RESULT"
