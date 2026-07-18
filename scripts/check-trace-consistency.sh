#!/usr/bin/env bash
# check-trace-consistency.sh — standalone, report-only cross-artifact
# consistency checker (issue #103, features trace-consistency-core and
# trace-consistency-state, plan Phases 2–3).
#
# Where validate-trace.sh checks ONE artifact (the trace against the frozen
# schema contract), this checker asks whether the trace, progress.md, the
# feature list, and the review-gate marker tell the SAME story. Same CLI
# family as validate-trace.sh: findings to stdout, report-only (never called
# by lifecycle scripts here — gate wiring is Phase 4), exit 0 no findings ·
# 1 findings · 2 usage/environment error.
#
# Core rules (Phase 2):
#   log_without_span / span_without_log
#                     the lifted #95 multiset detector (tests/meta/
#                     test_trace_action_log_consistency.sh detect(), built
#                     explicitly for this issue to lift; pipeline kept
#                     VERBATIM below): compare `[role] step feature_id
#                     outcome` tuples from span=="agent" trace lines against
#                     the `## Action Log` payload bullets of progress.md
#                     (`- [<role>] <step> <feature_id> <outcome> — <summary>`,
#                     exactly what log-handback.sh writes), via comm on
#                     sorted multisets. A bullet with no span is a
#                     hand-written claim; a span with no bullet is an
#                     unlogged action. Findings echo the tuple — deliberate
#                     and safe: enum-valued fields already public in
#                     progress.md (plan decision 6); free-text summaries are
#                     never echoed.
#                         VIOLATION consistency: log_without_span [<role>] <step> <feature_id> <outcome>
#                         VIOLATION consistency: span_without_log [<role>] <step> <feature_id> <outcome>
#   role_attribution_gap
#                     every span=="agent" line must carry a gen_ai.agent.name
#                     inside the closed log-handback role enum (conductor |
#                     planning-subagent | generator-subagent |
#                     implementation-subagent | test-subagent |
#                     code-review-subagent). Line-numbered
#                     and VALUE-FREE (an out-of-enum role is an attribute
#                     value and is not echoed):
#                         VIOLATION consistency: role_attribution_gap line <N>
#
# State rules (Phase 3):
#   unverified_feature_pass
#                     every passes:true entry in feature_list.json must be
#                     backed by an agent span with
#                     harness.lifecycle_step=="green_handback", matching
#                     harness.feature_id, and harness.outcome=="pass" —
#                     completion without evidence otherwise.
#                         VIOLATION consistency: unverified_feature_pass <feature_id>
#   feature_start_missing
#                     every passes:true entry in feature_list.json must be
#                     backed by at least one agent span with
#                     harness.lifecycle_step=="feature_start" and matching
#                     harness.feature_id (issue #291; role not enforced —
#                     narrower than the red-first triple's role check).
#                     Waived by the same governed teeth_proof_waiver /
#                     deprecated red_first_waiver alias as teeth_proof_missing
#                     (key-presence precedence: a malformed canonical key
#                     shadows a valid legacy one and does not waive).
#                         VIOLATION consistency: feature_start_missing <feature_id>
#   review_reject_cap_exceeded
#                     the detection half of the issue #300 3-rejection stop
#                     rule: when a single harness.feature_id accumulates
#                     THREE OR MORE agent spans with
#                     harness.lifecycle_step=="review_verdict" and
#                     harness.outcome=="fail", flag it once. Count is PER
#                     feature_id (fewer than 3 rejections for a feature → no
#                     finding); the feature id is echoed, like the sibling
#                     feature-id findings. Report-only here — the review-gate
#                     hard-block on this finding is a separate feature.
#                         VIOLATION consistency: review_reject_cap_exceeded <feature_id>
#   review_sha_mismatch
#                     the review_gate_approve span's harness.review_gate_sha
#                     must equal the content of the
#                     .copilot-tracking/review-gate/approved-head marker.
#                     MARKER-ONLY (plan Open Question 2, resolved): no
#                     live-HEAD git leg, no gh/network — the checker works
#                     on a plain directory of artifacts.
#                         VIOLATION consistency: review_sha_mismatch
#   pr_mismatch       scan-and-skip (plan Open Question 1, option (a)):
#                     when progress.md carries a GitHub PR reference
#                     (…/pull/<N>) AND the trace carries a pr_create span
#                     with harness.pr_number, the numbers must agree.
#                         VIOLATION consistency: pr_mismatch
#
# Missing OPTIONAL artifacts (feature_list.json, the approved-head marker,
# a PR reference, the relevant spans) skip their rules with a NOTE — never
# a violation, exit unaffected:
#     NOTE: <rule> check skipped (<what is absent>)
# Missing REQUIRED artifacts (the trace, its sibling progress.md) are an
# environment error: exit 2.
#
# Artifact resolution:
#   ./scripts/check-trace-consistency.sh <issue-number>
#       trace.jsonl lives at <main root>/.copilot-tracking/issues/issue-NN/
#       (main root resolved via the shared git common dir, like
#       validate-trace); marker at
#       <main root>/.copilot-tracking/review-gate/approved-head.
#       progress.md + feature_list.json resolve from the main-root issue dir
#       when present, FALLING BACK to the invoking worktree's toplevel
#       tracking dir otherwise (#103 loop-2 F1) — the real layout, where
#       log-handback.sh writes progress at the worktree toplevel and the
#       main root holds only the trace.
#   ./scripts/check-trace-consistency.sh <path/to/trace.jsonl>
#       progress.md and feature_list.json are SIBLINGS of the named trace
#       (hermetic L0 fixtures); when the trace lives at a contract-shaped
#       path <root>/.copilot-tracking/issues/issue-NN/trace.jsonl the marker
#       is <root>/.copilot-tracking/review-gate/approved-head, otherwise the
#       marker is treated as absent (NOTE skip).
#
# Fork budget: a handful of constant-count processes (two jq passes, the
# lifted awk/sed/comm pipeline, one feature-list jq) — never per-line forks;
# this gets gate-wired in Phase 4.
#
# Exit codes: 0 no violations · 1 ≥1 violation · 2 usage/environment error

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

