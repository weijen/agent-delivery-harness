#!/usr/bin/env bash
# sanitize-trace.sh — turn a real (local-only) trace.jsonl into a commit-safe
# replay fixture (issue #99, feature trace-sanitize-fixture, plan Phase 3).
#
# Usage:
#   scripts/sanitize-trace.sh [--head N] <in.jsonl> <out.jsonl>
#
# Pipeline (plan D4):
#   1. Span-window trim: with --head N only the first N spans of the input
#      are kept (input order preserved); without --head all spans are kept.
#   2. Redaction reuse: every line passes through trace_redact from
#      scripts/trace-lib.sh, sourced from this script's own directory — one
#      redaction policy, never a forked pattern list. Missing/unsourceable
#      trace-lib is a hard error (fail closed): no redactor, no output.
#   3. Path scrub (fixture-specific, beyond the runtime redactor): absolute
#      home-rooted paths (/Users/<name>/..., /home/<name>/...) anywhere in a
#      span — harness.worktree, harness.summary, args — are rewritten to the
#      placeholder <SCRUBBED_PATH>. The scrub is DECODE-AWARE (loop-2 major):
#      a raw sed layer catches literal forms, then a jq walk over every
#      DECODED string value catches JSON-escaped slashes (\/Users\/...),
#      tilde-rooted home paths (~/...), and Windows home paths
#      (C:\Users\...). A line whose decoded content needs no scrub keeps its
#      original bytes (clean output is never re-encoded).
#   4. Fail-closed leak audit on the OUTPUT, independent of the sourced
#      redactor (so a broken/no-op trace_redact cannot slip a leak through):
#        - a second trace_redact pass must be a no-op (fixed point);
#        - no home-rooted absolute path may survive — checked on the RAW
#          bytes AND on the jq-DECODED string values (escaped, tilde, and
#          Windows forms cannot hide from the audit);
#        - no well-known secret shape (ghp_/gho_/…, github_pat_, AKIA) may
#          survive — a minimal hardcoded backstop for the audit only; the
#          redaction POLICY stays trace_redact's alone;
#        - every output line must still parse as JSON (valid JSONL).
#      Any audit failure → non-zero exit and NO file left at <out.jsonl>
#      (the sanitizer stages its work in a temp file and only moves it into
#      place after the audit passes).
#
# Governance: committing a fixture is a human act — the sanitizer always
# prints a human-review-required footer; AGENTS.md sensitivity rules apply.
# Consumers: the existing validator path mode
# (./scripts/validate-trace.sh <out.jsonl>) — no new eval runner (plan D5).
#
# Exit codes: 0 sanitized fixture written · 1 leak audit failed (no output
# left behind) · 2 usage or environment error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  {
    echo "usage: ./scripts/sanitize-trace.sh [--head N] <in.jsonl> <out.jsonl>"
    echo "  --head N   keep only the first N spans of the input"
    echo "exit codes: 0 fixture written, 1 leak audit failed, 2 usage/environment error"
  } >&2
}

err() {
  printf 'sanitize-trace: error: %s\n' "$*" >&2
}

# --- CLI parsing ---------------------------------------------------------------
HEAD_N=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)
      if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        err "--head requires a positive integer span count"
        usage
        exit 2
      fi
      HEAD_N="$2"
      shift 2
      ;;
    -*)
      err "unknown option '$1'"
      usage
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
if [ "${#POSITIONAL[@]}" -ne 2 ]; then
  usage
  exit 2
fi
IN="${POSITIONAL[0]}"
OUT="${POSITIONAL[1]}"

if [ ! -f "$IN" ]; then
  err "input trace not found: ${IN}"
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required for the valid-JSONL audit"
  exit 2
fi

