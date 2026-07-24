#!/usr/bin/env bash
# trace-lib.sh — single sourceable tracing primitive for the harness
# (issue #93, schema contract: docs/evaluation/trace-schema.v1.json).
#
# Exposes:
#   trace_span <type> <key=value>...
#     Appends exactly one schema-v1 JSON line to
#     <main checkout root>/.copilot-tracking/issues/issue-<PAD>/trace.jsonl
#     (PAD = 2-digit zero-padded issue number). The main checkout root is
#     dirname of `git rev-parse --git-common-dir` (issue #94 plan D1) —
#     identical to `git rev-parse --show-toplevel` in a plain repo, and the
#     MAIN checkout when called from a linked worktree, so one issue run
#     produces one trace file that survives worktree teardown.
#     Auto-stamps schema_version,
#     timestamp (ISO-8601 UTC), harness.issue (number), harness.version
#     (the SemVer release read from the top-level VERSION file, falling back
#     to 0.0.0-dev when absent), an optional harness.commit (short HEAD SHA of
#     the harness scripts, omitted when it cannot be determined), and a unique
#     span_id. On a successful append it also sets the global
#     TRACE_LAST_SPAN_ID to the span_id it wrote (cleared to "" on every drop
#     path) so a caller can parent a following span to it without re-parsing
#     the trace file (issue #174 in-process parent linkage).
#   trace_redact
#     stdin→stdout filter masking secret shapes; every serialized line
#     passes through it immediately before append (no caller can bypass it).
#   trace_now_ms
#     Prints integer epoch MILLISECONDS (portable macOS bash 3.2 + Linux;
#     never fails — falls back to seconds*1000 when no sub-second clock
#     source exists).
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

# Directory holding this library, captured at source time so the VERSION
# lookup and harness.commit reflect the harness scripts actually in use.
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
#   - bare JWTs (eyJ + three dot-separated base64url segments, length-floored)
#   - Azure SAS `sig=` query values and storage `AccountKey=` values
#     (key kept, value masked; value bounded by " & ; or whitespace)
#   - escaped PEM PRIVATE KEY blocks (-----BEGIN ... PRIVATE KEY----- ...
#     -----END ... PRIVATE KEY-----) collapsed on one serialized line
# JSON-safety invariant (loop-2 hardening): value matching is quoted-string
# shaped. The ':'-separated generic rule only masks inside a quoted JSON
# string value ("key":"value"), and the '='/header rules only fire on shapes
# that cannot occur in JSON structure (jq -c never emits '=' or a space-free
# 'word: ' outside string values), so redaction can never truncate an
# unquoted JSON number (e.g. gen_ai.usage.token_total=42) or break a line.
# Unquoted value rules also exclude backslash so they do not consume JSON
# escape introducers before embedded quotes (for example token_source=\"$3\").
trace_redact() {
  sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/[Ii]nstrumentation[Kk]ey=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/InstrumentationKey=[REDACTED]/g' \
    -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED]/g' \
    -e 's/[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+[A-Za-z0-9._~+=-]+/Bearer [REDACTED]/g' \
    -e 's/(^|[^[:alnum:]_])(([sS][eE][cC][rR][eE][tT]|[tT][oO][kK][eE][nN]|[pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[aA][pP][iI]_?[kK][eE][yY]|[cC][rR][eE][dD][eE][nN][tT][iI][aA][lL])[[:alnum:]_.]*"[[:space:]]*:[[:space:]]*")[^"]*/\1\2[REDACTED]/g' \
    -e 's/(^|[^[:alnum:]_])(([sS][eE][cC][rR][eE][tT]|[tT][oO][kK][eE][nN]|[pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[aA][pP][iI]_?[kK][eE][yY]|[cC][rR][eE][dD][eE][nN][tT][iI][aA][lL])[[:alnum:]_.]*=)[^"\\[:space:]]+/\1\2[REDACTED]/g' \
    -e 's/([A-Z0-9_]*(SECRET|TOKEN|PASSWORD|ACCESS_KEY|API_KEY)S?=)[^"\\[:space:]]+/\1[REDACTED]/g' \
    -e 's/(([A-Za-z0-9]+-)+([Aa][Pp][Ii][-_]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[[:space:]]*:[[:space:]]*)[^"\\[:space:]]+/\1[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED]/g' \
    -e 's/([?&][Ss][Ii][Gg]=)[^"&[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Aa]ccount[Kk]ey=)[^";[:space:]]+/\1[REDACTED]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END [A-Z ]*PRIVATE KEY-----/[REDACTED]/g'
}

