#!/usr/bin/env bash
# log-export.sh — opt-in step-level LOG exporter: projects a per-issue schema-v1
# log.jsonl onto (a) an OTLP/HTTP+JSON logs body ({ resourceLogs: [...] }) and
# (b) Application Insights Track API MessageData envelopes
# (Microsoft.ApplicationInsights.Message), one record → one record (issue #220;
# feature log-export-mapping — plan Phase 5). A sibling to scripts/trace-export.sh
# that keeps that script's frozen byte-contract untouched.
#
# Correlation (the #223 deep-link keys): every OTLP logRecord shares its issue's
# deterministic 32-hex .traceId (the SAME derivation scripts/trace_tools/otlp.py
# trace_id uses, so a log joins its issue's trace) and carries the record
# span_id as .spanId WHEN present (never fabricated). Each MessageData envelope
# carries tags["ai.operation.id"]="issue-<NN>" and tags["ai.operation.parentId"]
# = the record span_id when present.
#
# Mapping (schema-v1 log record → projected record):
#   OTLP logRecord: traceId (per-issue), spanId (record span_id, omitted when
#     absent), timeUnixNano ("<epoch>000000000", string concat — no float),
#     severityNumber (info→9/warn→13/error→17), severityText (the level),
#     body.stringValue (the message), attributes (allowlist v1, deny-by-default,
#     each { key, value: { stringValue } }).
#   MessageData envelope: ver 1, name "Microsoft.ApplicationInsights.Message",
#     time (record timestamp), data.baseType "MessageData",
#     data.baseData.message (the message), data.baseData.severityLevel
#     (info→1/warn→2/error→3), data.baseData.properties (allowlist v1,
#     stringified → customDimensions). Dry-run envelopes OMIT iKey (the
#     transport injects it at ship time).
#   The allowlist-excluded free-text fields (harness.args_summary,
#     harness.summary and friends) never become attributes/properties and are
#     byte-absent from the output (allowlist drop; redaction is plan Phase 6).
#
# Opt-in gating (decoupling doctrine — never wired into the lifecycle scripts):
#   - LOG_EXPORT_OTLP != 1        → exit 0 no-op notice; NOTHING written.
#   - LOG_EXPORT_OTLP=1 + a --dry-run-*-to-file seam → writes the projected
#     body to a file WITHOUT any network call (zero config beyond the opt-in
#     flag; the seams never ship, so they never touch curl).
#
# Serialization (plan D3, jq-owned): the mapping engine (auto/python/jq) emits
# the LOGICAL JSON structure; this script pretty-prints it through `jq .` so the
# on-disk bytes stay jq-canonical (and byte-identical) across engines.
#
# Usage:
#   ./scripts/log-export.sh <issue-number> [--dry-run-otlp-logs-to-file <out>]
#       exports <main root>/.copilot-tracking/issues/issue-NN/log.jsonl
#   ./scripts/log-export.sh <path/to/log.jsonl> [--dry-run-logs-to-file <out>]
#       exports the given file directly
#
# The dry-run output file is an INTERNAL SEAM for sensors/CI, not a stable
# contract (leading // comment lines say so in-band).
#
# Exit codes: 0 exported / clean no-op · 1 export failure · 2 usage/environment
# error — matches trace-export.sh / validate-trace.sh.

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

# --- Mapping engine selection (mirrors trace-export.sh) ------------------------
# The log projection can be produced by an embedded jq program or by the Python
# pilot under scripts/trace_tools. LOG_EXPORT_ENGINE selects: `jq` forces jq;
# `python` forces the pilot; `auto` (default) prefers the pilot when python3 +
# uv are present AND the package imports, else jq. The resolved engine is
# ANNOUNCED on stderr (`notice: engine=<engine>`). Prints the resolved engine on
# stdout for capture. Output is byte-identical across engines (jq-owned
# serialization).
resolve_log_export_engine() {
  local requested="${LOG_EXPORT_ENGINE:-auto}"
  local resolved
  case "$requested" in
    jq)
      resolved="jq"
      ;;
    python)
      if command -v python3 >/dev/null 2>&1; then
        resolved="python"
      else
        yellow "notice: LOG_EXPORT_ENGINE=python but python3 is unavailable — falling back to the jq engine" >&2
        resolved="jq"
      fi
      ;;
    auto)
      if command -v python3 >/dev/null 2>&1 \
          && command -v uv >/dev/null 2>&1 \
          && PYTHONPATH="${SCRIPT_DIR}" python3 -c 'import trace_tools' >/dev/null 2>&1; then
        resolved="python"
      else
        resolved="jq"
      fi
      ;;
    *)
      yellow "notice: unrecognised LOG_EXPORT_ENGINE=${requested} — using the jq engine" >&2
      resolved="jq"
      ;;
  esac
  printf 'notice: engine=%s\n' "$resolved" >&2
  printf '%s\n' "$resolved"
}

