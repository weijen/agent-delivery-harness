#!/usr/bin/env bash
# Regression sensor (#369): CI installs ShellCheck from one pinned upstream
# version rather than the runner's mutable distro package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/harness-smoke.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Eq '^  SHELLCHECK_VERSION:[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+$' "$WORKFLOW" \
  || fail "workflow-level ShellCheck version pin is missing"
INSTALLER="${ROOT}/scripts/install/install-ci-tool.sh"
for workflow in "$WORKFLOW" "${ROOT}/profiles/adopter-smoke.yml"; do
  version="$(awk '$1 == "SHELLCHECK_VERSION:" {print $2}' "$workflow")"
  digest="$(awk '$1 == "SHELLCHECK_SHA256:" {print $2}' "$workflow")"
  grep -Fxq "SHELLCHECK_VERSION_PIN=$version" "$INSTALLER" || fail "ShellCheck version parity differs"
  grep -Fxq "SHELLCHECK_SHA256_PIN=$digest" "$INSTALLER" || fail "ShellCheck checksum parity differs"
  grep -Fq 'run: ./scripts/install-ci-tool.sh shellcheck' "$workflow" \
    || fail "workflow does not use verified shared installation"
done
if grep -Eq 'apt-get install([[:space:]]+-y)?[[:space:]]+shellcheck' "$WORKFLOW"; then
  fail "workflow installs an unpinned distro ShellCheck package"
fi

printf 'ShellCheck CI version pin honored\n'
