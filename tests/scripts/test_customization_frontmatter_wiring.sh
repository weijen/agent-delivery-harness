#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

note() {
  printf 'PASS: %s\n' "$1"
}

shared_invocation='bash tests/evals/bin/validate-customization-frontmatter.sh'
consumers=(
  .github/workflows/harness-smoke.yml
  tests/scripts/test_harness_smoke.sh
)
invocation_patterns=(
  '^[[:space:]]+run:[[:space:]]+bash tests/evals/bin/validate-customization-frontmatter\.sh$'
  '^bash tests/evals/bin/validate-customization-frontmatter\.sh$'
)

for index in "${!consumers[@]}"; do
  consumer="${consumers[$index]}"
  invocation_count="$(grep -Ec "${invocation_patterns[$index]}" "$consumer" || true)"
  [ "$invocation_count" -eq 1 ] ||
    fail "${consumer} must invoke ${shared_invocation} exactly once"

  if grep -Fq 'files=(.copilot/agents/*.agent.md .copilot/skills/*/SKILL.md)' "$consumer"; then
    fail "${consumer} still contains the obsolete customization discovery parser"
  fi

  if grep -Fq "for file in \"\${files[@]}\"; do" "$consumer"; then
    fail "${consumer} still contains the obsolete customization frontmatter loop"
  fi
done

note "local smoke and GitHub Actions share customization frontmatter validation"