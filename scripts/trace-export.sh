#!/usr/bin/env bash
# trace-export.sh — opt-in trace exporter: projects a per-issue schema-v1
# trace.jsonl onto Application Insights Track API JSON envelopes (issue
# #112, feature trace-export-mapping-core, plan Phase 1).
#
# "App-Insights-native envelopes carrying OTel-conventional attribute
# names": the allowlisted gen_ai.* / harness.* keys ride verbatim inside
# each envelope's properties (→ customDimensions), so KQL can slice by
# customDimensions["harness.version"] without a schema translation layer.
#
# THIS FEATURE covers mapping + gating + the --dry-run-to-file seam ONLY.
# The redaction gate (validate-trace reuse + fixed-point output audit) is
# feature 2 (trace-export-redaction-gate) — its seam is redaction_gate()
# below, invoked on the STAGED output before anything leaves the staging
# dir. Transport (connection-string parsing + curl POST to v2/track) is
# feature 3 (trace-export-transport) — its seam is ship_envelopes(), which
# currently refuses with a clear not-implemented notice. This script never
# touches the network in feature-1 scope.
#
# Opt-in gating (plan Gate 0; decoupling doctrine — never wired into the
# lifecycle scripts, invocation is manual or via a user-side hook):
#   - TRACE_EXPORT_OTLP != 1        → exit 0 no-op notice; NOTHING written.
#   - TRACE_EXPORT_OTLP=1, ship path, APPLICATIONINSIGHTS_CONNECTION_STRING
#     unset                         → exit 0 no-op notice naming the var.
#   - --dry-run-to-file works WITHOUT a connection string (the CI seam
#     needs zero config); dry-run envelopes OMIT iKey entirely — the
#     transport injects it at ship time.
#
# Envelope mapping (plan mapping table v1, conductor-resolved pins):
#   tool/lifecycle → Microsoft.ApplicationInsights.RemoteDependency /
#     RemoteDependencyData: name = gen_ai.tool.name | harness.lifecycle_step,
#     type = harness.tool | harness.lifecycle, id = span_id, duration =
#     harness.duration_ms as hh:mm:ss.fff (absent → 00:00:00.000), success =
#     harness.outcome == pass (absent → true), resultCode = stringified
#     harness.exit_status when present (else the outcome, else omitted).
#   agent/model → Microsoft.ApplicationInsights.Event / EventData:
#     name = harness.agent/<gen_ai.agent.name> | harness.model/<model>;
#     numeric gen_ai.usage.* land in measurements as JSON NUMBERS.
#   Every envelope: ver 1, time = the span's own timestamp, tags carry
#     ai.cloud.role and ai.operation.id = "issue-<NN>"; properties carry the
#     allowlist-v1 projection, STRINGIFIED, deny-by-default (unknown/future
#     keys and the four excluded free-text fields never leave the process).
#   harness.version is load-bearing (plan D6): any span missing it aborts
#     the whole export (all-or-nothing batch, exit 1).
#
# Malformed lines: the exporter is not a validator — non-JSON(-object)
# lines are skipped and counted (stderr notice); refusal semantics belong
# to the feature-2 redaction gate (which reuses validate-trace.sh).
#
# Usage:
#   ./scripts/trace-export.sh <issue-number> [--dry-run-to-file <out.json>]
#       exports <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl
#   ./scripts/trace-export.sh <path/to/trace.jsonl> [--dry-run-to-file <out.json>]
#       exports the given file directly
#
# The dry-run output file is an INTERNAL SEAM for sensors/CI, not a stable
# contract (leading // comment lines say so in-band).
#
# Exit codes: 0 exported / clean no-op · 1 gate or export failure ·
# 2 usage/environment error — matches validate-trace.sh / sanitize-trace.sh.

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