# map_logs_python — run the Python pilot's log projection over stdin for the
# named subcommand, emitting the SAME two-line marker protocol as jq then a
# jq-pretty body. The pilot writes compact JSON; `jq .` re-serializes it so the
# staged bytes are jq-canonical (and byte-identical to the jq engine). Reads
# stdin, writes the reconstructed projection (markers + pretty body) on stdout.
map_logs_python() { # map_logs_python <subcommand>
  local sub="$1" raw header body
  if ! raw="$(PYTHONPATH="${SCRIPT_DIR}" python3 -m trace_tools "$sub")"; then
    return 1
  fi
  header="$(printf '%s\n' "$raw" | sed -n '1,2p')"
  if ! body="$(printf '%s\n' "$raw" | tail -n +3 | jq .)"; then
    return 1
  fi
  printf '%s\n%s\n' "$header" "$body"
}

usage() {
  {
    echo "usage: ./scripts/log-export.sh <issue-number|log-path> [--dry-run-otlp-logs-to-file <out> | --dry-run-logs-to-file <out>]"
    echo "  <issue-number>  exports <main root>/.copilot-tracking/issues/issue-NN/log.jsonl"
    echo "  <log-path>      exports the given log.jsonl file directly"
    echo "  --dry-run-otlp-logs-to-file <out>  write the OTLP/HTTP+JSON resourceLogs body to a file (never ships)"
    echo "  --dry-run-logs-to-file <out>       write the App-Insights MessageData envelope array to a file (never ships)"
    echo "opt-in: LOG_EXPORT_OTLP=1 enables the exporter (independent consent from the"
    echo "        trace stream). The dry-run seams are zero-network and need no other config."
    echo "engine: LOG_EXPORT_ENGINE selects the mapping engine — auto (default; Python"
    echo "        pilot when python3+uv present, else jq), python, or jq. jq is always the"
    echo "        fallback; output is byte-identical across engines."
    echo "exit codes: 0 exported / clean no-op, 1 export failure, 2 usage/environment error"
  } >&2
}

