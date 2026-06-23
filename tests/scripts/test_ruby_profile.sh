#!/usr/bin/env bash
# Regression sensor (issue #40): the Ruby profile descriptor must declare every
# Profile Interface field, detect a Gemfile surface, resolve BOTH variant axes
# (lint/format tool: Standard Ruby vs RuboCop; test framework: RSpec vs
# Minitest), expose the gate functions init.sh drives, add a typecheck slot ONLY
# when Sorbet/Steep is configured, and SKIP (return 2) gates when the Ruby
# toolchain is absent instead of hard-failing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

desc="profiles/ruby.profile.sh"

if [ ! -f "$desc" ]; then
  note "missing $desc"
  echo "ruby profile sensor FAILED"
  exit 1
fi

bash -n "$desc" || note "$desc is not valid bash"

# Source the descriptor in hermetic fixtures and assert its shape + behavior.
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<PROBE
set -euo pipefail

# --- Fixture A: Standard Ruby + RSpec ----------------------------------------
a="\$(mktemp -d)"
cd "\$a"
printf 'source "https://rubygems.org"\ngem "standard"\ngem "rspec"\n' > Gemfile
mkdir spec
# shellcheck source=/dev/null
. "$ROOT/$desc"

[ "\${PROFILE_ID:-}" = "ruby" ] || { echo "BAD PROFILE_ID=\${PROFILE_ID:-}"; exit 11; }
case "\${PROFILE_DETECT:-}" in *Gemfile*) : ;; *) echo "BAD PROFILE_DETECT"; exit 12 ;; esac
[ "\${PROFILE_TOOL_REQUIREMENTS:-}" = "ruby" ] || { echo "BAD TOOLREQ"; exit 13; }
[ -n "\${PROFILE_INSTRUCTIONS:-}" ] || { echo "EMPTY INSTRUCTIONS"; exit 14; }
for fw in Rails Sinatra Hanami; do
  case " \${PROFILE_FRAMEWORKS:-} " in *" \$fw "*) : ;; *) echo "MISSING FRAMEWORK \$fw"; exit 15 ;; esac
done

[ "\${PROFILE_RUBY_LINTER:-}" = "standardrb" ] || { echo "BAD LINTER=\${PROFILE_RUBY_LINTER:-} (want standardrb)"; exit 16; }
[ "\${PROFILE_RUBY_TEST:-}" = "rspec" ] || { echo "BAD TEST=\${PROFILE_RUBY_TEST:-} (want rspec)"; exit 17; }
[ "\${PROFILE_SURFACE_LABEL:-}" = "Ruby surface detected (Gemfile, standardrb/rspec)" ] || { echo "BAD LABEL=\${PROFILE_SURFACE_LABEL:-}"; exit 18; }
# Standard Ruby is a combined lint+format path: a single lint gate, no typecheck.
[ "\${PROFILE_GATES[*]:-}" = "lint test" ] || { echo "BAD GATES=\${PROFILE_GATES[*]:-}"; exit 19; }
case "\${PROFILE_GATE_lint_OK:-}" in *lint+format*) : ;; *) echo "standardrb lint gate must signal combined lint+format"; exit 20 ;; esac
[ "\${PROFILE_GATE_test_OK:-}" = "rspec passing" ] || { echo "BAD rspec OK msg"; exit 21; }

declare -F profile_detect >/dev/null || { echo "NO profile_detect"; exit 22; }
profile_detect || { echo "detect false with Gemfile"; exit 23; }
declare -F profile_sync >/dev/null || { echo "NO profile_sync"; exit 24; }
for g in "\${PROFILE_GATES[@]}"; do
  declare -F "profile_gate_\${g}" >/dev/null || { echo "NO profile_gate_\${g}"; exit 25; }
  for suffix in OK FAIL FIX SKIP; do
    v="PROFILE_GATE_\${g}_\${suffix}"
    [ -n "\${!v:-}" ] || { echo "EMPTY \$v"; exit 26; }
  done
done

# SKIP: with no ruby/bundler on a minimal PATH, gates return 2 (warn, not fail).
fakebin="\$(mktemp -d)"  # empty: no ruby/bundle
rc=0; PATH="\$fakebin" profile_gate_lint || rc=\$?
[ "\$rc" = "2" ] || { echo "lint did not SKIP without ruby (rc=\$rc)"; exit 27; }
rc=0; PATH="\$fakebin" profile_gate_test || rc=\$?
[ "\$rc" = "2" ] || { echo "test did not SKIP without ruby (rc=\$rc)"; exit 28; }
rm -rf "\$fakebin"

