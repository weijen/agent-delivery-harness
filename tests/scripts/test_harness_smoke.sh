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

require_text() {
  local file="$1"
  local pattern="$2"
  local description="$3"

  if ! grep -Eiq "$pattern" "$file"; then
    echo "missing ${description} in ${file}" >&2
    exit 1
  fi
}

require_text ".copilot/instructions/harness.instructions.md" 'harness-enabled projects.*strict|strict.*harness-enabled projects' \
  "strict harness adherence wording"
require_text ".copilot/prompts/session-ritual.prompt.md" 'harness-enabled projects.*strict|strict.*harness-enabled projects' \
  "strict harness adherence wording"

require_text ".copilot/instructions/harness.instructions.md" 'override.*personal workflow tiers|personal workflow tiers.*override' \
  "personal workflow tier override wording"
require_text ".copilot/instructions/harness.instructions.md" 'override.*generic coding-agent behavior|generic coding-agent behavior.*override' \
  "generic coding-agent override wording"

require_text ".copilot/prompts/session-ritual.prompt.md" 'Conductor.*implementation-subagent.*test-subagent.*code-review-subagent' \
  "role separation wording in the prompt path"

require_text ".copilot/instructions/harness.instructions.md" 'deviat(e|es|ed|ion).*stop.*report.*recover|stop.*report.*recover.*deviat(e|es|ed|ion)' \
  "harness deviation stop/report/recover wording"
require_text ".copilot/prompts/session-ritual.prompt.md" 'deviat(e|es|ed|ion).*stop.*report.*recover|stop.*report.*recover.*deviat(e|es|ed|ion)' \
  "harness deviation stop/report/recover wording in the prompt path"

require_text ".copilot/instructions/harness.instructions.md" 'Action Log' \
  "progress Action Log requirement"
require_text ".copilot/instructions/harness.instructions.md" 'Conductor.*Action Log|Action Log.*Conductor' \
  "conductor Action Log requirement"
require_text ".copilot/instructions/harness.instructions.md" 'subagents?.*Action Log|Action Log.*subagents?' \
  "subagent Action Log requirement"
require_text "docs/HARNESS.md" 'Action Log' \
  "issue workflow Action Log wording"

require_text ".copilot/agents/planning-subagent.agent.md" 'Action Log' \
  "planning-subagent Action Log handback instruction"
require_text "scripts/start-issue.sh" '^##[[:space:]]+Action Log' \
  "progress.md Action Log scaffold heading"
require_text ".copilot/agents/code-review-subagent.agent.md" '\*\*Action Log:\*\*' \
  "code-review-subagent Action Log output template entry"
require_text "AGENTS.md" 'strict harness adherence|strictly adhere.*harness|harness.*strictly adhere' \
  "strict harness adherence wording in the agent map"
require_text "AGENTS.md" 'Action Log' \
  "Action Log expectation in the agent map"

printf 'harness smoke passed\n'