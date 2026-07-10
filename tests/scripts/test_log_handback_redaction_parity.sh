#!/usr/bin/env bash
# Regression sensor (#270 f3): when scripts/trace-lib.sh is unavailable,
# scripts/log-handback.sh still redacts the Action Log line — and its degraded
# fallback must mask EVERY secret shape that trace-lib's trace_redact masks, not
# just the two GitHub token shapes. The teeth are a behavioral PARITY check: the
# degraded bullet must be byte-identical to what trace_redact would produce for
# the same line, so the two redaction policies cannot silently diverge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
hard_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

HELPER="${ROOT}/scripts/log-handback.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
[ -x "$HELPER" ] || hard_fail "scripts/log-handback.sh not found or not executable"
[ -f "$LIB" ] || hard_fail "scripts/trace-lib.sh not found (needed to derive the parity oracle)"

# Oracle: the canonical redactor.
# shellcheck source=scripts/trace-lib.sh
source "$LIB"
declare -F trace_redact >/dev/null 2>&1 || hard_fail "trace-lib.sh did not provide trace_redact"

# A battery of single-line secret shapes trace_redact is expected to mask:
# GitHub PAT/token, AWS access key, Azure InstrumentationKey, Anthropic + OpenAI
# keys, a bearer token, an env-style token=…, a ?sig=… URL, an AccountKey=…, and
# a JWT. (Multiline shapes like PEM private keys can't ride a one-line summary.)
BATTERY='ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 AKIA1234567890ABCDEF InstrumentationKey=12345678-1234-1234-1234-123456789abc sk-ant-ABCDEFGHIJKLMNOPQRSTUV sk-ABCDEFGHIJKLMNOPQRSTUV Bearer abc123def456ghi789 token=supersecretvalue123 https://h/x?sig=abcdef123456 AccountKey=YWJjZGVmZ2hpMTIzNDU2 eyJhbGciOiJIUzI1 eyJzdWIiOiIxMjM0 SflKxwRJSMeKKF2QT'

ROLE='test-subagent'; STEP='green_handback'; FID='redaction-demo'; OUTCOME='pass'
make_bullet() { printf -- '- [%s] %s %s %s — %s' "$1" "$2" "$3" "$4" "$5"; }

EXPECT="$(make_bullet "$ROLE" "$STEP" "$FID" "$OUTCOME" "$BATTERY" | trace_redact)"
RAW_BULLET="$(make_bullet "$ROLE" "$STEP" "$FID" "$OUTCOME" "$BATTERY")"
[ "$EXPECT" != "$RAW_BULLET" ] \
  || hard_fail "fixture bug: the secret battery is not masked by trace_redact at all"

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cp cat sed awk tr cut grep printf head tail sort date od wc cksum

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# Degraded fixture: log-handback.sh present, trace-lib.sh ABSENT.
R="${TMP_DIR}/nolib"
mkdir -p "${R}/scripts"
cp "$HELPER" "${R}/scripts/log-handback.sh"
[ ! -e "${R}/scripts/trace-lib.sh" ] || hard_fail "fixture bug: degraded repo must not contain trace-lib.sh"
git -C "$R" init -q -b feature/issue-21-redaction
git -C "$R" config user.name "Harness Test"
git -C "$R" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${R}/README.md"
git -C "$R" add README.md scripts
git -C "$R" commit -q -m initial
mkdir -p "${R}/.copilot-tracking/issues/issue-21"
cat > "${R}/.copilot-tracking/issues/issue-21/progress.md" <<'MD'
# Issue 21 progress

## Action Log

- _seed._
MD

OUT="$(cd "$R" && PATH="$BIN" ./scripts/log-handback.sh \
        "$ROLE" "$STEP" "$FID" "$OUTCOME" "$BATTERY" 2>&1)" \
  || { printf '%s\n' "$OUT"; fail "degraded log-handback must still exit 0"; }

PROG="${R}/.copilot-tracking/issues/issue-21/progress.md"
ACTUAL="$(grep -F -- "[${ROLE}] ${STEP} ${FID}" "$PROG" | tail -1)"
[ -n "$ACTUAL" ] || fail "degraded run did not append an Action Log bullet"

# 1. Exact parity with the canonical redactor.
if [ "$ACTUAL" != "$EXPECT" ]; then
  printf '# expected: %s\n# actual:   %s\n' "$EXPECT" "$ACTUAL" >&2
  fail "degraded redaction is not at parity with trace_redact — the fallback masks fewer shapes than trace-lib"
fi

# 2. Belt-and-braces: no raw secret literal may survive.
for raw in \
  'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123' \
  'github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123' \
  'AKIA1234567890ABCDEF' \
  'InstrumentationKey=12345678-1234-1234-1234-123456789abc' \
  'sk-ant-ABCDEFGHIJKLMNOPQRSTUV' \
  'supersecretvalue123' \
  'YWJjZGVmZ2hpMTIzNDU2'; do
  if printf '%s' "$ACTUAL" | grep -Fq -- "$raw"; then
    fail "degraded Action Log line leaked a raw secret: ${raw}"
  fi
done

if [ "$fails" -ne 0 ]; then
  printf '\n%d degraded-redaction parity violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'log-handback degraded redaction is at parity with trace_redact\n'
