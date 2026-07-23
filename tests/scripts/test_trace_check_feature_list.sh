#!/usr/bin/env bash
# test_trace_check_feature_list.sh — regression sensor for check-feature-list.sh
# trace emission (issue #94, feature trace-check-feature-list, plan Phase 3).
#
# Contract under test (plan instrumentation table, decision D2):
#
#   check-feature-list.sh emits exactly ONE **tool** span per invocation —
#   span=tool, gen_ai.tool.name=check-feature-list. It must NOT emit a
#   lifecycle span: the 13-step lifecycle vocabulary is FROZEN and has no
#   feature-list-validation step (D2). Every span carries harness.outcome,
#   a NUMERIC harness.exit_status and NUMERIC harness.duration_ms, plus
#   harness.require_complete (0|1), and passes the #92 contract filter.
#
#   1. Valid + complete list          → outcome=pass, exit_status=0,
#      harness.incomplete_count=0 (JSON number); script exit 0 unchanged.
#   2. Valid + incomplete, warn mode  → outcome=pass (warning is non-blocking)
#      with harness.warning=incomplete_features and numeric
#      harness.incomplete_count=N; script exit 0 + warning text unchanged.
#   3. Valid + incomplete, REQUIRE_FEATURES_COMPLETE=1 → outcome=fail,
#      non-zero numeric exit_status, incomplete_count=N; script exit 1
#      unchanged.
#   4. Malformed JSON (hard fail)     → outcome=fail, non-zero numeric
#      exit_status; script exit 1 + "not valid JSON" message unchanged.
#   5. Guarded sourcing (plan D5): with trace-lib.sh absent the script still
#      behaves exactly as today (exit codes/messages), emitting nothing.
#
#   Spans land at the invoking repo's main root
#   (.copilot-tracking/issues/issue-NN/trace.jsonl), issue resolved via the
#   script's own TRACE_ISSUE export (plan D6 — the script never cds and may
#   run from any branch).
#
# Fixture style follows test_lifecycle_order.sh: throwaway repos under
# mktemp -d, scripts copied in individually, pinned PATH. The checked
# feature_list.json lives at the worktree-shaped path issue-lib resolves
# (<repo>/.worktrees/issue-NN/.copilot-tracking/issues/issue-NN/) — no real
# git worktree is needed for the check itself.
#
# Exit codes: 0 emission contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate check-feature-list trace emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

# --- Fixture helpers (test_lifecycle_order.sh style) ----------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

# make_repo <dir> <with_trace_lib:0|1>
make_repo() {
  local dir="$1" with_lib="$2"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/issue-lib.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/check-feature-list.sh" "${dir}/scripts/"
  if [ "$with_lib" = "1" ]; then
    cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  fi
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
}

# write_feature_list <repo-dir> <issue-pad> <json-content...>
# Places feature_list.json at the worktree-shaped path issue-lib resolves.
write_feature_list() {
  local repo="$1" pad="$2" content="$3"
  local dir="${repo}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$dir"
  printf '%s\n' "$content" > "${dir}/feature_list.json"
}

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'
INCOMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":false},{"id":"b","title":"B","steps":[],"passes":false},{"id":"c","title":"C","steps":[],"passes":true,"verification":"done"}]}'

# Assert the single tool span for one invocation.
# check_tool_span <label> <trace-file> <issue-num> <outcome> <require-flag>
check_tool_span() {
  local label="$1" file="$2" issue="$3" outcome="$4" reqflag="$5" line
  [ -f "$file" ] \
    || fail "${label}: check-feature-list.sh must emit a tool span to the main-root trace file (${file} missing) — check-feature-list.sh is not instrumented (feature trace-check-feature-list)"
  [ "$(wc -l < "$file" | tr -d '[:space:]')" = "1" ] \
    || fail "${label}: exactly ONE span per invocation expected, got $(wc -l < "$file" | tr -d '[:space:]') lines"
  line="$(cat "$file")"
  validate_span "$line" \
    || fail "${label}: span rejected by the contract-driven jq validation filter: ${line}"
  # D2: a TOOL span, never a lifecycle span (frozen vocabulary).
  printf '%s\n' "$line" | jq -e '
      (.span == "tool")
      and (.["gen_ai.tool.name"] == "check-feature-list")
      and (has("harness.lifecycle_step") | not)
    ' >/dev/null \
    || fail "${label}: must be a tool span with gen_ai.tool.name=check-feature-list and NO lifecycle_step (plan D2, frozen vocabulary): ${line}"
  printf '%s\n' "$line" | jq -e --argjson issue "$issue" --arg outcome "$outcome" --arg req "$reqflag" '
      ((.["harness.issue"] == $issue) and ((.["harness.issue"] | type) == "number"))
      and (.["harness.outcome"] == $outcome)
      and ((.["harness.exit_status"] | type) == "number")
      and (if $outcome == "pass"
           then (.["harness.exit_status"] == 0)
           else (.["harness.exit_status"] != 0)
           end)
      and ((.["harness.duration_ms"] | type) == "number")
      and (.["harness.duration_ms"] >= 0)
      and ((.["harness.require_complete"] | tostring) == $req)
    ' >/dev/null \
    || fail "${label}: span must carry harness.issue=${issue} (number), harness.outcome=${outcome}, numeric harness.exit_status/duration_ms, harness.require_complete=${reqflag}: ${line}"
}

# Pinned PATH: everything check-feature-list + trace-lib need, plus no gh at
# all (explicit SLUG= keeps issue_derive_slug from being called).
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

