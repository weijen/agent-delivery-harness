#!/usr/bin/env bash
# Regression sensor (issue #199): the reusable instruction files stay free of
# extraction residue from the Azure AI Foundry / Content Understanding project
# the harness was carved out of.
#
#   - "Content Understanding" and "1-week POC" must not appear at all (they are
#     product facts / a stale assumption, not reusable doctrine).
#   - "Foundry" may appear ONLY on a line that explicitly marks it as an example
#     (contains "e.g."), never as a bare fact about the repo.
#
# The Azure-scoped terraform file (`terraform-azure.instructions.md`, applyTo
# '**/*.tf') is intentionally Azure-specific and is checked by the same rules:
# Azure itself is allowed, but the extracted product nouns are not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

instr_dir=".copilot/instructions"
[ -d "$instr_dir" ] || { echo "no $instr_dir; nothing to check"; exit 0; }

# 1. Banned outright: the specific product noun and the stale POC assumption.
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  note "banned product residue (remove entirely): $hit"
done < <(grep -rniE 'content understanding|1-week POC' "$instr_dir" || true)

# 2. Foundry allowed only as an explicitly-marked example (line contains "e.g.").
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  case "$hit" in
    *e.g.*|*E.g.*|*eg:*) : ;;  # marked example — allowed
    *) note "unmarked Foundry product reference (genericize or mark as e.g. example): $hit" ;;
  esac
done < <(grep -rniE 'foundry' "$instr_dir" || true)

if [ "$fail" -ne 0 ]; then
  echo "instructions-product-generic sensor FAILED"
  exit 1
fi
echo "instructions-product-generic checks passed"
