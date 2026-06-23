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

# 1. Required CLIs ------------------------------------------------------------
echo "[1/6] Required tools"
for tool in git gh; do
  if command -v "$tool" >/dev/null 2>&1; then
    note_ok "$tool found"
  else
    note_fail "$tool not found" "install it before continuing"
  fi
done
# uv / az are soft until the project needs them.
for tool in uv az; do
  if command -v "$tool" >/dev/null 2>&1; then
    note_ok "$tool found"
  else
    note_warn "$tool not installed" "install when you reach the matching phase (uv for code, az for Foundry/infra)"
  fi
done

# 2. GitHub auth (HARD-FAIL) --------------------------------------------------
echo "[2/6] GitHub authentication"
if gh auth status >/dev/null 2>&1; then
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
has_python=0 has_go=0 has_pnpm=0 has_terraform=0
profile_detect && has_python=1
[ -f "$PWD/go.mod" ] && has_go=1
if [ -f "$PWD/pnpm-lock.yaml" ] || [ -f "$PWD/package.json" ]; then has_pnpm=1; fi
if find "$PWD" -maxdepth 3 -name '*.tf' -not -path '*/.terraform/*' -print -quit | grep -q .; then has_terraform=1; fi

if [ "$has_python$has_go$has_pnpm$has_terraform" = "0000" ]; then
  note_ok "docs-only project surface detected"
else
  [ "$has_python" = "1" ] && note_ok "$PROFILE_SURFACE_LABEL"
  [ "$has_go" = "1" ] && note_ok "Go surface detected (go.mod)"
  [ "$has_pnpm" = "1" ] && note_ok "Node/pnpm surface detected (package.json or pnpm-lock.yaml)"
  [ "$has_terraform" = "1" ] && note_ok "Terraform surface detected (*.tf)"
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
    for g in "${PROFILE_GATES[@]}"; do
      ok_var="PROFILE_GATE_${g}_OK"
      fail_var="PROFILE_GATE_${g}_FAIL"
      fix_var="PROFILE_GATE_${g}_FIX"
      if "profile_gate_${g}" >/dev/null 2>&1; then
        note_ok "${!ok_var}"
      else
        note_fail "${!fail_var}" "${!fix_var}"
      fi
    done
  fi

  if [ "$has_go" = "1" ]; then
    if command -v go >/dev/null 2>&1; then
      if go test ./... >/dev/null 2>&1; then note_ok "go test passing"; else note_fail "go test failed" "go test ./..."; fi
      if go vet ./... >/dev/null 2>&1; then note_ok "go vet clean"; else note_fail "go vet failed" "go vet ./..."; fi
    else
      note_warn "Go surface detected but go is not installed — skipping Go gates" "install go to run: go test ./... && go vet ./..."
    fi
  fi

  if [ "$has_pnpm" = "1" ]; then
    if command -v pnpm >/dev/null 2>&1; then
      if [ -f "$PWD/package.json" ] && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
        if pnpm test >/dev/null 2>&1; then note_ok "pnpm test passing"; else note_fail "pnpm test failed" "pnpm test"; fi
      else
        note_warn "Node/pnpm surface has no package.json test script — skipping pnpm test"
      fi
    else
      note_warn "Node/pnpm surface detected but pnpm is not installed — skipping pnpm gates" "install pnpm to run project scripts"
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

  if [ "$has_python$has_go$has_pnpm$has_terraform" = "0000" ]; then
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