# Integer epoch milliseconds, portable across macOS bash 3.2 and Linux.
# Preference order: GNU `date +%s%N` (Linux) when it yields pure digits,
# then perl Time::HiRes, then python3, then seconds*1000 as a last resort.
# Never fails (plan D2): worst case prints a coarser millisecond value.
trace_now_ms() {
  local ns=""
  ns="$(date +%s%N 2>/dev/null || true)"
  if [[ "$ns" =~ ^[0-9]{16,}$ ]]; then
    # Nanoseconds (19 digits this era) fit 64-bit bash arithmetic.
    printf '%s' "$((ns / 1000000))"
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    ns="$(perl -MTime::HiRes=time -e 'printf("%d", time() * 1000)' 2>/dev/null || true)"
    if [[ "$ns" =~ ^[0-9]+$ ]]; then
      printf '%s' "$ns"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    ns="$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || true)"
    if [[ "$ns" =~ ^[0-9]+$ ]]; then
      printf '%s' "$ns"
      return 0
    fi
  fi
  printf '%s000' "$(date +%s 2>/dev/null || printf '0')"
  return 0
}

# Resolve the MAIN checkout root (plan D1): dirname of the git common dir,
# absolutized and canonicalized. Equals --show-toplevel in a plain repo;
# resolves to the main checkout from a linked worktree. Prints nothing and
# returns 1 when unresolvable (caller warns and drops the span).
trace__main_root() {
  local common=""
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *)  common="$(pwd)/$common" ;;
  esac
  (cd "$(dirname "$common")" 2>/dev/null && pwd -P) || return 1
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
  TRACE_LAST_SPAN_ID=""
  if [ "${TRACE_COLLAPSE_CHILD_SPANS:-0}" = "1" ]; then
    return 0
  fi
  if [ -z "$span_type" ]; then
    trace_warn "trace_span: missing span type — span dropped"
    return 0
  fi
  shift
  case "$span_type" in
    # >>> trace-schema:span_types (authority docs/evaluation/trace-schema.v1.json .span_types; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
    agent|model|tool|lifecycle) ;;
    # <<< trace-schema:span_types
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
      span|schema_version|timestamp|harness.issue|harness.version|harness.commit|span_id)
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

  # Main-root pinning (plan D1): the trace file lives at the MAIN checkout
  # root regardless of caller CWD, so a linked worktree's spans and the
  # post-teardown `finish` span all land in one file.
  local main_root=""
  main_root="$(trace__main_root)" || {
    trace_warn "trace_span: cannot resolve the main checkout root — span dropped"
    return 0
  }

  # harness.version is the SemVer release, read from the top-level VERSION
  # file (the source of truth for "which release"). Resolve the harness root
  # robustly: prefer the VERSION sitting next to scripts/ (${TRACE_LIB_DIR}/..),
  # else the git toplevel of the harness scripts. First line, trimmed; falls
  # back to 0.0.0-dev when the file is missing or empty so the required
  # harness.version field is always stamped.
  local version_file=""
  if [ -f "${TRACE_LIB_DIR}/../VERSION" ]; then
    version_file="${TRACE_LIB_DIR}/../VERSION"
  else
    local harness_top=""
    harness_top="$(git -C "$TRACE_LIB_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$harness_top" ] && [ -f "${harness_top}/VERSION" ]; then
      version_file="${harness_top}/VERSION"
    fi
  fi
  local version=""
  if [ -n "$version_file" ]; then
    version="$(head -n1 "$version_file" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [ -z "$version" ]; then
    version="0.0.0-dev"
  fi

  # harness.commit is the "which code" signal: the short HEAD SHA of the
  # harness scripts. Optional (omit-never-fake): when it cannot be determined
  # the span is still emitted, just without harness.commit.
  local commit=""
  commit="$(git -C "$TRACE_LIB_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -z "$commit" ]; then
    commit="$(git -C "$toplevel" rev-parse --short HEAD 2>/dev/null || true)"
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
  # TRACE_PARENT_SPAN_ID. Typing (plan D6, extended by issue #94 plan D4):
  # integer-looking values on gen_ai.usage.* keys and on the exact keys
  # harness.exit_status / harness.duration_ms / harness.incomplete_count /
  # harness.violation_count / harness.warning_count (#103 trace-gate counts)
  # become JSON numbers; everything else stays a string (harness.stage and
  # digits-only shas like harness.review_gate_sha remain strings). Keep this
  # exact-key list in step with check-trace-consistency.sh's known-key type map.
  local line=""
  line="$(jq -cn \
    --arg span "$span_type" \
    --arg timestamp "$timestamp" \
    --arg version "$version" \
    --arg commit "$commit" \
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
       + (if $commit != "" then {"harness.commit": $commit} else {} end)
       + (if $parent != "" then {parent_span_id: $parent} else {} end))
      | reduce $ARGS.positional[] as $kv (.;
          ($kv | index("=")) as $i
          | ($kv[:$i]) as $k
          | ($kv[$i + 1:]) as $v
          | . + { ($k):
              # >>> trace-schema:numeric_keys (authority docs/evaluation/trace-schema.v1.json .numeric_keys + .numeric_key_prefixes; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
              (if (($k | startswith("gen_ai.usage."))
                   or ($k | startswith("harness.economics."))
                   or ($k == "harness.exit_status")
                   or ($k == "harness.duration_ms")
                   or ($k == "harness.finding_count")
                   or ($k == "harness.incomplete_count")
                   or ($k == "harness.violation_count")
                   or ($k == "harness.warning_count"))
              # <<< trace-schema:numeric_keys
                  and ($v | test("^[0-9]+$"))
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

  local trace_dir="${main_root}/.copilot-tracking/issues/issue-${issue_pad}"
  mkdir -p "$trace_dir" 2>/dev/null || {
    trace_warn "trace_span: cannot create ${trace_dir} — span dropped"
    return 0
  }
  printf '%s\n' "$redacted" >> "${trace_dir}/trace.jsonl" 2>/dev/null || {
    trace_warn "trace_span: cannot append to ${trace_dir}/trace.jsonl — span dropped"
    return 0
  }
  # shellcheck disable=SC2034  # exposed to callers after a successful append
  TRACE_LAST_SPAN_ID="$span_id"
  return 0
}

# trace_log <level> <message> [key=value]...
# Appends one schema-v1 JSONL log record (the detail stream) to the
# main-root-pinned .copilot-tracking/issues/issue-NN/log.jsonl, a sibling of
# trace.jsonl. Mirrors trace_span's structure and reuses its helpers. All
# failure modes are warn-and-return-0; malformed input is rejected without
# writing.
# trace_log() removed (issue #333): the log.jsonl detail stream had no
# remaining writers after #332 and duplicated trace.jsonl; failure detail
# lives in spans. HARNESS_LOG env no longer has any effect.

# --- Shared terminal lifecycle-span EXIT trap (issue #213, P-1) ---------------
# trace_lifecycle_init <lifecycle_step> [attr_fn] [post_fn]
#   Installs the stage-tracking state + an EXIT trap that emits EXACTLY ONE
#   `lifecycle` span (harness.lifecycle_step=<lifecycle_step>) carrying
#   outcome/exit_status/duration_ms, plus any extra `key=value` attributes that
#   the optional attr_fn prints (one per line) — evaluated at exit time so
#   late-bound values (branch, pr_number, worktree_removed, …) are captured.
#
#   The span is emitted only after the caller ARMS the trap via
#   trace_lifecycle_arm (which also stamps the duration T0), so any refusal
#   BEFORE arming — e.g. a usage error or an on-main refusal — emits nothing,
#   preserving the prior inline templates' "TRACE_STAGE gates emission" and
#   "T0 set at the arming stage" semantics exactly.
#
#   The optional 3rd arg post_fn (issue #329, plan Phase A) names a function
#   invoked AFTER the terminal span (and its trace_log line) are written —
#   i.e. AFTER the trace file already contains the finish/pr_merge/etc span
#   this exit is emitting. This is the ONLY correct place for any closeout
#   step that must see the terminal span already on disk (e.g. regenerating
#   trace-summary.json from the truly-final trace). post_fn runs on EVERY
#   armed exit — pass, fail, or blocked — so a mandatory closeout step is
#   never silently skipped on a failing path. It is called best-effort: any
#   error it raises is swallowed and never changes `rc`, the exit code the
#   caller originally raised, preserving teardown safety exactly. Backward
#   compatible: existing 1-2 arg callers (start-issue, create-pr, merge-pr,
#   the finish-issue path before this feature) are unaffected.
#
#   This is the single home for the boilerplate that used to be copy-pasted into
#   start-issue / create-pr / merge-pr / finish-issue (drift-guarded by
#   tests/meta/test_lifecycle_trap_no_inline_copy.sh). When trace-lib.sh is
#   absent, each lifecycle script's inline guard block defines NOOP
#   trace_lifecycle_init / trace_lifecycle_arm so the lifecycle never breaks.
trace_lifecycle_init() {
  TRACE_LIFECYCLE_STEP="${1:?trace_lifecycle_init: lifecycle step required}"
  TRACE_LIFECYCLE_ATTR_FN="${2:-}"
  TRACE_LIFECYCLE_POST_FN="${3:-}"
  TRACE_LIFECYCLE_ARMED=0
  TRACE_LIFECYCLE_T0=0
  trap '__trace_lifecycle_exit' EXIT
}

# Arm the terminal span and stamp its duration origin. Call once, at the stage
# where the prior inline template set TRACE_STAGE + TRACE_T0.
trace_lifecycle_arm() {
  TRACE_LIFECYCLE_ARMED=1
  TRACE_LIFECYCLE_T0="$(trace_now_ms)"
  # (log.jsonl start line removed — issue #333; the lifecycle span is the record)
}

__trace_lifecycle_exit() {
  local rc=$?
  if [ "${TRACE_LIFECYCLE_ARMED:-0}" = "1" ]; then
    local outcome=pass
    [ "$rc" -eq 0 ] || outcome=fail
    local -a attrs=(
      "harness.lifecycle_step=${TRACE_LIFECYCLE_STEP}"
      "harness.outcome=${outcome}"
      "harness.exit_status=${rc}"
      "harness.duration_ms=$(( $(trace_now_ms) - TRACE_LIFECYCLE_T0 ))"
    )
    if [ -n "${TRACE_LIFECYCLE_ATTR_FN:-}" ] &&
       declare -F "${TRACE_LIFECYCLE_ATTR_FN}" >/dev/null 2>&1; then
      local a
      while IFS= read -r a; do
        [ -n "$a" ] && attrs+=("$a")
      done < <("${TRACE_LIFECYCLE_ATTR_FN}")
    fi
    trace_span lifecycle "${attrs[@]}"
    # (log.jsonl end line removed — issue #333; the span above is the record)
    # Post-emission hook (issue #329, plan Phase A): runs AFTER the terminal
    # span above is already on disk, on every armed exit regardless of
    # outcome. Best-effort — a failing/absent post_fn must never change the
    # exit code the caller originally raised (`rc` is fixed before this
    # block and returned unconditionally below).
    if [ -n "${TRACE_LIFECYCLE_POST_FN:-}" ] &&
       declare -F "${TRACE_LIFECYCLE_POST_FN}" >/dev/null 2>&1; then
      "${TRACE_LIFECYCLE_POST_FN}" || true
    fi
  fi
  exit "$rc"
}