empty="\$(mktemp -d)"; ( cd "\$empty" && ! profile_detect ) || { echo "detect true in empty dir"; exit 29; }
rm -rf "\$empty"
cd /; rm -rf "\$a"

# --- Fixture B: RuboCop + Minitest -------------------------------------------
b="\$(mktemp -d)"
cd "\$b"
printf 'source "https://rubygems.org"\ngem "rubocop"\ngem "minitest"\n' > Gemfile
printf 'AllCops:\n  NewCops: enable\n' > .rubocop.yml
mkdir test
# shellcheck source=/dev/null
. "$ROOT/$desc"

[ "\${PROFILE_RUBY_LINTER:-}" = "rubocop" ] || { echo "BAD LINTER=\${PROFILE_RUBY_LINTER:-} (want rubocop)"; exit 30; }
[ "\${PROFILE_RUBY_TEST:-}" = "minitest" ] || { echo "BAD TEST=\${PROFILE_RUBY_TEST:-} (want minitest)"; exit 31; }
[ "\${PROFILE_SURFACE_LABEL:-}" = "Ruby surface detected (Gemfile, rubocop/minitest)" ] || { echo "BAD LABEL"; exit 32; }
[ "\${PROFILE_GATE_lint_OK:-}" = "rubocop clean" ] || { echo "BAD rubocop OK msg"; exit 33; }
[ "\${PROFILE_GATE_test_OK:-}" = "minitest passing" ] || { echo "BAD minitest OK msg"; exit 34; }
# No Sorbet/Steep configured: typecheck slot must be absent.
case " \${PROFILE_GATES[*]:-} " in *" typecheck "*) echo "typecheck slot must be absent without Sorbet/Steep"; exit 35 ;; esac
[ "\${PROFILE_GATES[*]:-}" = "lint test" ] || { echo "BAD GATES=\${PROFILE_GATES[*]:-}"; exit 36; }
cd /; rm -rf "\$b"

# --- Fixture C: Sorbet configured -> typecheck slot appears ------------------
c="\$(mktemp -d)"
cd "\$c"
printf 'source "https://rubygems.org"\ngem "sorbet"\n' > Gemfile
mkdir -p sorbet; printf '%s\n' '--dir' '.' > sorbet/config
# shellcheck source=/dev/null
. "$ROOT/$desc"
[ "\${PROFILE_RUBY_TYPECHECK:-}" = "sorbet" ] || { echo "BAD TYPECHECK=\${PROFILE_RUBY_TYPECHECK:-}"; exit 40; }
[ "\${PROFILE_GATES[*]:-}" = "lint typecheck test" ] || { echo "BAD TS GATES=\${PROFILE_GATES[*]:-}"; exit 41; }
declare -F profile_gate_typecheck >/dev/null || { echo "NO profile_gate_typecheck"; exit 42; }
cd /; rm -rf "\$c"

# --- Fixture D: RuboCop config AND standard gem -> RuboCop wins ---------------
d="\$(mktemp -d)"
cd "\$d"
printf 'source "https://rubygems.org"\ngem "standard"\ngem "rubocop"\n' > Gemfile
printf 'AllCops:\n  NewCops: enable\n' > .rubocop.yml
# shellcheck source=/dev/null
. "$ROOT/$desc"
[ "\${PROFILE_RUBY_LINTER:-}" = "rubocop" ] || { echo "BAD LINTER=\${PROFILE_RUBY_LINTER:-} (RuboCop must win when both configured)"; exit 43; }
cd /; rm -rf "\$d"

echo "PROBE-OK"
PROBE

if ! out="$(bash "$probe" 2>&1)"; then
  note "ruby descriptor probe failed: $out"
elif [ "$out" != "PROBE-OK" ]; then
  note "ruby descriptor probe unexpected output: $out"
fi

# Lint the descriptor when shellcheck is available (CI also lints it).
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$desc" || note "$desc failed shellcheck"
fi

if [ "$fail" -ne 0 ]; then
  echo "ruby profile sensor FAILED"
  exit 1
fi
echo "ruby profile descriptor checks passed"
