#!/usr/bin/env bash
# Regression sensor (issue #38): the Node profile descriptor must declare every
# Profile Interface field, detect a package.json surface, resolve the package
# manager VARIANT (pnpm vs npm), expose the gate functions init.sh drives, gate
# typecheck CONDITIONALLY on TypeScript, and SKIP (return 2) optional gates whose
# tool/script is absent instead of hard-failing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

desc="profiles/node.profile.sh"

if [ ! -f "$desc" ]; then
  note "missing $desc"
  echo "node profile sensor FAILED"
  exit 1
fi

bash -n "$desc" || note "$desc is not valid bash"

# Source the descriptor in hermetic fixtures and assert its shape + behavior.
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<PROBE
set -euo pipefail

# --- Fixture A: pnpm + JS-only (no TypeScript) -------------------------------
a="\$(mktemp -d)"
cd "\$a"
printf '{"scripts":{"test":"true"}}\n' > package.json
printf 'lockfileVersion: "9.0"\n' > pnpm-lock.yaml
# shellcheck source=/dev/null
. "$ROOT/$desc"

[ "\${PROFILE_ID:-}" = "node" ] || { echo "BAD PROFILE_ID=\${PROFILE_ID:-}"; exit 11; }
case "\${PROFILE_DETECT:-}" in *package.json*) : ;; *) echo "BAD PROFILE_DETECT"; exit 12 ;; esac
case "\${PROFILE_VARIANTS:-}" in *pnpm*npm*) : ;; *) echo "BAD PROFILE_VARIANTS"; exit 13 ;; esac
[ "\${PROFILE_TOOL_REQUIREMENTS:-}" = "node" ] || { echo "BAD TOOLREQ"; exit 14; }
[ -n "\${PROFILE_INSTRUCTIONS:-}" ] || { echo "EMPTY INSTRUCTIONS"; exit 15; }
[ -n "\${PROFILE_FRAMEWORKS:-}" ] || { echo "EMPTY FRAMEWORKS"; exit 16; }

# Variant: a pnpm lockfile resolves the pnpm package manager + label.
[ "\${PROFILE_PM:-}" = "pnpm" ] || { echo "BAD PM=\${PROFILE_PM:-} (want pnpm)"; exit 17; }
[ "\${PROFILE_SURFACE_LABEL:-}" = "Node surface detected (package.json, pnpm)" ] || { echo "BAD LABEL=\${PROFILE_SURFACE_LABEL:-}"; exit 18; }

# JS-only project: typecheck slot is omitted (empty-slot rule).
[ "\${PROFILE_GATES[*]:-}" = "format_check lint test" ] || { echo "BAD JS GATES=\${PROFILE_GATES[*]:-}"; exit 19; }

declare -F profile_detect >/dev/null || { echo "NO profile_detect"; exit 20; }
profile_detect || { echo "detect false with package.json"; exit 21; }
for g in "\${PROFILE_GATES[@]}"; do
  declare -F "profile_gate_\${g}" >/dev/null || { echo "NO profile_gate_\${g}"; exit 22; }
  for suffix in OK FAIL FIX SKIP; do
    v="PROFILE_GATE_\${g}_\${suffix}"
    [ -n "\${!v:-}" ] || { echo "EMPTY \$v"; exit 23; }
  done
done
[ "\${PROFILE_GATE_test_OK:-}" = "node tests passing" ] || { echo "BAD test OK msg"; exit 24; }

# detect is false in a package.json-free dir.
empty="\$(mktemp -d)"; ( cd "\$empty" && ! profile_detect ) || { echo "detect true in empty dir"; exit 25; }
rm -rf "\$empty"
cd /; rm -rf "\$a"

# --- Fixture B: npm + TypeScript ---------------------------------------------
b="\$(mktemp -d)"
cd "\$b"
printf '{"scripts":{"test":"true"}}\n' > package.json
printf '{}\n' > package-lock.json
printf '{}\n' > tsconfig.json
# Re-source in the new \$PWD so variant + conditional detection re-run.
# shellcheck source=/dev/null
. "$ROOT/$desc"

[ "\${PROFILE_PM:-}" = "npm" ] || { echo "BAD PM=\${PROFILE_PM:-} (want npm)"; exit 30; }
[ "\${PROFILE_SURFACE_LABEL:-}" = "Node surface detected (package.json, npm)" ] || { echo "BAD npm LABEL"; exit 31; }
# TypeScript present (tsconfig.json): typecheck slot is included.
[ "\${PROFILE_GATES[*]:-}" = "format_check lint typecheck test" ] || { echo "BAD TS GATES=\${PROFILE_GATES[*]:-}"; exit 32; }
declare -F profile_gate_typecheck >/dev/null || { echo "NO profile_gate_typecheck"; exit 33; }
cd /; rm -rf "\$b"

# --- Fixture C: optional gate SKIP (return 2) --------------------------------
# A package.json with no format/lint scripts and no prettier/eslint on PATH must
# make those gates SKIP (exit 2), not hard-fail.
c="\$(mktemp -d)"
cd "\$c"
printf '{"scripts":{"test":"true"}}\n' > package.json
# shellcheck source=/dev/null
. "$ROOT/$desc"
isolated="\$(mktemp -d)"  # empty PATH dir: no prettier/eslint/jq
rc=0; PATH="\$isolated" profile_gate_format_check || rc=\$?
[ "\$rc" = "2" ] || { echo "format_check did not SKIP (rc=\$rc)"; exit 40; }
rc=0; PATH="\$isolated" profile_gate_lint || rc=\$?
[ "\$rc" = "2" ] || { echo "lint did not SKIP (rc=\$rc)"; exit 41; }
rm -rf "\$isolated"
cd /; rm -rf "\$c"

echo "PROBE-OK"
PROBE

if ! out="$(bash "$probe" 2>&1)"; then
  note "node descriptor probe failed: $out"
elif [ "$out" != "PROBE-OK" ]; then
  note "node descriptor probe unexpected output: $out"
fi

# Lint the descriptor when shellcheck is available (CI also lints it).
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$desc" || note "$desc failed shellcheck"
fi

if [ "$fail" -ne 0 ]; then
  echo "node profile sensor FAILED"
  exit 1
fi
echo "node profile descriptor checks passed"
