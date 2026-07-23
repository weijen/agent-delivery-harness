#!/usr/bin/env bash
# Regression sensor (#369): CI installs ShellCheck from one pinned upstream
# version rather than the runner's mutable distro package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/harness-smoke.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Eq '^  SHELLCHECK_VERSION:[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+$' "$WORKFLOW" \
  || fail "workflow-level ShellCheck version pin is missing"
grep -Fq 'releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz' "$WORKFLOW" \
  || fail "ShellCheck install does not use the pinned upstream release"
grep -Fq '${SHELLCHECK_SHA256}' "$WORKFLOW" \
  || fail "ShellCheck release digest is not verified"
if grep -Eq 'apt-get install([[:space:]]+-y)?[[:space:]]+shellcheck' "$WORKFLOW"; then
  fail "workflow installs an unpinned distro ShellCheck package"
fi

printf 'ShellCheck CI version pin honored\n'