usage() {
  {
    echo "usage: ./scripts/check-trace-consistency.sh <issue-number|trace-path>"
    echo "  <issue-number>  checks <main root>/.copilot-tracking/issues/issue-NN/ artifacts"
    echo "  <trace-path>    checks the given trace.jsonl with progress.md (and"
    echo "                  feature_list.json when present) as sibling files"
    echo "exit codes: 0 no violations, 1 violations found, 2 usage/environment error"
  } >&2
}

# --- Environment preconditions (exit 2: the checker could not run) -----------
if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
ARG="$1"

if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to check trace consistency" >&2
  exit 2
fi

# --- Resolve the artifact set (house CLI shape, like validate-trace) ---------
TRACE_FILE=""
MARKER_FILE=""
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file; progress.md and
    # feature_list.json are siblings in the same directory.
    TRACE_FILE="$ARG"
    ;;
  *)
    # Issue-number mode: resolve the main-checkout artifact set.
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
    MARKER_FILE="${MAIN_ROOT}/.copilot-tracking/review-gate/approved-head"
    ;;
esac

if [ ! -f "$TRACE_FILE" ]; then
  red "error: trace file not found: ${TRACE_FILE}" >&2
  usage
  exit 2
fi

ISSUE_DIR="$(cd "$(dirname "$TRACE_FILE")" && pwd)"
ARTIFACT_DIR="$ISSUE_DIR"
if [ -z "$MARKER_FILE" ]; then
  # Path mode: the marker is resolvable only when the trace sits at a
  # contract-shaped path; otherwise the rule skips with a NOTE below.
  if [[ "$ISSUE_DIR" =~ ^(.*)/\.copilot-tracking/issues/issue-[0-9][0-9]+$ ]]; then
    MARKER_FILE="${BASH_REMATCH[1]}/.copilot-tracking/review-gate/approved-head"
  fi
fi

