#!/usr/bin/env bash
# Repository-bound GitHub identity helpers. Source this file, then call
# harness_identity_activate before gh or authenticated Git operations.

if [ -n "${__HARNESS_GITHUB_IDENTITY_LIB_SOURCED:-}" ]; then
  return 0
fi
__HARNESS_GITHUB_IDENTITY_LIB_SOURCED=1
__HARNESS_IDENTITY_WARNING_EMITTED=0

harness_identity_repo_root() {
  local root=""
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  (cd "$root" && pwd -P)
}

harness_identity_load() {
  local root="${1:-}" binding="" line="" key="" value=""
  local seen_account=0 seen_name=0 seen_email=0

  if [ -z "$root" ]; then
    root="$(harness_identity_repo_root)" || return 2
  fi
  binding="${root}/.github/harness-identity.env"
  [ -f "$binding" ] || return 2

  # The binding is MACHINE-LOCAL by design (each developer copies the .example
  # and fills their own account). A committed binding turns one person's
  # identity into repo config and hard-breaks every other developer whose
  # machine cannot mint that account's token (apex-vs incident, 2026-07-23).
  if git -C "$root" ls-files --error-unmatch .github/harness-identity.env >/dev/null 2>&1; then
    printf 'warning: .github/harness-identity.env is COMMITTED — it is machine-local; untrack it (git rm --cached) and gitignore it\n' >&2
  fi
  [ ! -L "$binding" ] || {
    printf 'error: refusing symlinked GitHub identity binding: %s\n' "$binding" >&2
    return 1
  }

  unset HARNESS_GH_ACCOUNT HARNESS_GIT_NAME HARNESS_GIT_EMAIL
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        ;;
      *)
        printf 'error: invalid GitHub identity binding line in %s\n' "$binding" >&2
        return 1
        ;;
    esac
    case "$key" in
      HARNESS_GH_ACCOUNT)
        [ "$seen_account" -eq 0 ] || {
          printf 'error: duplicate %s in %s\n' "$key" "$binding" >&2
          return 1
        }
        HARNESS_GH_ACCOUNT="$value"
        seen_account=1
        ;;
      HARNESS_GIT_NAME)
        [ "$seen_name" -eq 0 ] || {
          printf 'error: duplicate %s in %s\n' "$key" "$binding" >&2
          return 1
        }
        HARNESS_GIT_NAME="$value"
        seen_name=1
        ;;
      HARNESS_GIT_EMAIL)
        [ "$seen_email" -eq 0 ] || {
          printf 'error: duplicate %s in %s\n' "$key" "$binding" >&2
          return 1
        }
        HARNESS_GIT_EMAIL="$value"
        seen_email=1
        ;;
      *)
        printf 'error: unsupported key %s in %s\n' "$key" "$binding" >&2
        return 1
        ;;
    esac
  done <"$binding"

  # Underscores appear in GitHub EMU logins (e.g. name_shortcode) even though
  # classic usernames forbid them (adopter finding, foundry PoC 2026-07-23).
  if ! [[ "${HARNESS_GH_ACCOUNT:-}" =~ ^[A-Za-z0-9]+([-_][A-Za-z0-9]+)*$ ]]; then
    printf 'error: HARNESS_GH_ACCOUNT is missing or invalid in %s\n' "$binding" >&2
    return 1
  fi
  if [ -z "${HARNESS_GIT_EMAIL:-}" ] \
    || [[ "${HARNESS_GIT_EMAIL}" =~ [[:space:]] ]]; then
    printf 'error: HARNESS_GIT_EMAIL is missing or invalid in %s\n' "$binding" >&2
    return 1
  fi
  if [ -z "${HARNESS_GIT_NAME:-}" ]; then
    HARNESS_GIT_NAME="${HARNESS_GH_ACCOUNT}"
  fi

  # Unfilled template placeholders are NOT a configuration: applying them
  # would write the literal "Your Git Author Name" into git config and bind a
  # nonexistent account (apex-vs incident, 2026-07-23). Treat as absent.
  case "${HARNESS_GH_ACCOUNT}:${HARNESS_GIT_NAME}:${HARNESS_GIT_EMAIL}" in
    *your-github-account*|*"Your Git Author Name"*)
      printf 'warning: .github/harness-identity.env still contains template placeholders — ignoring the binding until it is filled in\n' >&2
      unset HARNESS_GH_ACCOUNT HARNESS_GIT_NAME HARNESS_GIT_EMAIL
      return 2
      ;;
  esac

  export HARNESS_GH_ACCOUNT HARNESS_GIT_NAME HARNESS_GIT_EMAIL
  return 0
}

