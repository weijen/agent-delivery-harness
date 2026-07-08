#!/usr/bin/env bash
# Regression sensor (issue #184, #173 drift-sensor pattern): subagent model pins.
#
# A `model:` pin in an agent's frontmatter rots — when the Copilot model lineup
# moves on, an unknown pin either silently falls back to a default or fails to
# launch, both invisible to the conductor (issue #184, report A-X6). Policy
# (decided with the human): the subagents inherit the session model; no agent
# frontmatter carries a `model:` pin.
#
# Two directions, both must hold:
#   1. No stranded pin — no `.copilot/agents/*.agent.md` frontmatter carries a
#      `model:` key. All subagents inherit the session model.
#   2. Documented drift guard — the sync-docs skill names stale model-pin
#      frontmatter as a high-rot pattern, so a future model generation that
#      re-introduces a pin is caught by the docs-hygiene surface, not silently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

agents_dir=".copilot/agents"
sync_docs=".copilot/skills/sync-docs/SKILL.md"

fail=0
note() { echo "✗ $*"; fail=1; }

# --- Direction 1: no agent frontmatter carries a model: pin ---------------------
for f in "${agents_dir}"/*.agent.md; do
  [ -f "$f" ] || continue
  # Read only the frontmatter block (between the first and second `---`).
  frontmatter="$(awk 'NR==1 && $0=="---"{inb=1; next} inb && $0=="---"{exit} inb{print}' "$f")"
  if printf '%s\n' "$frontmatter" | grep -qE '^[[:space:]]*model:'; then
    pin="$(printf '%s\n' "$frontmatter" | grep -E '^[[:space:]]*model:' | head -1)"
    note "${f} frontmatter pins a model ('${pin# }') — remove it so the subagent inherits the session model"
  fi
done

# --- Direction 2: sync-docs documents stale model-pin frontmatter as high-rot ---
[ -f "$sync_docs" ] || { echo "✗ missing $sync_docs"; exit 1; }
if ! grep -qiE 'model[- ]pin' "$sync_docs"; then
  note "${sync_docs} does not name stale model-pin frontmatter as a high-rot pattern (add it so pin drift is caught)"
fi

if [ "$fail" -ne 0 ]; then
  echo "agent model-pin sensor FAILED"
  exit 1
fi
echo "agent model-pin checks passed"