# Real-layout fallback (#103 loop-2 review F1): on live runs the main root
# holds only trace.jsonl — log-handback.sh writes progress.md (and the
# scaffold puts feature_list.json) in the INVOKING worktree's toplevel
# tracking dir. In issue-number mode, when the main-root progress.md is
# absent, resolve progress.md AND feature_list.json from the invoking
# worktree's toplevel (log-handback's resolution pattern); the trace and
# the review-gate marker stay at the main root.
if [ -n "${ISSUE_PAD:-}" ] && [ ! -f "${ARTIFACT_DIR}/progress.md" ]; then
  if WT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    WT_CANDIDATE="${WT_TOPLEVEL}/.copilot-tracking/issues/issue-${ISSUE_PAD}"
    if [ -f "${WT_CANDIDATE}/progress.md" ]; then
      ARTIFACT_DIR="$WT_CANDIDATE"
    fi
  fi
fi
PROGRESS_FILE="${ARTIFACT_DIR}/progress.md"
FEATURE_LIST_FILE="${ARTIFACT_DIR}/feature_list.json"

if [ ! -f "$PROGRESS_FILE" ]; then
  red "error: progress.md not found next to the trace: ${PROGRESS_FILE}" >&2
  exit 2
fi

if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d)"
else
  TMP_DIR="${TMPDIR:-/tmp}/check-trace-consistency.$$.${RANDOM}"
  mkdir -p "$TMP_DIR"
fi
trap 'rm -rf "${TMP_DIR}"' EXIT

violations=0

# --- Core: Action Log ↔ agent-span multiset comparison ------------------------
# ============================================================================
# LIFTED #95 DETECTOR (tuple extraction + Action Log slice + comm side
# selection copied from tests/meta/test_trace_action_log_consistency.sh
# detect() — the mutation-tested reference, built in #95 explicitly for this
# issue to lift; only the temp-file names and the finding prefixes differ,
# plus ONE tolerance deviation (#103 gate wiring): the oracle feeds jq the
# trace as parsed JSON and would ABORT on an unparseable line, while the
# live checker reads raw lines through `fromjson? | objects` so a corrupt
# line (already flagged invalid_json by validate-trace.sh) cannot crash the
# consistency pass. The tuple template string itself stays byte-identical.
# The meta test keeps its own inlined copy as the oracle; the
# test_trace_consistency_core.sh parity leg holds THIS copy tuple-for-tuple
# to it, so the two cannot drift apart silently — plan decision 5.)
# ============================================================================
SPANS_SORTED="${TMP_DIR}/spans.sorted"
LOGS_SORTED="${TMP_DIR}/logs.sorted"
jq -R -r 'fromjson? | objects | select(.span == "agent")
       | "[\(.["gen_ai.agent.name"])] \(.["harness.lifecycle_step"] // "-") \(.["harness.feature_id"] // "-") \(.["harness.outcome"] // "-")"' \
  "$TRACE_FILE" | sort > "$SPANS_SORTED"
awk '/^## Action Log/{inlog=1; next} /^## /{inlog=0} inlog' "$PROGRESS_FILE" \
  | sed -En 's/^- (\[[^]]+\] [^ ]+ [^ ]+ [^ ]+) — .*/\1/p' \
  | sort > "$LOGS_SORTED"

while IFS= read -r tuple; do
  [ -n "$tuple" ] || continue
  printf 'VIOLATION consistency: log_without_span %s\n' "$tuple"
  violations=$((violations + 1))
done < <(comm -23 "$LOGS_SORTED" "$SPANS_SORTED")
while IFS= read -r tuple; do
  [ -n "$tuple" ] || continue
  printf 'VIOLATION consistency: span_without_log %s\n' "$tuple"
  violations=$((violations + 1))
done < <(comm -13 "$LOGS_SORTED" "$SPANS_SORTED")

# --- Single trace pass: role attribution + state-rule span extraction ---------
# One jq program (single-pass house style, like validate-trace) emits a line
# protocol parsed below:
#   ::gap <N>        span=="agent" on line N lacks gen_ai.agent.name or its
#                    value is outside the closed log-handback role enum
#   ::green <fid>    green_handback agent span with outcome pass for <fid>
#   ::fstart <fid>   feature_start agent span for <fid> (role not enforced)
#   ::reject <fid>   review_verdict agent span with outcome fail for <fid>
#   ::approve <sha>  review_gate_approve span's harness.review_gate_sha
#   ::pr <num>       pr_create span's harness.pr_number
# Unparseable lines are skipped (schema conformance is validate-trace's job).
STATE_FILTER="${TMP_DIR}/consistency-state.jq"
cat > "$STATE_FILTER" <<'JQ'
# >>> trace-schema:roles (authority docs/evaluation/trace-schema.v1.json .roles; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
["conductor", "planning-subagent", "generator-subagent", "implementation-subagent",
 "test-subagent", "code-review-subagent"] as $roles