usage() {
  {
    echo "usage: ./scripts/trace-export.sh <issue-number|trace-path> [--dry-run-to-file <out.json>]"
    echo "  <issue-number>  exports <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl"
    echo "  <trace-path>    exports the given trace.jsonl file directly"
    echo "  --dry-run-to-file <out.json>  write the envelope array to a file instead of shipping"
    echo "opt-in: TRACE_EXPORT_OTLP=1 enables the exporter; the ship path additionally"
    echo "        requires APPLICATIONINSIGHTS_CONNECTION_STRING (dry-run does not)"
    echo "exit codes: 0 exported / clean no-op, 1 gate or export failure, 2 usage/environment error"
  } >&2
}

# --- Seam: redaction gate (feature 2, trace-export-redaction-gate) -----------
# Runs on the STAGED output file before anything leaves the staging dir —
# feature 2 replaces this body with the validate-trace input gate plus the
# sanitize-trace-style fixed-point/backstop audit of the serialized
# envelopes (plan Gate 1 + Gate 2). Feature-1 scope: pass-through.
redaction_gate() { # redaction_gate <staged-envelope-file>
  local staged="$1"
  [ -f "$staged" ] || return 1
  return 0
}

# --- Seam: transport (feature 3, trace-export-transport) ---------------------
# Feature 3 replaces this body with connection-string parsing (regional
# IngestionEndpoint + InstrumentationKey), iKey injection, and the curl
# POST to ${IngestionEndpoint%/}/v2/track with itemsReceived==itemsAccepted
# verification. Until then the ship path refuses loudly — it must never
# pretend spans were shipped.
ship_envelopes() { # ship_envelopes <staged-envelope-file>
  red "error: the ship path (curl POST to v2/track) is not implemented yet — feature trace-export-transport (issue #112 Phase 3); use --dry-run-to-file <out.json> for the envelope projection" >&2
  exit 2
}

# --- Argument parsing (exit 2: usage error) -----------------------------------
ARG=""
DRY_RUN_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run-to-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      DRY_RUN_FILE="$2"
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

# --- Gate 0: opt-in (plan Gate 0) ---------------------------------------------
# Disabled is a clean no-op BEFORE anything is resolved or written — not
# even the --dry-run-to-file target may appear.
if [ "${TRACE_EXPORT_OTLP:-}" != "1" ]; then
  yellow "notice: trace export is disabled — set TRACE_EXPORT_OTLP=1 to opt in (nothing written)" >&2
  exit 0
fi
# Ship path needs the connection string; the dry-run seam does not (zero
# config beyond the opt-in flag — plan D5, the CI seam).
if [ -z "$DRY_RUN_FILE" ] && [ -z "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}" ]; then
  yellow "notice: TRACE_EXPORT_OTLP=1 but APPLICATIONINSIGHTS_CONNECTION_STRING is not set — nothing to ship (no-op); dry-run via --dry-run-to-file needs no connection string" >&2
  exit 0
fi

# --- Environment preconditions (exit 2: the exporter could not run) -----------
if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to build export envelopes" >&2
  exit 2
fi

# --- Resolve the trace file (CLI parity with validate-trace.sh / trace-report.sh)
TRACE_FILE=""
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file explicitly.
    TRACE_FILE="$ARG"
    ;;
  *)
    # Issue-number mode: resolve the main-checkout trace path.
    if ! ISSUE_NUM="$(issue_parse_number "$ARG" 2>/dev/null)"; then
      usage
      exit 2
    fi
    if ! MAIN_ROOT="$(issue_main_root 2>/dev/null)"; then
      red "error: cannot resolve the main checkout root (not inside a git repo?)" >&2
      exit 2
    fi
    ISSUE_PAD="$(printf '%02d' "$ISSUE_NUM")"
    TRACE_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/trace.jsonl"
    ;;
esac

if [ ! -f "$TRACE_FILE" ]; then
  red "error: trace file not found: ${TRACE_FILE}" >&2
  usage
  exit 2
