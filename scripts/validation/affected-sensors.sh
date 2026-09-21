#!/usr/bin/env bash
# affected-sensors.sh — resolve the scoped sensor set for a change (issue #343).
#
# Usage:
#   scripts/validation/affected-sensors.sh [--declared <list>] [--diff <base-ref>] [<changed-path>...]
#   scripts/validation/affected-sensors.sh --tests-root <dir> --repo-root <dir> ...   (fixture override)
#   scripts/validation/affected-sensors.sh --list   (canonical full-suite discovery, no execution)
#   scripts/validation/affected-sensors.sh --gate pre-pr --diff <base-ref>
#   scripts/validation/affected-sensors.sh --gate release|maintenance
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
GATE=""
CHANGED=()

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --declared)
      [ "$#" -ge 2 ] && [ -n "$2" ] \
        || { printf 'affected-sensors.sh: --declared requires a value\n' >&2; exit 2; }
      DECLARED="$2"; shift 2 ;;
    --diff) DIFF_BASE="${2:-}"; shift 2 ;;
    --list) LIST=1; shift ;;
    --gate)
      case "${2:-}" in
        pre-pr|release|maintenance) GATE="$2"; shift 2 ;;
        *) printf 'affected-sensors.sh: --gate requires pre-pr, release or maintenance\n' >&2; exit 2 ;;
      esac ;;
    --repo-root) REPO_ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --tests-root) TESTS_ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do CHANGED+=("$1"); shift; done ;;
    -*) printf 'affected-sensors.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) CHANGED+=("$1"); shift ;;
  esac
done

[ -n "$TESTS_ROOT" ] || TESTS_ROOT="${REPO_ROOT}/tests"
if [ "$LIST" -eq 1 ] && [ -n "$GATE" ]; then
  printf 'affected-sensors.sh: --list and --gate are distinct selection modes\n' >&2
  exit 2
fi

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

# Explicit paths have no status information, so treat them conservatively.
DELETED=(${CHANGED[@]+"${CHANGED[@]}"})
if [ -n "$DIFF_BASE" ]; then
  if ! BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "${DIFF_BASE}^{commit}" 2>/dev/null)" \
    || ! git -C "$REPO_ROOT" merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null; then
    printf 'affected-sensors.sh: git discovery failed — diff base %s must name an ancestor of HEAD\n' "$DIFF_BASE" >&2
    exit 2
  fi
  discover_changed_paths() {
    local output="" filter="${1:-}"
    local args=()
    [ -z "$filter" ] || args+=(--diff-filter=D)
    output="$(git -C "$REPO_ROOT" diff --no-renames --name-only ${args[@]+"${args[@]}"} "${BASE_SHA}..HEAD" 2>/dev/null)" || return 1
    printf '%s\n' "$output"
    output="$(git -C "$REPO_ROOT" diff --no-renames --name-only ${args[@]+"${args[@]}"} --cached 2>/dev/null)" || return 1
    printf '%s\n' "$output"
    output="$(git -C "$REPO_ROOT" diff --no-renames --name-only ${args[@]+"${args[@]}"} 2>/dev/null)" || return 1
    printf '%s\n' "$output"
    [ -z "$filter" ] || return 0
    output="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null)" || return 1
    printf '%s\n' "$output"
  }
  if ! DISCOVERED="$(discover_changed_paths)" || ! DELETED_PATHS="$(discover_changed_paths deleted)"; then
    printf 'affected-sensors.sh: git discovery failed for diff base %s\n' "$DIFF_BASE" >&2
    exit 2
  fi
  while IFS= read -r p; do
    [ -n "$p" ] && CHANGED+=("$p")
  done < <(printf '%s\n' "$DISCOVERED" | sort -u)
  while IFS= read -r p; do
    [ -n "$p" ] && DELETED+=("$p")
  done < <(printf '%s\n' "$DELETED_PATHS" | sort -u)
fi