# <<< trace-schema:roles
| [inputs] as $lines
| range(0; $lines | length) as $i
| ($i + 1) as $n
| [ $lines[$i] | fromjson? ] as $parsed
| if ($parsed | length) == 0 or (($parsed[0] | type) != "object")
  then empty
  else $parsed[0] as $span
  | ( if ($span.span == "agent")
         and (($roles | index($span["gen_ai.agent.name"])) == null)
      then "::gap \($n)"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "green_handback")
         and ($span["harness.outcome"] == "pass")
         and (($span["harness.feature_id"] | type) == "string")
      then "::green \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "feature_start")
         and (($span["harness.feature_id"] | type) == "string")
      then "::fstart \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "review_verdict")
         and ($span["harness.outcome"] == "fail")
         and (($span["harness.feature_id"] | type) == "string")
      then "::reject \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span["harness.lifecycle_step"] == "review_gate_approve")
         and (($span["harness.review_gate_sha"] | type) == "string")
      then "::approve \($span["harness.review_gate_sha"])"
      else empty
      end ),
    ( if ($span["harness.lifecycle_step"] == "pr_create")
         and ($span["harness.pr_number"] != null)
      then "::pr \($span["harness.pr_number"] | tostring)"
      else empty
      end )
  end
JQ
if ! state_out="$(jq -nRr -f "$STATE_FILTER" < "$TRACE_FILE")"; then
  red "error: the consistency jq pass failed to run" >&2
  exit 2
fi

green_ids=$'\n'
feature_start_ids=$'\n'
reject_ids=$'\n'
approve_sha=""
pr_span_number=""
while IFS= read -r out_line; do
  case "$out_line" in
    '::gap '*)
      printf 'VIOLATION consistency: role_attribution_gap line %s\n' \
        "${out_line#'::gap '}"
      violations=$((violations + 1))
      ;;
    '::green '*)   green_ids="${green_ids}${out_line#'::green '}"$'\n' ;;
    '::fstart '*)  feature_start_ids="${feature_start_ids}${out_line#'::fstart '}"$'\n' ;;
    '::reject '*)  reject_ids="${reject_ids}${out_line#'::reject '}"$'\n' ;;
    '::approve '*) approve_sha="${out_line#'::approve '}" ;;  # last wins
    '::pr '*)      pr_span_number="${out_line#'::pr '}" ;;    # last wins
  esac
done <<< "$state_out"

