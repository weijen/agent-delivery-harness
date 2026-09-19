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

require() {
  local path="$1"
  local claim="$2"
  grep -qF "$claim" "$path" || fail "${path} is missing current claim: ${claim}"
}

reject_regex() {
  local path="$1"
  local contradiction="$2"
  ! grep -Eqi "$contradiction" "$path" \
    || fail "${path} retains contradictory claim: ${contradiction}"
}

reject README.md "required only once Python code is added"
reject README.md "docs-only repo (like this spec pack today)"
reject README.md "suite (with coverage)"
reject docs/getting-started.md "A docs-only repo (like this one today)"
reject .copilot/instructions/harness.instructions.md "docs-only era; ruff/mypy/pytest once Python lands"
# Adversarial (code-review-subagent, issue #384): the same stale claims the
# feature removed from one bullet still appear elsewhere in the identical file.
reject .copilot/instructions/harness.instructions.md "with coverage"
reject .copilot/instructions/harness.instructions.md "Docs-only era:"
reject .copilot/instructions/harness.instructions.md "Code era:"
reject .copilot/instructions/harness.instructions.md "docs-era equivalent"

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

require docs/HARNESS.md 'green local sensor run on macOS is **advisory**'
require docs/HARNESS.md 'merge-time CI result is authoritative'
require docs/HARNESS.md 'git log --reverse | head -1'
require docs/HARNESS.md 'exited 141 on Ubuntu'
for divergence in \
  'pipelines whose consumer exits early' \
  "BSD versus GNU \`sed -i\` syntax" \
  "\`date\` flags and output formats" \
  "\`mktemp\` templates and option support" \
  "locale- or implementation-dependent \`sort\` behavior" \
  'Git version-specific command and pipeline behavior'; do
  require docs/HARNESS.md "$divergence"
done
require docs/HARNESS.md "\`trace.jsonl\` lives under \`.copilot-tracking/issues/issue-NN/\` in the **main checkout**"
require docs/HARNESS.md "\`feature_list.json\`, \`plan.md\`, and \`progress.md\` live under the same relative path"
require docs/HARNESS.md '**issue worktree**'
reject_regex docs/HARNESS.md 'local.*macOS.*authoritative'
reject_regex docs/HARNESS.md 'trace\.jsonl.*issue worktree'
reject_regex docs/HARNESS.md 'feature_list\.json.*main checkout'

require docs/getting-started.md "Tested upgrade skew: \`v0.36.0\` to \`v0.37.3\`"
require docs/getting-started.md 'five downstream-diverged managed files'
require docs/getting-started.md 'first update preserved every adopter version'
require docs/getting-started.md 'repeat update classified each as adopter-only'
reject docs/getting-started.md 'v0.17.0'
reject_regex docs/getting-started.md 'tested[^.]*all[^.]*versions'

profile_current="$(awk '
  /^## Current profile workflow/ {capture=1; next}
  capture && /^## / {exit}
  capture {print}
' docs/multi-language-profiles.md)"
for authority in profiles/README.md scripts/scaffold-language.sh docs/harness-contract.yml \
  tests/scripts/test_harness_contract.sh .copilot-tracking/review-gate/issue-NN/approved-head; do
  printf '%s\n' "$profile_current" | grep -qF "$authority" \
    || fail "current profile workflow must reference ${authority}"
  case "$authority" in
    .copilot-tracking/*) ;;
    *) [ -f "$authority" ] || fail "documented profile authority missing: ${authority}" ;;
  esac
done
require docs/multi-language-profiles.md '](archive/multi-language-profiles.md)'
require docs/archive/multi-language-profiles.md '# Language Profiles: Historical Design'
reject docs/multi-language-profiles.md 'Before any profile generator'
if printf '%s\n' "$profile_current" | grep -qiE 'before.*implemented|add a generator|review-gate/approved-head'; then
  fail "current profile workflow must not describe shipped work as pending or use unscoped approval"
fi
require profiles/README.md 'explicit marker'
reject_regex profiles/README.md 'moves a language.s surface detection|does not hard-code the details'
require scripts/init.sh 'pyproject.toml'
require scripts/init.sh 'package.json'

for doc in product-quality-rubric failure-mode-taxonomy observability-and-trace-schema github-copilot; do
  [ -f "docs/${doc}.md" ] || fail "current operating guide missing: docs/${doc}.md"
  [ ! -e "docs/evaluation/${doc}.md" ] \
    || fail "research directory retains duplicate operating authority: ${doc}"
  [ ! -e "docs/runtime-adapters/${doc}.md" ] \
    || fail "adapter directory retains duplicate operating authority: ${doc}"
  require scripts/install-harness.sh "docs/${doc}.md"
done
for consumer in AGENTS.md .copilot/instructions/harness.instructions.md \
  .copilot/agents/code-review-subagent.agent.md docs/HARNESS.md \
  schemas/trace-schema.v1.json; do
  reject_regex "$consumer" 'docs/(evaluation/(product-quality-rubric|failure-mode-taxonomy|observability-and-trace-schema)|runtime-adapters/github-copilot)\.md'
done
require .copilot/agents/code-review-subagent.agent.md 'docs/product-quality-rubric.md'
require .copilot/instructions/harness.instructions.md 'docs/observability-and-trace-schema.md'
require docs/github-copilot.md '](observability-and-trace-schema.md)'
require docs/observability-and-trace-schema.md '](../schemas/trace-schema.v1.json)'
require docs/failure-mode-taxonomy.md '](../schemas/trace-schema.v1.json)'

printf 'current-state documentation checks passed\n'
