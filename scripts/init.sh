#!/usr/bin/env bash
# init.sh — preflight + environment sensor for the harness repo.
#
# Run this at the START of every agent/dev session. It is a SENSOR, not an
# interactive installer: it CHECKS that you are logged in and the environment is
# healthy, and fails loudly with remediation instructions if a HARD check fails.
# It never runs an interactive `az login` / `gh auth login` itself.
#
# Hard requirements (exit 1 if missing): git, gh, gh auth.
# Soft requirements (warn only while the project has no code yet):
#   - uv / Python 3.14: required once a pyproject.toml lives at the repo root.
#   - az / Azure login: required for Foundry / Terraform / deploy work
#     (opt in with REQUIRE_AZ=1 ./scripts/init.sh).
#
# Exit codes:
#   0  environment ready
#   1  a hard preflight check failed (fix it, then re-run)

set -euo pipefail

# Pin VIRTUAL_ENV to this repo's venv when one exists. Without this, a VIRTUAL_ENV
# inherited from a sibling checkout makes every `uv run` print a yellow warning.
[ -d "$PWD/.venv" ] && export VIRTUAL_ENV="$PWD/.venv"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

fail=0
note_fail() {
  red "  ✗ $1"
  if [ -n "${2:-}" ]; then
    printf '    → %s\n' "$2"
  fi
  fail=1
  return 0
}
note_warn() {
  yellow "  ! $1"
  if [ -n "${2:-}" ]; then
    printf '    → %s\n' "$2"
  fi
  return 0
}
note_ok() {
  green "  ✓ $1"
  return 0
}

# run_gate_loop — iterate the currently-sourced PROFILE_GATES, printing OK / SKIP
# / FAIL from the descriptor's message strings. A gate exit code of 2 means SKIP
# (an optional tool/script is absent) → warn, not hard-fail; any other nonzero is
# a real failure that fails preflight. Python gates only return 0/1, so the SKIP
# branch is dormant for Python and its hard-fail contract is preserved.
run_gate_loop() {
  local g ok_var fail_var fix_var skip_var rc skip_msg
  for g in "${PROFILE_GATES[@]}"; do
    ok_var="PROFILE_GATE_${g}_OK"
    fail_var="PROFILE_GATE_${g}_FAIL"
    fix_var="PROFILE_GATE_${g}_FIX"
    skip_var="PROFILE_GATE_${g}_SKIP"
    if "profile_gate_${g}" >/dev/null 2>&1; then
      note_ok "${!ok_var}"
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        skip_msg="${!skip_var:-}"
        [ -n "$skip_msg" ] || skip_msg="${g} skipped"
        note_warn "$skip_msg"
      else
        note_fail "${!fail_var}" "${!fix_var}"
      fi
    fi
  done
}

repo_name="$(basename "$PWD")"
bold "==> ${repo_name} preflight"

# Load the language profile descriptor(s). Python surface detection, dependency
# sync, and quality gates are declared in profiles/<id>.profile.sh rather than
# hard-coded here (issue #35). Go/Node/Terraform remain inline compatibility
# paths until their own profile issues land.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/../profiles"
if [ ! -f "${PROFILES_DIR}/python.profile.sh" ]; then
  red "profile descriptor missing: ${PROFILES_DIR}/python.profile.sh"
  exit 1
fi
# shellcheck source=profiles/python.profile.sh
. "${PROFILES_DIR}/python.profile.sh"

# Project-CI coverage detection (issue #129) — guarded source so a checkout that
# predates the lib still runs preflight.
CI_COVERAGE_LIB="${SCRIPT_DIR}/ci-coverage-lib.sh"
if [ -f "$CI_COVERAGE_LIB" ]; then
  # shellcheck source=scripts/ci-coverage-lib.sh
  . "$CI_COVERAGE_LIB"
fi

# 1. Required CLIs ------------------------------------------------------------
echo "[1/6] Required tools"
gh_identity_ready=1
for tool in git gh; do
  if command -v "$tool" >/dev/null 2>&1; then
    note_ok "$tool found"
  else
    note_fail "$tool not found" "install it before continuing"
  fi