harness_identity_activate() {
  local root="${1:-}" load_rc=0 token="" active_account="" verified_account=""

  harness_identity_load "$root" || load_rc=$?
  if [ "$load_rc" -eq 2 ]; then
    if [ "${__HARNESS_IDENTITY_WARNING_EMITTED}" -eq 0 ]; then
      printf 'warning: .github/harness-identity.env not found; using current gh authentication\n' >&2
      __HARNESS_IDENTITY_WARNING_EMITTED=1
    fi
    return 0
  fi
  [ "$load_rc" -eq 0 ] || return "$load_rc"

  if command -v gh >/dev/null 2>&1; then
    active_account="$(
      env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login 2>/dev/null || true
    )"
  fi
  if [ -n "$active_account" ] && [ "$active_account" != "$HARNESS_GH_ACCOUNT" ]; then
    printf "info: global gh account '%s' differs; using repository-bound account '%s' for this process\n" \
      "$active_account" "$HARNESS_GH_ACCOUNT" >&2
  fi

  token="$(
    env -u GH_TOKEN -u GITHUB_TOKEN \
      gh auth token --user "$HARNESS_GH_ACCOUNT" 2>/dev/null
  )" || {
    printf "error: cannot mint a token for bound GitHub account '%s'; run: gh auth login --hostname github.com\n" \
      "$HARNESS_GH_ACCOUNT" >&2
    return 1
  }
  [ -n "$token" ] || {
    printf "error: cannot mint a token for bound GitHub account '%s'; gh returned an empty token\n" \
      "$HARNESS_GH_ACCOUNT" >&2
    return 1
  }

  verified_account="$(
    GH_TOKEN="$token" GITHUB_TOKEN='' gh api user --jq .login 2>/dev/null
  )" || {
    printf "error: token verification failed for bound GitHub account '%s'\n" \
      "$HARNESS_GH_ACCOUNT" >&2
    return 1
  }
  if [ "$verified_account" != "$HARNESS_GH_ACCOUNT" ]; then
    printf "error: token for bound GitHub account '%s' resolved as '%s'\n" \
      "$HARNESS_GH_ACCOUNT" "$verified_account" >&2
    return 1
  fi

  GH_TOKEN="$token"
  export GH_TOKEN
  unset GITHUB_TOKEN
}

harness_identity_configure_git() {
  local root="${1:-}" load_rc=0 remote_url="" remote_path=""

  if [ -z "$root" ]; then
    root="$(harness_identity_repo_root)" || return 1
  fi
  harness_identity_load "$root" || load_rc=$?
  if [ "$load_rc" -eq 2 ]; then
    return 0
  fi
  [ "$load_rc" -eq 0 ] || return "$load_rc"

  git -C "$root" config --local user.name "$HARNESS_GIT_NAME"
  git -C "$root" config --local user.email "$HARNESS_GIT_EMAIL"

  if ! remote_url="$(git -C "$root" remote get-url origin 2>/dev/null)"; then
    return 0
  fi
  case "$remote_url" in
    https://github.com/*|https://*@github.com/*)
      remote_path="${remote_url#https://}"
      remote_path="${remote_path#*/}"
      git -C "$root" remote set-url origin \
        "https://${HARNESS_GH_ACCOUNT}@github.com/${remote_path}"
      git -C "$root" config --local --unset-all \
        credential.https://github.com.helper >/dev/null 2>&1 || true
      git -C "$root" config --local --add \
        credential.https://github.com.helper ''
      git -C "$root" config --local --add \
        credential.https://github.com.helper '!gh auth git-credential'
      ;;
    *)
      printf "warning: origin '%s' is not an HTTPS github.com URL; leaving credential routing unchanged\n" \
        "$remote_url" >&2
      ;;
  esac
}