# --- State: review_reject_cap_exceeded (issue #300) ---------------------------
# The DETECTION half of the 3-rejection stop rule: when a single
# harness.feature_id accumulates >=3 agent spans with
# harness.lifecycle_step=="review_verdict" and harness.outcome=="fail", flag
# it once. The count is PER feature_id. The per-line ::reject fids collected
# above are counted here in bash (sort|uniq -c is a constant fork budget — no
# per-line forks); the feature id is echoed, consistent with the sibling
# feature-id findings.
if [ "$reject_ids" != $'\n' ]; then
  while IFS= read -r reject_line; do
    [ -n "$reject_line" ] || continue
    reject_count="${reject_line%% *}"
    reject_fid="${reject_line#* }"
    if [ "$reject_count" -ge 3 ]; then
      printf 'VIOLATION consistency: review_reject_cap_exceeded %s\n' "$reject_fid"
      violations=$((violations + 1))
    fi
  done < <(printf '%s' "$reject_ids" | grep -v '^$' | sort | uniq -c \
    | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1 /')
fi

# --- Second trace pass: red-first evidence per feature (issue #144) ------------
# A completed (passes:true) coded feature must show one complete role-correct,
# file-ordered RED-first profile for the SAME harness.feature_id, all
# harness.outcome==pass, in TRACE FILE ORDER. Accepted profiles are:
#   generator-subagent red_handback -> impl_handback -> green_handback
# or the historical:
#   test-subagent red_handback -> implementation-subagent impl_handback ->
#   test-subagent green_handback
# (strictly increasing file positions red < impl < green). This pass does NOT
# read feature_list.json and never fabricates spans — it only observes what the
# trace already contains and emits one verdict per feature that has ≥1 agent
# span carrying a harness.feature_id:
#   ::redfirst <fid> ok       a role-correct ordered triple exists
#   ::redfirst <fid> role     an ordered triple exists by lifecycle step but a
#                             participating span has the wrong role profile;
#                             a passing feature emits red_first_profile_mismatch
#   ::redfirst <fid> missing  no ordered triple of the three steps exists
# A feature with no span here yields no line; the passing-feature loop below
# treats an absent verdict exactly like `missing`. The waiver decision and the
# passes:true selection stay on the bash side against feature_list.json.
REDFIRST_FILTER="${TMP_DIR}/consistency-redfirst.jq"
cat > "$REDFIRST_FILTER" <<'JQ'
# ordered(reds; impls; greens): does some red.idx < impl.idx < green.idx exist?
# Greedy is exact here: the earliest red leaves the most room for an impl after
# it, and the earliest such impl leaves the most room for a green after it.
def ordered($reds; $impls; $greens):
  ($reds | map(.idx) | min) as $r
  | if $r == null then false
    else ([$impls[] | select(.idx > $r) | .idx] | min) as $i
    | if $i == null then false
      else ([$greens[] | select(.idx > $i)] | length) > 0
      end
    end;
[ inputs
  | fromjson? | objects
  | select(.span == "agent")
  | select((.["harness.feature_id"] | type) == "string")
  | { fid:     .["harness.feature_id"],
      role:    .["gen_ai.agent.name"],
      step:    .["harness.lifecycle_step"],
      outcome: .["harness.outcome"] } ]
| to_entries
| map(.value + { idx: .key })          # array index == trace file order
| group_by(.fid)[]
| .[0].fid as $fid
| [ .[] | select(.outcome == "pass") ] as $pass
| [ $pass[] | select(.step == "red_handback") ]   as $reds
| [ $pass[] | select(.step == "impl_handback") ]  as $impls
| [ $pass[] | select(.step == "green_handback") ] as $greens
| [ $reds[]   | select(.role == "test-subagent") ]           as $rcRed
| [ $impls[]  | select(.role == "implementation-subagent") ] as $rcImpl
| [ $greens[] | select(.role == "test-subagent") ]           as $rcGreen
| [ $reds[]   | select(.role == "generator-subagent") ] as $generatorRed
| [ $impls[]  | select(.role == "generator-subagent") ] as $generatorImpl
| [ $greens[] | select(.role == "generator-subagent") ] as $generatorGreen
| ( if ordered($rcRed; $rcImpl; $rcGreen)
         or ordered($generatorRed; $generatorImpl; $generatorGreen) then "ok"
    elif ordered($reds; $impls; $greens) then "role"
    else "missing" end ) as $verdict
| "::redfirst \($fid) \($verdict)"
JQ
if ! redfirst_out="$(jq -nRr -f "$REDFIRST_FILTER" < "$TRACE_FILE")"; then
  red "error: the red-first evidence jq pass failed to run" >&2
  exit 2
fi

redfirst_ok_ids=$'\n'
redfirst_role_ids=$'\n'
while IFS= read -r rf_line; do
  case "$rf_line" in
    '::redfirst '*)
      rf_rest="${rf_line#'::redfirst '}"
      rf_fid="${rf_rest% *}"
      rf_verdict="${rf_rest##* }"
      case "$rf_verdict" in
        ok) redfirst_ok_ids="${redfirst_ok_ids}${rf_fid}"$'\n' ;;
        role) redfirst_role_ids="${redfirst_role_ids}${rf_fid}"$'\n' ;;
      esac
      ;;
  esac
done <<< "$redfirst_out"