done
if [ -f "${SCRIPT_DIR}/github-identity-lib.sh" ] && command -v gh >/dev/null 2>&1; then
  # shellcheck source=scripts/github-identity-lib.sh
  source "${SCRIPT_DIR}/github-identity-lib.sh"
  if ! harness_identity_activate "$(harness_identity_repo_root)"; then
    gh_identity_ready=0
    note_fail \
      "repository-bound GitHub account is unavailable" \
      "authenticate the account named in .github/harness-identity.env"
  fi
fi
# uv / az are soft until the project needs them.
for tool in uv az; do
  if command -v "$tool" >/dev/null 2>&1; then
    note_ok "$tool found"
  else
    note_warn "$tool not installed" "install when you reach the matching phase (uv for code, az for Foundry/infra)"
  fi
done

shellcheck_pin_file="${SCRIPT_DIR}/../.github/workflows/harness-smoke.yml"
shellcheck_ci_version=""
if [ -f "$shellcheck_pin_file" ]; then
  shellcheck_ci_version="$(awk '$1 == "SHELLCHECK_VERSION:" { print $2; exit }' "$shellcheck_pin_file")"
fi
if [ -n "$shellcheck_ci_version" ]; then
  if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck_local_version="$(shellcheck --version 2>/dev/null \
      | awk -F ': ' '$1 == "version" { print $2; exit }')"; then
      shellcheck_local_version=""
    fi
    if [ "$shellcheck_local_version" = "$shellcheck_ci_version" ]; then
      note_ok "ShellCheck ${shellcheck_local_version} matches CI"
    else
      note_warn \
        "ShellCheck version mismatch: local ${shellcheck_local_version:-unknown}, CI ${shellcheck_ci_version}" \
        "install ShellCheck ${shellcheck_ci_version} for CI parity"
    fi
  else
    note_warn \
      "ShellCheck not installed; CI uses ${shellcheck_ci_version}" \
      "install ShellCheck ${shellcheck_ci_version} for CI parity"
  fi
fi

# 2. GitHub auth (HARD-FAIL) --------------------------------------------------
echo "[2/6] GitHub authentication"
if [ "$gh_identity_ready" -eq 0 ]; then
  :
elif gh auth status >/dev/null 2>&1; then
  note_ok "gh authenticated ($(gh api user --jq .login 2>/dev/null || echo '?'))"
elif [ "${ALLOW_GH_UNAUTH:-0}" = "1" ]; then
  note_warn "gh not authenticated (allowed for devcontainer bootstrap)" "run: gh auth login"
else
  note_fail "gh not authenticated" "run: gh auth login"
fi

# 3. Azure auth (conditional) -------------------------------------------------
# Local docs / harness work should not be blocked by an expired Azure session.
# Foundry, Terraform, and deploy work must opt in with REQUIRE_AZ=1 ./scripts/init.sh.
echo "[3/6] Azure authentication"
if command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then
  note_ok "az logged in (sub: $(az account show --query name -o tsv 2>/dev/null || echo '?'))"
elif [ "${REQUIRE_AZ:-0}" = "1" ]; then
  note_fail "az not authenticated (REQUIRE_AZ=1)" "install az + run: az login"
else
  note_warn "az not authenticated (required for Foundry/infra/deploy; run: REQUIRE_AZ=1 ./scripts/init.sh)"
fi

# 4. Commit signing (warn) ----------------------------------------------------
echo "[4/6] Commit signing"
if [ "$(git config --get commit.gpgsign 2>/dev/null)" = "true" ]; then
  sigfmt="$(git config --get gpg.format 2>/dev/null || echo gpg)"
  note_ok "commit signing enabled ($sigfmt)"
else
  note_warn "commit signing not enabled for this repo (commits may show Unverified)"
fi

# 5. Project surfaces --------------------------------------------------------
echo "[5/6] Project surfaces"
has_python=0 has_go=0 has_node=0 has_ruby=0 has_java=0 has_terraform=0
profile_detect && has_python=1
[ -f "$PWD/go.mod" ] && has_go=1
[ -f "$PWD/package.json" ] && has_node=1
[ -f "$PWD/Gemfile" ] && has_ruby=1
{ [ -f "$PWD/pom.xml" ] || [ -f "$PWD/build.gradle" ] || [ -f "$PWD/build.gradle.kts" ]; } && has_java=1
if find "$PWD" -maxdepth 3 -name '*.tf' -not -path '*/.terraform/*' -print -quit | grep -q .; then has_terraform=1; fi

