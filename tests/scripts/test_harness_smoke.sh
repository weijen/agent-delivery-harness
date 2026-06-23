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

# --- Bash instructions (#44) -------------------------------------------------
bash_instructions=".copilot/instructions/bash.instructions.md"
[ -f "$bash_instructions" ] || { echo "missing ${bash_instructions}" >&2; exit 1; }
awk '
  NR == 1 && $0 != "---" { exit 1 }
  NR > 1 && $0 == "---" { found = 1; exit 0 }
  END { if (!found) exit 1 }
' "$bash_instructions" || { echo "missing/invalid frontmatter in ${bash_instructions}" >&2; exit 1; }

require_text "$bash_instructions" 'applyTo:.*scripts/\*\*/\*\.sh' \
  "applyTo glob for harness scripts"
require_text "$bash_instructions" 'applyTo:.*tests/\*\*/\*\.sh' \
  "applyTo glob for harness shell tests"
require_text "$bash_instructions" 'set -euo pipefail' \
  "strict-mode expectation"
require_text "$bash_instructions" 'shellcheck' \
  "shellcheck validation expectation"
require_text "$bash_instructions" 'bash -n' \
  "syntax-check validation expectation"
require_text "$bash_instructions" 'trap' \
  "trap/cleanup guidance"
require_text "$bash_instructions" 'fake|fixture' \
  "fake CLI fixture guidance"
require_text "$bash_instructions" 'temp(orary)?[ -]?(repo|dir)|mktemp' \
  "temporary repo/dir guidance"
require_text "$bash_instructions" 'hard[ -]?fail|warning|warn' \
  "hard-fail vs warning exit-semantics guidance"
require_text "$bash_instructions" 'byte-for-byte|snapshot' \
  "behavioral contract test guidance"

require_text "AGENTS.md" 'bash\.instructions\.md' \
  "Bash instructions reference in the agent map"

# --- CI sensor-suite execution (#51) -----------------------------------------
workflow=".github/workflows/harness-smoke.yml"
require_text "$workflow" 'tests/scripts/test_\*\.sh' \
  "workflow execution of the tests/scripts sensor glob"
require_text "$workflow" 'tests/meta/test_\*\.sh' \
  "workflow execution of the tests/meta sensor glob"
require_text "$workflow" 'shellcheck[^\n]*tests/' \
  "workflow shellcheck coverage of tests/"

# --- CI-green merge gate doctrine (#51) --------------------------------------
require_text ".copilot/instructions/harness.instructions.md" 'merge-pr\.sh' \
  "merge-pr.sh reference in the harness merge doctrine"
require_text ".copilot/instructions/harness.instructions.md" 'green.*(precondition|before.*merg)|(precondition|before.*merg).*green' \
  "green-CI precondition for merge wording"
require_text "AGENTS.md" 'merge-pr\.sh' \
  "merge-pr.sh reference in the agent map golden rules"
require_text "AGENTS.md" 'green.*CI|CI.*green' \
  "green-CI merge precondition wording in the agent map"
require_text "docs/HARNESS.md" 'merge-pr\.sh' \
  "merge-pr.sh reference in the HARNESS smoke boundary"
require_text "docs/HARNESS.md" 'branch-protection required check' \
  "branch-protection required-check recommendation"

# --- Public exposure audit skill (#53) ---------------------------------------
require_text ".copilot/instructions/harness.instructions.md" 'public-exposure-audit' \
  "public-exposure-audit skill in the verify-gate inferential sensor set"
require_text "AGENTS.md" 'public-exposure-audit' \
  "public-exposure-audit skill row in the agent map skills table"

printf 'harness smoke passed\n'