# --- State: unverified_feature_pass -------------------------------------------
# Every passes:true feature must have green_handback evidence in the trace.
if [ -f "$FEATURE_LIST_FILE" ]; then
  if passing_ids="$(jq -r '.features[]? | select(.passes == true) | .id | strings' \
      "$FEATURE_LIST_FILE" 2>/dev/null)"; then
    # Governed red-first waivers (issue #144): a feature may skip red-first
    # checking only when it carries a teeth_proof_waiver (canonical) or the
    # deprecated red_first_waiver alias OBJECT whose .kind is in the closed set
    # AND whose .reason is a non-empty string after trimming whitespace. Any
    # other shape (missing, wrong type, invalid kind, empty reason) is NOT a
    # waiver. Extracted once here, not per feature.
    waiver_ids=$'\n'
    if raw_waiver_ids="$(jq -r '
        ["bootstrap", "visual-only", "doc-only", "justified"] as $kinds
        | .features[]?
        | select(.passes == true)
        | (if has("teeth_proof_waiver") then .teeth_proof_waiver else .red_first_waiver end) as $w
        | select(($w | type) == "object")
        | select(($w.kind | type) == "string" and ($kinds | index($w.kind)) != null)
        | select(($w.reason | type) == "string" and ($w.reason | test("\\S")))
        | .id | strings' \
        "$FEATURE_LIST_FILE" 2>/dev/null)"; then
      while IFS= read -r wfid; do
        [ -n "$wfid" ] || continue
        waiver_ids="${waiver_ids}${wfid}"$'\n'
      done <<< "$raw_waiver_ids"
    fi
    # Completed-feature teeth proof (issue #264): without a governed waiver,
    # a passes:true feature is satisfied by either a role-correct ordered
    # RED-first triple or a governed teeth_proof OBJECT whose .kind is in the
    # closed proof set and whose .evidence is a non-empty string after
    # trimming. teeth_proof satisfies the hard rule but still emits warn-only
    # context when trace ordering is absent.
    teeth_ids=$'\n'
    if raw_teeth_ids="$(jq -r '
        ["red_first", "mutation", "negative_fixture"] as $kinds
        | .features[]?
        | select(.passes == true)
        | select((.teeth_proof | type) == "object")
        | .teeth_proof as $t
        | select(($t.kind | type) == "string" and ($kinds | index($t.kind)) != null)
        | select(($t.evidence | type) == "string" and ($t.evidence | test("\\S")))
        | .id | strings' \
        "$FEATURE_LIST_FILE" 2>/dev/null)"; then
      while IFS= read -r tfid; do
        [ -n "$tfid" ] || continue
        teeth_ids="${teeth_ids}${tfid}"$'\n'
      done <<< "$raw_teeth_ids"
    fi
    while IFS= read -r fid; do
      [ -n "$fid" ] || continue
      if [[ "$green_ids" != *$'\n'"$fid"$'\n'* ]]; then
        printf 'VIOLATION consistency: unverified_feature_pass %s\n' "$fid"
        violations=$((violations + 1))
      fi
      if [[ "$waiver_ids" != *$'\n'"$fid"$'\n'* ]] \
          && [[ "$redfirst_role_ids" == *$'\n'"$fid"$'\n'* ]]; then
        printf 'VIOLATION consistency: red_first_profile_mismatch %s\n' "$fid"
        violations=$((violations + 1))
      fi
      if [[ "$waiver_ids" == *$'\n'"$fid"$'\n'* ]]; then
        :  # governed waiver — proof satisfied
      elif [[ "$redfirst_ok_ids" == *$'\n'"$fid"$'\n'* ]]; then
        :  # role-correct ordered triple present
      elif [[ "$teeth_ids" == *$'\n'"$fid"$'\n'* ]]; then
        printf 'WARNING consistency: red_first_ordering_absent %s\n' "$fid"
      else
        printf 'VIOLATION consistency: teeth_proof_missing %s\n' "$fid"
        violations=$((violations + 1))
        printf 'WARNING consistency: red_first_ordering_absent %s\n' "$fid"
      fi
      if [[ "$waiver_ids" == *$'\n'"$fid"$'\n'* ]]; then
        :  # governed waiver — feature_start not required
      elif [[ "$feature_start_ids" == *$'\n'"$fid"$'\n'* ]]; then
        :  # feature_start span present for this feature_id
      else
        printf 'VIOLATION consistency: feature_start_missing %s\n' "$fid"
        violations=$((violations + 1))
      fi
    done <<< "$passing_ids"
  else
    printf 'NOTE: unverified_feature_pass check skipped (feature_list.json is not valid JSON)\n'
  fi
