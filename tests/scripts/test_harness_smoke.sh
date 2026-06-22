#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT"

[ -f .github/workflows/harness-smoke.yml ] || { echo "missing harness-smoke workflow" >&2; exit 1; }

bash -n scripts/*.sh
shellcheck scripts/*.sh

shopt -s nullglob
files=(.copilot/agents/*.agent.md .copilot/skills/*/SKILL.md)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No Copilot agent or skill files found; skipping frontmatter validation."
else
  for file in "${files[@]}"; do
    awk '
      NR == 1 && $0 != "---" { exit 1 }
      NR > 1 && $0 == "---" { found = 1; exit 0 }
      END { if (!found) exit 1 }
    ' "$file"
  done
fi

if git grep -n -E 'check-pr\.sh|gh pr checks --watch|required status checks|branch protection gate' -- .github README.md AGENTS.md scripts; then
  echo "old CI/CD watch or branch-protection wording was reintroduced" >&2
  exit 1
fi

printf 'harness smoke passed\n'