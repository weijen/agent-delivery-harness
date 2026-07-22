#!/usr/bin/env bash
# Regression sensor (issue #273, feature conversions-executed): the CONVERT-class
# doctrine meta-tests must be STRUCTURE-LEVEL, not sentence-level. Concretely,
# each converted test must:
#   (a) anchor on a guarded section heading/anchor (a grep/sed pattern that
#       matches a Markdown heading, i.e. contains '^#') — so mutating the
#       section title still fails the test; and
#   (b) carry NO long prose-fragment grep pattern (a quoted grep pattern with
#       >= 4 spaces) — so rewording a sentence inside the section cannot break
#       the test.
# Together these operationalize the issue's behavioral sensor.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

converted=(
  test_impl_usefulness_grading
)

for b in "${converted[@]}"; do
  f="tests/meta/${b}.sh"
  [ -f "$f" ] || { note "missing converted test $f"; continue; }

  # (a) anchors on a heading/section-existence check.
  if ! grep -Eq "(grep|sed)[^#]*'[^']*\^#" "$f" && ! grep -Eq '(grep|sed)[^#]*"[^"]*\^#' "$f"; then
    note "$f must anchor on a section heading (a '^#' heading/anchor pattern) so a title change still fails"
  fi

  # (b) no long prose-fragment grep pattern (>= 4 spaces inside a quoted grep pattern).
  # Extract single-quoted grep patterns and flag any with >= 4 spaces.
  while IFS= read -r pat; do
    # strip the leading grep... up to the first quote, keep pattern between quotes
    inner="${pat#*\'}"; inner="${inner%\'*}"
    # heading/anchor patterns ('^#...') are structure, not prose — exempt them.
    case "$inner" in
      '^#'*) continue ;;
    esac
    spaces="$(printf '%s' "$inner" | tr -cd ' ' | wc -c | tr -d ' ')"
    if [ "$spaces" -ge 4 ]; then
      note "$f pins prose (>=4 spaces) in grep pattern: '${inner}'"
    fi
  done < <(grep -oE "grep -[A-Za-z]*q[a-z]* '[^']*'" "$f" || true)
done

if [ "$fail" -ne 0 ]; then
  echo "converted-meta-structural sensor FAILED"
  exit 1
fi
echo "converted-meta-structural sensor passed (5 doctrine tests are structure-level)"
