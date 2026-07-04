#!/usr/bin/env bash
# trace-lib.sh — single sourceable tracing primitive for the harness
# (issue #93, schema contract: docs/evaluation/trace-schema.v1.json).
#
# Exposes:
#   trace_span <type> <key=value>...
#     Appends exactly one schema-v1 JSON line to
#     <git toplevel>/.copilot-tracking/issues/issue-<PAD>/trace.jsonl
#     (PAD = 2-digit zero-padded issue number). Auto-stamps schema_version,
#     timestamp (ISO-8601 UTC), harness.issue (number), harness.version
#     (short HEAD SHA of the harness scripts), and a unique span_id.
#   trace_redact
#     stdin→stdout filter masking secret shapes; every serialized line
#     passes through it immediately before append (no caller can bypass it).
#
# Guarantees (plan D2): a trace-write failure NEVER fails the calling
# script — every error path warns to stderr and returns 0. There is no
# `exit` anywhere in this library.
#
# Issue resolution precedence (plan D5):
#   1. TRACE_ISSUE env var
#   2. current branch matching feature/issue-NN-*
#   3. worktree basename matching issue-NN
#
# parent_span_id: pass parent_span_id=<id> as an argument, or export
# TRACE_PARENT_SPAN_ID (argument wins).
#
# Source it; do not execute it directly.

set -euo pipefail

# Directory holding this library, captured at source time so
# harness.version reflects the harness scripts actually in use.
TRACE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Warn-only diagnostics: stderr, never a non-zero return (plan D2).
trace_warn() {
  printf 'trace-lib: warning: %s\n' "$*" >&2
  return 0
}

# Redact secret shapes from a fully-serialized span line (stdin→stdout).
# Portable sed -E only (BSD + GNU); patterns per plan D3:
#   - GitHub tokens ghp_/gho_/ghu_/ghs_/ghr_ and github_pat_
#   - AWS access key ids AKIA[0-9A-Z]{16}
#   - Bearer <token>
#   - generic secret/token/password/passwd/api_key/apikey/credential
#     JSON pairs ("key":"value") and embedded key=value shapes
#     (case-insensitive; value masked, key kept)
#   - uppercase env-style keys ending in SECRET/TOKEN/PASSWORD/ACCESS_KEY/
#     API_KEY(S)=value (uppercase-only, so lowercase gen_ai.usage.*_tokens
#     stays safe)
#   - hyphen-tolerant header shapes (X-Api-Key: value)
# JSON-safety invariant (loop-2 hardening): value matching is quoted-string
# shaped. The ':'-separated generic rule only masks inside a quoted JSON
# string value ("key":"value"), and the '='/header rules only fire on shapes
# that cannot occur in JSON structure (jq -c never emits '=' or a space-free
# 'word: ' outside string values), so redaction can never truncate an
# unquoted JSON number (e.g. gen_ai.usage.token_total=42) or break a line.
trace_redact() {
  sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+[A-Za-z0-9._~+=-]+/Bearer [REDACTED]/g' \
    -e 's/(^|[^[:alnum:]_])(([sS][eE][cC][rR][eE][tT]|[tT][oO][kK][eE][nN]|[pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[aA][pP][iI]_?[kK][eE][yY]|[cC][rR][eE][dD][eE][nN][tT][iI][aA][lL])[[:alnum:]_.]*"[[:space:]]*:[[:space:]]*")[^"]*/\1\2[REDACTED]/g' \
    -e 's/(^|[^[:alnum:]_])(([sS][eE][cC][rR][eE][tT]|[tT][oO][kK][eE][nN]|[pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[aA][pP][iI]_?[kK][eE][yY]|[cC][rR][eE][dD][eE][nN][tT][iI][aA][lL])[[:alnum:]_.]*=)[^"[:space:]]+/\1\2[REDACTED]/g' \
    -e 's/([A-Z0-9_]*(SECRET|TOKEN|PASSWORD|ACCESS_KEY|API_KEY)S?=)[^"[:space:]]+/\1[REDACTED]/g' \
    -e 's/(([A-Za-z0-9]+-)+([Aa][Pp][Ii][-_]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[[:space:]]*:[[:space:]]*)[^"[:space:]]+/\1[REDACTED]/g'
}

# Unique-per-call span id: 8 random bytes as hex, with a pid/time fallback
# when /dev/urandom is unavailable.
trace__span_id() {
  local hex=""
  hex="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$hex" ]; then
    hex="$(date +%s 2>/dev/null || true)-$$-${RANDOM}"
  fi
  printf '%s' "$hex"
}

