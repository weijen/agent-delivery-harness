#!/usr/bin/env bash
# Regression sensor (#348): adopters receive a placeholder identity template,
# never this harness repository's account binding.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

TARGET="${TMP_DIR}/target"
mkdir -p "$TARGET"
"$INSTALL" "$TARGET" --write >"${TMP_DIR}/install.out" 2>&1 \
  || {
    cat "${TMP_DIR}/install.out" >&2
    fail "installer must write the adopter identity template"
  }

TEMPLATE="${TARGET}/.github/harness-identity.env.example"
[ -f "$TEMPLATE" ] || fail "installer must ship harness-identity.env.example"
[ ! -e "${TARGET}/.github/harness-identity.env" ] \
  || fail "installer must not propagate the source repository binding"
[ -f "${TARGET}/scripts/github-identity-lib.sh" ] \
  || fail "installer must ship the shared identity helper"
grep -Fq 'HARNESS_GH_ACCOUNT=your-github-account' "$TEMPLATE" \
  || fail "template must show a placeholder account"
if grep -Eq 'weijen|11629' "$TEMPLATE"; then
  fail "template must not contain this repository's account identity"
fi

grep -Fq '.github/harness-identity.env' "${ROOT}/docs/getting-started.md" \
  || fail "getting-started must document repository identity binding"
grep -Fq "never runs \`gh auth switch\`" "${ROOT}/docs/getting-started.md" \
  || fail "documentation must state the non-mutating global-account contract"

BOUND_TARGET="${TMP_DIR}/bound-target"
mkdir -p "${BOUND_TARGET}/.github"
git -C "$BOUND_TARGET" init -q -b main
git -C "$BOUND_TARGET" remote add origin https://github.com/example/adopter.git
cat >"${BOUND_TARGET}/.github/harness-identity.env" <<'EOF'
HARNESS_GH_ACCOUNT=adopter-account
HARNESS_GIT_NAME=Adopter Author
HARNESS_GIT_EMAIL=123+adopter-account@users.noreply.github.com
EOF
"$INSTALL" "$BOUND_TARGET" --write >"${TMP_DIR}/bound-install.out" 2>&1 \
  || {
    cat "${TMP_DIR}/bound-install.out" >&2
    fail "installer must apply an existing target binding"
  }
[ "$(git -C "$BOUND_TARGET" config --local user.name)" = "Adopter Author" ] \
  || fail "installer must apply target-local Git author identity"
[ "$(git -C "$BOUND_TARGET" remote get-url origin)" = \
  "https://adopter-account@github.com/example/adopter.git" ] \
  || fail "installer must route the target origin through its own bound account"

printf 'installer identity template contract honored\n'
