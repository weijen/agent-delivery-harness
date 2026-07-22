#!/usr/bin/env bash
# Harness-repository sensor (#348): this repository binds its public GitHub
# identity, while the adopter template remains account-neutral.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINDING="${ROOT}/.github/harness-identity.env"
TEMPLATE="${ROOT}/.github/harness-identity.env.example"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$BINDING" ] || fail "repository identity binding is missing"
grep -Fxq 'HARNESS_GH_ACCOUNT=weijen' "$BINDING" \
  || fail "repository must bind the weijen GitHub account"
grep -Fxq 'HARNESS_GIT_NAME=Wei Jen Lu' "$BINDING" \
  || fail "repository Git author name is incorrect"
grep -Fxq 'HARNESS_GIT_EMAIL=11629+weijen@users.noreply.github.com' "$BINDING" \
  || fail "repository Git noreply email is incorrect"

[ -f "$TEMPLATE" ] || fail "adopter identity template is missing"
if grep -Eq 'weijen|11629' "$TEMPLATE"; then
  fail "adopter template leaks this repository's identity"
fi

printf 'repository identity binding contract honored\n'
