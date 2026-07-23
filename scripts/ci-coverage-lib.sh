#!/usr/bin/env bash
# ci-coverage-lib.sh — detect code surfaces that lack project-CI coverage.
#
# Issue #129. A "code surface" is a language the harness profiles can detect
# (python, go, node, java, ruby). "Project-CI coverage" means a GitHub Actions
# workflow (.github/workflows/*.yml|*.yaml) OTHER THAN harness-smoke.yml whose
# text references that surface's gate-command signatures (PROFILE_CI_SIGNATURES,
# declared in the profile descriptor). harness-smoke.yml runs the HARNESS's own
# sensors, not an adopting project's gates, so it never counts as project CI.
#
# This library is the ONE place that references language-specific gate tokens on
# behalf of scripts/review-gate.sh and scripts/create-pr.sh, which
# docs/harness-contract.yml freezes as language-neutral. Those owner scripts
# source this lib and print its output through a variable, staying token-free.
#
# Public API (all read $PWD as the repo root):
#   ci_coverage_uncovered_surfaces   -> prints one surface id (python|go|node|
#                                       java|ruby) per line for each detected
#                                       surface with NO project-CI coverage;
#                                       empty output when all covered / docs-only.
#   ci_coverage_message <id>...      -> a single token-free-prefixed human line
#                                       naming the uncovered surfaces.
#
# shellcheck shell=bash

CI_COVERAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_COVERAGE_PROFILES_DIR="${CI_COVERAGE_LIB_DIR}/../profiles"

# The ordered code surfaces subject to the project-CI coverage check. Terraform
# is a code surface but has no unit-test/lint gate-signature model, so it is out
# of scope here (matches the issue's Python/Go/Node/Java/Ruby wording).
CI_COVERAGE_SURFACES="python go node java ruby"

# _ci_coverage_workflows — echo the project workflow files under
# .github/workflows (excluding harness-smoke.yml). Emits nothing when none exist.
_ci_coverage_workflows() {
  local wf
  for wf in "$PWD"/.github/workflows/*.yml "$PWD"/.github/workflows/*.yaml; do
    [ -e "$wf" ] || continue
    case "$(basename "$wf")" in
      harness-smoke.yml | harness-smoke.yaml) continue ;;
    esac
    printf '%s\n' "$wf"
  done
}

# _ci_coverage_surface_sigs <id> — when the profile detects its surface in $PWD,
# print its PROFILE_CI_SIGNATURES and return 0; otherwise print nothing and
# return 1. Sourced in a subshell so the profile's PROFILE_* never leak into the
# caller (e.g. init.sh's live Python descriptor).
_ci_coverage_surface_sigs() {
  local id="$1" profile="${CI_COVERAGE_PROFILES_DIR}/$1.profile.sh"
  [ -f "$profile" ] || return 1
  (
    # shellcheck disable=SC1090
    . "$profile" >/dev/null 2>&1 || exit 2
    declare -F profile_detect >/dev/null 2>&1 || exit 2
    if profile_detect; then
      printf '%s' "${PROFILE_CI_SIGNATURES:-}"
      exit 0
    else
      detect_rc=$?
    fi
    [ "$detect_rc" -eq 1 ] && exit 1
    exit 2
  )
}

# ci_coverage_uncovered_surfaces — print each detected surface (by id) that no
# project workflow covers. A detected surface with no declared signatures cannot
# be proven covered, so it is reported (fail visible rather than silently pass).
ci_coverage_uncovered_surfaces() {
  local workflows id sigs wf covered surface_rc grep_rc
  workflows="$(_ci_coverage_workflows)"
  for id in $CI_COVERAGE_SURFACES; do
    if sigs="$(_ci_coverage_surface_sigs "$id")"; then
      surface_rc=0
    else
      surface_rc=$?
    fi
    if [ "$surface_rc" -eq 1 ]; then
      continue
    elif [ "$surface_rc" -ne 0 ]; then
      return 2
    fi
    covered=0
    if [ -n "$sigs" ] && [ -n "$workflows" ]; then
      while IFS= read -r wf; do
        [ -n "$wf" ] || continue
        if grep -Eq "$sigs" "$wf" 2>/dev/null; then
          covered=1
          break
        else
          grep_rc=$?
          [ "$grep_rc" -eq 1 ] || return 2
        fi
      done <<EOF
$workflows
EOF
    fi
    [ "$covered" = "1" ] || printf '%s\n' "$id"
  done
}

# ci_coverage_message <id>... — a single human line for a set of uncovered
# surface ids, with a token-free static prefix so callers (review-gate.sh) can
# print it verbatim and stay language-neutral.
ci_coverage_message() {
  printf 'project CI coverage missing for: %s' "$*"
}
