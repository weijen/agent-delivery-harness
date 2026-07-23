#!/usr/bin/env bash
# Shared throwaway-repository fixture for harness shell sensors.
# shellcheck disable=SC2034 # Public path globals are consumed by sourcing sensors.

if declare -F fixture_repo >/dev/null 2>&1; then
  return 0
fi

_fixture_git="$(command -v git)"
_fixture_mkdir="$(command -v mkdir)"
_fixture_mktemp="$(command -v mktemp)"
_fixture_rm="$(command -v rm)"
_fixture_cp="$(command -v cp)"
_fixture_readlink="$(command -v readlink)"

_fixture_source="${BASH_SOURCE[0]}"
while [ -L "$_fixture_source" ]; do
  _fixture_source_dir="$(cd "$(dirname "$_fixture_source")" && pwd -P)"
  _fixture_target="$("$_fixture_readlink" "$_fixture_source")"
  case "$_fixture_target" in
    /*) _fixture_source="$_fixture_target" ;;
    *) _fixture_source="${_fixture_source_dir}/${_fixture_target}" ;;
  esac
done
_fixture_lib_dir="$(cd "$(dirname "$_fixture_source")" && pwd -P)"
FIXTURE_SOURCE_ROOT="$(cd "${_fixture_lib_dir}/../../.." && pwd -P)"

FIXTURE_CLEANUP_DIRS=()
_FIXTURE_TRAP_INSTALLED=0

fixture_cleanup() {
  local fixture_dir
  for fixture_dir in "${FIXTURE_CLEANUP_DIRS[@]}"; do
    [ ! -e "$fixture_dir" ] || "$_fixture_rm" -rf "$fixture_dir" || true
  done
  FIXTURE_CLEANUP_DIRS=()
}

_fixture_install_cleanup_trap() {
  if [ "$_FIXTURE_TRAP_INSTALLED" -eq 0 ]; then
    trap fixture_cleanup EXIT
    _FIXTURE_TRAP_INSTALLED=1
  fi
}

_fixture_usage_error() {
  printf 'fixture_repo: %s\n' "$*" >&2
  return 2
}

fixture_repo() {
  local issue="" scripts_csv="" with_progress=0
  local issue_num=1 script="" source_script="" tmp_dir="" repo="" worktree=""
  local -a scripts=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree)
        [ "$#" -ge 2 ] || {
          _fixture_usage_error "--worktree requires an issue number"
          return 2
        }
        issue="$2"
        shift 2
        ;;
      --with-scripts)
        [ "$#" -ge 2 ] || {
          _fixture_usage_error "--with-scripts requires a CSV list"
          return 2
        }
        scripts_csv="$2"
        shift 2
        ;;
      --progress)
        with_progress=1
        shift
        ;;
      *)
        _fixture_usage_error "unknown option: $1"
        return 2
        ;;
    esac
  done

  if [ -n "$issue" ]; then
    [[ "$issue" =~ ^[0-9]+$ ]] && [ "$((10#$issue))" -gt 0 ] || {
      _fixture_usage_error "--worktree requires a positive integer"
      return 2
    }
    issue_num="$((10#$issue))"
  fi

  if [ -n "$scripts_csv" ]; then
    IFS=',' read -r -a scripts <<< "$scripts_csv"
    case ",${scripts_csv}," in
      *,review-gate.sh,*)
        case ",${scripts_csv}," in
          *,ci-coverage-lib.sh,*) ;;
          *) scripts+=("ci-coverage-lib.sh") ;;
        esac
        ;;
    esac
    for script in "${scripts[@]}"; do
      [[ "$script" =~ ^[A-Za-z0-9._-]+\.sh$ ]] || {
        _fixture_usage_error "invalid script name: $script"
        return 2
      }
      source_script="${FIXTURE_SOURCE_ROOT}/scripts/${script}"
      [ -f "$source_script" ] || {
        _fixture_usage_error "source script does not exist: $script"
        return 2
      }
    done
  fi

  _fixture_install_cleanup_trap
  tmp_dir="$("$_fixture_mktemp" -d "${TMPDIR:-/tmp}/harness-fixture.XXXXXX")"
  FIXTURE_CLEANUP_DIRS+=("$tmp_dir")
  repo="${tmp_dir}/repo"
  "$_fixture_mkdir" -p "${repo}/scripts"

  for script in "${scripts[@]}"; do
    "$_fixture_cp" "${FIXTURE_SOURCE_ROOT}/scripts/${script}" "${repo}/scripts/${script}"
  done

  "$_fixture_git" -C "$repo" init -q -b main
  "$_fixture_git" -C "$repo" config user.name "Harness Test"
  "$_fixture_git" -C "$repo" config user.email "harness-test@example.invalid"
  "$_fixture_git" -C "$repo" config commit.gpgsign false
  printf '/.worktrees/\n.copilot-tracking/\n' > "${repo}/.gitignore"
  printf 'fixture\n' > "${repo}/README.md"
  "$_fixture_git" -C "$repo" add .
  "$_fixture_git" -C "$repo" commit -q -m initial

  FIXTURE_TMP_DIR="$tmp_dir"
  FIXTURE_REPO="$repo"
  FIXTURE_MAIN="$repo"
  FIXTURE_WORKTREE="$repo"
  FIXTURE_BRANCH="main"
  FIXTURE_ISSUE=""
  FIXTURE_PROGRESS=""

  if [ -n "$issue" ]; then
    printf -v FIXTURE_ISSUE '%02d' "$issue_num"
    FIXTURE_BRANCH="feature/issue-${FIXTURE_ISSUE}-fixture"
    worktree="${repo}/.worktrees/issue-${FIXTURE_ISSUE}"
    "$_fixture_git" -C "$repo" worktree add -q -b "$FIXTURE_BRANCH" "$worktree"
    FIXTURE_WORKTREE="$worktree"
  fi

  if [ "$with_progress" -eq 1 ]; then
    [ -n "$FIXTURE_ISSUE" ] || printf -v FIXTURE_ISSUE '%02d' "$issue_num"
    FIXTURE_PROGRESS="${FIXTURE_WORKTREE}/.copilot-tracking/issues/issue-${FIXTURE_ISSUE}/progress.md"
    "$_fixture_mkdir" -p "$(dirname "$FIXTURE_PROGRESS")"
    cat > "$FIXTURE_PROGRESS" <<PROGRESS
# Issue ${issue_num} progress

Status: fixture.

- Branch: \`${FIXTURE_BRANCH}\`
- Worktree: \`${FIXTURE_WORKTREE}\`

## Action Log
PROGRESS
  fi
}