if [ "$GATE" = pre-pr ] && [ ${#CHANGED[@]} -eq 0 ] && [ -z "$DIFF_BASE" ]; then
  printf 'affected-sensors.sh: pre-pr requires --diff or explicit changed paths\n' >&2
  exit 2
fi
if [ -z "$GATE" ] && [ ${#CHANGED[@]} -eq 0 ] && [ -z "$DECLARED" ]; then
  printf 'affected-sensors.sh: no changed paths and no --declared sensors given\n' >&2
  usage >&2
  exit 2
fi

sensor_metadata() {
  local line stage_seen=0 trigger_seen=0 depends_seen=0 deletes_seen=0 dependency
  stage=feature
  trigger=routine
  dependencies=()
  deletion_dependencies=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '# harness-sensor-stage:'*)
        [ "$stage_seen" -eq 0 ] || return 2
        stage_seen=1
        case "$line" in
          '# harness-sensor-stage: feature') stage=feature ;;
          '# harness-sensor-stage: boundary') stage=boundary ;;
          *) return 2 ;;
        esac
        ;;
      '# harness-sensor-trigger:'*)
        [ "$trigger_seen" -eq 0 ] || return 2
        trigger_seen=1
        trigger="${line#'# harness-sensor-trigger: '}"
        case "$trigger" in routine|relevant|upgrade|maintenance) ;; *) return 2 ;; esac
        ;;
      '# harness-sensor-depends:'*)
        [ "$depends_seen" -eq 0 ] || return 2
        depends_seen=1
        read -r -a dependencies <<<"${line#'# harness-sensor-depends:'}"
        [ "${#dependencies[@]}" -gt 0 ] || return 2
        ;;
      '# harness-sensor-deletes:'*)
        [ "$deletes_seen" -eq 0 ] || return 2
        deletes_seen=1
        read -r -a deletion_dependencies <<<"${line#'# harness-sensor-deletes:'}"
        [ "${#deletion_dependencies[@]}" -gt 0 ] || return 2
        ;;
      '#'*|'') ;;
      *) [[ "$line" =~ ^[[:space:]]*$ ]] || break ;;
    esac
  done <"$1" || return 2
  for dependency in ${dependencies[@]+"${dependencies[@]}"} ${deletion_dependencies[@]+"${deletion_dependencies[@]}"}; do
    case "$dependency" in
      /*|..|../*|*/../*|*/..|.|'*'|'**'|*[![:alnum:]_./?*-]*) return 2 ;;
    esac
  done
  [ "$trigger" = routine ] || [ "$depends_seen" -eq 1 ] || [ "$deletes_seen" -eq 1 ]
}

# --- Scoped resolution ----------------------------------------------------------
if ! SENSOR_LIST="$(discover_sensors)"; then
  exit 2
fi
SENSORS=()
[ -z "$SENSOR_LIST" ] || mapfile -t SENSORS <<< "$SENSOR_LIST"
SENSOR_FILES=()
BOUNDARY_LIST=""
RESULT="$(mktemp)"
trap 'rm -f "${RESULT}"' EXIT

emit() { # emit <repo-relative-sensor-path>
  printf '%s\n' "$1" >> "$RESULT"
}

for sensor in "${SENSORS[@]}"; do
  file="${TESTS_ROOT}/${sensor#tests/}"
  if ! sensor_metadata "$file"; then
    printf 'affected-sensors.sh: invalid or unreadable sensor stage header or trigger/dependency metadata: %s\n' "$sensor" >&2
    exit 2
  fi
  if [ "$stage" = boundary ]; then
    BOUNDARY_LIST+="${sensor}"$'\n'
    [ -n "$GATE" ] || continue
  fi
  case "$GATE:$trigger" in
    release:upgrade|maintenance:maintenance|pre-pr:routine) emit "$sensor" ;;
  esac
  case "$GATE" in release|maintenance) continue ;; esac
  if [ "$trigger" = routine ]; then
    SENSOR_FILES+=("$file")
  fi
  for p in ${CHANGED[@]+"${CHANGED[@]}"}; do
    if [ "$p" = "$sensor" ]; then emit "$sensor"; fi
    for dependency in ${dependencies[@]+"${dependencies[@]}"}; do
      # The right-hand side is deliberately a declared path glob, not shell code.
      # shellcheck disable=SC2053
      if [[ "$p" == $dependency ]]; then emit "$sensor"; fi
    done
  done
  for p in ${DELETED[@]+"${DELETED[@]}"}; do
    for dependency in ${deletion_dependencies[@]+"${deletion_dependencies[@]}"}; do
      # shellcheck disable=SC2053 # Declared deletion dependency is a path glob.
      if [[ "$p" == $dependency ]]; then emit "$sensor"; fi
    done
  done
done

# Declared entries must also belong to the canonical sensor set.
if [ -n "$DECLARED" ]; then
  IFS=$' \t\n' read -r -d '' -a DECLARED_SENSORS < <(printf '%s\0' "${DECLARED//,/ }")
  if [ "${#DECLARED_SENSORS[@]}" -eq 0 ]; then
    printf 'affected-sensors.sh: --declared must contain at least one sensor identity\n' >&2
    exit 2
  fi
  for d in "${DECLARED_SENSORS[@]}"; do
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
  case "$GATE" in release|maintenance) break ;; esac
  base="$(basename "$p")"
  [ "${#SENSOR_FILES[@]}" -gt 0 ] || continue
  if [ -z "$GATE" ] && grep -Fxq -- "$p" <<< "$BOUNDARY_LIST"; then
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

LC_ALL=C sort -u "$RESULT"