# The Go, Node, Ruby, and Java descriptors are sourced late (step 6) so they do
# not clobber Python's PROFILE_* before the Python gate loop runs. Extract just
# their surface labels now via subshell sources so these report lines stay
# descriptor-driven.
go_label=""
if [ "$has_go" = "1" ]; then
  # shellcheck disable=SC1091  # sourced in a subshell purely to read its label
  go_label="$(. "$PROFILES_DIR/go.profile.sh" >/dev/null 2>&1; printf '%s' "$PROFILE_SURFACE_LABEL")"
  [ -n "$go_label" ] || go_label="Go surface detected (go.mod)"
fi
node_label=""
if [ "$has_node" = "1" ]; then
  # shellcheck disable=SC1091  # sourced in a subshell purely to read its label
  node_label="$(. "$PROFILES_DIR/node.profile.sh" >/dev/null 2>&1; printf '%s' "$PROFILE_SURFACE_LABEL")"
  [ -n "$node_label" ] || node_label="Node surface detected (package.json)"
fi
ruby_label=""
if [ "$has_ruby" = "1" ]; then
  # shellcheck disable=SC1091  # sourced in a subshell purely to read its label
  ruby_label="$(. "$PROFILES_DIR/ruby.profile.sh" >/dev/null 2>&1; printf '%s' "$PROFILE_SURFACE_LABEL")"
  [ -n "$ruby_label" ] || ruby_label="Ruby surface detected (Gemfile)"
fi
java_label=""
if [ "$has_java" = "1" ]; then
  # shellcheck disable=SC1091  # sourced in a subshell purely to read its label
  java_label="$(. "$PROFILES_DIR/java.profile.sh" >/dev/null 2>&1; printf '%s' "$PROFILE_SURFACE_LABEL")"
  [ -n "$java_label" ] || java_label="Java surface detected (pom.xml/build.gradle)"
fi

if [ "$has_python$has_go$has_node$has_ruby$has_java$has_terraform" = "000000" ]; then
  note_ok "docs-only project surface detected"
else
  [ "$has_python" = "1" ] && note_ok "$PROFILE_SURFACE_LABEL"
  [ "$has_go" = "1" ] && note_ok "$go_label"
  [ "$has_node" = "1" ] && note_ok "$node_label"
  [ "$has_ruby" = "1" ] && note_ok "$ruby_label"
  [ "$has_java" = "1" ] && note_ok "$java_label"
  [ "$has_terraform" = "1" ] && note_ok "Terraform surface detected (*.tf)"
fi

# Project-CI coverage (issue #129): a detected code surface with no project
# workflow running its gates is a WARN here — it fails closed later at the
# Pre-PR ci-gate. harness-smoke.yml is the harness's own CI, not project CI.
if declare -F ci_coverage_uncovered_surfaces >/dev/null 2>&1; then
  uncovered_surfaces="$(ci_coverage_uncovered_surfaces 2>/dev/null || true)"
  if [ -n "$uncovered_surfaces" ]; then
    note_warn "$(ci_coverage_message "$(printf '%s' "$uncovered_surfaces" | tr '\n' ' ')")" \
      "add a .github/workflows/*.yml that runs the project gates; the Pre-PR ci-gate fails closed until then (bypass: SKIP_CI_GATE=1)"
  fi
fi

if [ "$has_python" = "1" ]; then
  if ! command -v "$PROFILE_TOOL_REQUIREMENTS" >/dev/null 2>&1; then
    note_fail "$PROFILE_TOOL_MISSING" "$PROFILE_TOOL_MISSING_FIX"
  elif profile_sync >/dev/null 2>&1; then
    note_ok "$PROFILE_SYNC_OK"
  else
    note_fail "$PROFILE_SYNC_FAIL" "$PROFILE_SYNC_FIX"
  fi
else
  note_warn "$PROFILE_SYNC_SKIP_MSG"
fi

# 6. Quality gates (language-detected) ---------------------------------------
echo "[6/6] Quality gates"
if [ "$fail" -ne 0 ]; then
  yellow "  ! skipping gates until earlier preflight failures are fixed"
