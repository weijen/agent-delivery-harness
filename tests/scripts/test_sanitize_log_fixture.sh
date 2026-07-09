#!/usr/bin/env bash
# test_sanitize_log_fixture.sh — regression sensor for feature
# `log-sanitizer-parity` (issue #219).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/sanitize-trace.sh [--head N] <in.jsonl> <out.jsonl>
#
#   The sanitizer is stream-shape agnostic: it must clean a LOG stream
#   (`log.jsonl`, one JSON log record per line — level/ts/message/payload
#   fields) with the SAME fail-closed guarantees it gives a trace.jsonl.
#   This proves the redaction + path scrub + leak audit are keyed on the
#   BYTES of each JSONL line, not on trace-specific span keys, so the new
#   step-level log stream is covered by exactly one policy.
#
#   For a synthetic log.jsonl carrying a planted synthetic secret (ghp_…)
#   and home-rooted absolute paths (/Users/…, /home/…) inside log fields:
#
#   - Redaction reuse: the planted secret must be masked to [REDACTED]
#     (trace_redact's mask); no literal secret byte may survive.
#   - Path scrub: no '/Users/' or '/home/' substring may survive; scrubbed
#     paths are rewritten to the pinned placeholder <SCRUBBED_PATH>.
#   - Valid JSONL: every output line still parses as one JSON object
#     (jq empty over the output succeeds).
#   - Fail-closed audit PASSES on the sanitized output: a clean run exits 0
#     (exit 0 is only reachable after the sanitizer's own independent leak
#     audit is satisfied), and writes the output file.
#   - Fail-closed audit BITES on the raw log content (negative / mutation
#     leg): with a no-op trace_redact sourced from the sanitizer's own
#     script dir, the planted secret survives the redaction pass — the
#     independent output audit must catch it: NON-ZERO exit and NO leaking
#     file left at <out.jsonl>. Exit 0 with the raw secret on disk is the
#     one forbidden outcome. This proves the pass above is a real gate, not
#     a vacuous one.
#   - Human gate (governance): the sanitizer prints a footer stating human
#     review is required before commit.
#
# Exit codes: 0 log-parity contract honored · 1 a contract obligation
# regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANITIZER="${ROOT}/scripts/sanitize-trace.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required to validate sanitized log output"
[ -f "$SANITIZER" ] \
  || hard_fail "scripts/sanitize-trace.sh not found (${SANITIZER})"
[ -x "$SANITIZER" ] \
  || hard_fail "scripts/sanitize-trace.sh exists but is not executable (${SANITIZER})"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB}) — trace_redact is the sanitizer's redaction oracle"

# Pinned PATH: real tools only, isolated from the developer's ambient shell.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cksum; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done

# --- Fixture repo mirroring the harness layout (sanitizer resolves trace-lib
#     relative to its own script dir) -------------------------------------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts"
cp "$SANITIZER" "${FIX}/scripts/sanitize-trace.sh"
cp "$TRACE_LIB" "${FIX}/scripts/trace-lib.sh"
chmod +x "${FIX}/scripts/sanitize-trace.sh"

# Planted leak shapes (SYNTHETIC; never real credentials).
GHP="ghp_FAKE0LOGPARITY0SECRET0TOKEN0ABCDEFGH"
ABS_USERS="/Users/example/secret/path/run.log"
ABS_HOME="/home/example/secret/path/archive"

# Synthetic log.jsonl: a few valid JSON log records (NOT trace spans) — one
# with a planted secret in `message`, others with home-rooted absolute paths
# in `payload`/`message`.
IN="${TMP_DIR}/log.jsonl"
cat > "$IN" <<JSONL
{"ts":"2026-07-09T09:00:00Z","level":"info","step":"preflight","message":"harness log stream opened"}
{"ts":"2026-07-09T09:00:01Z","level":"warn","step":"implement","message":"rotated token ${GHP} after leak"}
{"ts":"2026-07-09T09:00:02Z","level":"info","step":"verify","message":"logs written under ${ABS_USERS}","payload":{"path":"${ABS_HOME}"}}
{"ts":"2026-07-09T09:00:03Z","level":"info","step":"closeout","message":"log stream flushed"}
JSONL

