#!/usr/bin/env bash
# Agent frontmatter policy and resolvable shared customization references.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
fail() { printf 'agent-model-pins: %s\n' "$*" >&2; exit 1; }

for file in .copilot/agents/*.agent.md; do
	[ -f "$file" ] || continue
	frontmatter="$(awk 'NR==1 && $0=="---"{inb=1; next} inb && $0=="---"{exit} inb{print}' "$file")"
	if grep -qE '^[[:space:]]*model:' <<<"$frontmatter"; then
		fail "${file} pins a model instead of inheriting the session model"
	fi
done

shared=".copilot/skills/_audit-conventions.md"
[ -f "$shared" ] || fail "missing ${shared}"
[ "$(sed -n '1p' "$shared")" != '---' ] || fail "${shared} must not have YAML frontmatter"
for skill in find-brute-force find-duplicates find-over-design dead-code-detection; do
	file=".copilot/skills/${skill}/SKILL.md"
	[ -f "$file" ] || fail "missing ${file}"
	grep -Fq '_audit-conventions.md' "$file" || fail "${file} lacks its shared reference"
done

review=".copilot/agents/code-review-subagent.agent.md"
[ -f "$review" ] || fail "missing ${review}"
for reference in public-exposure-audit/SKILL.md _review-known-false-positives.md; do
	[ -f ".copilot/skills/${reference}" ] || fail "missing reference target: ${reference}"
	grep -Fq "$reference" "$review" || fail "${review} lacks reference: ${reference}"
done

for skill in security-audit code-review public-exposure-audit; do
	file=".copilot/skills/${skill}/SKILL.md"
	[ -f "$file" ] || fail "missing ${file}"
	frontmatter="$(awk 'NR==1 && $0=="---"{inb=1; next} inb && $0=="---"{exit} inb{print}' "$file")"
	grep -Eq "^name:[[:space:]]*${skill}[[:space:]]*$" <<<"$frontmatter" \
		|| fail "${file} frontmatter name does not match its directory"
	if grep -Eq '^(license|author):' <<<"$frontmatter"; then
		fail "${file} carries imported provenance frontmatter"
	fi
done

printf 'agent frontmatter policy and shared references passed\n'