# --- Embedded jq log program (built per signal) -------------------------------
# Emits the shared allowlist v1 + correlation helpers, then the signal-specific
# projection. Both the OTLP-logs and MessageData programs share the allowlist so
# excluded free text is byte-absent by construction. $1 selects the signal.
write_log_jq_program() { # write_log_jq_program <otlp|appinsights> <dest.jq>
  local signal="$1" dest="$2"
  cat > "$dest" <<'JQ'
# Shippable-attribute ALLOWLIST v1 — the SAME deny-by-default surface the span
# projections use (27 keys + the gen_ai.usage.* prefix family). Any key not
# matched here is dropped, so excluded free text (harness.args_summary,
# harness.summary and friends) and unknown/future keys are byte-absent.
def allowlist:
  ["schema_version", "timestamp", "span", "span_id", "parent_span_id",
   "harness.issue", "harness.version",
   "harness.lifecycle_step", "harness.outcome", "harness.failure_mode",
   "harness.exit_status", "harness.duration_ms", "harness.incomplete_count",
   "harness.violation_count", "harness.warning_count",
   "harness.feature_id", "harness.stage",
   "gen_ai.tool.name", "gen_ai.operation.name", "gen_ai.agent.name",
   "gen_ai.request.model",
   "harness.review_gate_sha", "harness.pr_number",
   "harness.require_complete", "harness.warning", "harness.skill.name",
   "harness.subagent"];

def shippable_key:
  . as $k
  | ((allowlist | index($k)) != null) or ($k | startswith("gen_ai.usage."));

def zpad($n):
  tostring | if length >= $n then . else ("0" * ($n - length)) + . end;

def to_hex_digits:
  [ recurse(if . >= 16 then (. / 16 | floor) else empty end) ]
  | reverse
  | map(. % 16)
  | map("0123456789abcdef"[.:. + 1])
  | join("");

# Deterministic 32-lowercase-hex TraceId from harness.issue — the SAME
# derivation the span export uses (the log→trace join key).
def trace_id:
  ((.["harness.issue"] // 0) | floor | if . < 0 then 0 else . end)
  | (if . == 0 then "0" else to_hex_digits end)
  | zpad(32);

def epoch_seconds:
  (.["timestamp"] // "") | fromdateiso8601;
JQ

  if [ "$signal" = "otlp" ]; then
    cat >> "$dest" <<'JQ'

def sev_number:
  if . == "info" then 9 elif . == "warn" then 13 elif . == "error" then 17
  else 0 end;

def log_attributes:
  [ to_entries[]
    | select(.key | shippable_key)
    | { key: .key, value: { stringValue: (.value | tostring) } } ];

# One schema-v1 log record → one OTLP logRecord. spanId is OMITTED entirely
# when there is no non-empty span_id (honest correlation — never fabricated).
def log_record:
  . as $r
  | { traceId: ($r | trace_id),
      timeUnixNano: "\($r | epoch_seconds)000000000",
      severityNumber: ($r["level"] | sev_number),
      severityText: ($r["level"] // ""),
      body: { stringValue: ($r["message"] // "") },
      attributes: ($r | log_attributes) }
  + (if (($r["span_id"] // "") | length) > 0
     then { spanId: $r["span_id"] }
     else {} end);

[inputs] as $lines
| [ $lines[] | fromjson? | select(type == "object") ] as $recs
| (($lines | length) - ($recs | length)) as $skipped
| "::skipped \($skipped)",
  "::count \($recs | length)",
  ({ resourceLogs:
       [ { resource:
             { attributes:
                 [ { key: "service.name",
                     value: { stringValue: "agent-delivery-harness" } } ] },
           scopeLogs:
             [ { logRecords: [ $recs[] | log_record ] } ] } ] })
JQ
  else
    cat >> "$dest" <<'JQ'

def sev_level:
  if . == "info" then 1 elif . == "warn" then 2 elif . == "error" then 3
  else 0 end;

# properties → customDimensions: allowlisted keys only, values STRINGIFIED.
def props:
  [ to_entries[]
    | select(.key | shippable_key)
    | { key: .key, value: (.value | tostring) } ]
  | from_entries;

# One schema-v1 log record → one MessageData envelope. Dry-run envelopes OMIT
# iKey (the transport injects it at ship time). ai.operation.parentId carries
# the record span_id WHEN present (omitted when the record is uncorrelated).
def envelope:
  . as $r
  | { ver: 1,
      name: "Microsoft.ApplicationInsights.Message",
      time: ($r["timestamp"] // ""),
      tags: ({ "ai.operation.id": "issue-\($r["harness.issue"] // "unknown")" }
             + (if (($r["span_id"] // "") | length) > 0
                then { "ai.operation.parentId": $r["span_id"] }
                else {} end)),
      data: { baseType: "MessageData",
              baseData: { message: ($r["message"] // ""),
                          severityLevel: ($r["level"] | sev_level),
                          properties: ($r | props) } } };

[inputs] as $lines
| [ $lines[] | fromjson? | select(type == "object") ] as $recs
| (($lines | length) - ($recs | length)) as $skipped
| "::skipped \($skipped)",
  "::count \($recs | length)",
  ([ $recs[] | envelope ])
JQ
  fi
}

# --- Argument parsing (exit 2: usage error) -----------------------------------
ARG=""
DRY_RUN_OTLP_LOGS_FILE=""
DRY_RUN_LOGS_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run-otlp-logs-to-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      DRY_RUN_OTLP_LOGS_FILE="$2"
      shift 2
      ;;
    --dry-run-logs-to-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      DRY_RUN_LOGS_FILE="$2"
      shift 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [ -n "$ARG" ]; then
        usage
        exit 2
      fi
      ARG="$1"
      shift
      ;;
  esac
done
if [ -z "$ARG" ]; then
  usage
  exit 2
fi

# --- Gate 0: opt-in ------------------------------------------------------------
# Disabled is a clean no-op BEFORE anything is resolved or written — not even a
# dry-run target may appear. The exporter engages only when LOG_EXPORT_OTLP=1
# (independent consent from the higher-leak log stream).
if [ "${LOG_EXPORT_OTLP:-}" != "1" ]; then
  yellow "notice: log export is disabled — set LOG_EXPORT_OTLP=1 to opt in (nothing written)" >&2
  exit 0
fi

# --- Environment preconditions (exit 2: the exporter could not run) -----------
if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to build log export bodies" >&2
  exit 2
fi

# --- Resolve the log file (CLI parity with trace-export.sh) -------------------
LOG_FILE=""
case "$ARG" in
  */* | *.jsonl)
    LOG_FILE="$ARG"
    ;;
  *)
    if ! ISSUE_NUM="$(issue_parse_number "$ARG" 2>/dev/null)"; then
      usage
      exit 2
    fi
    if ! MAIN_ROOT="$(issue_main_root 2>/dev/null)"; then
      red "error: cannot resolve the main checkout root (not inside a git repo?)" >&2
      exit 2
    fi
    ISSUE_PAD="$(printf '%02d' "$ISSUE_NUM")"
    LOG_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/log.jsonl"
    ;;
esac

if [ ! -f "$LOG_FILE" ]; then
  red "error: log file not found: ${LOG_FILE}" >&2
  usage
  exit 2
fi
if [ ! -r "$LOG_FILE" ]; then
  red "error: log file is not readable: ${LOG_FILE}" >&2
  exit 2
fi

# --- Staging (never write destinations directly) ------------------------------
if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d)"
else
  TMP_DIR="${TMPDIR:-/tmp}/log-export.$$.${RANDOM}"
  if ! mkdir -m 700 "$TMP_DIR" 2>/dev/null; then
    red "error: staging dir cannot be created (pre-existing path refused): ${TMP_DIR}" >&2
    exit 2
  fi
fi
trap 'rm -rf "${TMP_DIR}"' EXIT

# run_log_projection — dispatch the selected engine over $LOG_FILE for one
# signal, emitting the two marker lines then a jq-pretty body. Prints on stdout;
# returns non-zero on engine failure.
run_log_projection() { # run_log_projection <otlp|appinsights> <python-subcommand>
  local signal="$1" sub="$2" engine filter
  engine="$(resolve_log_export_engine)"
  if [ "$engine" = "python" ]; then
    map_logs_python "$sub" < "$LOG_FILE"
    return $?
  fi
  filter="${TMP_DIR}/log-${signal}.jq"
  write_log_jq_program "$signal" "$filter"
  jq -nRr -f "$filter" < "$LOG_FILE"
}

# stage_and_write — parse the projection's markers, stage the body behind the
# // seam header, and move it to the dry-run destination.
stage_and_write() { # stage_and_write <projection> <dest> <label>
  local projection="$1" dest="$2" label="$3"
  local skipped count staged out_dir
  skipped="$(printf '%s\n' "$projection" | sed -n '1s/^::skipped //p')"
  count="$(printf '%s\n' "$projection" | sed -n '2s/^::count //p')"
  if ! [[ "$skipped" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]]; then
    red "error: the ${label} projection produced an unreadable header" >&2
    exit 2
  fi
  if [ "$skipped" -gt 0 ]; then
    yellow "notice: skipped ${skipped} malformed log line(s) (not valid JSON records)" >&2
  fi
  staged="${TMP_DIR}/${label}.staged.json"
  {
    printf '// log-export %s dry-run dump — INTERNAL SEAM for sensors/CI only.\n' "$label"
    printf '// This format is not a stable contract; it may change without notice.\n'
    printf '%s\n' "$projection" | tail -n +3
  } > "$staged"
  out_dir="$(dirname "$dest")"
  mkdir -p "$out_dir"
  mv "$staged" "$dest"
  green "dry run: wrote ${count} ${label} record(s) to ${dest} (nothing shipped)"
}

# --- OTLP/HTTP+JSON logs dry-run seam -----------------------------------------
if [ -n "$DRY_RUN_OTLP_LOGS_FILE" ]; then
  if ! otlp_projection="$(run_log_projection otlp map-logs-otlp)"; then
    red "error: the OTLP logs projection failed to run" >&2
    exit 2
  fi
  stage_and_write "$otlp_projection" "$DRY_RUN_OTLP_LOGS_FILE" "otlp-logs"
fi

# --- App-Insights MessageData dry-run seam ------------------------------------
if [ -n "$DRY_RUN_LOGS_FILE" ]; then
  if ! ai_projection="$(run_log_projection appinsights map-logs-appinsights)"; then
    red "error: the MessageData projection failed to run" >&2
    exit 2
  fi
  stage_and_write "$ai_projection" "$DRY_RUN_LOGS_FILE" "messagedata"
fi

# No seam requested → nothing to do (live ship is plan Phase 6+).
if [ -z "$DRY_RUN_OTLP_LOGS_FILE" ] && [ -z "$DRY_RUN_LOGS_FILE" ]; then
  yellow "notice: LOG_EXPORT_OTLP=1 but no dry-run seam requested — nothing to do (no-op)" >&2
fi
exit 0
