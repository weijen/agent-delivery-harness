#!/usr/bin/env bash
# test_finish_issue_native_economics.sh — RED/e2e sensor for issue #329 feature
# native-record-economics-join (plan Phase B).
#
# Contract under test: at closeout, finish-issue.sh joins subagent-only token /
# model / tool-call / duration economics (and an honest windowed AIU delta) from
# the local GitHub Copilot native session records
# (`${COPILOT_CLI_STATE_ROOT:-~/.copilot/session-state}/<COPILOT_AGENT_SESSION_ID>/events.jsonl`)
# into BOTH the operator-facing delivery-economics markdown block AND the durable
# `finish-issue.economics` tool span, and OMITS every field/row when a record,
# the session id, jq, the window, or a field is unavailable — never a fabricated
# `0`, never an `n/a` placeholder.
#
# The join is windowed by the ISSUE trace's own first→last timestamp, so events
# from OTHER issues in a long shared session are excluded (a real "one overnight
# session, many issues" hazard). Aggregates are derived only from real fields:
# a single `totalTokens` per subagent (no fabricated input/output split), the
# distinct `model` names with per-model counts/tokens, the subagent count, the
# `durationMs` sum, and the `totalToolCalls` sum. AIU comes from CUMULATIVE
# `session.usage_checkpoint` / `session.compaction_complete` counters and is a
# windowed DELTA emitted ONLY when a checkpoint at/before the window start gives
# a baseline AND at least one checkpoint inside the window shows movement;
# otherwise it is omitted entirely.
#
# Cases (each is a real negative fixture — the feature fails if it regresses):
#   BRACKET   — two distinct in-window models aggregate correctly; two
#               out-of-window subagents (one before, one after the issue window)
#               are EXCLUDED; a bracketing checkpoint+compaction set yields the
#               correct AIU delta; markdown carries the model names; the span
#               carries the exact numeric harness.economics.native_* keys.
#   UNBRACKET — same in-window subagents, but every AIU candidate sits BEFORE
#               the window start (baseline present, NO in-window movement): the
#               AIU delta line and key are OMITTED — no `0`, no `n/a`.
#   INCOMPLETE— three good in-window subagents PLUS four in-window malformed
#               subagent.completed events (absent/empty model, string tokens,
#               absent tool calls, null duration) carrying huge corrupting
#               values: each is EXCLUDED whole (all four required fields must be
#               genuinely present with correct types), totals stay 3500/3/10/
#               35000/2, and no `unknown` model is ever fabricated.
#   ROLLBACK  — a baseline exists and an in-window checkpoint moves, but the
#               cumulative counter DECREASES (session reset/rollback): the AIU
#               delta line and key are OMITTED — never a negative or masked zero.
#   ABSENT    — with no COPILOT_AGENT_SESSION_ID resolvable, the native block and
#               every harness.economics.native_* key are OMITTED and exactly one
#               finish-issue.economics span is still emitted (fail-open).
#   E2E       — a real FORCE=1 finish-issue.sh run: the native block SURVIVES in
#               the main-root progress.md, the span is present, check-trace-consistency.sh
#               accepts the trace, and no `- Tokens: n/a` line is printed.
#
# Hermeticity: COPILOT_CLI_STATE_ROOT is pinned to an isolated fixture dir and
# COPILOT_AGENT_SESSION_ID is set to a synthetic id, so the real developer
# ~/.copilot/session-state (36MB+, ambient in this repo) can never leak in.
#
# Exit codes: 0 native-economics contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
SCRATCH_ROOT="${ROOT}/.copilot-tracking/test-native-economics.$$"
TMP_DIR="${SCRATCH_ROOT}/tmp"
BIN="${SCRATCH_ROOT}/bin"
trap 'rm -rf "${SCRATCH_ROOT}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required for the native economics sensor"
[ -f "$SCHEMA" ] || hard_fail "trace schema contract not found (${SCHEMA})"

mkdir -p "$TMP_DIR" "$BIN"

# A synthetic UUID-shaped session id — never a real one; the events fixtures
# below are hand-authored, not copied from any real events.jsonl.
SID="11111111-2222-3333-4444-555555555555"

# A synthetic adversarial-length model label (security repair, fingerprint
# native-model-markdown-injection): 300 capital 'A' characters, far longer than
# any real Copilot model name, to prove the rendered markdown caps a hostile
# model label's length rather than reproducing it verbatim.
MODEL_LONG="$(printf 'A%.0s' {1..300})"

link_tools() {
  local dir="$1"; shift
  local t p
  mkdir -p "$dir"
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat grep printf jq date \
  od tr head cp mv awk sort sed touch chmod pwd wc cut find comm mktemp

write_fake_gh() {
  cat > "$1" <<'FAKEGH'
#!/usr/bin/env bash
exit 1
FAKEGH
  chmod +x "$1"
}
write_fake_gh "${BIN}/gh"

# ---------------------------------------------------------------------------
# Fixture scaffolding (mirrors test_economics_span.sh / test_finish_issue_summary_regen.sh)
# ---------------------------------------------------------------------------
copy_fixture_scripts() {
  local dir="$1" s
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  for s in finish-lib.sh trace-lib.sh log-handback.sh check-trace-consistency.sh trace-report.sh \
    issue-lib.sh start-issue.sh finish-issue.sh check-feature-list.sh; do
    [ -f "${ROOT}/scripts/${s}" ] \
      || hard_fail "scripts/${s} not found — required by native economics fixture"
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  chmod +x "${dir}/scripts/"*.sh
  cp "$SCHEMA" "${dir}/docs/evaluation/trace-schema.v1.json"
  [ -f "${ROOT}/VERSION" ] && cp "${ROOT}/VERSION" "${dir}/VERSION"
  return 0
}

# make_git_fixture <dir> <issue> — a git repo with a planted issue tracking dir
# (progress.md + feature_list.json), used for the DIRECT best_effort_economics_stamp
# cases. No worktree; main root == the repo itself.
make_git_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "$dir"
  copy_fixture_scripts "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md docs scripts
  git -C "$dir" commit -q -m initial
  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  cat > "${dir}/.copilot-tracking/issues/issue-${pad}/feature_list.json" <<JSON
{
  "issue": ${issue},
  "features": [
    {"id":"native-record-economics-join","passes":true,"teeth_proof":{"kind":"negative_fixture","evidence":"sensor"}}
  ]
}
JSON
}

