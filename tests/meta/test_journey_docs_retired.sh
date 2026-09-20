#!/usr/bin/env bash
# Guard usable documentation references and historical/current guidance boundaries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

check_retirement_notice() {
  local path="$1" notice
  notice="$(awk '
    /^<!-- snapshot-retirement:start -->$/ { capture=1; next }
    capture && /^<!-- snapshot-retirement:end -->$/ { complete=1; exit }
    capture { print }
    END { if (!complete) exit 1 }
  ' "$path")" \
    || { echo "journey-retirement: bounded retirement notice missing from ${path}"; exit 1; }
  if ! grep -Eqi '\bretired\b' <<<"$notice" \
    || ! grep -Eqi '\b(historical|snapshot)\b' <<<"$notice"; then
    echo "journey-retirement: historical retirement warning missing from ${path}"
    exit 1
  fi
  grep -Eq '\]\(\.\./harness-contract\.yml(#[^)]*)?\)' <<<"$notice" \
    || { echo "journey-retirement: current doctrine link missing from notice in ${path}"; exit 1; }
}

check_retirement_notice docs/archive/observability-journey.md
check_retirement_notice docs/archive/deep-tracing-journey.md

for spec in README architecture spec; do
  [ -s "docs/evaluation/l0-solution/${spec}.md" ] \
    && [ -s "docs/evaluation/l1-solution/${spec}.md" ] \
    || { echo "active evaluation specification missing: ${spec}"; exit 1; }
done
while IFS= read -r doc; do
  while IFS= read -r target; do
    case "$target" in https://*|http://*|mailto:*|\#*) continue ;; esac
    [ -e "$(dirname "$doc")/${target%%#*}" ] \
      || { echo "documentation broken link: ${doc} -> ${target}"; exit 1; }
  done < <(grep -oE '\]\([^[:space:])]+\)' "$doc" | sed -E 's/^\]\(//; s/\)$//')
done < <(find docs -type f -name '*.md' | LC_ALL=C sort)

printf 'documentation links, active specifications and journey retirement checks passed\n'
