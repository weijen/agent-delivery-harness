#!/usr/bin/env bash
# Regression sensor (issue #53): the public-exposure-audit skill must exist and
# document the full exposure-audit workflow — the sweep scope, the identifier
# categories, the non-exposure classification, the report fields, and the
# no-mandatory-scanner stance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

skill=".copilot/skills/public-exposure-audit/SKILL.md"

if [ ! -f "$skill" ]; then
  note "missing $skill"
  echo "public-exposure-audit skill sensor FAILED"
  exit 1
fi

# Valid opening + closing frontmatter fence.
awk 'NR==1 && $0!="---" {exit 2} NR>1 && $0=="---" {found=1; exit 0} END {if(!found) exit 3}' "$skill" \
  || note "$skill must open and close YAML frontmatter with ---"

# Frontmatter name.
grep -Eq '^name:[[:space:]]*public-exposure-audit[[:space:]]*$' "$skill" \
  || note "$skill frontmatter name: must be public-exposure-audit"

# --- Scope of the sweep ---
grep -Eiq 'tracked file' "$skill"                       || note "$skill must cover tracked files"
grep -Eiq 'reachable.*histor|git log|rev-list|--all'    "$skill" || note "$skill must cover reachable Git history"
grep -Eiq 'git metadata|author.*email|committer'        "$skill" || note "$skill must cover Git metadata / author email"
grep -Eiq 'ignored'  "$skill"                           || note "$skill must cover ignored files"
grep -Eiq 'untracked' "$skill"                          || note "$skill must cover untracked files"
grep -Eiq 'branch'   "$skill"                           || note "$skill must cover branch tips"

# --- Identifier categories ---
grep -Eiq 'personal' "$skill"                           || note "$skill must cover personal identifiers"
grep -Eiq 'company|internal' "$skill"                   || note "$skill must cover company/internal references"
grep -Eiq 'vendor|account|resource' "$skill"            || note "$skill must cover vendor/account/resource identifiers"
grep -Eiq 'local path|path' "$skill"                    || note "$skill must cover local paths"
grep -Eiq 'secret' "$skill"                             || note "$skill must cover secrets"
grep -Eiq 'token' "$skill"                              || note "$skill must cover tokens"
grep -Eiq 'cloud' "$skill"                              || note "$skill must cover cloud identifiers"
grep -Eiq 'subscription|tenant' "$skill"                || note "$skill must cover subscription/tenant IDs"
grep -Eiq 'url|endpoint' "$skill"                       || note "$skill must cover URLs/endpoints"

# --- Classification of non-exposure (AC#2) ---
grep -Eiq 'intentional public' "$skill"                 || note "$skill must classify intentional public documentation"
grep -Eiq 'synthetic|fixture' "$skill"                  || note "$skill must classify synthetic fixtures"
grep -Eiq 'example\.com|example email|invalid.*example' "$skill" || note "$skill must classify invalid example emails"
grep -Eiq 'placeholder' "$skill"                        || note "$skill must classify placeholder env var names"

# --- Report fields (AC#3) ---
grep -Eiq 'severity' "$skill"                           || note "$skill report must include severity"
grep -Eiq 'evidence' "$skill"                           || note "$skill report must include evidence"
grep -Eiq 'push' "$skill"                               || note "$skill report must include remote/push status"
grep -Eiq 'remediation' "$skill"                        || note "$skill report must include remediation guidance"
grep -Eiq 'residual risk' "$skill"                      || note "$skill report must include residual risk"

# --- No mandatory scanner dependency ---
grep -Eiq 'optional' "$skill"                           || note "$skill must mark third-party scanners optional"

if [ "$fail" -ne 0 ]; then
  echo "public-exposure-audit skill sensor FAILED"
  exit 1
fi
echo "public-exposure-audit skill checks passed"
