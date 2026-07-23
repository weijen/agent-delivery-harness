#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

reports=(
  copilot-health-check.md
  skill-prompt-modernization-review.md
  subagent-prompt-modernization-review.md
)

for report in "${reports[@]}"; do
  [ ! -e "docs/${report}" ] \
    || { echo "archived-reports: living report remains: docs/${report}"; exit 1; }
  [ -s "docs/archive/${report}" ] \
    || { echo "archived-reports: archive missing: docs/archive/${report}"; exit 1; }
done

health="docs/archive/copilot-health-check.md"
while IFS= read -r target; do
  case "$target" in
    http://*|https://*|\#*) continue ;;
  esac
  target="${target%%#*}"
  [ -e "docs/archive/${target}" ] \
    || { echo "archived-reports: broken health-check link: ${target}"; exit 1; }
done < <(grep -oE '\[[^]]+\]\([^)]+\)' "$health" | sed -E 's/^.*\(([^)]+)\)$/\1/')

printf 'archived report checks passed\n'