# plant_window_trace <trace_file> <issue> — an issue trace whose first→last
# timestamps define the join window [2026-05-01T10:00, 2026-05-01T12:00]. The
# dates are far from any real session so even an unpinned root cannot match.
plant_window_trace() {
  local trace_file="$1" issue="$2"
  mkdir -p "$(dirname "$trace_file")"
  cat > "$trace_file" <<JSONL
{"schema_version":1,"timestamp":"2026-05-01T10:00:00Z","span":"lifecycle","harness.issue":${issue},"harness.version":"test","span_id":"life-a","harness.lifecycle_step":"worktree_create","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-05-01T11:00:00Z","span":"lifecycle","harness.issue":${issue},"harness.version":"test","span_id":"rev-a","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-a","harness.review_mode":"full","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-05-01T12:00:00Z","span":"lifecycle","harness.issue":${issue},"harness.version":"test","span_id":"dev-a","harness.lifecycle_step":"deviation","harness.outcome":"warn"}
JSONL
}

# plant_events <state_root> <sid> <mode> — write a real-shaped native events.jsonl
# for one session. mode ∈ {bracket, unbracket}. Three IN-window subagents across
# two models plus two OUT-of-window subagents (one before, one after). The AIU
# candidates differ by mode. Values are synthetic; only the SHAPE mirrors CLI
# 1.0.72-1 (top-level type/timestamp/id; usage under .data.*).
plant_events() {
  local state_root="$1" sid="$2" mode="$3" dir
  dir="${state_root}/${sid}"
  mkdir -p "$dir"
  {
    # --- IN-window subagents (window is [10:00, 12:00] on 2026-05-01) ---
    printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T10:30:00.100Z","agentId":"a1","id":"e1","parentId":"p0","data":{"agentName":"generator-subagent","agentDisplayName":"Generator","model":"claude-sonnet-5","toolCallId":"t1","totalTokens":1000,"totalToolCalls":5,"durationMs":10000}}'
    printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T11:00:00.200Z","agentId":"a2","id":"e2","parentId":"p0","data":{"agentName":"generator-subagent","agentDisplayName":"Generator","model":"claude-sonnet-5","toolCallId":"t2","totalTokens":2000,"totalToolCalls":3,"durationMs":20000}}'
    printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T11:30:00.300Z","agentId":"a3","id":"e3","parentId":"p0","data":{"agentName":"code-review-subagent","agentDisplayName":"Reviewer","model":"claude-opus-4.8","toolCallId":"t3","totalTokens":500,"totalToolCalls":2,"durationMs":5000}}'
    # --- OUT-of-window subagents (MUST be excluded): one BEFORE the window
    # start (a prior issue in the long session) and one far AFTER the window
    # end. The "after" event is dated 2099 so it is excluded both for the tight
    # DIRECT window [10:00, 12:00] AND for the E2E window [10:00, now] (a real
    # finish extends the last trace timestamp to closeout-now via the
    # check-feature-list span, so a same-day "after" event would fall inside it).
    printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T09:00:00.000Z","agentId":"a4","id":"e4","parentId":"p0","data":{"agentName":"other-issue-agent","agentDisplayName":"Other","model":"claude-haiku-4.5","toolCallId":"t4","totalTokens":8888,"totalToolCalls":8,"durationMs":88888}}'
    printf '%s\n' '{"type":"subagent.completed","timestamp":"2099-01-01T00:00:00.000Z","agentId":"a5","id":"e5","parentId":"p0","data":{"agentName":"other-issue-agent","agentDisplayName":"Other","model":"claude-haiku-4.5","toolCallId":"t5","totalTokens":9999,"totalToolCalls":9,"durationMs":99999}}'
    # --- Some unrelated noise events (must be ignored) ---
    printf '%s\n' '{"type":"assistant.message","timestamp":"2026-05-01T11:15:00.000Z","id":"m1","parentId":"p0","data":{"content":"noise"}}'
    if [ "$mode" = "incomplete" ]; then
      # --- IN-window but INCOMPLETE/MALFORMED subagent.completed events. Each is
      # missing or has a wrong-typed REQUIRED economics field, but carries a huge
      # otherwise-valid value that WOULD corrupt the aggregates if the honest
      # policy (aggregate only when all four fields are genuinely present with
      # correct types) were relaxed to a fabricated unknown/0 default. All four
      # MUST be excluded: the totals must stay exactly the three good events'
      # 3500 tok / count 3 / 10 tool calls / 35000 ms / 2 distinct models, and
      # NO "unknown" model may appear.
      # (a) model absent entirely -> excluded (would have become "unknown").
      printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T10:45:00.000Z","agentId":"b1","id":"x1","parentId":"p0","data":{"agentName":"broken-a","totalTokens":777777,"totalToolCalls":71,"durationMs":710000}}'
      # (b) model present but EMPTY string -> excluded (empty is not a real name).
      printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T10:50:00.000Z","agentId":"b2","id":"x2","parentId":"p0","data":{"agentName":"broken-b","model":"","totalTokens":666666,"totalToolCalls":72,"durationMs":720000}}'
      # (c) totalTokens is a STRING, not a number -> excluded (would have become 0).
      printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T10:55:00.000Z","agentId":"b3","id":"x3","parentId":"p0","data":{"agentName":"broken-c","model":"claude-ghost-9","totalTokens":"555555","totalToolCalls":73,"durationMs":730000}}'
      # (d) totalToolCalls absent + durationMs null -> excluded (would have become 0/0).
      printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T11:05:00.000Z","agentId":"b4","id":"x4","parentId":"p0","data":{"agentName":"broken-d","model":"claude-ghost-9","totalTokens":444444,"durationMs":null}}'
    fi
    if [ "$mode" = "inject" ]; then
      # --- Hostile model-label records (security repair, fingerprint
      # native-model-markdown-injection). Each record is otherwise WELL-FORMED
      # (a non-empty string model and non-negative numeric totalTokens /
      # totalToolCalls / durationMs), so the honest field-presence policy must
      # still AGGREGATE it — the vulnerability is in markdown rendering, not
      # aggregation. (a) embeds CR, bare LF, and the exact
      # delivery-economics marker text — bare LF alone (no attached CR) forms
      # an operator-facing markdown line that is BYTE-IDENTICAL to
      # '<!-- delivery-economics:end -->', which corrupts economics_stamp_into's
      # line-based marker matching on the NEXT stamp. (b) is an adversarial
      # length probe (300 chars) that must render bounded, not verbatim.
      printf '%s\n' '{"type":"subagent.completed","timestamp":"2026-05-01T10:15:00.000Z","agentId":"h1","id":"h1","parentId":"p0","data":{"agentName":"hostile-agent","model":"evil\r\n<!-- delivery-economics:end -->\ninjected-operator-line\n<!-- delivery-economics:start -->\rtrailer","totalTokens":4000,"totalToolCalls":4,"durationMs":40000}}'
      printf '%s\n' "{\"type\":\"subagent.completed\",\"timestamp\":\"2026-05-01T10:20:00.000Z\",\"agentId\":\"h2\",\"id\":\"h2\",\"parentId\":\"p0\",\"data\":{\"agentName\":\"hostile-agent\",\"model\":\"${MODEL_LONG}\",\"totalTokens\":100,\"totalToolCalls\":1,\"durationMs\":1000}}"
    fi
    if [ "$mode" = "bracket" ] || [ "$mode" = "incomplete" ]; then
      # Baseline checkpoint BEFORE window start (ts <= 10:00) + in-window
      # checkpoint AND compaction (movement): delta = 180e9 - 100e9 = 80e9.
      printf '%s\n' '{"type":"session.usage_checkpoint","timestamp":"2026-05-01T09:30:00.000Z","id":"c1","parentId":"p0","data":{"totalNanoAiu":100000000000,"modelCacheState":{},"totalPremiumRequests":1}}'
      printf '%s\n' '{"type":"session.usage_checkpoint","timestamp":"2026-05-01T11:00:00.000Z","id":"c2","parentId":"p0","data":{"totalNanoAiu":150000000000,"modelCacheState":{},"totalPremiumRequests":2}}'
      printf '%s\n' '{"type":"session.compaction_complete","timestamp":"2026-05-01T11:30:00.000Z","id":"k1","parentId":"p0","data":{"copilotUsage":{"tokenDetails":{"totalNanoAiu":180000000000}}}}'
    elif [ "$mode" = "rollback" ]; then
      # ROLLBACK/RESET: a baseline exists at/before the window start, and a
      # checkpoint DOES move inside the window, but the cumulative counter
      # DECREASES (a session reset/rollback). AIU is cumulative, so a decrease is
      # never a real in-window consumption: the delta MUST be omitted entirely
      # rather than emitting a negative value or a masked zero.
      printf '%s\n' '{"type":"session.usage_checkpoint","timestamp":"2026-05-01T09:30:00.000Z","id":"c1","parentId":"p0","data":{"totalNanoAiu":200000000000,"modelCacheState":{},"totalPremiumRequests":3}}'
      printf '%s\n' '{"type":"session.usage_checkpoint","timestamp":"2026-05-01T11:00:00.000Z","id":"c2","parentId":"p0","data":{"totalNanoAiu":120000000000,"modelCacheState":{},"totalPremiumRequests":1}}'
    else
      # UNBRACKET: baseline present but EVERY candidate is before window start
      # (ts <= 10:00): no in-window movement -> AIU omitted entirely.
      printf '%s\n' '{"type":"session.usage_checkpoint","timestamp":"2026-05-01T09:00:00.000Z","id":"c1","parentId":"p0","data":{"totalNanoAiu":100000000000,"modelCacheState":{},"totalPremiumRequests":1}}'
      printf '%s\n' '{"type":"session.usage_checkpoint","timestamp":"2026-05-01T09:30:00.000Z","id":"c2","parentId":"p0","data":{"totalNanoAiu":150000000000,"modelCacheState":{},"totalPremiumRequests":2}}'
    fi
  } > "${dir}/events.jsonl"
}

