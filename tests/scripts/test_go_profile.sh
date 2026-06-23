#!/usr/bin/env bash
# Regression sensor (issue #39): the Go profile descriptor must declare every
# Profile Interface field, detect a go.mod surface, expose the gate functions
# init.sh drives, OMIT a separate typecheck slot (compilation covers it), and
# SKIP (return 2) the optional golangci-lint gate when the linter is absent
# instead of hard-failing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

desc="profiles/go.profile.sh"

if [ ! -f "$desc" ]; then
  note "missing $desc"
  echo "go profile sensor FAILED"
  exit 1
fi

bash -n "$desc" || note "$desc is not valid bash"

# Source the descriptor in hermetic fixtures and assert its shape + behavior.
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<PROBE
set -euo pipefail

# --- Fixture A: a go.mod surface ---------------------------------------------
a="\$(mktemp -d)"
cd "\$a"
printf 'module fixture\n\ngo 1.22\n' > go.mod
# shellcheck source=/dev/null
. "$ROOT/$desc"

[ "\${PROFILE_ID:-}" = "go" ] || { echo "BAD PROFILE_ID=\${PROFILE_ID:-}"; exit 11; }
case "\${PROFILE_DETECT:-}" in *go.mod*) : ;; *) echo "BAD PROFILE_DETECT"; exit 12 ;; esac
[ "\${PROFILE_TOOL_REQUIREMENTS:-}" = "go" ] || { echo "BAD TOOLREQ"; exit 13; }
[ "\${PROFILE_SURFACE_LABEL:-}" = "Go surface detected (go.mod)" ] || { echo "BAD LABEL=\${PROFILE_SURFACE_LABEL:-}"; exit 14; }
[ -n "\${PROFILE_INSTRUCTIONS:-}" ] || { echo "EMPTY INSTRUCTIONS"; exit 15; }
# Framework hints must include the spec's four without forcing one.
for fw in Gin Echo Chi net/http; do
  case " \${PROFILE_FRAMEWORKS:-} " in *" \$fw "*) : ;; *) echo "MISSING FRAMEWORK \$fw"; exit 16 ;; esac
done

# Go has a single toolchain: VARIANTS is empty.
[ -z "\${PROFILE_VARIANTS:-}" ] || { echo "EXPECTED EMPTY VARIANTS, got \${PROFILE_VARIANTS}"; exit 17; }

# No separate typecheck slot (empty-slot rule); golangci is present + optional.
[ "\${PROFILE_GATES[*]:-}" = "format_check lint golangci test" ] || { echo "BAD GATES=\${PROFILE_GATES[*]:-}"; exit 18; }
case " \${PROFILE_GATES[*]:-} " in *" typecheck "*) echo "typecheck slot must be omitted for Go"; exit 19 ;; esac

declare -F profile_detect >/dev/null || { echo "NO profile_detect"; exit 20; }
profile_detect || { echo "detect false with go.mod"; exit 21; }
declare -F profile_sync >/dev/null || { echo "NO profile_sync"; exit 22; }
for g in "\${PROFILE_GATES[@]}"; do
  declare -F "profile_gate_\${g}" >/dev/null || { echo "NO profile_gate_\${g}"; exit 23; }
  for suffix in OK FAIL FIX SKIP; do
    v="PROFILE_GATE_\${g}_\${suffix}"
    [ -n "\${!v:-}" ] || { echo "EMPTY \$v"; exit 24; }
  done
done
[ "\${PROFILE_GATE_test_OK:-}" = "go test passing" ] || { echo "BAD test OK msg"; exit 25; }
[ "\${PROFILE_GATE_lint_OK:-}" = "go vet clean" ] || { echo "BAD lint OK msg"; exit 26; }

# detect is false in a go.mod-free dir.
empty="\$(mktemp -d)"; ( cd "\$empty" && ! profile_detect ) || { echo "detect true in empty dir"; exit 27; }
rm -rf "\$empty"

# --- golangci-lint optional SKIP (return 2) ----------------------------------
# With go present but golangci-lint absent from PATH, the golangci gate SKIPs.
# Use a fake \`go\` shadowing real go on a minimal PATH; golangci-lint is not on
# the minimal PATH so it resolves as absent.
fakebin="\$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "\$fakebin/go"   # vet/test succeed
chmod +x "\$fakebin/go"
minpath="\$fakebin:/usr/bin:/bin"
rc=0; PATH="\$minpath" profile_gate_golangci || rc=\$?
[ "\$rc" = "2" ] || { echo "golangci did not SKIP without the linter (rc=\$rc)"; exit 30; }
# go vet + go test still run (they only need go).
rc=0; PATH="\$minpath" profile_gate_lint || rc=\$?
[ "\$rc" = "0" ] || { echo "go vet should pass with fake go (rc=\$rc)"; exit 31; }
rc=0; PATH="\$minpath" profile_gate_test || rc=\$?
[ "\$rc" = "0" ] || { echo "go test should pass with fake go (rc=\$rc)"; exit 32; }

# --- format_check is non-mutating --------------------------------------------
# gofmt is invoked in LIST mode (-l), never -w, during validation so a run never
# edits files. (\`gofmt -w\` may still appear in the FIX remediation hint.)
grep -q 'gofmt -l' "$ROOT/$desc" || { echo "format_check must use gofmt -l (list mode)"; exit 34; }
rm -rf "\$fakebin"
cd /; rm -rf "\$a"

echo "PROBE-OK"
PROBE

if ! out="$(bash "$probe" 2>&1)"; then
  note "go descriptor probe failed: $out"
elif [ "$out" != "PROBE-OK" ]; then
  note "go descriptor probe unexpected output: $out"
fi

# Lint the descriptor when shellcheck is available (CI also lints it).
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$desc" || note "$desc failed shellcheck"
fi

if [ "$fail" -ne 0 ]; then
  echo "go profile sensor FAILED"
  exit 1
fi
echo "go profile descriptor checks passed"
