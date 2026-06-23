#!/usr/bin/env bash
# Regression sensor (issue #42): the harness documentation must distinguish the
# Core Harness, Language Profiles, and Framework Templates layers; name the
# initial five-profile set (Python, Go, Node.js, Java, Ruby); reference the
# machine-readable contract and the profile generator; and stop reading as a
# Python-first project. These wording guarantees keep the docs in sync with the
# multi-language profile architecture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
require_text() {
  local file="$1" pattern="$2" description="$3"
  if [ ! -f "$file" ]; then
    echo "✗ missing $file (needed for: $description)"; fail=1; return
  fi
  if ! grep -Eiq -- "$pattern" "$file"; then
    echo "✗ missing ${description} in ${file}"; fail=1
  fi
}

# require_exact: like require_text but case-sensitive, to defend proper-noun
# layer names and the exact five-profile enumeration the docs must carry.
require_exact() {
  local file="$1" pattern="$2" description="$3"
  if [ ! -f "$file" ]; then
    echo "✗ missing $file (needed for: $description)"; fail=1; return
  fi
  if ! grep -Eq -- "$pattern" "$file"; then
    echo "✗ missing ${description} in ${file}"; fail=1
  fi
}

# --- docs/HARNESS.md: Core / Profile / Framework boundary + generator + contract
require_exact "docs/HARNESS.md" 'Core Harness' "Core Harness layer"
require_exact "docs/HARNESS.md" 'Language Profiles?' "Language Profiles layer"
require_exact "docs/HARNESS.md" 'Framework Templates?' "Framework Templates layer"
require_text "docs/HARNESS.md" 'harness-contract\.yml' "machine-readable contract reference"
require_text "docs/HARNESS.md" 'test_harness_contract\.sh' "non-regression contract sensor reference"
require_text "docs/HARNESS.md" 'scaffold-language\.sh' "language profile generator reference"
require_text "docs/HARNESS.md" 'profiles/<id>\.profile\.sh|profiles/README\.md' "profile descriptor location reference"
require_exact "docs/HARNESS.md" 'Python, Go, Node\.js, Java,( and)? Ruby' \
  "initial five-profile set named in HARNESS.md"

# --- README.md: not Python-first, names the five profiles, points at the contract
require_text "README.md" 'language-agnostic|language-neutral' "language-neutral framing in the README"
require_exact "README.md" 'Python, Go, Node\.js, Java,( and)? Ruby' \
  "initial five-profile set named in the README"
require_text "README.md" 'profiles/README\.md' "profile contract reference in the README"
require_text "README.md" 'scaffold-language\.sh' "profile generator reference in the README"

# --- AGENTS.md: profile contract + language instruction routing
require_text "AGENTS.md" 'profiles/README\.md' "profile contract reference in the agent map"
require_text "AGENTS.md" 'multi-language-profiles\.md' "multi-language profile design reference in the agent map"
require_text "AGENTS.md" 'scaffold-language\.sh' "language generator reference in the agent map"
require_text "AGENTS.md" '<language>\.instructions\.md' "per-language instruction routing reference in the agent map"
require_text "AGENTS.md" 'harness-contract\.yml' "frozen lifecycle contract reference in the agent map"
require_exact "AGENTS.md" 'Python, Go, Node\.js, Java,( and)? Ruby' \
  "initial five-profile set named in the agent map"

if [ "$fail" -ne 0 ]; then
  echo "docs profile-boundaries sensor FAILED"
  exit 1
fi
echo "docs profile-boundaries documentation checks passed"