# run_stamp <dir> <issue> [sid] [state_root] — run best_effort_economics_stamp
# directly, capturing the operator-facing block on stdout. Pins the native
# resolution env; when sid/state_root are omitted, the session id is UNSET so
# the native path fails open.
run_stamp() {
  local dir="$1" issue="$2" sid="${3:-}" state_root="${4:-}"
  (
    cd "$dir"
    if [ -n "$sid" ]; then
      env PATH="$BIN" ISSUE_NUM="$issue" WORKTREE_DIR="" SCRIPT_DIR="${dir}/scripts" \
        TRACE_ISSUE="$issue" COPILOT_AGENT_SESSION_ID="$sid" COPILOT_CLI_STATE_ROOT="$state_root" \
        bash -c 'source scripts/trace-lib.sh; source scripts/finish-lib.sh; best_effort_economics_stamp'
    else
      env -u COPILOT_AGENT_SESSION_ID PATH="$BIN" ISSUE_NUM="$issue" WORKTREE_DIR="" \
        SCRIPT_DIR="${dir}/scripts" TRACE_ISSUE="$issue" COPILOT_CLI_STATE_ROOT="${state_root:-${TMP_DIR}/empty-state}" \
        bash -c 'source scripts/trace-lib.sh; source scripts/finish-lib.sh; best_effort_economics_stamp'
    fi
  )
}