# Sanity: the raw fixture really carries the leak, so a PASS below is not
# vacuous. (This is the test's own precondition, not the sanitizer's job.)
grep -qF -- "$GHP" "$IN" \
  || hard_fail "test fixture bug: planted secret not present in the raw log.jsonl"
grep -qE '/(Users|home)/' "$IN" \
  || hard_fail "test fixture bug: planted home path not present in the raw log.jsonl"

run_sanitize() { # run_sanitize <scripts-dir> <out-report> <args...>
  local sdir="$1" rep="$2"; shift 2
  (cd "$FIX" && PATH="$BIN" "${sdir}/sanitize-trace.sh" "$@") > "$rep" 2>&1
}

# ==============================================================================
# A. Happy path: the log stream is redacted, path-scrubbed, valid JSONL, and
#    the sanitizer's own fail-closed audit passes (exit 0 + file written).
# ==============================================================================
OUT="${TMP_DIR}/log.sanitized.jsonl"
arc=0
run_sanitize "${FIX}/scripts" "${TMP_DIR}/a.out" "$IN" "$OUT" || arc=$?
[ "$arc" = "0" ] \
  || { cat "${TMP_DIR}/a.out" >&2; fail "sanitize-trace.sh on a leaky-but-valid log.jsonl must exit 0 (fail-closed audit must pass on the sanitized output)"; }
[ -f "$OUT" ] \
  || fail "sanitizer must write the output file (${OUT})"

if [ -f "$OUT" ]; then
  [ "$(wc -l < "$OUT" | tr -d '[:space:]')" = "4" ] \
    || fail "all 4 log records must be kept (got $(wc -l < "$OUT" | tr -d '[:space:]'))"

  grep -qF -- "$GHP" "$OUT" \
    && fail "planted ghp_ secret survived sanitization of the log stream (trace_redact reuse bypassed)"
  grep -qF '[REDACTED]' "$OUT" \
    || fail "sanitized log output must mask the planted secret as [REDACTED]"

  grep -qE '/(Users|home)/' "$OUT" \
    && fail "home-rooted absolute path survived the path scrub in the log output"
  grep -qF '<SCRUBBED_PATH>' "$OUT" \
    || fail "scrubbed paths must be rewritten to the pinned placeholder <SCRUBBED_PATH>"

  jq empty < "$OUT" >/dev/null 2>&1 \
    || fail "sanitized log output must remain valid JSONL (jq empty)"
fi

grep -qi 'human review' "${TMP_DIR}/a.out" \
  || fail "sanitizer must print the human-review-before-commit footer (governance: committing is a human act)"

# ==============================================================================
# B. Fail-closed audit BITES (negative / mutation leg): with a MUTANT no-op
#    trace_redact, the planted secret survives redaction — the sanitizer's
#    independent output audit must catch it: NON-ZERO exit and no leaking
#    file at <out>. Proves the PASS in A is a real gate on log content.
# ==============================================================================
MUT="${TMP_DIR}/mutant-repo"
mkdir -p "${MUT}/scripts"
cp "$SANITIZER" "${MUT}/scripts/sanitize-trace.sh"
chmod +x "${MUT}/scripts/sanitize-trace.sh"
cat > "${MUT}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib for the fail-closed audit test: redaction is a no-op, but
# the audit backstop constant (TRACE_SECRET_SHAPE_RE) is preserved so the
# sanitizer's independent audit can still fire.
trace_redact() { cat; }
trace_warn() { printf 'warning: %s\n' "$*" >&2; }
TRACE_SECRET_SHAPE_RE='gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}'
SH

OUT_MUT="${TMP_DIR}/log.mutant.jsonl"
mrc=0
run_sanitize "${MUT}/scripts" "${TMP_DIR}/b.out" "$IN" "$OUT_MUT" || mrc=$?
[ "$mrc" != "0" ] \
  || fail "fail-closed audit: with a no-op redactor the sanitizer must exit NON-ZERO on the leaky log stream (a secret survived), got exit 0"
if [ -f "$OUT_MUT" ] && grep -qF -- "$GHP" "$OUT_MUT"; then
  fail "fail-closed audit: the sanitizer left a leaking log output file at <out> (raw ghp_ secret on disk after non-zero exit)"
fi

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d log-sanitizer-parity contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'log-sanitizer-parity: sanitize-trace.sh cleans a log.jsonl fail-closed\n'