R1="${TMP_DIR}/r1"
make_repo "$R1" 1
write_feature_list "$R1" 50 "$COMPLETE_LIST"
write_feature_list "$R1" 51 "$INCOMPLETE_LIST"
write_feature_list "$R1" 52 "$INCOMPLETE_LIST"
mkdir -p "${R1}/.worktrees/issue-53/.copilot-tracking/issues/issue-53"
printf '{ not json\n' > "${R1}/.worktrees/issue-53/.copilot-tracking/issues/issue-53/feature_list.json"
cd "$R1"

# ============================================================================
# 1. Valid + complete → pass span, incomplete_count=0, exit 0 unchanged
# ============================================================================
PATH="$BIN" ./scripts/check-feature-list.sh 50 SLUG=x >"${TMP_DIR}/ok.out" 2>&1 \
  || { cat "${TMP_DIR}/ok.out"; fail "complete list: check-feature-list.sh must still exit 0 (behavior unchanged)"; }
grep -q "all features are complete" "${TMP_DIR}/ok.out" \
  || { cat "${TMP_DIR}/ok.out"; fail "complete list: success message must be unchanged"; }
check_tool_span "complete list" "${R1}/.copilot-tracking/issues/issue-50/trace.jsonl" 50 pass 0
jq -e '(.["harness.incomplete_count"] == 0) and ((.["harness.incomplete_count"] | type) == "number")' \
  "${R1}/.copilot-tracking/issues/issue-50/trace.jsonl" >/dev/null \
  || fail "complete list: span must carry harness.incomplete_count=0 as a JSON number"

# ============================================================================
# 2. Valid + incomplete, warn mode → pass span + warning attr, exit 0 unchanged
# ============================================================================
PATH="$BIN" ./scripts/check-feature-list.sh 51 SLUG=x >"${TMP_DIR}/warn.out" 2>&1 \
  || { cat "${TMP_DIR}/warn.out"; fail "warn mode: incomplete list must still exit 0 by default (behavior unchanged)"; }
grep -q "warning only" "${TMP_DIR}/warn.out" \
  || { cat "${TMP_DIR}/warn.out"; fail "warn mode: warning text must be unchanged"; }
check_tool_span "warn mode" "${R1}/.copilot-tracking/issues/issue-51/trace.jsonl" 51 pass 0
jq -e '
    (.["harness.incomplete_count"] == 2)
    and ((.["harness.incomplete_count"] | type) == "number")
    and (.["harness.warning"] == "incomplete_features")
  ' "${R1}/.copilot-tracking/issues/issue-51/trace.jsonl" >/dev/null \
  || fail "warn mode: span must carry numeric harness.incomplete_count=2 and harness.warning=incomplete_features (plan warn semantics: outcome stays pass, warning recorded as an attr)"

# ============================================================================
# 3. Incomplete + REQUIRE_FEATURES_COMPLETE=1 → fail span, exit 1 unchanged
# ============================================================================
if PATH="$BIN" REQUIRE_FEATURES_COMPLETE=1 ./scripts/check-feature-list.sh 52 SLUG=x >"${TMP_DIR}/hard.out" 2>&1; then
  cat "${TMP_DIR}/hard.out"; fail "hard mode: incomplete list must still exit 1 under REQUIRE_FEATURES_COMPLETE=1 (behavior unchanged)"
fi
grep -q "incomplete feature_list items remain." "${TMP_DIR}/hard.out" \
  || { cat "${TMP_DIR}/hard.out"; fail "hard mode: failure text must be unchanged"; }
check_tool_span "hard mode" "${R1}/.copilot-tracking/issues/issue-52/trace.jsonl" 52 fail 1
jq -e '(.["harness.incomplete_count"] == 2) and ((.["harness.incomplete_count"] | type) == "number")' \
  "${R1}/.copilot-tracking/issues/issue-52/trace.jsonl" >/dev/null \
  || fail "hard mode: fail span must still carry numeric harness.incomplete_count=2"

# ============================================================================
# 4. Malformed JSON → fail span, exit 1 + message unchanged
# ============================================================================
if PATH="$BIN" ./scripts/check-feature-list.sh 53 SLUG=x >"${TMP_DIR}/bad.out" 2>&1; then
  cat "${TMP_DIR}/bad.out"; fail "malformed JSON: check-feature-list.sh must still exit 1 (behavior unchanged)"
fi
grep -q "not valid JSON" "${TMP_DIR}/bad.out" \
  || { cat "${TMP_DIR}/bad.out"; fail "malformed JSON: error text must be unchanged"; }
check_tool_span "malformed JSON" "${R1}/.copilot-tracking/issues/issue-53/trace.jsonl" 53 fail 0

# ============================================================================
# 5. Guarded sourcing: trace-lib.sh absent — behavior identical, no emission
# ============================================================================
R2="${TMP_DIR}/r2"
make_repo "$R2" 0
[ ! -e "${R2}/scripts/trace-lib.sh" ] || fail "fixture bug: R2 must not contain trace-lib.sh"
write_feature_list "$R2" 60 "$COMPLETE_LIST"
cd "$R2"
PATH="$BIN" ./scripts/check-feature-list.sh 60 SLUG=x >"${TMP_DIR}/nolib.out" 2>&1 \
  || { cat "${TMP_DIR}/nolib.out"; fail "trace-lib absent: check-feature-list.sh must still exit 0 on a complete list (guarded source / no-op fallback, plan D5)"; }
grep -q "all features are complete" "${TMP_DIR}/nolib.out" \
  || { cat "${TMP_DIR}/nolib.out"; fail "trace-lib absent: success message must be unchanged"; }
[ ! -e "${R2}/.copilot-tracking/issues/issue-60/trace.jsonl" ] \
  || fail "trace-lib absent: no trace file may be created (no-op fallback)"

printf 'check-feature-list trace emission contract honored\n'