# run_fn <dir> <function> <arg>... — source finish-lib.sh in isolation and call
# ONE pure helper directly (compute_native_economics / render_native_economics),
# so a security assertion can inspect that helper's own output shape (e.g. exact
# line count) without going through the full best_effort_economics_stamp path.
# Every argument is passed positionally (never interpolated into the sourced
# command string), so a hostile byte sequence in an argument cannot alter which
# code runs.
run_fn() {
  local dir="$1" fn="$2"
  shift 2
  # shellcheck disable=SC2016 # $1/${@:2} are the INNER bash -c's own positional
  # params, deliberately kept unexpanded by the outer shell.
  (cd "$dir" && env PATH="$BIN" bash -c 'source scripts/finish-lib.sh; "$1" "${@:2}"' _ "$fn" "$@")
}

trace_of() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  printf '%s/.copilot-tracking/issues/issue-%s/trace.jsonl' "$dir" "$pad"
}
progress_of() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  printf '%s/.copilot-tracking/issues/issue-%s/progress.md' "$dir" "$pad"
}
economics_span_count() {
  jq -nRr '[inputs|fromjson?|objects|select(.["gen_ai.tool.name"]=="finish-issue.economics")]|length' < "$1"
}
last_economics_span() {
  jq -nRr '[inputs|fromjson?|objects|select(.["gen_ai.tool.name"]=="finish-issue.economics")]|last // empty' < "$1"
}
jq_span() {
  jq -e "$2" >/dev/null <<< "$1"
}
block_has() {
  printf '%s\n' "$1" | grep -F -q -- "$2"
}

# ===========================================================================
# CASE BRACKET — direct stamp: in-window aggregation, out-of-window exclusion,
# model names in markdown, bracketing AIU delta, and exact numeric span keys.
# ===========================================================================
F_BR="${TMP_DIR}/bracket"
I_BR=41
make_git_fixture "$F_BR" "$I_BR"
plant_window_trace "$(trace_of "$F_BR" "$I_BR")" "$I_BR"
STATE_BR="${TMP_DIR}/state-bracket"
plant_events "$STATE_BR" "$SID" bracket

OUT_BR="$(run_stamp "$F_BR" "$I_BR" "$SID" "$STATE_BR" 2>/dev/null)"

# Markdown block: a clearly-labelled subagent-only native section.
block_has "$OUT_BR" '## Delivery economics (auto-stamped, trace-derived)' \
  || fail "BRACKET: the base trace-derived economics block must still be present"
if ! printf '%s\n' "$OUT_BR" | grep -Eqi 'native|subagent-only'; then
  fail "BRACKET: a native/subagent-only economics section must be rendered"
fi
# Subagent-only token total = 1000+2000+500 = 3500 (out-of-window 8888/9999 excluded).
block_has "$OUT_BR" '3500' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: subagent-only token total must be 3500 (in-window only)"; }
# Out-of-window tokens MUST NOT leak into the block.
if block_has "$OUT_BR" '8888' || block_has "$OUT_BR" '9999'; then
  printf '%s\n' "$OUT_BR"; fail "BRACKET: out-of-window subagent tokens (8888/9999) must be excluded"
fi
# Model NAMES appear in the markdown (operator-facing).
block_has "$OUT_BR" 'claude-sonnet-5' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: markdown must name model claude-sonnet-5"; }
block_has "$OUT_BR" 'claude-opus-4.8' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: markdown must name model claude-opus-4.8"; }
# Never an n/a tokens placeholder when real data exists.
if block_has "$OUT_BR" '- Tokens: n/a'; then
  printf '%s\n' "$OUT_BR"; fail "BRACKET: must never print a '- Tokens: n/a' placeholder"
fi
# Bracketing AIU delta = 180e9 - 100e9 = 80000000000 present in the block.
block_has "$OUT_BR" '80000000000' \
  || { printf '%s\n' "$OUT_BR"; fail "BRACKET: bracketing AIU delta 80000000000 must render"; }

TR_BR="$(trace_of "$F_BR" "$I_BR")"
[ "$(economics_span_count "$TR_BR")" = "1" ] \
  || fail "BRACKET: expected exactly one finish-issue.economics span"
