#!/usr/bin/env bash
# Regression sensor (issue #182, #173 drift-sensor pattern): the profile-aware
# routing map in .copilot/instructions/harness.instructions.md must stay in sync
# with the language instruction files that actually exist on disk.
#
# Two directions, both must hold:
#   1. Referential integrity — every concrete `<name>.instructions.md` the map
#      names must exist on disk (no dangling routes).
#   2. Reachability — every language instruction file on disk must be reachable
#      from the map (no orphaned instruction file that a subagent would never be
#      routed to). Structural, non-language instruction files are exempt.
#
# This is what would have caught A-X1: bash.instructions.md and
# terraform-azure.instructions.md existed but the map never routed to them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

harness=".copilot/instructions/harness.instructions.md"
instr_dir=".copilot/instructions"

# Structural instruction files that are NOT per-language routing targets: the
# harness contract itself, the always-on TDD discipline, and cross-project
# workflow doctrine. These are referenced by role, not by file-extension routing.
structural="harness tdd workflow-tiers"

fail=0
note() { echo "✗ $*"; fail=1; }

[ -f "$harness" ] || { echo "✗ missing $harness"; exit 1; }

# --- Direction 1: every instruction file named by the map must exist -----------
# The generic placeholder `<language>.instructions.md` reads as
# `language.instructions.md` under this pattern; it is not a concrete file.
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  [ "$ref" = "language.instructions.md" ] && continue
  [ -f "${instr_dir}/${ref}" ] || note "routing map names ${ref} but ${instr_dir}/${ref} does not exist"
done < <(grep -oE '[a-z0-9_-]+\.instructions\.md' "$harness" | sort -u)

# --- Direction 2: every language instruction file on disk must be reachable -----
for f in "${instr_dir}"/*.instructions.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .instructions.md)"
  case " $structural " in
    *" $base "*) continue ;;
  esac
  grep -qF "${base}.instructions.md" "$harness" ||
    note "${f} exists but is not reachable from the routing map in ${harness} (add a routing entry)"
done

if [ "$fail" -ne 0 ]; then
  echo "routing-map drift sensor FAILED"
  exit 1
fi
echo "routing-map drift checks passed"
