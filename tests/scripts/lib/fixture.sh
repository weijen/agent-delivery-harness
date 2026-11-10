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

fixture_review_pass() {
  local issue="$1" fid="${2:-F1}" root common pad track trace
  root="$("$_fixture_git" rev-parse --show-toplevel)"
  common="$("$_fixture_git" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="${PWD}/${common}" ;; esac
  common="$(cd "$(dirname "$common")" && pwd -P)"
  printf -v pad '%02d' "$((10#$issue))"
  track="${root}/.copilot-tracking/issues/issue-${pad}"
  trace="${common}/.copilot-tracking/issues/issue-${pad}"
  "$_fixture_mkdir" -p "$track" "$trace"
  jq -nc --arg id "$fid" '{features:[{id:$id,title:"Reviewed fixture",steps:[],passes:true,verification:"isolated fixture"}]}' \
    > "${track}/feature_list.json"
  jq -nc --argjson issue "$((10#$issue))" --arg id "$fid" \
    --arg sha "$("$_fixture_git" rev-parse HEAD)" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{schema_version:1,timestamp:$timestamp,span:"agent",span_id:"f000000000000001",
      "harness.issue":$issue,"harness.version":"0.0.0-test",
      "gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor",
      "harness.lifecycle_step":"review_verdict","harness.feature_id":$id,
      "harness.outcome":"pass","harness.review_mode":"full","harness.reviewed_sha":$sha}' \
    >> "${trace}/trace.jsonl"
}

fixture_repo() {
  local issue="" scripts_csv="" with_progress=0
  local issue_num=1 script="" source_script="" tmp_dir="" repo="" worktree=""
  local directory="" script_directory="" copied_scripts=""
  local -a scripts=() sources=()

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
    scripts+=("lib/test-budget-lib.sh")
    case ",${scripts_csv}," in
      *,log-handback.sh,*) scripts+=("trace/log-handback.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,render-action-log.sh,*) scripts+=("trace/render-action-log.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,check-trace-consistency.sh,*) scripts+=("trace/check-trace-consistency.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,init.sh,*) scripts+=("lifecycle/init.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,start-issue.sh,*) scripts+=("lifecycle/start-issue.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,create-pr.sh,*) scripts+=("lifecycle/create-pr.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,merge-pr.sh,*) scripts+=("lifecycle/merge-pr.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,finish-issue.sh,*) scripts+=("lifecycle/finish-issue.sh") ;;
    esac
    case ",${scripts_csv}," in
      *,start-issue.sh,*|*,create-pr.sh,*|*,merge-pr.sh,*|*,finish-issue.sh,*|*,validation/review-gate.sh,*)
        case ",${scripts_csv}," in
          *,lib/lifecycle-runtime-lib.sh,*) ;;
          *) scripts+=("lib/lifecycle-runtime-lib.sh") ;;
        esac
        ;;
    esac
    case ",${scripts_csv}," in
      *,validation/review-gate.sh,*)
        case ",${scripts_csv}," in
          *,lib/ci-coverage-lib.sh,*) ;;
          *) scripts+=("lib/ci-coverage-lib.sh") ;;
        esac
        # Review/publication fixtures use explicit gates and their evidence verifier.
        for dep in validation/rebind-evidence.sh run-sensors.sh validation/run-sensors.sh validation/affected-sensors.sh \
          validation/verify-sensor-evidence.sh validation/check-feature-list.sh lib/issue-lib.sh lib/trace-lib.sh; do
          case ",${scripts_csv}," in
            *,"${dep}",*) ;;
            *) scripts+=("${dep}") ;;
          esac
        done
        ;;
    esac
    case ",${scripts_csv}," in
      *,create-pr.sh,*)
        case ",${scripts_csv}," in
          *,run-sensors.sh,*) ;;
          *) scripts+=("run-sensors.sh") ;;
        esac
        case ",${scripts_csv}," in
          *,validation/affected-sensors.sh,*) ;;
          *) scripts+=("validation/affected-sensors.sh") ;;
        esac
        ;;
    esac
    for script in "${scripts[@]}"; do
      if [ "$script" = run-sensors.sh ]; then
        scripts+=("validation/run-sensors.sh")
        break
      fi
    done
    for script in "${scripts[@]}"; do
      [[ "$script" =~ ^((lib|validation|lifecycle|trace)/)?[A-Za-z0-9._-]+\.sh$ ]] || {
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

  for directory in . lib validation lifecycle trace; do
    sources=()
    for script in "${scripts[@]}"; do
      script_directory="${script%/*}"
      [[ "$script" == */* ]] || script_directory=.
      [ "$script_directory" = "$directory" ] || continue
      case ":${copied_scripts}" in *":${script}:"*) continue ;; esac
      copied_scripts+="${script}:"
      sources+=("${FIXTURE_SOURCE_ROOT}/scripts/${script}")
    done
    [ "${#sources[@]}" -gt 0 ] || continue
    [ "$directory" = . ] || "$_fixture_mkdir" -p "${repo}/scripts/${directory}"
    "$_fixture_cp" "${sources[@]}" "${repo}/scripts/${directory}/"
  done
  if [ -f "${repo}/scripts/run-sensors.sh" ]; then
    "$_fixture_mkdir" -p "${repo}/tests/scripts"
    printf '#!/usr/bin/env bash\nbash -n scripts/run-sensors.sh\n' \
      >"${repo}/tests/scripts/test_fixture_syntax.sh"
  fi

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