SP_BR="$(last_economics_span "$TR_BR")"
jq_span "$SP_BR" '."harness.economics.native_subagent_tokens" == 3500 and (."harness.economics.native_subagent_tokens"|type=="number")' \
  || fail "BRACKET: native_subagent_tokens must be numeric 3500"
jq_span "$SP_BR" '."harness.economics.native_subagent_count" == 3 and (."harness.economics.native_subagent_count"|type=="number")' \
  || fail "BRACKET: native_subagent_count must be numeric 3"
jq_span "$SP_BR" '."harness.economics.native_tool_calls" == 10 and (."harness.economics.native_tool_calls"|type=="number")' \
  || fail "BRACKET: native_tool_calls must be numeric 10"
jq_span "$SP_BR" '."harness.economics.native_duration_ms" == 35000 and (."harness.economics.native_duration_ms"|type=="number")' \
  || fail "BRACKET: native_duration_ms must be numeric 35000"
jq_span "$SP_BR" '."harness.economics.native_models_distinct" == 2 and (."harness.economics.native_models_distinct"|type=="number")' \
  || fail "BRACKET: native_models_distinct must be numeric 2"
jq_span "$SP_BR" '."harness.economics.native_aiu_nano_delta" == 80000000000 and (."harness.economics.native_aiu_nano_delta"|type=="number")' \
  || fail "BRACKET: native_aiu_nano_delta must be numeric 80000000000"
# The span carries NO raw model-name string (numeric prefix stays numeric-only).
jq_span "$SP_BR" '[to_entries[] | select(.key|startswith("harness.economics.native_")) | .value | type] | all(. == "number")' \
  || fail "BRACKET: every harness.economics.native_* span value must be numeric"
# The consolidated checker must accept the resulting span's schema and types;
# unrelated feature-state findings in this focused fixture are ignored.
(cd "$F_BR" && env PATH="$BIN" ./scripts/check-trace-consistency.sh "$I_BR") \
  >"${TMP_DIR}/vt-br.out" 2>&1 || true
if grep -Eq 'schema_violation|type_violation|invalid_json|failure_mode_violation' \
    "${TMP_DIR}/vt-br.out"; then
  fail "BRACKET: consolidated checker rejected the native economics schema/types (out: $(tr '\n' '|' < "${TMP_DIR}/vt-br.out"))"
fi

# ===========================================================================
# CASE UNBRACKET — AIU omitted when no checkpoint moves inside the window,
# even though a baseline exists; subagent economics still present.
# ===========================================================================
F_UN="${TMP_DIR}/unbracket"
I_UN=42
make_git_fixture "$F_UN" "$I_UN"
plant_window_trace "$(trace_of "$F_UN" "$I_UN")" "$I_UN"
STATE_UN="${TMP_DIR}/state-unbracket"
plant_events "$STATE_UN" "$SID" unbracket

OUT_UN="$(run_stamp "$F_UN" "$I_UN" "$SID" "$STATE_UN" 2>/dev/null)"

block_has "$OUT_UN" '3500' \
  || { printf '%s\n' "$OUT_UN"; fail "UNBRACKET: subagent-only token total 3500 must still render"; }
# No AIU delta anywhere (no value, no 0, no n/a).
if block_has "$OUT_UN" '80000000000' || block_has "$OUT_UN" '50000000000'; then
  printf '%s\n' "$OUT_UN"; fail "UNBRACKET: no AIU delta may be printed when unbracketed"
fi
if printf '%s\n' "$OUT_UN" | grep -Eqi 'aiu'; then
  # An AIU LABEL with no bracket is the exact half-present field #329 forbids.
  printf '%s\n' "$OUT_UN"; fail "UNBRACKET: no AIU line may be rendered when the window is not bracketed"
fi
TR_UN="$(trace_of "$F_UN" "$I_UN")"
SP_UN="$(last_economics_span "$TR_UN")"
jq_span "$SP_UN" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "UNBRACKET: native_subagent_tokens must still be 3500"
jq_span "$SP_UN" 'has("harness.economics.native_aiu_nano_delta") == false' \
  || fail "UNBRACKET: native_aiu_nano_delta must be ABSENT (omit-never-zero) when unbracketed"

# ===========================================================================
# CASE INCOMPLETE — honesty of the field-presence policy: three good in-window
# subagents PLUS four in-window subagent.completed events each missing or
# wrong-typing a REQUIRED economics field (absent/empty model, string tokens,
# absent tool calls, null duration) but carrying huge otherwise-valid values.
# The honest policy aggregates a record ONLY when all four required fields are
# genuinely present with correct types, so every malformed record is EXCLUDED
# rather than mapped to an "unknown" model or a fabricated 0 — totals stay
# exactly the three good events' 3500 / 3 / 10 / 35000 / 2.
# ===========================================================================
F_IN="${TMP_DIR}/incomplete"
I_IN=45
make_git_fixture "$F_IN" "$I_IN"
plant_window_trace "$(trace_of "$F_IN" "$I_IN")" "$I_IN"
STATE_IN="${TMP_DIR}/state-incomplete"
plant_events "$STATE_IN" "$SID" incomplete

OUT_IN="$(run_stamp "$F_IN" "$I_IN" "$SID" "$STATE_IN" 2>/dev/null)"

