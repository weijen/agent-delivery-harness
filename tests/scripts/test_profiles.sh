#!/usr/bin/env bash
# Regression sensor (issue #35): the profile descriptor format and the Python
# descriptor must exist, declare every Profile Interface field, and expose the
# detection/sync/gate functions init.sh drives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

desc="profiles/python.profile.sh"
readme="profiles/README.md"

if [ ! -f "$desc" ]; then
  note "missing $desc"
  echo "profiles sensor FAILED"
  exit 1
fi
[ -f "$readme" ] || note "missing $readme (descriptor format must be documented)"

bash -n "$desc" || note "$desc is not valid bash"

# README documents the Profile Interface field set.
if [ -f "$readme" ]; then
  for field in detect variants sync format_check lint typecheck test tool_requirements instructions frameworks; do
    grep -Eiq -- "$field" "$readme" || note "$readme must document the '$field' field"
  done
fi

# Source the descriptor in a hermetic subshell and assert its shape.
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<PROBE
set -euo pipefail
# shellcheck source=/dev/null
. "$ROOT/$desc"
[ "\${PROFILE_ID:-}" = "python" ] || { echo "BAD PROFILE_ID=\${PROFILE_ID:-}"; exit 11; }
case "\${PROFILE_DETECT:-}" in *pyproject.toml*) : ;; *) echo "BAD PROFILE_DETECT"; exit 12 ;; esac
[ "\${PROFILE_SURFACE_LABEL:-}" = "Python surface detected (pyproject.toml)" ] || { echo "BAD LABEL"; exit 13; }
[ "\${PROFILE_TOOL_REQUIREMENTS:-}" = "uv" ] || { echo "BAD TOOLREQ"; exit 14; }
[ -n "\${PROFILE_INSTRUCTIONS:-}" ] || { echo "EMPTY INSTRUCTIONS"; exit 15; }
[ -n "\${PROFILE_FRAMEWORKS:-}" ] || { echo "EMPTY FRAMEWORKS"; exit 16; }
[ "\${PROFILE_GATES[*]:-}" = "format_check lint typecheck test" ] || { echo "BAD GATES=\${PROFILE_GATES[*]:-}"; exit 17; }
declare -F profile_detect >/dev/null || { echo "NO profile_detect"; exit 18; }
declare -F profile_sync   >/dev/null || { echo "NO profile_sync"; exit 19; }
for g in "\${PROFILE_GATES[@]}"; do
  declare -F "profile_gate_\${g}" >/dev/null || { echo "NO profile_gate_\${g}"; exit 20; }
  for suffix in OK FAIL FIX; do
    v="PROFILE_GATE_\${g}_\${suffix}"
    [ -n "\${!v:-}" ] || { echo "EMPTY \$v"; exit 21; }
  done
done
# detect is false in an empty dir, true once pyproject.toml exists.
empty="\$(mktemp -d)"; ( cd "\$empty" && ! profile_detect ) || { echo "detect true in empty dir"; exit 22; }
( cd "\$empty" && touch pyproject.toml && profile_detect ) || { echo "detect false with pyproject.toml"; exit 23; }
rm -rf "\$empty"
echo "PROBE-OK"
PROBE

if ! out="$(bash "$probe" 2>&1)"; then
  note "descriptor probe failed: $out"
elif [ "$out" != "PROBE-OK" ]; then
  note "descriptor probe unexpected output: $out"
fi

# Lint the descriptor when shellcheck is available (CI also lints it).
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$desc" || note "$desc failed shellcheck"
fi

if [ "$fail" -ne 0 ]; then
  echo "profiles sensor FAILED"
  exit 1
fi
echo "profiles descriptor checks passed"
