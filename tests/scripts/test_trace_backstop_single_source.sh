#!/usr/bin/env bash
# test_trace_backstop_single_source.sh — drift sensor for issue #172.
#
# The secret-shape backstop (an audit grep run AFTER trace_redact, deliberately
# independent of the redactor's EXECUTION) must live in ONE place:
# scripts/trace-lib.sh defines TRACE_SECRET_SHAPE_RE, and both
# scripts/trace-export.sh and scripts/sanitize-trace.sh reference that constant
# instead of carrying a hand-forked literal copy. This sensor fails if either
# consumer drifts back to a forked literal, or if the shared constant is
# missing/empty.
#
# Exit codes: 0 single-sourced · 1 drift detected.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
EXPORT="${ROOT}/scripts/trace-export.sh"
SANITIZE="${ROOT}/scripts/sanitize-trace.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for f in "$LIB" "$EXPORT" "$SANITIZE"; do
  [ -f "$f" ] || fail "expected file not found: ${f}"
done

# 1. trace-lib.sh defines the single shared backstop constant, non-empty.
# shellcheck source=scripts/trace-lib.sh
source "$LIB" || fail "sourcing trace-lib.sh failed under set -euo pipefail"
[ -n "${TRACE_SECRET_SHAPE_RE:-}" ] \
  || fail "trace-lib.sh must define a non-empty TRACE_SECRET_SHAPE_RE (single backstop source)"

# The shared constant must still catch the canonical well-known shapes.
printf 'ghp_%s\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  | grep -qE "$TRACE_SECRET_SHAPE_RE" \
  || fail "TRACE_SECRET_SHAPE_RE no longer matches a canonical ghp_ token shape"
printf 'AKIAABCDEFGH12345678\n' \
  | grep -qE "$TRACE_SECRET_SHAPE_RE" \
  || fail "TRACE_SECRET_SHAPE_RE no longer matches a canonical AKIA access-key shape"

# 2. Both consumers reference the shared constant (sanitize audits in 2 sites).
grep -q 'TRACE_SECRET_SHAPE_RE' "$EXPORT" \
  || fail "trace-export.sh must reference the shared TRACE_SECRET_SHAPE_RE backstop"
sanitize_refs="$(grep -c 'TRACE_SECRET_SHAPE_RE' "$SANITIZE")"
[ "$sanitize_refs" -ge 2 ] \
  || fail "sanitize-trace.sh must reference TRACE_SECRET_SHAPE_RE in both audit sites (found ${sanitize_refs})"

# 3. No forked literal backstop copy may survive in either consumer. Check
# several distinctive fragments so a rewritten-but-equivalent fork is caught.
for f in "$EXPORT" "$SANITIZE"; do
  for frag in \
    'AKIA[0-9A-Z]{16}' \
    'gh[pousr]_[A-Za-z0-9_]{20,}' \
    'github_pat_[A-Za-z0-9_]{20,}' \
    'sk-ant-[A-Za-z0-9_-]{20,}'; do
    if grep -qF "$frag" "$f"; then
      fail "forked backstop literal (${frag}) still present in ${f} — must reference the shared source"
    fi
  done
done

printf 'secret-shape backstop is single-sourced\n'