fi
if [ ! -r "$TRACE_FILE" ]; then
  red "error: trace file is not readable: ${TRACE_FILE}" >&2
  exit 2
fi

# mktemp when available; a mkdir fallback keeps the exporter usable in
# minimal environments (e.g. sensor-pinned PATHs) without weakening cleanup.
# ALL output is staged here first (sanitize-trace precedent): nothing lands
# at its destination until the gate seam has passed.
if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d)"
else
  TMP_DIR="${TMPDIR:-/tmp}/trace-export.$$.${RANDOM}"
  mkdir -p "$TMP_DIR"
fi
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Single-pass jq projection (one jq invocation builds the whole array) -----
# Output protocol (parsed by bash below): three marker lines, then the
# pretty-printed envelope array:
#   ::skipped <N>     lines that are not JSON objects (skip-and-count);
#   ::noversion <N>   parsed spans missing harness.version (plan D6 abort);
#   ::count <N>       envelopes built.
MAPPING_FILTER="${TMP_DIR}/export-envelopes.jq"
cat > "$MAPPING_FILTER" <<'JQ'
# Shippable-attribute ALLOWLIST v1 (plan table + conductor-resolved forks:
# harness.warning IS allowlisted — enum-ish values from our own scripts;
# gen_ai.usage.* is a PREFIX rule). Deny-by-default: any key not matched
# here is dropped before envelope construction, so excluded free text
# (harness.args_summary, harness.summary, harness.worktree, harness.branch)
# and unknown/future keys are byte-absent from the output.
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
   "harness.require_complete", "harness.warning"];

def shippable_key:
  . as $k
  | ((allowlist | index($k)) != null) or ($k | startswith("gen_ai.usage."));

# properties → customDimensions: allowlisted keys only, values STRINGIFIED
# (Track API customDimensions are strings; numeric analysis rides
# measurements instead).
def props:
  [ to_entries[]
    | select(.key | shippable_key)
    | { key: .key, value: (.value | tostring) } ]
  | from_entries;

def lpad($n):
  tostring | if length >= $n then . else ("0" * ($n - length)) + . end;

