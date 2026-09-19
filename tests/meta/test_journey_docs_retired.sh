#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cd "$ROOT"

inventory="${TMP_DIR}/inventory"
awk '
  /<!-- documentation-inventory:start -->/ {capture=1; next}
  /<!-- documentation-inventory:end -->/ {capture=0}
  capture && /^\| `docs\// {
    gsub(/`/, ""); split($0, fields, "|")
    for (i=2; i<=4; i++) gsub(/^ +| +$/, "", fields[i])
    print fields[2] "\t" fields[3] "\t" fields[4]
  }
' docs/evaluation/README.md >"$inventory"
[ "$(cut -f1 "$inventory" | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')" = \
  b641530f15b82f7ce64ed46eddf8110d9f9034a8296c2ef977cd4f288ce2bb55 ] \
  || { echo "documentation inventory must account for all 62 audited original files"; exit 1; }
while IFS=$'\t' read -r original canonical kind; do
  [ -f "$canonical" ] || { echo "inventory destination missing: ${canonical}"; exit 1; }
  case "$kind" in adopter|maintainer|research|history|optional|project-owned) ;;
    *) echo "unclassified document: ${original}"; exit 1 ;;
  esac
  if [ "$original" != "$canonical" ]; then
    [ ! -e "$original" ] || { echo "duplicate old authority remains: ${original}"; exit 1; }
  fi
done <"$inventory"

check_snapshot() {
  local path="$1"
  local expected_hash="$2"
  local stripped target
  stripped="${TMP_DIR}/$(basename "$path")"

  grep -qF '<!-- snapshot-retirement:start -->' "$path" \
    || { echo "journey-retirement: notice start missing from ${path}"; exit 1; }
  grep -qF 'point-in-time snapshot' "$path" \
    || { echo "journey-retirement: snapshot warning missing from ${path}"; exit 1; }
  # shellcheck disable=SC2016  # backticks are literal Markdown, not shell syntax
  grep -qF 'export scripts and `trace_tools` examples no longer run' "$path" \
    || { echo "journey-retirement: retired examples missing from ${path}"; exit 1; }
  grep -qF '#352' "$path" \
    || { echo "journey-retirement: topology retirement missing from ${path}"; exit 1; }
  grep -qF '#394' "$path" \
    || { echo "journey-retirement: current contract transition missing from ${path}"; exit 1; }
  # shellcheck disable=SC2016  # backticks are literal Markdown, not shell syntax
  grep -qF '[`docs/harness-contract.yml`](../harness-contract.yml)' "$path" \
    || { echo "journey-retirement: current doctrine link missing from ${path}"; exit 1; }

  while IFS= read -r target; do
    case "$target" in https://*|http://*|mailto:*|\#*) continue ;; esac
    [ -e "$(dirname "$path")/${target%%#*}" ] \
      || { echo "journey-retirement: broken link ${target} in ${path}"; exit 1; }
  done < <(grep -oE '\]\([^)]*\)' "$path" | sed -E 's/^\]\(//; s/\)$//')

  # Link targets may relocate; preserve every other byte of the original narrative.
  awk '
    /<!-- snapshot-retirement:start -->/ { skip = 1; next }
    /<!-- snapshot-retirement:end -->/ { skip = 0; next }
    !skip
  ' "$path" | sed -E 's/\]\([^)]*\)/](LINK)/g' >"$stripped"
  [ "$(shasum -a 256 "$stripped" | awk '{print $1}')" = "$expected_hash" ] \
    || { echo "journey-retirement: historical body changed in ${path}"; exit 1; }
}

check_snapshot docs/archive/observability-journey.md \
  f8fe63b0c1890865f62e82e9fe320dbdc5e0ab64a2dd945fb143516ede9cb583
check_snapshot docs/archive/deep-tracing-journey.md \
  7d694e36e0ed583572a2c1e44f2486e60f0b823fc8659881068bad255660023c

for spec in README architecture spec; do
  [ -s "docs/evaluation/l0-solution/${spec}.md" ] \
    && [ -s "docs/evaluation/l1-solution/${spec}.md" ] \
    || { echo "active evaluation specification missing: ${spec}"; exit 1; }
done
for issue in 66 67 68 69; do
  grep -q "issues/${issue})" docs/evaluation/l1-solution/implementation-issues.md \
    || { echo "pending L1 issue missing from live index: ${issue}"; exit 1; }
done
if grep -Eq '^### Issue |^## Phase |^## Acceptance' docs/evaluation/l1-solution/implementation-issues.md; then
  echo "L1 index must not duplicate issue requirements"; exit 1
fi
while IFS= read -r doc; do
  while IFS= read -r target; do
    case "$target" in https://*|http://*|mailto:*|\#*) continue ;; esac
    [ -e "$(dirname "$doc")/${target%%#*}" ] \
      || { echo "documentation broken link: ${doc} -> ${target}"; exit 1; }
  done < <(grep -oE '\]\([^[:space:])]+\)' "$doc" | sed -E 's/^\]\(//; s/\)$//')
done < <(find docs -type f -name '*.md' | LC_ALL=C sort)

printf 'documentation inventory, links and journey retirement checks passed\n'