else
  printf 'NOTE: unverified_feature_pass check skipped (no feature_list.json)\n'
fi

# --- State: review_sha_mismatch (marker-only — no git, no network) ------------
if [ -z "$approve_sha" ]; then
  printf 'NOTE: review_sha_mismatch check skipped (no review_gate_approve span in trace)\n'
elif [ -z "$MARKER_FILE" ] || [ ! -f "$MARKER_FILE" ]; then
  printf 'NOTE: review_sha_mismatch check skipped (no approved-head marker)\n'
else
  marker_sha=""
  IFS= read -r marker_sha < "$MARKER_FILE" || true
  if [ "$approve_sha" != "$marker_sha" ]; then
    printf 'VIOLATION consistency: review_sha_mismatch\n'
    violations=$((violations + 1))
  fi
fi

# --- State: pr_mismatch (scan-and-skip) ----------------------------------------
# The LAST …/pull/<N> reference in progress.md is the claim (#103 loop-2 F5:
# closeout lines come last; earlier prose may cite other PRs, e.g. "split
# from …/pull/55"); the pr_create span's harness.pr_number is the evidence.
# Either side absent → NOTE skip. The greedy `.*` prefix makes POSIX
# leftmost-longest matching select the last occurrence.
progress_content="$(cat "$PROGRESS_FILE")"
if [[ "$progress_content" =~ .*/pull/([0-9]+) ]]; then
  pr_progress_number="${BASH_REMATCH[1]}"
  if [ -z "$pr_span_number" ]; then
    printf 'NOTE: pr_mismatch check skipped (no pr_create span in trace)\n'
  elif [ "$pr_progress_number" != "$pr_span_number" ]; then
    printf 'VIOLATION consistency: pr_mismatch\n'
    violations=$((violations + 1))
  fi
else
  printf 'NOTE: pr_mismatch check skipped (no PR reference in progress.md)\n'
fi

# --- State: dark_run (completed issue window with no runtime tools) ------------
if [ "${TRACE_ALLOW_DARK_RUN:-}" = "1" ]; then
  printf 'NOTE: dark_run check skipped (TRACE_ALLOW_DARK_RUN=1)\n'
else
  dark_run_facts="$(jq -nRr '
    reduce inputs as $line
      ({worktree_create: false, finish: false, runtime_tools: 0, issue: ""};
       [ $line | fromjson? | objects ][0] as $span
       | if $span == null then .
         else
           .worktree_create = (.worktree_create or
             ($span.span == "lifecycle" and
              $span["harness.lifecycle_step"] == "worktree_create"))
           | .finish = (.finish or
             ($span.span == "lifecycle" and
              $span["harness.lifecycle_step"] == "finish"))
           | .runtime_tools +=
             (if $span.span == "tool" and
                 (($span["harness.session_id"] | type) == "string")
              then 1 else 0 end)
           | .issue =
             (if .issue == "" and (($span["harness.issue"] | type) == "number")
              then ($span["harness.issue"] | tostring) else .issue end)
         end)
    | [.worktree_create, .finish, .runtime_tools, .issue] | @tsv
  ' < "$TRACE_FILE")"
  IFS=$'\t' read -r dark_has_worktree_create dark_has_finish \
    dark_runtime_tool_count dark_issue <<< "$dark_run_facts"
  if [ "$dark_has_worktree_create" != "true" ] || [ "$dark_has_finish" != "true" ]; then
    printf 'NOTE: dark_run check skipped (issue window not complete — needs worktree_create and finish)\n'
  elif [ "$dark_runtime_tool_count" = "0" ]; then
    printf 'VIOLATION consistency: dark_run %s\n' "${dark_issue:-unknown}"
    violations=$((violations + 1))
  fi
fi

# --- Report tail + exit semantics (house family) --------------------------------
printf '%d violation(s)\n' "$violations"
if [ "$violations" -gt 0 ]; then
  red "✗ trace/artifact consistency check failed: ${TRACE_FILE}"
  exit 1
fi
green "✓ trace consistent with progress.md, feature list, and review-gate state: ${TRACE_FILE}"
