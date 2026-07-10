#!/usr/bin/env bash
# Regression sensor (issue #177): skill references must resolve.
#   - The obsolete `general` skill is deleted and no tracked file still points at
#     .copilot/skills/general/ (the modernization review reports, which document
#     the deletion decision, are the only allowed mentions).
#   - create-pr's pre-PR quality gates reference only skills that exist; the dead
#     `skills/typescript` / `skills/python` / `skills/testing` refs stay removed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

skills_dir=".copilot/skills"

# 1. The general skill is gone.
[ ! -e "${skills_dir}/general" ] || note "${skills_dir}/general must be deleted"

# 2. No tracked file references the deleted general skill (the modernization
#    review reports, which document the deletion decision, are the only allowed
#    exceptions).
while IFS= read -r f; do
  case "$f" in
    docs/skill-prompt-modernization-review.md) continue ;;
    docs/subagent-prompt-modernization-review.md) continue ;;
    tests/meta/test_skill_references_resolve.sh) continue ;;
  esac
  note "$f still references the deleted skills/general path"
done < <(git grep -l 'skills/general' -- '*.md' '*.sh' 2>/dev/null || true)

# 2b. No living doc presents `general` as a skill via a bare backtick reference
#     `general` (the path-form leg #2 only catches skills/general refs, not the
#     bare-word form). The historical/changelog docs that narrate #177's removal
#     in past tense are the only allowed exceptions.
# shellcheck disable=SC2016  # `general` is a literal grep pattern, not a command substitution
while IFS= read -r f; do
  case "$f" in
    docs/PROGRESS.md) continue ;;
    docs/copilot-health-check.md) continue ;;
    docs/skill-prompt-modernization-review.md) continue ;;
    docs/subagent-prompt-modernization-review.md) continue ;;
    tests/meta/test_skill_references_resolve.sh) continue ;;
  esac
  note "$f presents the deleted \`general\` skill as a live bare-word skill reference"
done < <(git grep -l '`general`' -- '*.md' 2>/dev/null || true)

# 3. create-pr must not reference nonexistent skills.
cp="${skills_dir}/create-pr/SKILL.md"
if [ -f "$cp" ]; then
  for dead in typescript python testing; do
    grep -q "skills/${dead}" "$cp" && note "$cp references nonexistent skill skills/${dead}"
  done
  # Every skills/<name> it does reference must resolve to a real skill dir.
  while IFS= read -r name; do
    [ -d "${skills_dir}/${name}" ] || note "$cp references nonexistent skill skills/${name}"
  done < <(grep -oE 'skills/[a-z0-9-]+' "$cp" | sed 's#skills/##' | sort -u)
fi

# 4. code-review frontmatter is normalized to kebab-case (X-5).
cr="${skills_dir}/code-review/SKILL.md"
if [ -f "$cr" ]; then
  grep -Eq '^name:[[:space:]]*code-review[[:space:]]*$' "$cr" \
    || note "$cr frontmatter name: must be code-review (kebab-case)"
fi

if [ "$fail" -ne 0 ]; then
  echo "skill-references-resolve sensor FAILED"
  exit 1
fi
echo "skill-references-resolve checks passed"
