#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() {
  echo "current-state-docs: $*" >&2
  exit 1
}

reject() {
  local path="$1"
  local stale="$2"
  ! grep -qF "$stale" "$path" || fail "${path} retains stale claim: ${stale}"
}

reject README.md "required only once Python code is added"
reject README.md "docs-only repo (like this spec pack today)"
reject README.md "suite (with coverage)"
reject docs/getting-started.md "A docs-only repo (like this one today)"
reject .copilot/instructions/harness.instructions.md "docs-only era; ruff/mypy/pytest once Python lands"

for path in README.md docs/getting-started.md .copilot/instructions/harness.instructions.md; do
  grep -qiF "dormant" "$path" || fail "${path} does not describe the dormant Python surface"
done

for path in README.md docs/getting-started.md docs/multi-language-profiles.md docs/HARNESS.md; do
  for language in Go Java Ruby; do
    grep -Ei "${language}.*scaffold" "$path" >/dev/null \
      || fail "${path} does not label ${language} gates as scaffold-level"
  done
done

reject docs/HARNESS.md "not by hard-coded branches"
reject docs/HARNESS.md "The core does not hard-code any language"
reject docs/multi-language-profiles.md "through profiles rather than new hard-coded"
grep -qiF "explicit marker" docs/HARNESS.md \
  || fail "docs/HARNESS.md does not describe explicit marker detection"
grep -qiF "explicit marker" docs/multi-language-profiles.md \
  || fail "docs/multi-language-profiles.md does not describe explicit marker detection"

printf 'current-state documentation checks passed\n'
