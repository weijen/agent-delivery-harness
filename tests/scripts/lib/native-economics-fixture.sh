#!/usr/bin/env bash
# shellcheck disable=SC2034 # Public fixture globals are consumed by sourcing sensors.
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"

SCRATCH_ROOT="$FIXTURE_TMP_DIR"
TEMPLATE_REPO="$FIXTURE_REPO"
TMP_DIR="${SCRATCH_ROOT}/tmp"
BIN="${SCRATCH_ROOT}/bin"
mkdir -p "${TEMPLATE_REPO}/docs/evaluation"
cp "$SCHEMA" "${TEMPLATE_REPO}/docs/evaluation/trace-schema.v1.json"
[ -f "${ROOT}/VERSION" ] && cp "${ROOT}/VERSION" "${TEMPLATE_REPO}/VERSION"
git -C "$TEMPLATE_REPO" add docs VERSION 2>/dev/null || git -C "$TEMPLATE_REPO" add docs
git -C "$TEMPLATE_REPO" commit -q -m "add trace contract"

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
# Fixture scaffolding shared by economics and finish-closeout sensors.
# ---------------------------------------------------------------------------
copy_fixture_scripts() {
  local dir="$1"
  git clone -q "$TEMPLATE_REPO" "$dir"
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
}

# make_git_fixture <dir> <issue> — a git repo with a planted issue tracking dir
# (progress.md + feature_list.json), used for the DIRECT best_effort_economics_stamp
# cases. No worktree; main root == the repo itself.
make_git_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  copy_fixture_scripts "$dir"
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