block_has "$OUT_IN" '3500' \
  || { printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: subagent-only token total must stay 3500 (malformed records excluded)"; }
# No malformed record's corrupting value may leak into the block.
for corrupt in 777777 666666 555555 444444; do
  if block_has "$OUT_IN" "$corrupt"; then
    printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: malformed record value ${corrupt} must be excluded, not aggregated"
  fi
done
# A fabricated "unknown" model name must never appear (the old default).
if printf '%s\n' "$OUT_IN" | grep -Fq -- 'unknown'; then
  printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: absent/invalid model must be EXCLUDED, never mapped to 'unknown'"
fi
# A malformed record's partially-valid model name must not sneak into the models.
if block_has "$OUT_IN" 'claude-ghost-9'; then
  printf '%s\n' "$OUT_IN"; fail "INCOMPLETE: a record with one malformed required field must be excluded whole"
fi
TR_IN="$(trace_of "$F_IN" "$I_IN")"
SP_IN="$(last_economics_span "$TR_IN")"
jq_span "$SP_IN" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "INCOMPLETE: native_subagent_tokens must stay 3500 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_subagent_count" == 3' \
  || fail "INCOMPLETE: native_subagent_count must stay 3 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_tool_calls" == 10' \
  || fail "INCOMPLETE: native_tool_calls must stay 10 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_duration_ms" == 35000' \
  || fail "INCOMPLETE: native_duration_ms must stay 35000 (malformed excluded)"
jq_span "$SP_IN" '."harness.economics.native_models_distinct" == 2' \
  || fail "INCOMPLETE: native_models_distinct must stay 2 (malformed excluded)"

# ===========================================================================
# CASE ROLLBACK — AIU is cumulative: when the in-window checkpoint value has
# DECREASED below the baseline (a session reset/rollback), the delta is omitted
# entirely rather than emitting a negative or masked-zero value. The subagent
# economics still render.
# ===========================================================================
F_RB="${TMP_DIR}/rollback"
I_RB=46
make_git_fixture "$F_RB" "$I_RB"
plant_window_trace "$(trace_of "$F_RB" "$I_RB")" "$I_RB"
STATE_RB="${TMP_DIR}/state-rollback"
plant_events "$STATE_RB" "$SID" rollback

OUT_RB="$(run_stamp "$F_RB" "$I_RB" "$SID" "$STATE_RB" 2>/dev/null)"

block_has "$OUT_RB" '3500' \
  || { printf '%s\n' "$OUT_RB"; fail "ROLLBACK: subagent-only token total 3500 must still render"; }
# No AIU line and no delta value (positive, negative, or masked zero).
if printf '%s\n' "$OUT_RB" | grep -Eqi 'aiu'; then
  printf '%s\n' "$OUT_RB"; fail "ROLLBACK: no AIU line may render when the cumulative counter decreased"
fi
if block_has "$OUT_RB" '-80000000000' || block_has "$OUT_RB" '80000000000'; then
  printf '%s\n' "$OUT_RB"; fail "ROLLBACK: no AIU delta may be printed on a decreasing counter"
fi
TR_RB="$(trace_of "$F_RB" "$I_RB")"
SP_RB="$(last_economics_span "$TR_RB")"
jq_span "$SP_RB" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "ROLLBACK: native_subagent_tokens must still be 3500"
jq_span "$SP_RB" 'has("harness.economics.native_aiu_nano_delta") == false' \
  || fail "ROLLBACK: native_aiu_nano_delta must be ABSENT (omit-never-fake) on a decreasing counter"

# ===========================================================================
# CASE INJECT — security repair, fingerprint native-model-markdown-injection
# (failure_class validation-bypass). compute_native_economics honestly accepts
# any non-empty string model (field-presence honesty is about type/presence,
# not content sanity), so a hostile in-window subagent.completed record can
# carry a `model` containing CR, bare LF, and the literal
# <!-- delivery-economics:start/end --> marker text, or an adversarially long
# label. render_native_economics must still render a BOUNDED, SINGLE-LINE,
# marker-safe models line — never reproducing raw CR/LF/marker bytes verbatim —
# while compute_native_economics's numeric aggregates (which are grouped on the
# RAW model string, unaffected by rendering-time sanitization) stay honest: no
# fabricated totals, no dropped in-window subagent. Two full stamps are run to
# prove economics_stamp_into's line-based marker matching stays a single
# well-formed region even when the FIRST stamp's own rendered block is the
# hostile input under test.
# ===========================================================================
F_IJ="${TMP_DIR}/inject"
I_IJ=48
make_git_fixture "$F_IJ" "$I_IJ"
plant_window_trace "$(trace_of "$F_IJ" "$I_IJ")" "$I_IJ"
STATE_IJ="${TMP_DIR}/state-inject"
plant_events "$STATE_IJ" "$SID" inject

# --- Unit-level proof directly on the two pure helpers: the rendered native
# block must stay exactly 5 lines (the fixed template — no AIU line in this
# fixture) no matter how many raw newlines the hostile model label embeds.
WIN_IJ="$(run_fn "$F_IJ" native_economics_window "$(trace_of "$F_IJ" "$I_IJ")")"
NATIVE_JSON_IJ="$(run_fn "$F_IJ" compute_native_economics "${STATE_IJ}/${SID}/events.jsonl" "${WIN_IJ%% *}" "${WIN_IJ##* }")"
[ -n "$NATIVE_JSON_IJ" ] || fail "INJECT: compute_native_economics must still aggregate a well-typed-but-hostile record"
jq -e '.subagent_tokens == 7600 and .subagent_count == 5 and .tool_calls == 15 and .duration_ms == 76000 and (.models|length) == 4' \
  >/dev/null <<<"$NATIVE_JSON_IJ" \
  || { printf '%s\n' "$NATIVE_JSON_IJ"; fail "INJECT: hostile-but-well-typed records must still be honestly aggregated (7600/5/15/76000/4 models)"; }
NATIVE_BLOCK_IJ="$(run_fn "$F_IJ" render_native_economics "$NATIVE_JSON_IJ")"
NATIVE_LINES_IJ="$(printf '%s\n' "$NATIVE_BLOCK_IJ" | wc -l | tr -d ' ')"
[ "$NATIVE_LINES_IJ" = "5" ] \
  || { printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: render_native_economics must stay exactly 5 fixed lines (got ${NATIVE_LINES_IJ}); a hostile model label must never inject extra lines"; }
if printf '%s\n' "$NATIVE_BLOCK_IJ" | grep -Fxq -- '<!-- delivery-economics:end -->' \
  || printf '%s\n' "$NATIVE_BLOCK_IJ" | grep -Fxq -- '<!-- delivery-economics:start -->'; then
  printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: no rendered line may be byte-identical to a delivery-economics marker"
fi
if printf '%s\n' "$NATIVE_BLOCK_IJ" | grep -q $'\r'; then
  printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: rendered native block must never contain a raw CR byte"
fi
if block_has "$NATIVE_BLOCK_IJ" "$MODEL_LONG"; then
  printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: the full 300-char adversarial model label must never render verbatim (unbounded)"
fi
# An ordinary model label mixed into the same fixture must render unchanged.
block_has "$NATIVE_BLOCK_IJ" 'claude-sonnet-5' \
  || { printf '%s\n' "$NATIVE_BLOCK_IJ"; fail "INJECT: an ordinary model label must still render unchanged alongside hostile ones"; }

# --- Full end-to-end proof: run best_effort_economics_stamp TWICE against the
# same hostile fixture (the first stamp's own output is what could corrupt the
# marker region on the second, marker-replace-path stamp).
OUT_IJ1="$(run_stamp "$F_IJ" "$I_IJ" "$SID" "$STATE_IJ" 2>/dev/null)"
OUT_IJ2="$(run_stamp "$F_IJ" "$I_IJ" "$SID" "$STATE_IJ" 2>/dev/null)"
if printf '%s\n' "$OUT_IJ1$OUT_IJ2" | grep -q $'\r'; then
  fail "INJECT: neither stamp's stdout block may contain a raw CR byte"
fi
PROG_IJ="$(progress_of "$F_IJ" "$I_IJ")"
[ -f "$PROG_IJ" ] || fail "INJECT: progress.md must exist after two stamps"
START_CT_IJ="$(grep -Fxc -- '<!-- delivery-economics:start -->' "$PROG_IJ" || true)"
END_CT_IJ="$(grep -Fxc -- '<!-- delivery-economics:end -->' "$PROG_IJ" || true)"
[ "$START_CT_IJ" = "1" ] \
  || { cat -n "$PROG_IJ"; fail "INJECT: progress.md must carry exactly one start marker after two stamps (got ${START_CT_IJ})"; }
[ "$END_CT_IJ" = "1" ] \
  || { cat -n "$PROG_IJ"; fail "INJECT: progress.md must carry exactly one end marker after two stamps (got ${END_CT_IJ})"; }
# The single end marker must be the LAST line of the file — any corrupted
# leftover body content from a mis-matched marker replacement would land
# AFTER it, which the bare count check above cannot distinguish on its own.
END_LINE_IJ="$(grep -Fxn -- '<!-- delivery-economics:end -->' "$PROG_IJ" | tail -1 | cut -d: -f1)" || true
TOTAL_LINES_IJ="$(wc -l < "$PROG_IJ" | tr -d ' ')"
{ [ -n "$END_LINE_IJ" ] && [ "$END_LINE_IJ" = "$TOTAL_LINES_IJ" ]; } \
  || { cat -n "$PROG_IJ"; fail "INJECT: no content may trail the end marker (end marker at line ${END_LINE_IJ:-<none>} of ${TOTAL_LINES_IJ} total) — marker replacement must produce exactly one well-formed region"; }
grep -F -q '7600' "$PROG_IJ" \
  || { cat -n "$PROG_IJ"; fail "INJECT: the surviving progress.md must still carry the honest 7600 subagent token total"; }
if grep -F -q -- "$MODEL_LONG" "$PROG_IJ"; then
  fail "INJECT: the surviving progress.md must never carry the full unbounded adversarial model label"
fi
TR_IJ="$(trace_of "$F_IJ" "$I_IJ")"
[ "$(economics_span_count "$TR_IJ")" = "2" ] \
  || fail "INJECT: two stamps must emit exactly two finish-issue.economics spans"
SP_IJ="$(last_economics_span "$TR_IJ")"
jq_span "$SP_IJ" '."harness.economics.native_subagent_tokens" == 7600 and (."harness.economics.native_subagent_tokens"|type=="number")' \
  || fail "INJECT: native_subagent_tokens must stay honestly numeric 7600 (hostile records aggregated, never dropped)"
jq_span "$SP_IJ" '."harness.economics.native_models_distinct" == 4 and (."harness.economics.native_models_distinct"|type=="number")' \
  || fail "INJECT: native_models_distinct must stay honestly numeric 4 (raw cardinality unaffected by rendering-time sanitization)"

# ===========================================================================
# CASE ABSENT — fail-open: no session id -> no native block, no native_* keys,
# still exactly one economics span, and no n/a token placeholder.
# ===========================================================================
F_AB="${TMP_DIR}/absent"
I_AB=43
make_git_fixture "$F_AB" "$I_AB"
plant_window_trace "$(trace_of "$F_AB" "$I_AB")" "$I_AB"

OUT_AB="$(run_stamp "$F_AB" "$I_AB" 2>/dev/null)"

if printf '%s\n' "$OUT_AB" | grep -Eqi 'native|subagent-only'; then
  printf '%s\n' "$OUT_AB"; fail "ABSENT: no native economics section may render without a session"
fi
if block_has "$OUT_AB" '- Tokens: n/a'; then
  printf '%s\n' "$OUT_AB"; fail "ABSENT: must not emit a '- Tokens: n/a' placeholder"
fi
TR_AB="$(trace_of "$F_AB" "$I_AB")"
[ "$(economics_span_count "$TR_AB")" = "1" ] \
  || fail "ABSENT: exactly one finish-issue.economics span must still be emitted"
SP_AB="$(last_economics_span "$TR_AB")"
jq_span "$SP_AB" '[to_entries[] | select(.key|startswith("harness.economics.native_"))] | length == 0' \
  || fail "ABSENT: no harness.economics.native_* keys may be emitted when records are absent"

# ===========================================================================
# CASE E2E — a REAL finish-issue.sh closeout: the native block SURVIVES into the
# main-root progress.md, the span is present, validate-trace accepts, no n/a.
# ===========================================================================
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
export ABANDONED=1
F_E2E="${TMP_DIR}/e2e"
I_E2E=44
PAD_E2E="$(printf '%02d' "$I_E2E")"
copy_fixture_scripts "$F_E2E"
git -C "$F_E2E" init -q -b main
git -C "$F_E2E" config user.name "Harness Test"
git -C "$F_E2E" config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > "${F_E2E}/.gitignore"
printf 'fixture\n' > "${F_E2E}/README.md"
git -C "$F_E2E" add .gitignore README.md scripts docs
git -C "$F_E2E" commit -q -m initial
if ! start_out="$(cd "$F_E2E" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$I_E2E" SLUG=fixture 2>&1)"; then
  printf '%s\n' "$start_out"; hard_fail "E2E setup: start-issue failed"
fi
[ -d "${F_E2E}/.worktrees/issue-${PAD_E2E}" ] || hard_fail "E2E setup: worktree not created"
cat > "${F_E2E}/.worktrees/issue-${PAD_E2E}/.copilot-tracking/issues/issue-${PAD_E2E}/feature_list.json" <<JSON
{"features":[{"id":"native-record-economics-join","title":"native","steps":[],"passes":true,"verification":"done","teeth_proof":{"kind":"negative_fixture","evidence":"sensor"}}]}
JSON
# Overwrite the main-root trace with our fixed window (start-issue wrote its own
# current-timestamp spans); finish appends only the economics + finish spans,
# both AFTER the window is read, so the window stays [10:00, 12:00] on 2026-05-01.
plant_window_trace "$(trace_of "$F_E2E" "$I_E2E")" "$I_E2E"
STATE_E2E="${TMP_DIR}/state-e2e"
plant_events "$STATE_E2E" "$SID" bracket

rc=0
E2E_OUT="$(cd "$F_E2E" && env -u TRACE_ISSUE PATH="$BIN" FORCE=1 \
  COPILOT_AGENT_SESSION_ID="$SID" COPILOT_CLI_STATE_ROOT="$STATE_E2E" \
  ./scripts/finish-issue.sh "$I_E2E" SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$E2E_OUT"; fail "E2E: finish-issue.sh must exit 0"; }
if printf '%s\n' "$E2E_OUT" | grep -F -q -- '- Tokens: n/a'; then
  printf '%s\n' "$E2E_OUT"; fail "E2E: finish output must never print '- Tokens: n/a'"
fi
MAIN_PROG="$(progress_of "$F_E2E" "$I_E2E")"
[ -f "$MAIN_PROG" ] || fail "E2E: main-root progress.md must survive teardown (${MAIN_PROG})"
grep -Eqi 'native|subagent-only' "$MAIN_PROG" \
  || { echo "--- ${MAIN_PROG} ---"; cat "$MAIN_PROG" 2>/dev/null; fail "E2E: native economics section must survive in main-root progress.md"; }
grep -F -q '3500' "$MAIN_PROG" \
  || fail "E2E: surviving progress.md must carry the in-window subagent token total 3500"
grep -F -q 'claude-sonnet-5' "$MAIN_PROG" \
  || fail "E2E: surviving progress.md must name the subagent model"
TR_E2E="$(trace_of "$F_E2E" "$I_E2E")"
[ "$(economics_span_count "$TR_E2E")" = "1" ] \
  || fail "E2E: exactly one finish-issue.economics span must be present"
SP_E2E="$(last_economics_span "$TR_E2E")"
jq_span "$SP_E2E" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "E2E: span native_subagent_tokens must be 3500 after a real finish"
jq_span "$SP_E2E" '."harness.economics.native_aiu_nano_delta" == 80000000000' \
  || fail "E2E: span native_aiu_nano_delta must be 80000000000 after a real finish"
# NOTE: check-trace-consistency.sh is exercised on the BRACKET direct trace above; the
# minimal E2E fixture trace intentionally lacks the full lifecycle-step set, so
# its completeness check is out of scope for THIS feature's native-keys contract.

if [ "$fails" -ne 0 ]; then
  printf '%s failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'native economics join contract honored\n'
