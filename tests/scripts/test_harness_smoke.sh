#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT"

[ -f .github/workflows/harness-smoke.yml ] || { echo "missing harness-smoke workflow" >&2; exit 1; }

# tests/evals/bin/*.sh added for issue #61 f3 (eval tooling lint coverage).
# tests/scripts/lib/*.sh added for issue #64 f3 (fold-in of #63 deferral): the
# TAP helper tap.sh is lint-clean, so this adds no spurious failure.
bash -n scripts/*.sh tests/evals/bin/*.sh tests/scripts/lib/*.sh
shellcheck scripts/*.sh profiles/*.profile.sh tests/evals/bin/*.sh tests/scripts/lib/*.sh

bash tests/evals/bin/validate-customization-frontmatter.sh

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

require_top_level_permissions_contents_read() {
  local file="$1"

  if ! awk -v file="$file" '
    BEGIN {
      top_permissions = 0
      in_permissions = 0
      contents_read = 0
      error = ""
    }
    /^permissions:[[:space:]]*\{[^}]*contents:[[:space:]]*read[^}]*\}[[:space:]]*(#.*)?$/ {
      top_permissions = 1
      contents_read = 1
      next
    }
    /^[^[:space:]#][^:]*:[[:space:]]*$/ {
      if (in_permissions) {
        in_permissions = 0
        if (!contents_read && error == "") {
          error = "top-level permissions block is missing contents: read"
        }
      }
      if ($0 == "permissions:") {
        top_permissions = 1
        in_permissions = 1
        next
      }
    }
    in_permissions && /^  contents:[[:space:]]*read([[:space:]]*#.*)?$/ { contents_read = 1 }
    END {
      if (error == "" && !top_permissions) {
        error = "missing top-level permissions block"
      }
      if (error == "" && !contents_read) {
        error = "top-level permissions block is missing contents: read"
      }
      if (error != "") {
        printf "%s in %s\n", error, file > "/dev/stderr"
        exit 1
      }
    }
  ' "$file"; then
    exit 1
  fi
}

require_pinned_action_ref() {
  local file="$1"
  local action="$2"
  local version_comment="$3"

  if ! awk -v file="$file" -v action="$action" -v version_comment="$version_comment" '
    BEGIN {
      found = 0
      valid = 1
    }
    $0 ~ "^[[:space:]]+uses:[[:space:]]" action "@" {
      found = 1
      if ($0 !~ "^[[:space:]]+uses:[[:space:]]" action "@[0-9a-fA-F]{40}[[:space:]]*# " version_comment "([[:space:]].*)?$") {
        printf "mutable or uncommented %s ref in %s:%d: %s\n", action, file, NR, $0 > "/dev/stderr"
        valid = 0
      }
    }
    END {
      if (!found) {
        printf "missing %s uses step in %s\n", action, file > "/dev/stderr"
        exit 1
      }
      exit(valid ? 0 : 1)
    }
  ' "$file"; then
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

require_text ".copilot/prompts/session-ritual.prompt.md" 'One agent owns the issue end-to-end' \
  "single-agent ownership wording in the prompt path (#352)"
require_text ".copilot/prompts/session-ritual.prompt.md" 'code-review-subagent.*review' \
  "independent reviewer role wording in the prompt path"

require_text ".copilot/instructions/harness.instructions.md" 'deviat(e|es|ed|ion).*stop.*report.*recover|stop.*report.*recover.*deviat(e|es|ed|ion)' \
  "harness deviation stop/report/recover wording"
require_text ".copilot/prompts/session-ritual.prompt.md" 'deviat(e|es|ed|ion).*stop.*report.*recover|stop.*report.*recover.*deviat(e|es|ed|ion)' \
  "harness deviation stop/report/recover wording in the prompt path"

require_text ".copilot/instructions/harness.instructions.md" 'Action Log' \
  "progress Action Log requirement"
require_text ".copilot/instructions/harness.instructions.md" 'Action Log.*rendered|rendered.*Action Log' \
  "rendered Action Log requirement (#332/#352)"
require_text "docs/HARNESS.md" 'Action Log' \
  "issue workflow Action Log wording"

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

# --- Eval tooling CI lint coverage (#61 f3) ----------------------------------
# The CI workflow must lint tests/evals/bin/*.sh with BOTH bash -n (syntax) and
# the shellcheck linter, so a broken eval tool (e.g. validate-manifest.sh)
# fails CI.
require_text "$workflow" 'bash -n[^\n]*tests/evals/bin' \
  "workflow bash -n syntax coverage of tests/evals/bin"
require_text "$workflow" 'shellcheck[^\n]*tests/evals/bin' \
  "workflow shellcheck coverage of tests/evals/bin"

# --- TAP helper lib CI lint coverage (#64 f3, fold-in of #63 deferral) --------
# The CI workflow must lint tests/scripts/lib/*.sh (the TAP helper tap.sh) with
# BOTH bash -n (syntax) and the shellcheck linter. The tests/scripts/*.sh glob
# is non-recursive, so lib/ is otherwise missed by CI.
require_text "$workflow" 'bash -n[^\n]*tests/scripts/lib' \
  "workflow bash -n syntax coverage of tests/scripts/lib"
require_text "$workflow" 'shellcheck[^\n]*tests/scripts/lib' \
  "workflow shellcheck coverage of tests/scripts/lib"

# --- Python workflow hardening (#268) ----------------------------------------
python_workflows=(.github/workflows/harness-smoke.yml .github/workflows/python-ci.yml)
for workflow in "${python_workflows[@]}"; do
  require_top_level_permissions_contents_read "$workflow"
  require_pinned_action_ref "$workflow" 'actions/checkout' 'v4'
  require_pinned_action_ref "$workflow" 'astral-sh/setup-uv' 'v5'
done

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