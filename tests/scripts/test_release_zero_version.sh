#!/usr/bin/env bash
# test_release_zero_version.sh — regression sensor for the zero-version release
# policy (issue #260).
#
# Contract under test (PINNED HERE as the executable spec): pyproject.toml's
# [tool.semantic_release] config MUST keep the harness on the 0.x line and make
# 1.0.0 a manual-only decision. python-semantic-release v10 defaults
# allow_zero_version to FALSE — which forces the first computed release to 1.0.0
# regardless of the change level (the #257 -> premature 1.0.0 bug). So the config
# MUST explicitly set:
#   - allow_zero_version = true   (stay on 0.x until a human cuts 1.0.0)
#   - major_on_zero = false       (a BREAKING CHANGE on 0.x bumps the minor, not
#                                  to 1.0.0; 1.0.0 requires an explicit --major)
#
# Exit codes: 0 both obligations present · 1 an obligation is missing (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYPROJECT="${ROOT}/pyproject.toml"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

[ -f "$PYPROJECT" ] || { fail "pyproject.toml not found"; exit 1; }

# Extract the [tool.semantic_release] table body (header exclusive) up to the
# next top-level [section] header, then strip comment lines. Matching only
# within this stripped body prevents a false GREEN where the explanatory prose
# in a nearby comment (which mentions "allow_zero_version"/"major_on_zero")
# masks a flipped or removed real setting.
section="$(awk '
  /^\[tool\.semantic_release\]/ { in_sec = 1; next }
  /^\[/ { in_sec = 0 }
  in_sec { sub(/#.*/, ""); print }
' "$PYPROJECT")"

[ -n "$section" ] \
  || fail "pyproject.toml must carry a [tool.semantic_release] section"
printf '%s\n' "$section" | grep -qE '^[[:space:]]*allow_zero_version[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  || fail "PSR must set allow_zero_version = true (stay on 0.x; do not auto-jump to 1.0.0)"
printf '%s\n' "$section" | grep -qE '^[[:space:]]*major_on_zero[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
  || fail "PSR must set major_on_zero = false (1.0.0 is a manual decision, not a mechanical major bump on 0.x)"

if [ "$fails" -ne 0 ]; then
  printf '\n%d zero-version-policy obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'zero-version release policy honored (allow_zero_version=true, major_on_zero=false)\n'