# Resolve the issue number (unpadded, digits only) per the D5 precedence.
# Prints nothing and returns 1 when unresolvable.
trace__resolve_issue() {
  local raw="" branch="" base=""
  if [ -n "${TRACE_ISSUE:-}" ]; then
    raw="${TRACE_ISSUE}"
  else
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$branch" =~ ^feature/issue-([0-9]+)- ]]; then
      raw="${BASH_REMATCH[1]}"
    else
      base="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || true)")"
      if [[ "$base" =~ issue-([0-9]+) ]]; then
        raw="${BASH_REMATCH[1]}"
      fi
    fi
  fi
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$((10#$raw))"
}

# trace_span <type> <key=value>...
# Appends one redacted schema-v1 JSONL span. All failure modes are
# warn-and-return-0; malformed input is rejected without writing.
trace_span() {
  local span_type="${1:-}"
  if [ -z "$span_type" ]; then
    trace_warn "trace_span: missing span type — span dropped"
    return 0
  fi
  shift
  case "$span_type" in
    agent|model|tool|lifecycle) ;;
    *)
      trace_warn "trace_span: unknown span type '${span_type}' — span dropped"
      return 0
      ;;
  esac

  local kv
  for kv in "$@"; do
    if [[ "$kv" != *=* ]] || [ -z "${kv%%=*}" ]; then
      trace_warn "trace_span: malformed argument '${kv}' (expected key=value) — span dropped"
      return 0
    fi
  done

  # Reserved-key protection (loop-2 hardening): the auto-stamped identity
  # fields cannot be spoofed by a caller. Each reserved key is dropped with
  # a warning and the span is still emitted with the remaining legitimate
  # attributes. parent_span_id is intentionally NOT reserved (caller-winnable).
  local -a attrs=()
  local key
  for kv in "$@"; do
    key="${kv%%=*}"
    case "$key" in
      span|schema_version|timestamp|harness.issue|harness.version|span_id)
        trace_warn "trace_span: reserved key '${key}' cannot be overridden — attribute dropped"
        ;;
      *)
        attrs+=("$kv")
        ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    trace_warn "trace_span: jq not found — span dropped"
    return 0
  fi

  local issue_num=""
  issue_num="$(trace__resolve_issue)" || {
    trace_warn "trace_span: cannot resolve issue number (set TRACE_ISSUE, or use a feature/issue-NN-* branch or issue-NN worktree) — span dropped"
    return 0
  }
  local issue_pad=""
  issue_pad="$(printf '%02d' "$issue_num" 2>/dev/null)" || {
    trace_warn "trace_span: cannot pad issue number '${issue_num}' — span dropped"
    return 0
  }

  local toplevel=""
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    trace_warn "trace_span: not inside a git worktree — span dropped"
    return 0
  }

  local version=""
  version="$(git -C "$TRACE_LIB_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -z "$version" ]; then
    version="$(git -C "$toplevel" rev-parse --short HEAD 2>/dev/null || true)"
  fi
  if [ -z "$version" ]; then
    trace_warn "trace_span: cannot determine harness version (git rev-parse --short HEAD failed) — span dropped"
    return 0
  fi

  local timestamp=""
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || {
    trace_warn "trace_span: cannot produce a UTC timestamp — span dropped"
    return 0
  }

  local span_id=""
  span_id="$(trace__span_id)"
  if [ -z "$span_id" ]; then
    trace_warn "trace_span: cannot generate a span_id — span dropped"
    return 0
  fi

  # Build the span with jq -n so arbitrary values are JSON-escaped
  # correctly (plan D4). Auto-stamps first; caller key=value pairs are
  # folded in afterwards so an explicit parent_span_id= argument wins over
  # TRACE_PARENT_SPAN_ID. Typing (plan D6): only integer-looking values on
  # gen_ai.usage.* keys become JSON numbers; everything else stays a string.
  local line=""
  line="$(jq -cn \
    --arg span "$span_type" \
    --arg timestamp "$timestamp" \
    --arg version "$version" \
    --arg span_id "$span_id" \
    --arg parent "${TRACE_PARENT_SPAN_ID:-}" \
    --argjson issue "$issue_num" \
    --args '
      ({
        schema_version: 1,
        timestamp: $timestamp,
        span: $span,
        "harness.issue": $issue,
        "harness.version": $version,
        span_id: $span_id
       }
       + (if $parent != "" then {parent_span_id: $parent} else {} end))
      | reduce $ARGS.positional[] as $kv (.;
          ($kv | index("=")) as $i
          | ($kv[:$i]) as $k
          | ($kv[$i + 1:]) as $v
          | . + { ($k):
              (if ($k | startswith("gen_ai.usage.")) and ($v | test("^[0-9]+$"))
               then ($v | tonumber)
               else $v
               end) })
    ' ${attrs[@]+"${attrs[@]}"} 2>/dev/null)" || {
    trace_warn "trace_span: jq failed to serialize the span — span dropped"
    return 0
  }

  # Redaction is applied to the fully-serialized line so no field —
  # including future extra fields — can bypass it (plan D3).
  local redacted=""
  redacted="$(printf '%s\n' "$line" | trace_redact 2>/dev/null)" || {
    trace_warn "trace_span: redaction filter failed — span dropped"
    return 0
  }
  if [ -z "$redacted" ]; then
    trace_warn "trace_span: redaction produced an empty line — span dropped"
    return 0
  fi

  local trace_dir="${toplevel}/.copilot-tracking/issues/issue-${issue_pad}"
  mkdir -p "$trace_dir" 2>/dev/null || {
    trace_warn "trace_span: cannot create ${trace_dir} — span dropped"
    return 0
  }
  printf '%s\n' "$redacted" >> "${trace_dir}/trace.jsonl" 2>/dev/null || {
    trace_warn "trace_span: cannot append to ${trace_dir}/trace.jsonl — span dropped"
    return 0
  }
  return 0
}