else
  if [ "$has_python" = "1" ]; then
    run_gate_loop
  fi

  if [ "$has_go" = "1" ]; then
    if [ ! -f "$PROFILES_DIR/go.profile.sh" ]; then
      note_warn "Go surface detected but its profile is not installed (generator-supported) — skipping Go gates" "regenerate it: ./scripts/scaffold-language.sh go --write"
    elif command -v go >/dev/null 2>&1; then
      # Source the Go descriptor now (late) so its PROFILE_* override Python's
      # after the Python gate loop has already run, then drive the shared loop.
      # shellcheck source=/dev/null  # generator-supported descriptor, present only once scaffolded
      . "$PROFILES_DIR/go.profile.sh"
      run_gate_loop
    else
      note_warn "Go surface detected but go is not installed — skipping Go gates" "install go to run: go vet ./... && go test ./..."
    fi
  fi

  if [ "$has_node" = "1" ]; then
    if command -v node >/dev/null 2>&1; then
      # Source the Node descriptor now (late) so its PROFILE_* override Python's
      # after the Python gate loop has already run, then drive the shared loop.
      # shellcheck source=profiles/node.profile.sh
      . "$PROFILES_DIR/node.profile.sh"
      run_gate_loop
    else
      note_warn "Node surface detected but node is not installed — skipping Node gates" "install node to run the project's format/lint/test scripts"
    fi
  fi

  if [ "$has_ruby" = "1" ]; then
    if [ ! -f "$PROFILES_DIR/ruby.profile.sh" ]; then
      note_warn "Ruby surface detected but its profile is not installed (generator-supported) — skipping Ruby gates" "regenerate it: ./scripts/scaffold-language.sh ruby --write"
    elif command -v ruby >/dev/null 2>&1; then
      # Source the Ruby descriptor now (late) so its PROFILE_* override Python's
      # after the Python gate loop has already run, then drive the shared loop.
      # shellcheck source=/dev/null  # generator-supported descriptor, present only once scaffolded
      . "$PROFILES_DIR/ruby.profile.sh"
      run_gate_loop
    else
      note_warn "Ruby surface detected but ruby is not installed — skipping Ruby gates" "install ruby + bundler to run the project's lint/test"
    fi
  fi

  if [ "$has_java" = "1" ]; then
    if [ ! -f "$PROFILES_DIR/java.profile.sh" ]; then
      note_warn "Java surface detected but its profile is not installed (generator-supported) — skipping Java gates" "regenerate it: ./scripts/scaffold-language.sh java --write"
    else
      # Source the Java descriptor now (late) so its PROFILE_* override Python's
      # after the Python gate loop has already run, then drive the shared loop.
      # The gate functions self-SKIP (return 2) when the build tool / wrapper is
      # unavailable or an optional Spotless/lint tool is not configured.
      # shellcheck source=/dev/null  # generator-supported descriptor, present only once scaffolded
      . "$PROFILES_DIR/java.profile.sh"
      run_gate_loop
    fi
  fi

  if [ "$has_terraform" = "1" ]; then
    if command -v terraform >/dev/null 2>&1; then
      if terraform fmt -check -recursive >/dev/null 2>&1; then note_ok "terraform fmt clean"; else note_fail "terraform fmt failed" "terraform fmt -recursive"; fi
      if find "$PWD" -name '.terraform' -type d -print -quit | grep -q .; then
        if terraform validate >/dev/null 2>&1; then note_ok "terraform validate clean"; else note_fail "terraform validate failed" "terraform validate"; fi
      else
        note_warn "Terraform surface detected but .terraform is absent — skipping terraform validate" "run terraform init in the relevant module"
      fi
    else
      note_warn "Terraform surface detected but terraform is not installed — skipping Terraform gates" "install terraform to run fmt/validate"
    fi
  fi

  if [ "$has_python$has_go$has_node$has_ruby$has_java$has_terraform" = "000000" ]; then
    note_warn "docs-only project — no language gates detected; run shellcheck on the harness scripts when you touch them"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  green "Preflight passed. Environment is ready."
  echo "Next: read .copilot-tracking/issues/<issue>/progress.md (or project docs if no issue yet) and pick the next feature."
  exit 0
else
  red "Preflight FAILED. Fix the items above and re-run ./scripts/init.sh"
  exit 1
fi