# harness.duration_ms → Track API duration string hh:mm:ss.fff
# (absent input → "00:00:00.000").
def fmt_duration:
  ((. // 0) | floor) as $t
  | ((($t / 3600000) | floor) | lpad(2)) + ":"
    + (((($t % 3600000) / 60000) | floor) | lpad(2)) + ":"
    + (((($t % 60000) / 1000) | floor) | lpad(2)) + "."
    + (($t % 1000) | lpad(3));

# tool + lifecycle spans → RemoteDependencyData (AI dependencies table).
def dependency_base:
  . as $s
  | { ver: 2,
      name: (if $s.span == "tool"
             then ($s["gen_ai.tool.name"] // "unknown")
             else ($s["harness.lifecycle_step"] // "unknown")
             end),
      id: ($s["span_id"] // ""),
      type: (if $s.span == "tool" then "harness.tool" else "harness.lifecycle" end),
      duration: ($s["harness.duration_ms"] | fmt_duration),
      success: (if $s | has("harness.outcome")
                then ($s["harness.outcome"] == "pass")
                else true
                end),
      properties: ($s | props) }
  + (if $s | has("harness.exit_status")
     then { resultCode: ($s["harness.exit_status"] | tostring) }
     elif $s | has("harness.outcome")
     then { resultCode: ($s["harness.outcome"] | tostring) }
     else {}
     end);

# agent + model spans → EventData (AI customEvents table); numeric
# gen_ai.usage.* become measurements (JSON NUMBERS, never strings).
def event_base:
  . as $s
  | [ $s | to_entries[]
      | select((.key | startswith("gen_ai.usage.")) and (.value | type == "number")) ]
    as $usage
  | { ver: 2,
      name: (if $s.span == "agent"
             then "harness.agent/\($s["gen_ai.agent.name"] // "unknown")"
             else "harness.model/\($s["gen_ai.request.model"] // "unknown")"
             end),
      properties: ($s | props) }
  + (if ($usage | length) > 0 then { measurements: ($usage | from_entries) } else {} end);

# One span → one envelope. Dry-run envelopes OMIT iKey entirely; the
# transport (feature 3) injects it at ship time.
def envelope:
  . as $s
  | (if $s.span == "tool" or $s.span == "lifecycle"
     then { name: "Microsoft.ApplicationInsights.RemoteDependency",
            data: { baseType: "RemoteDependencyData", baseData: ($s | dependency_base) } }
     else { name: "Microsoft.ApplicationInsights.Event",
            data: { baseType: "EventData", baseData: ($s | event_base) } }
     end) as $shape
  | { ver: 1,
      name: $shape.name,
      time: ($s["timestamp"] // ""),
      sampleRate: 100,
      tags: { "ai.cloud.role": "agent-delivery-harness",
              "ai.operation.id": "issue-\($s["harness.issue"] // "unknown")" },
      data: $shape.data };

[inputs] as $lines
| [ $lines[] | fromjson? | select(type == "object") ] as $spans
| (($lines | length) - ($spans | length)) as $skipped
| ([ $spans[] | select(has("harness.version") | not) ] | length) as $noversion
| "::skipped \($skipped)",
  "::noversion \($noversion)",
  "::count \($spans | length)",
  ([ $spans[] | envelope ])
JQ

if ! projection="$(jq -nRr -f "$MAPPING_FILTER" < "$TRACE_FILE")"; then
  red "error: the envelope projection jq pass failed to run" >&2
  exit 2
fi

skipped="$(printf '%s\n' "$projection" | sed -n '1s/^::skipped //p')"
noversion="$(printf '%s\n' "$projection" | sed -n '2s/^::noversion //p')"
count="$(printf '%s\n' "$projection" | sed -n '3s/^::count //p')"
if ! [[ "$skipped" =~ ^[0-9]+$ && "$noversion" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]]; then
  red "error: the envelope projection produced an unreadable header" >&2
  exit 2
fi

# Skip-and-count (not refuse — refusal semantics are the feature-2 gate's).
if [ "$skipped" -gt 0 ]; then
  yellow "notice: skipped ${skipped} malformed line(s) (not valid JSON spans); run ./scripts/validate-trace.sh for details" >&2
fi

# harness.version is the queryable dimension (plan D6): all-or-nothing
# batch — a single span without it aborts the whole export.
if [ "$noversion" -gt 0 ]; then
  red "error: ${noversion} span(s) lack harness.version — refusing to export (harness.version is the queryable dimension; nothing shipped)" >&2
  exit 1
fi

# --- Stage the serialized envelope array (never write destinations directly) --
STAGED="${TMP_DIR}/envelopes.staged.json"
{
  printf '// trace-export dry-run envelope dump — INTERNAL SEAM for sensors/CI only.\n'
  printf '// This format is not a stable contract; it may change without notice.\n'
  printf '// Strip these // comment lines to obtain one JSON array of Track API envelopes.\n'
  printf '%s\n' "$projection" | tail -n +4
} > "$STAGED"

# Gate seam (feature 2): audits the staged OUTPUT before anything leaves
# the staging dir. Any gate failure ships/writes zero envelopes.
if ! redaction_gate "$STAGED"; then
  red "error: export gate rejected the staged envelopes — nothing written" >&2
  exit 1
fi

# --- Deliver: dry-run file or ship seam ---------------------------------------
if [ -n "$DRY_RUN_FILE" ]; then
  OUT_DIR="$(dirname "$DRY_RUN_FILE")"
  mkdir -p "$OUT_DIR"
  mv "$STAGED" "$DRY_RUN_FILE"
  green "dry run: wrote ${count} envelope(s) to ${DRY_RUN_FILE} (nothing shipped)"
  exit 0
fi

ship_envelopes "$STAGED"