# --- Redactor: trace_redact from trace-lib, fail closed --------------------------
if [ ! -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  err "scripts/trace-lib.sh not found (${SCRIPT_DIR}/trace-lib.sh) — trace_redact is the single redaction policy; refusing to sanitize without it"
  exit 2
fi
# shellcheck source=scripts/trace-lib.sh
source "${SCRIPT_DIR}/trace-lib.sh"
if ! declare -F trace_redact >/dev/null 2>&1; then
  err "trace-lib.sh did not provide trace_redact — refusing to sanitize"
  exit 2
fi

# --- Staging: sanitize into a temp file beside <out>, move only when clean -------
TMP_OUT="${OUT}.sanitizing.$$"
TMP_AUDIT="${OUT}.audit.$$"
TMP_RAW="${OUT}.raw.$$"
TMP_NORM="${OUT}.norm.$$"
TMP_SCRUB="${OUT}.scrub.$$"
TMP_JQ="${OUT}.scrub.jq.$$"
TMP_DECODED="${OUT}.decoded.$$"
trap 'rm -f "$TMP_OUT" "$TMP_AUDIT" "$TMP_RAW" "$TMP_NORM" "$TMP_SCRUB" "$TMP_JQ" "$TMP_DECODED"' EXIT

# Layer 1 (raw bytes): home-rooted absolute paths → <SCRUBBED_PATH>. The
# character class stops at a double quote, whitespace, or backslash so a JSON
# string boundary (or an escape sequence inside one) ends the match and the
# line stays valid JSON.
scrub_paths() {
  sed -E 's#/(Users|home)/[^"[:space:]\\]*#<SCRUBBED_PATH>#g'
}

# Layer 2 (decoded values, loop-2 major): walk every DECODED string value and
# scrub path forms the raw layer cannot see — JSON-escaped slashes decode to
# plain /Users/... here, plus tilde-rooted (~/...) and Windows (C:\Users\...)
# home paths. Applied per line; a line whose scrubbed normal form equals its
# plain normal form keeps its ORIGINAL bytes, so clean output is never
# re-encoded by jq.
cat > "$TMP_JQ" <<'JQ'
def scrub:
  gsub("/(Users|home)/[^\\s\"]*"; "<SCRUBBED_PATH>")
  | gsub("~/[^\\s\"]*"; "<SCRUBBED_PATH>")
  | gsub("[A-Za-z]:\\\\+[^\\s\"]*"; "<SCRUBBED_PATH>");
walk(if type == "string" then scrub else . end)
JQ

select_spans() {
  if [ -n "$HEAD_N" ]; then
    head -n "$HEAD_N" "$IN"
  else
    cat "$IN"
  fi
}

if ! select_spans | trace_redact | scrub_paths > "$TMP_RAW"; then
  err "sanitization pipeline failed — no output written"
  exit 2
fi

# Decode-aware pass: normal form and scrubbed form of every line, in input
# order; any jq failure (undecodable line) fails closed before output exists.
if ! jq -c '.' < "$TMP_RAW" > "$TMP_NORM" 2>/dev/null; then
  err "decode-aware scrub failed: input is not decodable JSONL — no output written"
  exit 2
fi
if ! jq -c -f "$TMP_JQ" < "$TMP_RAW" > "$TMP_SCRUB" 2>/dev/null; then
  err "decode-aware scrub failed while walking string values — no output written"
  exit 2
fi
# One decoded document per input line, or the streams cannot be zipped.
if [ "$(wc -l < "$TMP_RAW" | tr -d '[:space:]')" != "$(wc -l < "$TMP_NORM" | tr -d '[:space:]')" ] \
  || [ "$(wc -l < "$TMP_NORM" | tr -d '[:space:]')" != "$(wc -l < "$TMP_SCRUB" | tr -d '[:space:]')" ]; then
  err "decode-aware scrub failed: line/document count mismatch (blank or multi-document lines?) — no output written"
  exit 2
fi
: > "$TMP_OUT"
while IFS= read -r raw_line && IFS= read -r norm_line <&3 && IFS= read -r scrub_line <&4; do
  if [ "$norm_line" = "$scrub_line" ]; then
    printf '%s\n' "$raw_line" >> "$TMP_OUT"
  else
    printf '%s\n' "$scrub_line" >> "$TMP_OUT"
  fi
done < "$TMP_RAW" 3< "$TMP_NORM" 4< "$TMP_SCRUB"

# --- Fail-closed leak audit on the OUTPUT ----------------------------------------
# Independent of the sourced redactor where possible: even if trace_redact is
# a broken no-op, the backstop greps below still refuse to release a leak.
audit_failed=0

# 1. Fixed point of trace_redact: a second pass must change nothing.
if ! trace_redact < "$TMP_OUT" > "$TMP_AUDIT" 2>/dev/null; then
  err "leak audit: second trace_redact pass failed (fail closed)"
  audit_failed=1
elif [ "$(cksum < "$TMP_OUT")" != "$(cksum < "$TMP_AUDIT")" ]; then
  err "leak audit: a second trace_redact pass would still alter the output — secret-shaped content survived"
  audit_failed=1
fi

# 2. No home-rooted absolute path may survive the scrub.
if grep -qE '/(Users|home)/' "$TMP_OUT"; then
  err "leak audit: a home-rooted absolute path (/Users/... or /home/...) survived the path scrub"
  audit_failed=1
fi

# 2b. Decoded-value audit (loop-2 major): decode every string value and grep
# the DECODED representation, so JSON-escaped (\/Users\/...), tilde-rooted
# (~/...), and Windows (C:\Users\...) forms cannot hide behind the encoding.
# An undecodable output fails closed here (also caught by check 4).
if ! jq -r '.. | strings' < "$TMP_OUT" > "$TMP_DECODED" 2>/dev/null; then
  err "leak audit: output string values could not be decoded for the path audit (fail closed)"
  audit_failed=1
else
  if grep -qE '/(Users|home)/' "$TMP_DECODED"; then
    err "leak audit: a home-rooted absolute path survived in a DECODED string value"
    audit_failed=1
  fi
  # shellcheck disable=SC2088 # literal tilde is the point: auditing for ~-rooted paths, no expansion wanted
  if grep -qF -- '~/' "$TMP_DECODED"; then
    err "leak audit: a tilde-rooted home path (~/...) survived in a decoded string value"
    audit_failed=1
  fi
  if grep -qE '[A-Za-z]:\\+[Uu]sers' "$TMP_DECODED"; then
    err "leak audit: a Windows home path (C:\\Users\\...) survived in a decoded string value"
    audit_failed=1
  fi
  if grep -qE 'gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}' "$TMP_DECODED"; then
    err "leak audit: a secret-shaped token survived in a decoded string value"
    audit_failed=1
  fi
fi

# 3. Well-known secret shapes (audit backstop, not the redaction policy).
if grep -qE 'gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}' "$TMP_OUT"; then
  err "leak audit: a secret-shaped token survived sanitization (redactor broken or bypassed)"
  audit_failed=1
fi

# 4. Output must still be valid JSONL (one JSON object per line).
if ! jq empty < "$TMP_OUT" >/dev/null 2>&1; then
  err "leak audit: sanitized output is no longer valid JSONL"
  audit_failed=1
fi

if [ "$audit_failed" -ne 0 ]; then
  err "refusing to write ${OUT} — sanitized output failed the leak audit"
  exit 1
fi

mv "$TMP_OUT" "$OUT"

in_spans="$(wc -l < "$IN" | tr -d '[:space:]')"
out_spans="$(wc -l < "$OUT" | tr -d '[:space:]')"
printf 'sanitize-trace: wrote %s span(s) (input had %s) to %s\n' \
  "$out_spans" "$in_spans" "$OUT"
printf 'sanitize-trace: HUMAN REVIEW REQUIRED before commit — inspect %s line by line (AGENTS.md sensitivity rules apply; committing a fixture is a human act)\n' "$OUT" >&2
exit 0
