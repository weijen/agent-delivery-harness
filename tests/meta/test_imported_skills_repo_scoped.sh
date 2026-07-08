#!/usr/bin/env bash
# Regression sensor (issue #178): the security-audit and code-review skills were
# imported wholesale from awesome-ai-agent-skills; this pins them to their
# repo-scoped, example-free rewrite so a future edit cannot re-import the generic
# originals (fabricated findings, absent-tool mandates, foreign author metadata).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

sec=".copilot/skills/security-audit/SKILL.md"
cr=".copilot/skills/code-review/SKILL.md"

# --- No imported provenance frontmatter on either skill ---
for f in "$sec" "$cr"; do
  [ -f "$f" ] || { note "missing $f"; continue; }
  grep -Eiq '^(license|author):' "$f" && note "$f must not carry imported license/author frontmatter"
  grep -Eiq 'awesome-ai-agent-skills' "$f" && note "$f must not credit the awesome-ai-agent-skills import"
  grep -Eq '^name:[[:space:]]*'"$(basename "$(dirname "$f")")"'[[:space:]]*$' "$f" \
    || note "$f frontmatter name: must match its folder (kebab-case)"
done

# --- security-audit is repo-scoped, built-in-tools-first, and keeps severity ---
if [ -f "$sec" ]; then
  grep -Eiq 'workflow permission|permissions:' "$sec" || note "$sec must cover GitHub Actions workflow permissions"
  grep -Eiq 'injection' "$sec"                         || note "$sec must cover shell/CI script injection"
  grep -Eiq 'secret' "$sec"                            || note "$sec must cover secrets handling"
  grep -Eiq 'pin' "$sec"                               || note "$sec must cover dependency/action pinning"
  grep -Eiq 'built-in tools first|scanners? (are )?optional|optional accelerator' "$sec" \
    || note "$sec must take the built-in-tools-first, scanners-optional stance"
  grep -Eiq 'severity' "$sec"                          || note "$sec must keep a severity classification"
  # Must NOT mandate the imported generic scanners as hard requirements.
  grep -Eiq 'prowler|scoutsuite|owasp zap' "$sec" \
    && note "$sec must not mandate imported cloud/web scanners (Prowler/ScoutSuite/OWASP ZAP)"
fi

# --- code-review keeps its judgment scaffold and drops the worked examples ---
if [ -f "$cr" ]; then
  grep -Eiq 'understand the intent' "$cr" || note "$cr must keep the 'understand the intent first' review step"
  if ! { grep -Eq 'Critical' "$cr" && grep -Eq 'Warning' "$cr" && grep -Eq 'Info' "$cr"; }; then
    note "$cr must keep the Critical/Warning/Info severity vocabulary"
  fi
  grep -Eiq 'Review Checklist' "$cr" || note "$cr must keep the review checklist table"
  # The fabricated worked examples (fake SQLi / MD5 / N+1 demos) must be gone.
  grep -Eiq 'hashlib\.md5|OR .1.=.1|order_items WHERE order_id' "$cr" \
    && note "$cr must not reintroduce the fabricated worked examples"
fi

if [ "$fail" -ne 0 ]; then
  echo "imported-skills-repo-scoped sensor FAILED"
  exit 1
fi
echo "imported-skills-repo-scoped checks passed"
